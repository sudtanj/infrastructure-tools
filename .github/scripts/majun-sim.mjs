// Runs the Majun PS2 core pages in headless Chromium, BIOS only, and samples PCSX2Web.stats().
// usage: node majun-sim.mjs <bios file> <out dir> <seconds> <name=dir> [<name=dir> ...]
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const [biosPath, outDir, secondsArg, ...cores] = process.argv.slice(2);
const seconds = Number(secondsArg);
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
  try {
    await page.goto(`${base}/index.html?threads=1${query ? "&" + query : ""}`, { waitUntil: 'load' });
    result.webgpu = await page.evaluate(async () => !!(navigator.gpu && (await navigator.gpu.requestAdapter())));
    await page.waitForSelector('#bios-input', { state: 'attached', timeout: 60_000 });
    await page.setInputFiles('#bios-input', biosPath);
    await page.waitForFunction(() => document.body.dataset.bios === 'set', null, { timeout: 90_000 });
    await page.waitForFunction(() => document.body.dataset.state === 'ready', null, { timeout: BOOT_TIMEOUT_MS });
    await page.evaluate(() => document.getElementById('slate-primary').click());
    await page.waitForFunction(() => document.body.dataset.state === 'running', null, { timeout: BOOT_TIMEOUT_MS });

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
  try { result.log = await page.evaluate(() => window.PCSX2Web.logText()); } catch { /* page gone */ }
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
  const [name, spec2] = spec.split('=');
  const [dir, query] = spec2.split('?');
  results.push(await runCore(browser, name, dir, query));
}
await browser.close();

fs.writeFileSync(path.join(outDir, 'samples.json'), JSON.stringify(results.map(({ log, row, ...r }) => ({ ...r, row })), null, 1));
const lines = [
  `BIOS only, ${seconds} s per core, sampled every ${SAMPLE_MS / 1000} s.`, '',
  '| core | mean speed % | min speed % | EE busy % | GS busy % | VU busy % | frames presented | display | result |',
  '|---|---|---|---|---|---|---|---|---|',
  ...results.map(({ row: r }) => `| ${r.core} | ${fmt(r.meanSpeed)} | ${fmt(r.minSpeed)} | ${fmt(r.ee)} | ${fmt(r.gs)} | ${fmt(r.vu)} | ${fmt(r.presented)} | ${r.display} | ${r.pass ? 'PASS' : 'FAIL'} |`),
];
for (const r of results) for (const p of r.problems) lines.push('', `- ${r.name}: ${p}`);
fs.writeFileSync(path.join(outDir, 'summary.md'), `${lines.join('\n')}\n`);
console.log(lines.join('\n'));
process.exit(results.every((r) => r.row.pass) ? 0 : 1);
