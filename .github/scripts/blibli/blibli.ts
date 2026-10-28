// Blibli's daily check-in on the emulator: opens the "Main Terus Untung
// Terus" page (a 7-day streak, +5 to +200 points) and presses "Check in".
// The points are credited on the press; there is nothing else to claim (the
// page's missions need purchases). Once done the button reads "Come back
// tomorrow", so running it more than once a day is harmless. Logs only why it
// stopped early.
//
//   node blibli.ts      (Node 23.6+; needs adb, no modules)
//
// Env: DEVICE (default 100.113.219.108:5555; emulator-5554 on the runner).
//
// The page is opened by its link rather than from the home screen, whose
// carousels keep `uiautomator dump` from ever seeing an idle screen.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { alert, LOGIN_ACTIVITY, LOGIN_LABEL } from "../android-alert.ts";

const PKG = "blibli.mobile.commerce";
const CHECK_IN_URL = "https://www.blibli.com/promosi/zona-cuan";
const DEVICE = process.env.DEVICE ?? "100.113.219.108:5555";
// Cold starts on the emulator are slow.
const WAIT_MS = 120_000;

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

// The visible screen's nodes; an empty list while uiautomator finds no idle
// moment. The old dump is removed first so a failed one is not read again.
async function screen(): Promise<Node[]> {
  const xml = await shell("rm -f /sdcard/blibli.xml; uiautomator dump /sdcard/blibli.xml >/dev/null 2>&1 && cat /sdcard/blibli.xml").catch(() => "");
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

// By resource id without its package ("bt_text" for blibli.mobile.commerce:id/bt_text).
const byId = (nodes: Node[], id: string) => nodes.find((n) => n.id.endsWith(`:id/${id}`) && n.w > 0 && n.h > 0);

async function tap(n: Node) {
  await shell(`input tap ${n.x} ${n.y}`);
}

// Clears what can cover the app: an "isn't responding" dialog (the launcher
// hangs for a while after a cold boot), a permission prompt (denied; never
// granted on the owner's behalf). True if something was cleared.
async function clearInterruptions(nodes: Node[]): Promise<boolean> {
  const wait = byId(nodes, "aerr_wait");
  if (wait) {
    await tap(wait);
    return true;
  }
  const deny = byId(nodes, "permission_deny_button");
  if (deny) {
    await tap(deny);
    return true;
  }
  return false;
}

// The check-in button's label: "Check in", or "Come back tomorrow" once done.
async function button(ms = WAIT_MS): Promise<Node | undefined> {
  for (const end = Date.now() + ms; Date.now() < end; ) {
    const nodes = await screen();
    const node = byId(nodes, "bt_text");
    if (node) return node;
    if (!(await clearInterruptions(nodes))) await sleep(3_000);
  }
  return undefined;
}

const CHECK_IN = /^(check|cek)\s*-?\s*in$/i;

// When the check-in button does not show: a login screen or a login button
// means the session expired; anything else may be a changed app.
async function stuck() {
  const f = await focused().catch(() => "");
  const login = (await screen()).find((n) => LOGIN_LABEL.test(n.text.trim()) || LOGIN_LABEL.test(n.desc.trim()));
  if (LOGIN_ACTIVITY.test(f) || login) {
    alert(`Blibli is logged out (${login ? `"${login.text || login.desc}" button` : "login screen"} shown); log in again over VNC.`);
  } else {
    alert("Blibli: the check-in button did not show, so today's check-in was not done. Not logged in, or the app changed.");
  }
}

async function checkIn(): Promise<void> {
  const before = await button();
  if (!before) return stuck();
  if (!CHECK_IN.test(before.text.trim())) return; // already checked in today
  await tap(before);
  // The label changes once the server has taken it.
  for (const end = Date.now() + 60_000; Date.now() < end; ) {
    await sleep(3_000);
    const after = await button(10_000);
    if (after && !CHECK_IN.test(after.text.trim())) return;
  }
  alert('Blibli: "Check in" was pressed but the page did not take it; today\'s check-in may not be done.');
}

async function main() {
  // host:port is a network device; a local emulator needs no connect.
  if (DEVICE.includes(":")) await promisify(execFile)("adb", ["connect", DEVICE]);
  await shell("input keyevent KEYCODE_WAKEUP");
  await shell("am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS");
  try {
    // A fresh start, so the page shows today's state.
    await shell(`am force-stop ${PKG}`);
    await shell(`am start -a android.intent.action.VIEW -d ${CHECK_IN_URL} -p ${PKG}`);
    await checkIn();
  } finally {
    await shell("input keyevent KEYCODE_HOME").catch(() => {});
    await shell(`am force-stop ${PKG}`).catch(() => {});
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
