// Firsty Free on the emulator: watches rewarded ads ("Watch ad +20 MB") until
// the free data reaches Firsty's 240 MB holding cap, the 18-ads-a-day limit
// stops crediting, or no ad loads. Earned data lasts 7 days, so topping up on
// each scheduled run (05:00, 07:00, 17:00 WIB) keeps it full; the 360 MB/day
// maximum is only reachable when the data is being used in between.
//
//   node firsty.ts      (Node 23.6+; needs adb, no modules)
//
// Env: DEVICE (default android-emulator:5555; emulator-5554 on the runner).
//
// Accepts Firsty's ad-consent prompt (the owner asked for that, 2026-11-08);
// answers nothing else on the owner's behalf.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { alert, LOGIN_ACTIVITY, LOGIN_LABEL } from "../android-alert.ts";

const PKG = "com.firsty.app";
const DEVICE = process.env.DEVICE ?? "android-emulator:5555";
const CAP_MB = 240; // Firsty: "a maximum of 240 MB of unused data at a time"
const PER_AD_MB = 20;
const MAX_ADS = 18; // per day
const AD_MS = 150_000; // one ad, from tap to back in the app
// Today's credited ads, kept on the device (saved with the AVD): "YYYY-MM-DD N"
// plus " done" once the daily limit stopped crediting. The app shows neither.
// ponytail: the day is WIB; if Firsty resets at another hour, a run between
// the two midnights is skipped or tries in vain (two ads, a minute or two).
const DAY_FILE = "/data/local/tmp/firsty-day";
const today = () => new Date(Date.now() + 7 * 3600_000).toISOString().slice(0, 10);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);

type Node = { text: string; x: number; y: number; x1: number };

async function adb(...args: string[]): Promise<string> {
  const { stdout } = await promisify(execFile)("adb", ["-s", DEVICE, ...args], { maxBuffer: 16 << 20 });
  return stdout;
}
const shell = (cmd: string) => adb("shell", cmd);
const focused = () => shell("dumpsys window | grep mCurrentFocus").catch(() => "");
const inApp = async () => /com\.firsty\.app\/\S*MainActivity/.test(await focused());

async function screen(): Promise<Node[]> {
  const xml = await shell("rm -f /sdcard/firsty.xml; uiautomator dump /sdcard/firsty.xml >/dev/null 2>&1 && cat /sdcard/firsty.xml").catch(() => "");
  const nodes: Node[] = [];
  for (const [tag] of xml.matchAll(/<node [^>]*>/g)) {
    const attr = (name: string) => tag.match(new RegExp(` ${name}="([^"]*)"`))?.[1] ?? "";
    const b = attr("bounds").match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!b) continue;
    const [x0, y0, x1, y1] = b.slice(1).map(Number);
    const text = (attr("text") || attr("content-desc")).replace(/&#10;/g, "\n").trim();
    if (text) nodes.push({ text, x: (x0 + x1) >> 1, y: (y0 + y1) >> 1, x1 });
  }
  return nodes;
}

// Fresh unless `front`, which only brings it back.
const launch = async (front = false) => {
  if (!front) await shell(`am force-stop ${PKG}`);
  await shell(`am start -n $(cmd package resolve-activity --brief ${PKG} | tail -1)`);
};
const tap = (n: Node) => shell(`input tap ${n.x} ${n.y}`);
// The home screen's big balance: "20 MB" (or "1.2 GB").
function balance(nodes: Node[]): number | undefined {
  for (const n of nodes) {
    const m = n.text.match(/^(\d+(?:[.,]\d+)?)\s*(MB|GB)$/);
    if (m) return parseFloat(m[1].replace(",", ".")) * (m[2] === "GB" ? 1024 : 1);
  }
}
const CONSENT = /asks for your consent|^Consent$|Manage options/;
// Taps "Consent" on the ad-consent prompt: true if tapped, false if no prompt,
// undefined (after alerting) if the prompt has no Consent button.
async function consent(nodes: Node[]): Promise<boolean | undefined> {
  if (!nodes.some((n) => CONSENT.test(n.text))) return false;
  const button = nodes.find((n) => n.text === "Consent");
  if (button) return tap(button).then(() => true);
  alert("Firsty's ad-consent prompt has no Consent button; answer it over VNC.");
}
// Ad close/skip controls (AdMob and others; English and Indonesian).
const CLOSE = /^(close|close ad|interstitial close button|skip|skip ad|skip video|lewati|tutup|x|×)$/i;
// AdMob's "Reward granted ×" pill: the × is an unlabelled image right of the text.
const GRANTED = /^(reward granted|hadiah diberikan)$/i;

// "<app> isn't responding": the launcher's keeps coming back after a cold
// boot while Wait is pressed, so close that one (it restarts); wait for others.
async function clearAnr(nodes: Node[]): Promise<boolean> {
  const title = nodes.find((n) => n.text.endsWith("isn't responding"));
  const button = title && nodes.find((n) => n.text === (title.text.includes("Launcher") ? "Close app" : "Wait"));
  if (button) await tap(button);
  return !!button;
}

// The home screen with its balance, or undefined after alerting.
// The app hides "Watch ad" until an ad has loaded, which can take minutes, and
// (likely) once the day's ads are used up: neither is worth an alert.
async function home(): Promise<{ mb: number; nodes: Node[] } | undefined> {
  let mb: number | undefined;
  let relaunched = false;
  for (const end = Date.now() + 300_000; Date.now() < end; await sleep(3_000)) {
    const nodes = await screen();
    const c = await consent(nodes);
    if (c === undefined) return;
    if (c) continue;
    if (LOGIN_ACTIVITY.test(await focused()) || nodes.some((n) => LOGIN_LABEL.test(n.text))) {
      alert("Firsty is logged out; log in again over VNC.");
      return;
    }
    if (await clearAnr(nodes)) continue;
    mb = balance(nodes);
    if (mb !== undefined && nodes.some((n) => n.text.startsWith("Watch ad"))) return { mb, nodes };
    // Halfway with the balance but no button: a fresh start reloads the ad.
    if (mb !== undefined && !relaunched && end - Date.now() < 150_000) {
      await launch(), (relaunched = true);
      continue;
    }
    // Another tab: back to Data. Out of the app (an ad left it): reopen it.
    // No Back while it loads; that closes it.
    const data = mb === undefined && nodes.find((n) => n.text === "Data");
    if (data) await tap(data);
    else if (!(await inApp())) await launch(true);
  }
  if (mb !== undefined) return log(`${mb} MB, but no ad offered for 5 min (none loading, or today's limit reached)`);
  log("on screen:", await focused(), JSON.stringify((await screen()).map((n) => n.text).slice(0, 30)));
  alert('Firsty: the "Watch ad" button did not show, so no free data was collected.');
}

// One ad: tap "Watch ad", wait for it to play, close it once it allows.
// True if it got back to the app; undefined at an unanswerable consent prompt.
async function watch(nodes: Node[]): Promise<boolean | undefined> {
  await tap(nodes.find((n) => n.text.startsWith("Watch ad"))!);
  const start = Date.now();
  let left = false;
  for (; Date.now() - start < AD_MS; await sleep(5_000)) {
    const app = await inApp();
    const now = await screen();
    const c = await consent(now);
    if (c === undefined) return;
    if (c) continue;
    // Still on the app's own screen (the button hides while the ad loads): not started yet.
    if (app && !left) {
      if (Date.now() - start > 45_000) return true; // no ad loaded
      continue;
    }
    left = true;
    if (app && now.some((n) => balance([n]) !== undefined)) return true;
    // Rewarded ads only offer a close control once the reward is earned.
    const granted = now.find((n) => GRANTED.test(n.text));
    const close = now.find((n) => CLOSE.test(n.text)) ?? (granted && { ...granted, x: granted.x1 + 35 });
    if (close) await tap(close);
    // An ad may open the store or a browser; never act there, just go back.
    else if (!/com\.firsty\.app/.test(await focused()) || Date.now() - start > 40_000) {
      await shell("input keyevent KEYCODE_BACK");
    }
  }
  return inApp();
}

async function main() {
  if (DEVICE.includes(":")) await promisify(execFile)("adb", ["connect", DEVICE]);
  await shell("input keyevent KEYCODE_WAKEUP");
  await shell("am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS");
  const [day, n, done] = (await shell(`cat ${DAY_FILE} 2>/dev/null`).catch(() => "")).trim().split(" ");
  let ads = day === today() ? Number(n) || 0 : 0;
  if (day === today() && (done || ads >= MAX_ADS)) {
    log(`daily ad limit already reached (${ads} ads today); nothing to collect until tomorrow`);
    return;
  }
  const save = (full = false) => shell(`echo '${today()} ${ads}${full ? " done" : ""}' > ${DAY_FILE}`);
  try {
    await launch();
    let h = await home();
    if (!h) return;
    const before = h.mb;
    if (h.mb + PER_AD_MB > CAP_MB) log(`${h.mb} MB is at the ${CAP_MB} MB cap; nothing to collect`);
    let stalls = 0;
    while (ads < MAX_ADS && h.mb + PER_AD_MB <= CAP_MB) {
      const ok = await watch(h.nodes);
      if (ok === undefined) break;
      if (!ok) await launch(); // lost in an ad: start over
      await sleep(4_000);
      const mb = h.mb;
      h = await home();
      if (!h) return;
      if (h.mb > mb) {
        ads++, (stalls = 0);
        log(`ad ${ads}: ${h.mb} MB`);
        await save();
      } else if (++stalls >= 2) {
        log("no data credited twice; the daily limit is reached or no ads are available");
        await save(ads > 0); // none at all today may just be no ads loading
        break;
      }
    }
    log(`free data ${before} MB -> ${h.mb} MB`);
  } finally {
    await shell("input keyevent KEYCODE_HOME").catch(() => {});
    await shell(`am force-stop ${PKG}`).catch(() => {});
  }
}

main().then(() => process.exit(0), (e) => {
  console.error(e);
  process.exit(1);
});
