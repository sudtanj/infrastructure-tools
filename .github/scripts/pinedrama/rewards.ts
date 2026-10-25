// PineDrama's rewards page: open it from the coin tab in the middle of the
// bottom bar, check in, and press every "Klaim" (claim) button on it. Once the
// balance ("Poin Anda") reaches Rp500, exchange Rp500 to DANA with "Tukar".
//
// The page (SparkActivity) is a Lynx page: nothing on it is in the
// accessibility tree, so uiautomator and Playwright selectors see no text and
// no buttons. Unlike the video feed it is not FLAG_SECURE, so it is read from
// screenshots instead: its buttons are solid red pills, found by colour and
// read with OCR one at a time (OCR skips white text on red in a full page).
// Plain dialogs (the 18+ terms prompt, error toasts) are black text on white,
// read with a full-page OCR.
//
// Lynx ignores `input tap` (down and up in the same instant); a 150 ms press
// works.

import { execFile } from "node:child_process";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import type { AndroidDevice } from "playwright-core";
import { createWorker, PSM, type Worker } from "tesseract.js";

const PKG = "com.ss.android.ttmd.video";
const PAGE = "com.bytedance.hybrid.spark.page.SparkActivity";
// The coin tab, and the bottom bar holding it as a fallback (ids are obfuscated
// and can change with an app update).
const TAB_ID = "d9p";
const BAR_ID = "jui";
// Buttons that collect something. "Tonton" (watch) and "Mulai" (start, ads)
// begin tasks instead, so they are left alone.
const COLLECT = /check\s*in|klaim/i;
const ACCEPT = /^setuju$/i; // "Setuju dan lanjutkan": the 18+ terms prompt, accepted by the owner
const REFUSED = /salah|gagal/i; // "Ada sesuatu yang salah", "... gagal"
const MAX_PRESSES = 6;
// Exchanging: at most once per run, and only when the Tukar page offers both
// DANA and Rp500. Nothing is ever typed: if it asks to link DANA or for a
// number or code, that is left to the owner.
const REDEEM = process.env.REDEEM !== "0";
const REDEEM_AT = 500; // rupiah
const METHOD = /^dana$/i;
const AMOUNT = /^(rp)?500$/i;
const CONFIRM = /tukar|tarik|konfirmasi|lanjut/i;
const NEEDS_OWNER = /^(masukkan|otp|hubungkan|tautkan|sambungkan|verifikasi)$/i;
const RESULT = /berhasil|sukses|diproses|gagal|salah|tidak/i;
let redeemed = false;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), "rewards:", ...a);

type Box = { x: number; y: number; w: number; h: number };
type Word = { text: string; x: number; y: number; x0: number; x1: number };
type Shot = { w: number; h: number; px: Buffer };

async function shell(d: AndroidDevice, cmd: string): Promise<string> {
  return (await d.shell(cmd)).toString();
}

async function focused(d: AndroidDevice): Promise<string> {
  return shell(d, "dumpsys window | grep mCurrentFocus");
}

async function press(d: AndroidDevice, x: number, y: number) {
  await shell(d, `input swipe ${x} ${y} ${x + 1} ${y + 1} 150`);
}

// Absolute bounds of app:id/<id> in the app's `dumpsys activity top` tree.
async function viewBox(d: AndroidDevice, id: string): Promise<Box | undefined> {
  const out = await shell(d, "dumpsys activity top");
  const from = out.indexOf(`ACTIVITY ${PKG}/`);
  if (from < 0) return undefined;
  const stack: { ind: number; x: number; y: number; vis: boolean }[] = [];
  for (const line of out.slice(from).split("\n")) {
    const m = line.match(/^(\s*)\S+\{[0-9a-f]+ (\S)\S{8} \S{8} (-?\d+),(-?\d+)-(-?\d+),(-?\d+)(.*)\}/);
    if (!m) continue;
    const ind = m[1].length;
    while (stack.length && stack[stack.length - 1].ind >= ind) stack.pop();
    const p = stack[stack.length - 1] ?? { x: 0, y: 0, vis: true };
    const box = { x: p.x + +m[3], y: p.y + +m[4], w: +m[5] - +m[3], h: +m[6] - +m[4] };
    const vis = p.vis && m[2] === "V";
    stack.push({ ind, x: box.x, y: box.y, vis });
    if (vis && box.w > 0 && box.h > 0 && m[7].trim().endsWith(`app:id/${id}`)) return box;
  }
  return undefined;
}

// Raw RGBA screenshot (no PNG to decode).
async function screenshot(device: string): Promise<Shot> {
  const { stdout } = await promisify(execFile)("adb", ["-s", device, "exec-out", "screencap"], {
    encoding: "buffer",
    maxBuffer: 64 << 20,
  });
  const w = stdout.readUInt32LE(0), h = stdout.readUInt32LE(4);
  return { w, h, px: stdout.subarray(stdout.length - w * h * 4) };
}

// Grayscale PGM, which tesseract reads; inverted for white text on red.
function pgm(s: Shot, invert: boolean): Buffer {
  const out = Buffer.alloc(s.w * s.h);
  for (let i = 0; i < out.length; i++) {
    const l = (s.px[i * 4] * 299 + s.px[i * 4 + 1] * 587 + s.px[i * 4 + 2] * 114) / 1000;
    out[i] = invert ? 255 - l : l;
  }
  return Buffer.concat([Buffer.from(`P5\n${s.w} ${s.h}\n255\n`), out]);
}

// Solid red areas the size of a button, on a 4 px grid.
function redButtons(s: Shot): Box[] {
  const S = 4, gw = Math.ceil(s.w / S), gh = Math.ceil(s.h / S);
  const red = (gx: number, gy: number) => {
    const p = (gy * S * s.w + gx * S) * 4;
    return s.px[p] > 200 && s.px[p + 1] < 100 && s.px[p + 2] < 140;
  };
  const seen = new Uint8Array(gw * gh);
  const boxes: Box[] = [];
  for (let gy = 0; gy < gh; gy++)
    for (let gx = 0; gx < gw; gx++) {
      if (seen[gy * gw + gx] || !red(gx, gy)) continue;
      let x0 = gx, x1 = gx, y0 = gy, y1 = gy;
      const todo = [[gx, gy]];
      seen[gy * gw + gx] = 1;
      while (todo.length) {
        const [x, y] = todo.pop()!;
        x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
        for (const [nx, ny] of [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]])
          if (nx >= 0 && ny >= 0 && nx < gw && ny < gh && !seen[ny * gw + nx] && red(nx, ny)) {
            seen[ny * gw + nx] = 1;
            todo.push([nx, ny]);
          }
      }
      const b = { x: x0 * S, y: y0 * S, w: (x1 - x0 + 1) * S, h: (y1 - y0 + 1) * S };
      if (b.w >= 100 && b.w <= 600 && b.h >= 36 && b.h <= 120) boxes.push(b);
    }
  return boxes;
}

let worker: Worker | undefined;
async function ocr(): Promise<Worker> {
  return (worker ??= await createWorker("eng", undefined, { cachePath: tmpdir() }));
}

async function words(s: Shot): Promise<Word[]> {
  const w = await ocr();
  await w.setParameters({ tessedit_pageseg_mode: PSM.AUTO, user_defined_dpi: "320", debug_file: "/dev/null" });
  const { data } = await w.recognize(pgm(s, false), {}, { blocks: true });
  return (data.blocks ?? []).flatMap((b) =>
    b.paragraphs.flatMap((p) =>
      p.lines.flatMap((l) =>
        l.words.map((x) => ({
          text: x.text,
          x: (x.bbox.x0 + x.bbox.x1) >> 1,
          y: (x.bbox.y0 + x.bbox.y1) >> 1,
          x0: x.bbox.x0,
          x1: x.bbox.x1,
        })),
      ),
    ),
  );
}

async function buttons(s: Shot): Promise<{ label: string; x: number; y: number }[]> {
  const w = await ocr();
  await w.setParameters({ tessedit_pageseg_mode: PSM.SINGLE_LINE, user_defined_dpi: "320", debug_file: "/dev/null" });
  const img = pgm(s, true);
  const out = [];
  for (const b of redButtons(s)) {
    const { data } = await w.recognize(img, { rectangle: { left: b.x, top: b.y, width: b.w, height: b.h } });
    // Just the keyword: OCR adds stray characters from the rounded ends.
    const text = data.text.replace(/[^\p{L}\p{N} ]/gu, "").trim();
    const label = /check\s*in/i.test(text) ? "Check in" : /klaim/i.test(text) ? "Klaim" : text;
    out.push({ label, x: b.x + (b.w >> 1), y: b.y + (b.h >> 1) });
  }
  return out;
}

// The words on w's line, left to right; long digit runs (account or phone
// numbers) are hidden, since the log is public.
function lineOf(ws: Word[], w: Word): string {
  return ws
    .filter((x) => Math.abs(x.y - w.y) < 15)
    .sort((a, b) => a.x - b.x)
    .map((x) => x.text)
    .join(" ")
    .replace(/\d{6,}/g, "…");
}

// "Rp155" (or "Rp1.155", or split into several words by the wide font) on
// the Rp word's line, up to the "=" before the coin count. OCR can read the
// whole line as one word, and the "=" as anything ("Rp155-#4.667",
// "Rp1 55:-%4.667"): digits are read up to the first other character.
function rupiah(ws: Word[], rp: Word): number | undefined {
  let text = "", right = rp.x0;
  for (const w of ws.filter((x) => Math.abs(x.y - rp.y) < 20 && x.x0 >= rp.x0).sort((a, b) => a.x0 - b.x0)) {
    const t = w.text.match(/^(rp)?[\d.,]*/i)![0];
    if (w.x0 - right > 45 || (w !== rp && !/\d/.test(t))) break;
    text += t;
    right = w.x1;
    if (t !== w.text) break;
  }
  const n = text.replace(/^rp/i, "").split(",")[0].replace(/\./g, "");
  return /^\d+$/.test(n) ? Number(n) : undefined;
}

async function keyboardShown(d: AndroidDevice): Promise<boolean> {
  return (await shell(d, "dumpsys input_method | grep mInputShown")).includes("mInputShown=true");
}

// Exchanges Rp500 to DANA if the balance has it. On the rewards page.
async function redeem(d: AndroidDevice, device: string) {
  // The balance is near the top.
  for (let i = 0; i < 3; i++) {
    await shell(d, "input swipe 360 400 360 1100 300");
    await sleep(1_000);
  }
  await sleep(2_000);
  const ws = await words(await screenshot(device));
  const poin = ws.find((w) => /^poin$/i.test(w.text));
  const rp = poin && ws.find((w) => /^rp/i.test(w.text) && w.y > poin.y && w.y - poin.y < 120);
  const amount = rp && rupiah(ws, rp);
  if (!rp || amount === undefined) return log(`balance not found${rp ? ` (read "${lineOf(ws, rp)}")` : ""}`);
  log(`balance Rp${amount} (read "${lineOf(ws, rp)}")`);
  if (amount < REDEEM_AT) return;
  const tukar = ws.find((w) => /^tukar$/i.test(w.text) && Math.abs(w.y - rp.y) < 50);
  if (!tukar) return log('"Tukar" not found');
  log(`balance is at least Rp${REDEEM_AT}; opening Tukar`);
  await press(d, tukar.x, tukar.y);

  // A web page; it can take a while.
  let page: Word[] = [];
  for (let i = 0; i < 18 && !page.some((w) => METHOD.test(w.text)); i++) {
    await sleep(5_000);
    page = await words(await screenshot(device));
  }
  if (!page.some((w) => METHOD.test(w.text))) return log("the Tukar page did not load, or offers no DANA; not exchanging");
  for (const [name, re] of [["DANA", METHOD], ["Rp500", AMOUNT]] as const) {
    const w = page.find((x) => re.test(x.text.replace(/\s/g, "")));
    if (!w) return log(`the Tukar page offers no ${name}; not exchanging`);
    await press(d, w.x, w.y);
    await sleep(2_500);
    page = await words(await screenshot(device));
  }

  // Its button, then possibly a confirmation dialog's.
  let last: { label: string; y: number } | undefined;
  for (let i = 0; i < 2; i++) {
    const b = (await buttons(await screenshot(device))).find((x) => CONFIRM.test(x.label));
    if (!b) {
      if (!last) return log("no button to confirm the exchange; not exchanging");
      break;
    }
    // Still the same button: the first press was not accepted. Never press twice.
    if (last && last.label === b.label && Math.abs(last.y - b.y) < 40) break;
    log(`pressing "${b.label}"`);
    redeemed = true;
    await press(d, b.x, b.y);
    last = b;
    await sleep(3_000);
    const after = await words(await screenshot(device));
    if ((await keyboardShown(d)) || after.some((w) => NEEDS_OWNER.test(w.text)))
      return log("PineDrama asks for details (linking DANA, a number or a code); do that once by hand over VNC");
    const said = after.find((w) => RESULT.test(w.text));
    if (said) return log(`exchange: "${lineOf(after, said)}"`);
  }
  log("exchange sent; no answer seen");
}

async function waitFor(d: AndroidDevice, what: string, ms: number): Promise<boolean> {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(2_000)) if ((await focused(d)).includes(what)) return true;
  return false;
}

// Opens the rewards page from the feed, collects what it can, and goes back.
// Never throws: a failure here only skips the rewards.
export async function claimRewards(d: AndroidDevice, device: string): Promise<void> {
  try {
    // Right after a launch the feed (and its bottom bar) may still be loading.
    let tab: Box | undefined;
    for (let i = 0; i < 30 && !tab; i++) {
      tab = (await viewBox(d, TAB_ID)) ?? (await viewBox(d, BAR_ID));
      if (!tab) await sleep(2_000);
    }
    if (!tab) return log("coin tab not found; skipping");
    await shell(d, `input tap ${tab.x + (tab.w >> 1)} ${tab.y + (tab.h >> 1)}`);
    if (!(await waitFor(d, PAGE, 60_000))) return log("the rewards page did not open; skipping");
    await sleep(8_000); // the page loads its data after it shows
    // It reopens where it was last scrolled to; Check in is at the top.
    for (let i = 0; i < 3; i++) {
      await shell(d, "input swipe 360 400 360 1100 300");
      await sleep(1_000);
    }
    // Just after the app starts, the page shows before its buttons do.
    for (let i = 0; i < 6; i++) {
      await sleep(5_000);
      const s = await screenshot(device);
      if (redButtons(s).length || (await words(s)).some((w) => ACCEPT.test(w.text))) break;
    }

    let presses = 0, scrolls = 0, accepts = 0;
    const tried = new Set<string>();
    // A refusal ("something went wrong") comes from the server, so another
    // button with the same label would be refused too.
    const refused = new Set<string>();
    while (presses < MAX_PRESSES) {
      const s = await screenshot(device);
      const accept = (await words(s)).find((w) => ACCEPT.test(w.text));
      if (accept && accepts < 2) {
        log("accepting the 18+ terms prompt");
        accepts++;
        await press(d, accept.x, accept.y);
        await sleep(5_000);
        continue;
      }
      const target = (await buttons(s)).find(
        (b) => COLLECT.test(b.label) && !refused.has(b.label) && !tried.has(`${scrolls}:${b.label}:${b.y}`),
      );
      if (!target) {
        // Nothing (more) to collect here; look further down the page once or twice.
        if (scrolls >= 2) break;
        await shell(d, "input swipe 360 1000 360 400 600");
        scrolls++;
        await sleep(3_000);
        continue;
      }
      tried.add(`${scrolls}:${target.label}:${target.y}`);
      presses++;
      await press(d, target.x, target.y);
      // The answer is a toast for about 2 s, or the button changing.
      await sleep(2_000);
      const after = await words(await screenshot(device));
      const bad = after.find((w) => REFUSED.test(w.text));
      const said = bad ? ` ("${lineOf(after, bad)}")` : "";
      // Collected only if the button is gone (or relabelled) once the page settles.
      await sleep(4_000);
      const still = (await buttons(await screenshot(device))).some(
        (b) => b.label === target.label && Math.abs(b.y - target.y) < 40,
      );
      if (still) {
        refused.add(target.label);
        log(`"${target.label}": not accepted${said}`);
      } else log(`"${target.label}": claimed${said}`);
    }
    if (presses === 0) log("nothing to check in or claim");
    if (REDEEM && !redeemed) await redeem(d, device);
  } catch (e) {
    log("failed:", String(e).slice(0, 300));
  } finally {
    await worker?.terminate().catch(() => {});
    worker = undefined;
    // Back to the feed (from the Tukar page too).
    for (let i = 0; i < 4 && (await focused(d).catch(() => "")).includes(PAGE); i++) {
      await shell(d, "input keyevent KEYCODE_BACK").catch(() => {});
      await sleep(3_000);
    }
  }
}
