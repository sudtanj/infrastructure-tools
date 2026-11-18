import { chromium } from 'playwright';
import http from 'node:http';
const server = http.createServer((q, s) => {
  if (q.url === '/w.js') s.writeHead(200, { 'Content-Type': 'text/javascript' }).end('registerProcessor("x", class extends AudioWorkletProcessor { process() { return true; } });');
  else s.writeHead(200, { 'Content-Type': 'text/html' }).end('<html></html>');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}/`;
const ign = (...a) => ({ channel: 'chromium', args: ['--no-sandbox'], ignoreDefaultArgs: a });
const variants = {
  A: ign(),
  B_field_trial: ign('--disable-field-trial-config'),
  C_throttle: ign('--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'),
  D_ipc: ign('--disable-ipc-flooding-protection', '--disable-hang-monitor'),
  E_features: ign('--disable-features=ImprovedCookieControls,LazyFrameLoading,GlobalMediaControls,DestroyProfileOnBrowserClose,MediaRouter,DialMediaRouteProvider,AcceptCHFrame,AutoExpandDetailsElement,CertificateTransparencyComponentUpdater,AvoidUnnecessaryBeforeUnloadCheckSync,Translate,HttpsUpgrades,PaintHolding,ThirdPartyStoragePartitioning,LensOverlay,PlzDedicatedWorker'),
};
for (const [name, opts] of Object.entries(variants)) {
  let out;
  try {
    const browser = await chromium.launch(opts);
    const page = await browser.newPage();
    await page.goto(origin);
    out = await page.evaluate(async () => {
      const res = [];
      const race = (p) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 5s')), 5000))]);
      try {
        const w = new Worker('/w.js');
        res.push('worker made');
        w.terminate();
      } catch (e) { res.push(`worker ${e.message}`); }
      const c = new AudioContext();
      try { await race(c.audioWorklet.addModule('/w.js')); res.push('worklet ok'); } catch (e) { res.push(`worklet ${e.message}`); }
      return res.join('; ');
    });
    await browser.close();
  } catch (e) { out = `launch failed: ${String(e.message).split('\n')[0]}`; }
  console.log(`${name}: ${out}`);
}
server.close();
