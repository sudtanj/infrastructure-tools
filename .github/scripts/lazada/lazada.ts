// Lazada's daily coin check-in on the Redroid device: taps "Ambil Koin" on the
// home screen, then "Check-in" on the LazCoins page (+1 coin and more on a
// streak). Once done the button reads "Dapatkan lebih", so running it more
// than once a day is harmless. Logs only why it stopped early.
//
//   node lazada.ts      (Node 23.6+; needs adb, no modules)
//
// Env: DEVICE (default android-redroid:5555; 127.0.0.1:5555 on the runner).
//
// The LazCoins page is a WebView with no accessibility tree, so the button is
// found through the WebView's DevTools socket (reading the page only); the
// press itself is a real tap.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { alert, LOGIN_ACTIVITY, LOGIN_LABEL } from "../android-alert.ts";

const PKG = "com.lazada.android";
const DEVICE = process.env.DEVICE ?? "android-redroid:5555";
const WAIT_MS = 120_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);

type Node = { id: string; text: string; x: number; y: number; x0: number; y0: number; w: number; h: number };

async function adb(...args: string[]): Promise<string> {
  const { stdout } = await promisify(execFile)("adb", ["-s", DEVICE, ...args], { maxBuffer: 16 << 20 });
  return stdout;
}
const shell = (cmd: string) => adb("shell", cmd);
const focused = () => shell("dumpsys window | grep mCurrentFocus").catch(() => "");

async function screen(): Promise<Node[]> {
  const xml = await shell("rm -f /sdcard/lazada.xml; uiautomator dump /sdcard/lazada.xml >/dev/null 2>&1 && cat /sdcard/lazada.xml").catch(() => "");
  const nodes: Node[] = [];
  for (const [tag] of xml.matchAll(/<node [^>]*>/g)) {
    const attr = (name: string) => tag.match(new RegExp(` ${name}="([^"]*)"`))?.[1] ?? "";
    const b = attr("bounds").match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!b) continue;
    const [x0, y0, x1, y1] = b.slice(1).map(Number);
    nodes.push({ id: attr("resource-id"), text: attr("text") || attr("content-desc"), x: (x0 + x1) >> 1, y: (y0 + y1) >> 1, x0, y0, w: x1 - x0, h: y1 - y0 });
  }
  return nodes;
}

// An "isn't responding" dialog or a permission prompt (denied; never granted
// on the owner's behalf). True if something was cleared.
async function clearInterruptions(nodes: Node[]): Promise<boolean> {
  const n = nodes.find((n) => /:id\/(aerr_wait|permission_deny_button)$/.test(n.id));
  if (n) await shell(`input tap ${n.x} ${n.y}`);
  return !!n;
}

async function loggedOut(nodes: Node[]): Promise<boolean> {
  return LOGIN_ACTIVITY.test(await focused()) || nodes.some((n) => LOGIN_LABEL.test(n.text.trim()));
}

// Home screen: the "Ambil Koin" tile (two labels, "Ambil" over "Koin").
async function openCoins(): Promise<boolean> {
  for (const end = Date.now() + WAIT_MS; Date.now() < end; ) {
    const nodes = await screen();
    const ambil = nodes.find((n) => n.text === "Ambil" && nodes.some((k) => k.text === "Koin" && Math.abs(k.x - n.x) < 80));
    if (ambil) {
      await shell(`input tap ${ambil.x} ${ambil.y}`);
      return true;
    }
    if (await loggedOut(nodes)) {
      alert("Lazada is logged out; log in again over VNC in a Redroid session.");
      return false;
    }
    if (!(await clearInterruptions(nodes))) await sleep(3_000);
  }
  alert('Lazada: "Ambil Koin" did not show on the home screen, so today\'s check-in was not done.');
  return false;
}

// Evaluates JS in the LazCoins page through the WebView's DevTools socket.
async function page(): Promise<(expr: string) => Promise<any>> {
  const pid = (await shell(`pidof ${PKG}`)).trim().split(/\s+/)[0];
  const sock = `webview_devtools_remote_${pid}`;
  const port = (await adb("forward", "tcp:0", `localabstract:${sock}`)).trim();
  const pages: any[] = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const target = pages.find((p) => p.title === "LazCoins") ?? pages.find((p) => p.type === "page");
  if (!target) throw new Error("no LazCoins page");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  let id = 0;
  const pending = new Map<number, (v: any) => void>();
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    // Only replies to our own numbered requests; events and unknown ids are ignored.
    const resolve = typeof m.id === "number" ? pending.get(m.id) : undefined;
    if (typeof resolve !== "function") return;
    pending.delete(m.id);
    resolve(m.result?.result?.value);
  };
  return (expression) =>
    new Promise((resolve) => {
      pending.set(++id, resolve);
      ws.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
    });
}

// The check-in button's label ("Check-in", then "Dapatkan lebih") and centre
// in CSS pixels, once rendered.
const BUTTON = `(() => { const b = document.querySelector(".lazcoins-check-in-date-button");
  if (!b) return null; const r = b.getBoundingClientRect();
  return { text: b.innerText.trim(), x: r.x + r.width / 2, y: r.y + r.height / 2, dpr: devicePixelRatio }; })()`;
// Unanchored: the label is a carousel, so it may hold "Check-in" twice.
const CHECK_IN = /check-?\s?in/i;

async function button(evaluate: (e: string) => Promise<any>) {
  for (const end = Date.now() + 60_000; Date.now() < end; await sleep(2_000)) {
    const b = await evaluate(BUTTON).catch(() => null);
    if (b?.text) return b;
  }
  return null;
}

// One dump can fail (uiautomator wants an idle screen, and the page animates)
// or a dialog can cover it, so retry for a while.
async function webView(): Promise<Node | undefined> {
  let nodes: Node[] = [];
  for (const end = Date.now() + 30_000; Date.now() < end; await sleep(2_000)) {
    nodes = await screen();
    const web = nodes.find((n) => n.id.endsWith(":id/lazada_windvane_webview"));
    if (web) return web;
    // An expired session puts the login screen over the LazCoins page.
    if (await loggedOut(nodes)) return void alert("Lazada is logged out; log in again over VNC in a Redroid session.");
    await clearInterruptions(nodes);
  }
  alert("Lazada: the LazCoins page's WebView was not found.");
  log("no WebView on screen;", (await focused()).trim(), [...new Set(nodes.map((n) => n.id.split("/")[1]).filter(Boolean))].slice(0, 15).join(" "));
}

async function checkIn(): Promise<void> {
  let evaluate: ((e: string) => Promise<any>) | undefined;
  for (const end = Date.now() + 60_000; !evaluate && Date.now() < end; ) {
    evaluate = await page().catch(() => undefined);
    if (!evaluate) await sleep(3_000);
  }
  if (!evaluate) return alert("Lazada: the LazCoins page did not open, so today's check-in was not done.");
  // Up to three presses; the page is reloaded after each to see what the
  // server recorded (it doesn't always redraw by itself).
  for (let i = 0; i < 3; i++) {
    const b = await button(evaluate);
    if (!b) return alert("Lazada: the check-in button did not show on the LazCoins page.");
    if (!CHECK_IN.test(b.text)) {
      log(i ? "checked in" : "already checked in today");
      return; // already checked in today
    }
    const web = await webView();
    if (!web) return;
    // A short press: the page ignores some instant taps.
    const x = Math.round(web.x0 + b.x * b.dpr), y = Math.round(web.y0 + b.y * b.dpr);
    await shell(`input swipe ${x} ${y} ${x} ${y} 150`);
    await sleep(6_000);
    await evaluate("location.reload(), 1");
    await sleep(8_000);
  }
  alert('Lazada: "Check-in" was pressed but the page did not take it; today\'s check-in may not be done.');
}

async function main() {
  if (DEVICE.includes(":")) await promisify(execFile)("adb", ["connect", DEVICE]);
  await shell("input keyevent KEYCODE_WAKEUP");
  await shell("am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS");
  try {
    await shell(`am force-stop ${PKG}`);
    // Not monkey: it refuses to run on Redroid ("SYS_KEYS has no physical keys").
    await shell(`am start -n $(cmd package resolve-activity --brief ${PKG} | tail -1)`);
    if (await openCoins()) await checkIn();
  } finally {
    await adb("forward", "--remove-all").catch(() => {});
    await shell("input keyevent KEYCODE_HOME").catch(() => {});
    await shell(`am force-stop ${PKG}`).catch(() => {});
  }
}

main().then(() => process.exit(0), (e) => {
  console.error(e);
  process.exit(1);
});
