import { chromium } from 'playwright';
import http from 'node:http';
const server = http.createServer((q, s) => {
  if (q.url === '/w.js') s.writeHead(200, { 'Content-Type': 'text/javascript' }).end('registerProcessor("x", class extends AudioWorkletProcessor { process() { return true; } });');
  else s.writeHead(200, { 'Content-Type': 'text/html' }).end('<html></html>');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}/`;
const variants = {
  A_default: { channel: 'chromium', args: ['--no-sandbox'] },
  B_no_rt_priority: { channel: 'chromium', args: ['--no-sandbox', '--disable-features=AudioWorkletThreadRealtimePriority'] },
  C_rt_priority: { channel: 'chromium', args: ['--no-sandbox', '--enable-features=AudioWorkletThreadRealtimePriority'] },
  D_gpu_off: { channel: 'chromium', args: ['--no-sandbox', '--disable-gpu'] },
  E_single_process_audio: { channel: 'chromium', args: ['--no-sandbox', '--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox'] },
  F_fake: { channel: 'chromium', args: ['--no-sandbox', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] },
};
for (const [name, opts] of Object.entries(variants)) {
  let out;
  try {
    const browser = await chromium.launch(opts);
    const page = await browser.newPage();
    page.on('console', (m) => console.log(`  [${name} console] ${m.text().slice(0, 150)}`));
    await page.goto(origin);
    out = await page.evaluate(async () => {
      const res = [];
      for (const kind of ['served', 'blob']) {
        const c = new AudioContext();
        const url = kind === 'blob' ? URL.createObjectURL(new Blob(['registerProcessor("x", class extends AudioWorkletProcessor { process() { return true; } });'], { type: 'text/javascript' })) : '/w.js';
        try {
          await Promise.race([c.audioWorklet.addModule(url), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 6s')), 6000))]);
          res.push(`${kind} ok`);
        } catch (e) { res.push(`${kind} ${e.message}`); }
      }
      return res.join('; ');
    });
    await browser.close();
  } catch (e) { out = `launch failed: ${String(e.message).split('\n')[0]}`; }
  console.log(`${name}: ${out}`);
}
server.close();
