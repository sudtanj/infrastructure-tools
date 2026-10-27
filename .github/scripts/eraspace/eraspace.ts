// Plays EraSpace's "Luncurkan Roket" (launch the rocket) on the emulator:
// opens it from the rocket badge on the home screen, presses "Mulai Bermain",
// then "Luncurkan" until the app says "Kamu Perlu Token Bermain" (no tokens
// left: one free launch a day, more from purchases). Logs only why it stopped
// early.
//
//   node eraspace.ts      (Node 23.6+; needs adb, no modules)
//
// Env: DEVICE (default 100.113.219.108:5555; emulator-5554 on the runner),
// MAX_LAUNCHES (default 10).
//
// Unlike PineDrama, every screen here is in the accessibility tree, so it is
// read with `uiautomator dump` and buttons are found by their resource ids.
//
// At the emulator's 320 dpi (360x528 dp) the game page squeezes "Mulai
// Bermain" to zero height between two other sections, so the density is
// lowered while it runs and restored afterwards.
//
// Location is denied for the app (never granted on the owner's behalf), so on
// every launch it opens its App info page in Settings; Back returns to it.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const PKG = "com.eraspace.app";
const DEVICE = process.env.DEVICE ?? "100.113.219.108:5555";
const MAX_LAUNCHES = Number(process.env.MAX_LAUNCHES ?? 10);
const DENSITY = 240;
// Arm64-only apps are translated on the x86_64 emulator; screens are slow.
const WAIT_MS = 90_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);

type Node = { id: string; text: string; desc: string; x: number; y: number; w: number; h: number };

async function adb(...args: string[]): Promise<string> {
  const { stdout } = await promisify(execFile)("adb", ["-s", DEVICE, ...args], { maxBuffer: 16 << 20 });
  return stdout;
}

const shell = (cmd: string) => adb("shell", cmd);

async function focused(): Promise<string> {
  return shell("dumpsys window | grep mCurrentFocus");
}

const unescape = (s: string) =>
  s.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

// The visible screen's nodes. uiautomator can fail while an animation runs;
// an empty list then.
async function screen(): Promise<Node[]> {
  const xml = await shell("uiautomator dump /sdcard/eraspace.xml >/dev/null 2>&1 && cat /sdcard/eraspace.xml").catch(() => "");
  const nodes: Node[] = [];
  for (const [tag] of xml.matchAll(/<node [^>]*>/g)) {
    const attr = (name: string) => unescape(tag.match(new RegExp(` ${name}="([^"]*)"`))?.[1] ?? "");
    const b = attr("bounds").match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
    if (!b) continue;
    const [x0, y0, x1, y1] = b.slice(1).map(Number);
    nodes.push({ id: attr("resource-id"), text: attr("text"), desc: attr("content-desc"), x: (x0 + x1) >> 1, y: (y0 + y1) >> 1, w: x1 - x0, h: y1 - y0 });
  }
  return nodes;
}

// By resource id without its package ("btnLaunch" for com.eraspace.app.home:id/btnLaunch).
const byId = (nodes: Node[], id: string) => nodes.find((n) => n.id.endsWith(`:id/${id}`) && n.w > 0 && n.h > 0);

async function tap(n: Node) {
  await shell(`input tap ${n.x} ${n.y}`);
}

// Clears what can cover the app: its App info page, the location prompt, a
// marketing pop-up, the "leave the app?" prompt. True if something was cleared.
async function clearInterruptions(nodes: Node[]): Promise<boolean> {
  const f = await focused();
  if (f.includes("com.android.settings/")) {
    await shell("input keyevent KEYCODE_BACK");
    return true;
  }
  const deny = byId(nodes, "permission_deny_button");
  if (deny) {
    await tap(deny);
    return true;
  }
  const close = byId(nodes, "mcsdk_iam_close");
  if (close) {
    await tap(close);
    return true;
  }
  const stay = byId(nodes, "btnNegative");
  if (stay && /tidak/i.test(stay.text)) {
    await tap(stay);
    return true;
  }
  return false;
}

// Waits for the first of `ids` to show, clearing interruptions meanwhile.
async function waitFor(ids: string[], ms = WAIT_MS): Promise<{ id: string; node: Node; nodes: Node[] } | undefined> {
  for (const end = Date.now() + ms; Date.now() < end; ) {
    const nodes = await screen();
    for (const id of ids) {
      const node = byId(nodes, id);
      if (node) return { id, node, nodes };
    }
    if (!(await clearInterruptions(nodes))) await sleep(2_000);
    else await sleep(3_000);
  }
  return undefined;
}

let originalDensity: string | undefined;

async function restoreDensity() {
  if (originalDensity === undefined) return;
  await shell(originalDensity ? `wm density ${originalDensity}` : "wm density reset").catch(() => {});
  originalDensity = undefined;
}

async function play(): Promise<void> {
  const home = await waitFor(["fabGamification"]);
  if (!home) return log("the rocket badge did not show on the home screen; skipping");
  await tap(home.node);

  const landing = await waitFor(["btnStartPlay", "btnLaunch"]);
  if (!landing) return log('"Mulai Bermain" did not show; skipping');
  if (landing.id === "btnStartPlay") await tap(landing.node);

  let launches = 0;
  while (launches < MAX_LAUNCHES) {
    const game = await waitFor(["btnLaunch"]);
    if (!game) return log('"Luncurkan" did not show; stopping');
    await tap(game.node);
    // Either a prize ("100 Poin", with "Luncurkan Lagi") or a dialog.
    const answer = await waitFor(["tvPointReward", "tvTitle"], 60_000);
    if (!answer) return log("no answer to the launch; stopping");
    if (answer.id === "tvTitle") {
      const ok = byId(answer.nodes, "btnSuccess");
      if (ok) await tap(ok);
      break;
    }
    launches++;
    const again = byId(answer.nodes, "btnLaunchRocket");
    if (again) await tap(again);
  }
  // Let the last result settle before the app is closed.
  await sleep(3_000);
}

async function main() {
  // host:port is a network device; a local emulator needs no connect.
  if (DEVICE.includes(":")) await promisify(execFile)("adb", ["connect", DEVICE]);
  const stop = async () => {
    await restoreDensity();
    process.exit(1);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  await shell("input keyevent KEYCODE_WAKEUP");
  await shell("am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS");
  // "Physical density: 320" and, if set, "Override density: 280".
  originalDensity = (await shell("wm density")).match(/Override density: (\d+)/)?.[1] ?? "";
  try {
    await shell(`wm density ${DENSITY}`);
    // A fresh start, so it lays out at the new density.
    await shell(`am force-stop ${PKG}`);
    await shell(`monkey -p ${PKG} -c android.intent.category.LAUNCHER 1`);
    await play();
  } finally {
    await shell("input keyevent KEYCODE_HOME").catch(() => {});
    await shell(`am force-stop ${PKG}`).catch(() => {});
    await restoreDensity();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
