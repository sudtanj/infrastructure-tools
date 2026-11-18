import { chromium } from 'playwright';
const variants = {
  A_headless_chromium: { channel: 'chromium', args: ['--no-sandbox'] },
  B_headless_shell: { args: ['--no-sandbox'] },
  C_headed: { channel: 'chromium', headless: false, args: ['--no-sandbox'] },
  D_no_audio_oop: { channel: 'chromium', args: ['--no-sandbox', '--disable-features=AudioServiceOutOfProcess'] },
  E_headed_no_audio_oop: { channel: 'chromium', headless: false, args: ['--no-sandbox', '--disable-features=AudioServiceOutOfProcess'] },
  F_headless_unmuted: { channel: 'chromium', ignoreDefaultArgs: ['--mute-audio'], args: ['--no-sandbox', '--autoplay-policy=no-user-gesture-required'] },
};
for (const [name, opts] of Object.entries(variants)) {
  let out;
  try {
    const browser = await chromium.launch(opts);
    const page = await browser.newPage();
    await page.goto('about:blank');
    out = await page.evaluate(async () => {
      const c = new AudioContext();
      const url = URL.createObjectURL(new Blob(['registerProcessor("x", class extends AudioWorkletProcessor { process() { return true; } });'], { type: 'text/javascript' }));
      const t0 = performance.now();
      try {
        await Promise.race([c.audioWorklet.addModule(url), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout 8s')), 8000))]);
        return `ok ${Math.round(performance.now() - t0)} ms, ${c.state}, t=${c.currentTime.toFixed(2)}`;
      } catch (e) { return `${e.message}, ${c.state}, t=${c.currentTime.toFixed(2)}`; }
    });
    await browser.close();
  } catch (e) { out = `launch failed: ${String(e.message).split('\n')[0]}`; }
  console.log(`${name}: ${out}`);
}
