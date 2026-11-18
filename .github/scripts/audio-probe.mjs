import { chromium } from 'playwright';
import http from 'node:http';
const server = http.createServer((q, s) => {
  if (q.url === '/w.js') s.writeHead(200, { 'Content-Type': 'text/javascript' }).end('registerProcessor("x", class extends AudioWorkletProcessor { process() { return true; } });');
  else s.writeHead(200, { 'Content-Type': 'text/html' }).end('<html></html>');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}/`;
const variants = {
  A_chromium: { channel: 'chromium', args: ['--no-sandbox'] },
  B_chrome_stable: { channel: 'chrome', args: ['--no-sandbox'] },
  C_headless_new_flag: { channel: 'chrome', args: ['--no-sandbox', '--headless=new'] },
};
for (const [name, opts] of Object.entries(variants)) {
  let out;
  try {
    const browser = await chromium.launch(opts);
    const page = await browser.newPage();
    await page.goto(origin);
    out = `v${browser.version()} ` + await page.evaluate(async () => {
      const res = [];
      const race = (p) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 6s')), 6000))]);
      const offline = new OfflineAudioContext(2, 48000, 48000);
      try { await race(offline.audioWorklet.addModule('/w.js')); res.push('offline ok'); } catch (e) { res.push(`offline ${e.message}`); }
      const c = new AudioContext();
      try { await race(c.audioWorklet.addModule('/w.js')); res.push('realtime ok'); } catch (e) { res.push(`realtime ${e.message}`); }
      res.push(`sink ${JSON.stringify(c.sinkId)} t=${c.currentTime.toFixed(2)} out=${c.outputLatency}`);
      return res.join('; ');
    });
    await browser.close();
  } catch (e) { out = `launch failed: ${String(e.message).split('\n')[0]}`; }
  console.log(`${name}: ${out}`);
}
server.close();
