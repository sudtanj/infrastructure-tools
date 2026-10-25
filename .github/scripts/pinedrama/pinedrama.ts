// Opens PineDrama on the tailnet emulator, checks in and claims what the
// rewards page offers (rewards.ts), keeps a video playing, and swipes to the
// next one when the current one finishes; claims again at the end.
//
//   node pinedrama.ts      (Node 23.6+; needs adb and package.json's modules)
//
// Run by android-emulator-session on its schedule, against its own emulator
// (DEVICE=emulator-5554), or from anywhere on the tailnet with the default.
//
// Env: DEVICE (default 100.113.219.108:5555), MAX_VIDEOS (0 = forever),
// MAX_WATCH_SECONDS (swipe anyway after this, for videos that loop),
// MAX_MINUTES (stop after this, 0 = never), COIN_ID (stop once this view is
// gone; default qz8, the coin timer on the left, empty to ignore it),
// REWARDS (default 1: check in and claim on the rewards page before and
// after scrolling, see rewards.ts; 0 to skip).
//
// PineDrama's window is FLAG_SECURE (screenshots are black) and a playing
// video keeps uiautomator from going idle, so the screen can't tell us when a
// video ends. The app logs it instead: "SlotStrategyService: ... timingKeys=
// [video_play_finish]" when an episode ends, after which it loops the episode,
// so we follow logcat and swipe up on that line. As a fallback, Android's audio
// player list: each video is an AudioTrack owned by the app's uid, `started`
// while it plays; when none has played for END_GRACE_MS the video is over too.

import { execFile, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { _android, type AndroidDevice } from "playwright-core";
import { claimRewards } from "./rewards.ts";

const PKG = "com.ss.android.ttmd.video";
const DEVICE = process.env.DEVICE ?? "100.113.219.108:5555";
const MAX_VIDEOS = Number(process.env.MAX_VIDEOS ?? 0);
const MAX_WATCH_MS = Number(process.env.MAX_WATCH_SECONDS ?? 240) * 1000;
const MAX_MINUTES = Number(process.env.MAX_MINUTES ?? 0);
const COIN_ID = process.env.COIN_ID ?? "qz8";
const REWARDS = process.env.REWARDS !== "0";
const COIN_CHECK_MS = 30_000;
const POLL_MS = 2_000;
const END_GRACE_MS = 6_000;
// Arm64 app under translation on an x86_64 emulator: cold start takes minutes.
const START_TIMEOUT_MS = 300_000;
const PLAY_TIMEOUT_MS = 45_000;
// Popups that cover the feed. Prefer the declining button.
const DISMISS = /^(skip|not now|later|close|cancel|got it|no thanks|don.t allow|maybe later)$/i;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);

type Player = { piid: string; state: string };

async function shell(d: AndroidDevice, cmd: string): Promise<string> {
  return (await d.shell(cmd)).toString();
}

async function appUid(d: AndroidDevice): Promise<string> {
  const m = (await shell(d, `pm list packages -U ${PKG}`)).match(new RegExp(`package:${PKG.replace(/\./g, "\\.")} uid:(\\d+)`));
  if (!m) throw new Error(`${PKG} is not installed`);
  return m[1];
}

// Current players from `dumpsys audio`, e.g.
// "AudioPlaybackConfiguration piid:239 deviceIds:[2] u/pid:10209/9421 type:android.media.AudioTrack state:started ..."
async function players(d: AndroidDevice, uid: string): Promise<Player[]> {
  const out = await shell(d, `dumpsys audio | grep 'u/pid:${uid}/'`);
  const list: Player[] = [];
  for (const line of out.split("\n")) {
    const m = line.match(/AudioPlaybackConfiguration piid:(\d+).*?state:(\w+)/);
    if (m) list.push({ piid: m[1], state: m[2] });
  }
  return list;
}

const playing = (ps: Player[]) => ps.find((p) => p.state === "started");

// Whether view app:id/<id> is shown: in the app's `dumpsys activity top` tree
// with a size and every ancestor visible. Selector lookups take minutes here,
// this a few seconds. Lines look like
// "  android.widget.FrameLayout{5c8d9ac V.E...... ........ 0,268-128,440 #7f0a59b2 app:id/qz8}".
async function viewShown(d: AndroidDevice, id: string): Promise<boolean> {
  const out = await shell(d, "dumpsys activity top");
  const from = out.indexOf(`ACTIVITY ${PKG}/`);
  if (from < 0) return false;
  const next = out.indexOf("\n  ACTIVITY ", from + 1);
  const stack: { ind: number; vis: boolean }[] = [];
  for (const line of out.slice(from, next < 0 ? undefined : next).split("\n")) {
    const m = line.match(/^(\s*)\S+\{[0-9a-f]+ (\S)\S{8} \S{8} (-?\d+),(-?\d+)-(-?\d+),(-?\d+)(.*)\}/);
    if (!m) continue;
    const ind = m[1].length;
    while (stack.length && stack[stack.length - 1].ind >= ind) stack.pop();
    const vis = (stack[stack.length - 1]?.vis ?? true) && m[2] === "V";
    stack.push({ ind, vis });
    const sized = +m[5] > +m[3] && +m[6] > +m[4];
    if (vis && sized && m[7].trim().endsWith(`app:id/${id}`)) return true;
  }
  return false;
}

let deadline = Infinity;
let nextCoinCheck = 0;
let coinMisses = 0;
let stopReason = "";

// Checked between polls; the coin is looked up at most every COIN_CHECK_MS
// and must be missing twice in a row (a swipe or an ad can hide it briefly).
async function shouldStop(d: AndroidDevice): Promise<boolean> {
  if (stopReason) return true;
  if (Date.now() >= deadline) stopReason = `${MAX_MINUTES} minutes are up`;
  else if (COIN_ID && Date.now() >= nextCoinCheck) {
    nextCoinCheck = Date.now() + COIN_CHECK_MS;
    if (await inForeground(d)) {
      coinMisses = (await viewShown(d, COIN_ID)) ? 0 : coinMisses + 1;
      if (coinMisses === 1) log("coin not found; checking again");
      if (coinMisses >= 2) stopReason = "the coin is gone";
    }
  }
  return stopReason !== "";
}

async function inForeground(d: AndroidDevice): Promise<boolean> {
  const out = await shell(d, "dumpsys activity activities | grep topResumedActivity");
  return out.includes(PKG);
}

async function launch(d: AndroidDevice) {
  log("launching", PKG);
  await shell(d, `monkey -p ${PKG} -c android.intent.category.LAUNCHER 1`);
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline && !(await inForeground(d))) await sleep(POLL_MS);
}

// Slow: each lookup waits ~10 s for an idle UI that never comes while video plays.
async function dismissPopups(d: AndroidDevice) {
  for (const sel of [{ pkg: PKG, text: DISMISS }, { pkg: PKG, desc: DISMISS }]) {
    try {
      await d.tap(sel, { timeout: 3_000 });
      log("dismissed a popup");
    } catch {}
  }
}

async function swipeUp(d: AndroidDevice) {
  // 720x1280 screen; start above the nav bar and below the status bar.
  await shell(d, "input swipe 360 1000 360 250 250");
}

async function tapCenter(d: AndroidDevice) {
  await shell(d, "input tap 360 640");
}

// Waits for one of the app's players to start; nudges it once if it doesn't.
async function waitForPlayback(d: AndroidDevice, uid: string): Promise<Player | undefined> {
  let nudged = false;
  const deadline = Date.now() + PLAY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const p = playing(await players(d, uid));
    if (p) return p;
    if (!nudged && Date.now() > deadline - PLAY_TIMEOUT_MS / 2) {
      nudged = true;
      await dismissPopups(d);
      // A tap toggles pause on the feed.
      if (!playing(await players(d, uid))) await tapCenter(d);
    }
    await sleep(POLL_MS);
  }
  return undefined;
}

// Returns once the current video is over: no player of the app has been
// started for END_GRACE_MS, or MAX_WATCH_MS has passed.
// Time of the last "video_play_finish" log line from the app.
let finishedAt = 0;
let logcat: ReturnType<typeof spawn> | undefined;

function followLogcat() {
  const lc = (logcat = spawn("adb", ["-s", DEVICE, "logcat", "-T", "1", "-v", "brief", "SlotStrategyService:D", "*:S"], { stdio: ["ignore", "pipe", "ignore"] }));
  createInterface({ input: lc.stdout }).on("line", (line) => {
    if (line.includes("timingKeys=[video_play_finish]")) finishedAt = Date.now();
  });
  lc.on("exit", () => setTimeout(followLogcat, 5_000));
}

async function watch(d: AndroidDevice, uid: string, first: Player) {
  const start = Date.now();
  let current = first.piid;
  let silentSince = 0;
  while (Date.now() - start < MAX_WATCH_MS) {
    await sleep(POLL_MS);
    if (await shouldStop(d)) return;
    if (!(await inForeground(d))) return log("app left the foreground");
    if (finishedAt > start) return log("video finished");
    const p = playing(await players(d, uid));
    if (p) {
      silentSince = 0;
      if (p.piid !== current) {
        log(`app moved on by itself (player ${current} -> ${p.piid})`);
        current = p.piid;
      }
      continue;
    }
    silentSince ||= Date.now();
    if (Date.now() - silentSince >= END_GRACE_MS) return log("video finished");
  }
  log(`watched ${MAX_WATCH_MS / 1000}s; moving on`);
}

async function main() {
  // host:port is a network device; a local emulator needs no connect.
  if (DEVICE.includes(":")) await promisify(execFile)("adb", ["connect", DEVICE]);
  const d = (await _android.devices()).find((x) => x.serial() === DEVICE);
  if (!d) throw new Error(`${DEVICE} not in adb devices (unauthorized? approve it over VNC)`);
  const stop = async () => {
    logcat?.removeAllListeners("exit").kill();
    await d.close().catch(() => {});
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  log("device", d.serial(), d.model());
  await shell(d, "input keyevent KEYCODE_WAKEUP");
  // After a cold boot a "not responding" dialog (often the launcher's) can
  // cover the screen and take every tap.
  await shell(d, "am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS");
  const uid = await appUid(d);
  if (MAX_MINUTES > 0) deadline = Date.now() + MAX_MINUTES * 60_000;
  followLogcat();

  if (REWARDS) {
    if (!(await inForeground(d))) await launch(d);
    await claimRewards(d, DEVICE);
  }

  for (let n = 1; MAX_VIDEOS === 0 || n <= MAX_VIDEOS; n++) {
    if (!(await inForeground(d))) await launch(d);
    if (await shouldStop(d)) break;
    const p = await waitForPlayback(d, uid);
    if (!p) {
      log("nothing is playing; swiping past");
      await swipeUp(d);
      continue;
    }
    log(`video ${n} playing (player ${p.piid})`);
    await watch(d, uid, p);
    if (stopReason) break;
    if (await inForeground(d)) await swipeUp(d);
  }
  log("stopping:", stopReason || "video limit reached");
  // Watching can unlock more (watch-time milestones).
  if (REWARDS) {
    if (!(await inForeground(d))) await launch(d);
    await claimRewards(d, DEVICE);
  }
  await stop();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
