// Runs the Majun PS2 core pages in headless Chromium and samples PCSX2Web.stats().
// usage: node majun-sim.mjs <bios file> <out dir> <seconds> <name=dir> [<name=dir> ...]
// GAME_ISO=<file> (with GAME_NAME) boots that disc after the BIOS; without it the run is BIOS only.
// PROFILE=true also writes a CPU profile per worker (<name>.worker<i>.cpuprofile) and <name>.profile.md.
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const [biosPath, outDir, secondsArg, ...cores] = process.argv.slice(2);
const seconds = Number(secondsArg);
const PROFILE = process.env.PROFILE === 'true';
const GAME_ISO = process.env.GAME_ISO;
const GAME_NAME = process.env.GAME_NAME;
const TOP_N = 40;
const SAMPLE_MS = 10_000;
const BOOT_TIMEOUT_MS = 180_000;
const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain',
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN);
const fmt = (n, d = 0) => (Number.isFinite(n) ? n.toFixed(d) : 'n/a');

// COOP/COEP make the page cross-origin isolated, which the core's threads need.
function serve(root) {
  const server = http.createServer((req, res) => {
    const file = path.join(root, path.normalize(new URL(req.url, 'http://x').pathname).replace(/^(\.\.[/\\])+/, ''));
    const target = fs.existsSync(file) && fs.statSync(file).isDirectory() ? path.join(file, 'index.html') : file;
    if (!target.startsWith(root) || !fs.existsSync(target)) { res.writeHead(404).end(); return; }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(target)] || 'application/octet-stream',
      'Content-Length': fs.statSync(target).size,
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      'Cross-Origin-Resource-Policy': 'same-origin',
    });
    fs.createReadStream(target).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// Playwright's CDPSession cannot address child targets, so workers are attached without
// flatten mode and driven through Target.sendMessageToTarget.
async function attachWorkers(context, page) {
  const session = await context.newCDPSession(page);
  const workers = [];
  const pending = new Map();
  let nextId = 0;
  const send = (worker, method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    session.send('Target.sendMessageToTarget', { sessionId: worker.sessionId, message: JSON.stringify({ id, method, params }) }).catch(reject);
  });
  session.on('Target.attachedToTarget', (e) => {
    if (e.targetInfo.type === 'worker') workers.push({ sessionId: e.sessionId, url: e.targetInfo.url });
  });
  session.on('Target.receivedMessageFromTarget', (e) => {
    const m = JSON.parse(e.message);
    const p = pending.get(m.id);
    if (!p) return;
    pending.delete(m.id);
    if (m.error) p.reject(new Error(m.error.message)); else p.resolve(m.result);
  });
  await session.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: false });
  return {
    workers,
    async start() {
      await Promise.all(workers.map(async (w) => {
        await send(w, 'Profiler.enable');
        await send(w, 'Profiler.setSamplingInterval', { interval: 1000 });
        await send(w, 'Profiler.start');
      }));
    },
    stop: () => Promise.all(workers.map((w) => send(w, 'Profiler.stop').then((r) => r.profile, () => null))),
  };
}

// Self time per function: each sample owns the interval up to the next sample.
function selfTimes(profile) {
  const byId = new Map(profile.nodes.map((n) => [n.id, n.callFrame]));
  const totals = new Map();
  profile.samples.forEach((id, i) => {
    const f = byId.get(id);
    const key = `${f.functionName || '(anonymous)'}${f.url ? ` (${path.basename(f.url)})` : ''}`;
    totals.set(key, (totals.get(key) ?? 0) + (profile.timeDeltas[i + 1] ?? 0) / 1000);
  });
  return [...totals].sort((a, b) => b[1] - a[1]);
}

function profileReport(name, profiles) {
  const lines = [`## ${name} core CPU profile`, ''];
  const sampleCount = (p) => (p ? p.samples.length : -1);
  const eeIndex = profiles.reduce((best, p, i) => (sampleCount(p) > sampleCount(profiles[best]) ? i : best), 0);
  profiles.forEach((p, i) => {
    if (!p) { lines.push(`### worker ${i}: no profile`, ''); return; }
    const rows = selfTimes(p);
    const total = rows.reduce((a, r) => a + r[1], 0);
    lines.push(`### worker ${i}${i === eeIndex ? ' (EE: most samples)' : ''}: ${p.samples.length} samples, ${fmt(total)} ms`, '',
      '| function | self ms | self % |', '|---|---|---|',
      ...rows.slice(0, TOP_N).map(([fn, ms]) => `| \`${fn.replace(/\|/g, '/')}\` | ${fmt(ms)} | ${fmt((100 * ms) / total, 1)} |`), '');
  });
  return lines.join('\n');
}

async function runCore(browser, name, dir, query) {
  const server = await serve(path.resolve(dir));
  const base = `http://127.0.0.1:${server.address().port}`;
  const result = { name, samples: [], problems: [], webgpu: null, log: '' };
  const context = await browser.newContext();
  const page = await context.newPage();
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`[console.${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push(`[pageerror] ${e.message}`));
  page.on('crash', () => result.problems.push('page crashed'));
  const stats = () => page.evaluate(() => {
    const s = window.PCSX2Web.stats();
    const threads = document.getElementById('r-threads')?.textContent.match(/EE (\d+)%\s+GS (\d+)%\s+VU (\d+)%/);
    return {
      state: s.state, view: s.view, speed: s.speed, vps: s.vps, fps: s.displayFps, presented: s.framesPresented,
      dropped: s.framesDropped, display: s.display, gpuMode: s.gpuMode, gpuFallback: s.gpuFallback,
      ee: threads ? Number(threads[1]) : null, gs: threads ? Number(threads[2]) : null, vu: threads ? Number(threads[3]) : null,
    };
  });
  const profiler = PROFILE ? await attachWorkers(context, page) : null;
  try {
    await page.goto(`${base}/index.html?threads=1${query ? "&" + query : ""}`, { waitUntil: 'load' });
    result.webgpu = await page.evaluate(async () => !!(navigator.gpu && (await navigator.gpu.requestAdapter())));
    await page.waitForSelector('#bios-input', { state: 'attached', timeout: 60_000 });
    await page.setInputFiles('#bios-input', biosPath);
    await page.waitForFunction(() => document.body.dataset.bios === 'set', null, { timeout: 90_000 });
    if (GAME_ISO) {
      await page.setInputFiles('#disc-input', GAME_ISO);
      await page.waitForFunction(() => document.body.dataset.disc === 'set' || document.getElementById('slate-error')?.offsetParent, null, { timeout: 90_000 });
      if (await page.evaluate(() => document.body.dataset.disc !== 'set')) {
        throw new Error(`disc rejected: ${await page.evaluate(() => document.getElementById('slate-error').textContent.trim())}`);
      }
    }
    await page.waitForFunction(() => document.body.dataset.state === 'ready', null, { timeout: BOOT_TIMEOUT_MS });
    await page.evaluate(() => document.getElementById('slate-primary').click());
    await page.waitForFunction(() => document.body.dataset.state === 'running', null, { timeout: BOOT_TIMEOUT_MS });

    await profiler?.start();
    let prev = await stats();
    for (let t = SAMPLE_MS / 1000; t <= seconds && !result.problems.length; t += SAMPLE_MS / 1000) {
      await sleep(SAMPLE_MS);
      const s = { t, ...(await stats()) };
      result.samples.push(s);
      if (s.state !== 'running') result.problems.push(`state ${s.state} at ${t}s`);
      else if (s.presented <= prev.presented) result.problems.push(`no new frames between ${t - SAMPLE_MS / 1000}s and ${t}s`);
      prev = s;
    }
  } catch (e) {
    result.problems.push(String(e.message).split('\n')[0]);
    try { result.last = await stats(); } catch { /* page gone */ }
  }
  if (profiler) {
    const profiles = await profiler.stop();
    profiles.forEach((p, i) => p && fs.writeFileSync(path.join(outDir, `${name}.worker${i}.cpuprofile`), JSON.stringify(p)));
    const report = profileReport(name, profiles);
    fs.writeFileSync(path.join(outDir, `${name}.profile.md`), `${report}\n`);
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${report}\n`);
    console.log(`${name}: ${profiler.workers.length} workers profiled`);
  }
  // A clean stop makes the core print its end-of-run stats (EE JIT idle loops and the like) into the log.
  try {
    await page.evaluate(() => document.getElementById('btn-stop').click());
    await page.waitForFunction(() => document.body.dataset.state !== 'running', null, { timeout: 30_000 });
    await sleep(2000);
  } catch { /* already stopped or gone */ }
  try { result.log = await page.evaluate(() => window.PCSX2Web.logText()); } catch { /* page gone */ }
  if (GAME_ISO) {
    try { result.disc = await page.evaluate(() => window.PCSX2WebDisc.stats()); } catch { /* page gone */ }
    if (!/Disc boot/.test(result.log)) result.problems.push('core log has no "Disc boot" line');
  }
  fs.writeFileSync(path.join(outDir, `${name}.core.log`), `${result.log}\n--- browser console ---\n${consoleLines.join('\n')}\n`);
  await context.close();
  server.close();
  const speeds = result.samples.map((s) => s.speed);
  const last = result.samples.at(-1) ?? result.last;
  result.row = {
    core: name,
    meanSpeed: mean(speeds),
    minSpeed: speeds.length ? Math.min(...speeds) : NaN,
    ee: mean(result.samples.map((s) => s.ee).filter((v) => v !== null)),
    gs: mean(result.samples.map((s) => s.gs).filter((v) => v !== null)),
    vu: mean(result.samples.map((s) => s.vu).filter((v) => v !== null)),
    presented: last?.presented ?? NaN,
    display: last ? `${last.display}${result.webgpu ? '' : ' (no WebGPU)'}` : 'n/a',
    game: result.log.match(/Game: (.+)/)?.[1] ?? GAME_NAME,
    pass: result.problems.length === 0 && result.samples.length > 0,
  };
  return result;
}

fs.mkdirSync(outDir, { recursive: true });
const browser = await chromium.launch({
  channel: 'chromium',
  args: [
    '--no-sandbox', '--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-angle=vulkan',
    '--use-vulkan=swiftshader', '--ignore-gpu-blocklist',
  ],
});
const results = [];
for (const spec of cores) {
  const eq = spec.indexOf('=');
  const [dir, query] = spec.slice(eq + 1).split('?');
  const name = spec.slice(0, eq);
  results.push(await runCore(browser, name, dir, query));
}
await browser.close();

fs.writeFileSync(path.join(outDir, 'samples.json'), JSON.stringify(results.map(({ log, row, ...r }) => ({ ...r, row })), null, 1));
const lines = [
  `${GAME_ISO ? `Game ${GAME_NAME}` : 'BIOS only'}, ${seconds} s per core, sampled every ${SAMPLE_MS / 1000} s.`, '',
  `| core |${GAME_ISO ? ' game |' : ''} mean speed % | min speed % | EE busy % | GS busy % | VU busy % | frames presented | display | result |`,
  `|---|${GAME_ISO ? '---|' : ''}---|---|---|---|---|---|---|---|`,
  ...results.map(({ row: r }) => `| ${r.core} |${GAME_ISO ? ` ${r.game} |` : ''} ${fmt(r.meanSpeed)} | ${fmt(r.minSpeed)} | ${fmt(r.ee)} | ${fmt(r.gs)} | ${fmt(r.vu)} | ${fmt(r.presented)} | ${r.display} | ${r.pass ? 'PASS' : 'FAIL'} |`),
];
if (GAME_ISO) for (const r of results) lines.push('', `- ${r.name} disc: ${JSON.stringify(r.disc)}`);
for (const r of results) for (const p of r.problems) lines.push('', `- ${r.name}: ${p}`);
fs.writeFileSync(path.join(outDir, 'summary.md'), `${lines.join('\n')}\n`);
console.log(lines.join('\n'));
process.exit(results.every((r) => r.row.pass) ? 0 : 1);
