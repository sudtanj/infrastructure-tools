// Loaded by Electron from resources/app/ (the build renames the app's
// app.asar to wipter.asar, so Electron finds this instead), then loads the
// app's own, unchanged main process from wipter.asar. It does what a user would do
// in the window nobody sees: sign in, accept the consent prompt, turn
// sharing on, and it reports status on stdout as "wipter-shim: ..." lines.
// Everything happens inside the app's process: no DevTools port or pipe.
//
// Env: WIPTER_EMAIL, WIPTER_PASSWORD (removed from the environment before the
// app starts, so neither its page nor wipter-tunnel sees them);
// WIPTER_SELFTEST=1 exits 0 once the sign-in form shows (1 after 4 minutes).
'use strict';
const fs = require('fs');
const path = require('path');
const { app } = require('electron');

const email = process.env.WIPTER_EMAIL || '';
const password = process.env.WIPTER_PASSWORD || '';
const selftest = process.env.WIPTER_SELFTEST === '1';
for (const k of ['WIPTER_EMAIL', 'WIPTER_PASSWORD', 'WIPTER_SELFTEST', 'VITE_DEV_SERVER_URL'])
    delete process.env[k];

const debug = process.env.WIPTER_DEBUG === '1';
// Written straight to fd 1: unbuffered, and shown even if the main thread
// stalls right after.
const log = msg => { try { fs.writeSync(1, `wipter-shim: ${msg}\n`); } catch {} };
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Runs a script in the page, giving up after 20 s.
function run(win, js) {
    if (win.isDestroyed())
        return Promise.reject(new Error('the app window closed'));
    return Promise.race([
        win.webContents.executeJavaScript(js),
        sleep(20000).then(() => { throw new Error('the page did not answer in 20 s'); }),
    ]);
}

if (debug || selftest)
    log('shim loaded');

if (debug || selftest) {
    // A stalled main thread shows as the heartbeat stopping.
    const t0 = Date.now();
    setInterval(() => log(`heartbeat ${Math.round((Date.now()-t0)/1000)} s`), 10000).unref();
    app.on('ready', () => log('app ready'));
}

if (selftest) {
    setTimeout(() => {
        log('selftest: no sign-in form after 4 minutes');
        app.exit(1);
    }, 4*60*1000).unref();
}

// The app's own test IDs (data-testid) on the elements used here.
const probeJS = `(() => {
  const q = id => document.querySelector('[data-testid="' + id + '"]');
  const s = q('connection-status');
  const b = q('sign-in-button');
  return {
    ready: document.readyState === 'complete',
    signin: !!q('email-input'),
    signinEnabled: !!b && !b.disabled,
    consent: !!q('consent-agree-button'),
    status: s ? s.textContent.trim() : '',
    toggle: !!q('switch-status-button'),
    // What a screen this shim doesn't know says (headings and buttons), for the log.
    text: [...document.querySelectorAll('h1,h2,h3,button,[role=dialog] p')]
      .map(e => e.textContent.trim()).filter(Boolean).join(' | ').slice(0, 300),
  };
})()`;

// Sets a React-controlled input the way typing would: the native setter,
// then an input event.
const fillJS = (id, value) => `(() => {
  const e = document.querySelector('[data-testid="${id}"]');
  const i = e && (e.matches('input') ? e : e.querySelector('input'));
  if (!i) return false;
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  set.call(i, ${JSON.stringify(value)});
  i.dispatchEvent(new Event('input', { bubbles: true }));
  return true;
})()`;

const clickJS = id => `(() => {
  const e = document.querySelector('[data-testid="${id}"]');
  if (!e) return false;
  e.click();
  return true;
})()`;

let watching = false;
app.on('browser-window-created', (_e, win) => {
    const wc = win.webContents;
    if (debug || selftest)
        log('app window created');
    wc.on('did-fail-load', (_e, code, desc, url) => log(`the page failed to load (${code} ${desc}) ${url}`));
    wc.on('render-process-gone', (_e, d) => log(`the page's process is gone: ${d.reason} (exit code ${d.exitCode})`));
    wc.on('unresponsive', () => log('the page is not responding'));
    if (debug)
        wc.on('console-message', (e, _level, message) => log(`page console: ${e.message || message}`));
    // Every load, not just the first: the app may show another page (a splash,
    // an update screen) before index.html, and the shim must still start then.
    wc.on('did-finish-load', () => {
        if (debug || selftest)
            log(`page loaded: ${path.basename(wc.getURL().split('#')[0])}`);
        if (watching || !win.webContents.getURL().includes('index.html'))
            return;
        watching = true;
        wc.insertCSS(stillCSS).catch(() => {});
        (selftest ? runSelftest : supervise)(win).catch(err => {
            log(`stopped: ${err && err.message || err}`);
            app.exit(1);
        });
    });
});

const probe = win => run(win, probeJS);

// Memory of the app's processes (proportional set size, so shared pages count
// once), by Chromium process type.
function memory() {
    const by = {};
    let total = 0;
    for (const pid of fs.readdirSync('/proc').filter(p => /^\d+$/.test(p))) {
        try {
            const pss = +/^Pss:\s+(\d+)/m.exec(fs.readFileSync(`/proc/${pid}/smaps_rollup`, 'utf8'))[1];
            const argv = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0');
            // Chromium starts its helpers as /proc/self/exe --type=...
            const type = argv.find(a => a.startsWith('--utility-sub-type='))?.slice(19).split('.').pop()
                || argv.find(a => a.startsWith('--type='))?.slice(7)
                || (argv[0].endsWith('wipter-app.bin') ? 'main' : path.basename(argv[0]));
            by[type] = (by[type] || 0) + pss;
            total += pss;
        } catch {}
    }
    const mb = kb => `${Math.round(kb/1024)} MB`;
    return `${mb(total)} (${Object.entries(by).sort((a, b) => b[1]-a[1]).map(([t, kb]) => `${t} ${mb(kb)}`).join(', ')})`;
}

// Animations cost CPU on every frame even though nobody sees the window.
const stillCSS = '*, *::before, *::after { animation: none !important; transition: none !important; }';

async function runSelftest(win) {
    let last = '';
    for (;;) {
        const s = await probe(win).catch(err => ({ error: err.message }));
        if (s.ready && s.signin) {
            log('selftest: the sign-in form loaded');
            await sleep(15000);
            log(`selftest: memory ${memory()}`);
            return app.exit(0);
        }
        const now = JSON.stringify(s);
        if (now != last)
            log(`selftest: page state ${now}`);
        last = now;
        await sleep(2000);
    }
}

async function signIn(win) {
    log('signing in');
    for (const [id, value] of [['email-input', email], ['password-input', password]]) {
        if (!await run(win, fillJS(id, value)))
            throw new Error(`the sign-in form changed: no ${id}`);
    }
    for (let i = 0; !(await probe(win)).signinEnabled; i++) {
        if (i == 10)
            throw new Error('the sign-in button stays disabled (is WIPTER_EMAIL a valid address?)');
        await sleep(1000);
    }
    await run(win, clickJS('sign-in-button'));
    for (let i = 0; i < 45; i++) {
        await sleep(2000);
        const s = await probe(win);
        if (s.ready && !s.signin)
            return;
    }
    throw new Error('still on the sign-in form after 90 s (wrong email or password, or the account needs verifying in the app)');
}

async function supervise(win) {
    let signedIn = false, lastStatus = '', offlineSince = 0, lastToggle = 0, failures = 0;
    let unknownSince = 0, unknownLogged = 0;
    setTimeout(() => log(`memory after 5 minutes: ${memory()}`), 5*60*1000).unref();
    for (;;) {
        const s = await probe(win).catch(() => ({}));
        if (!s.ready) {
            await sleep(3000);
            continue;
        }
        // A screen with none of the elements below: report it after 2 minutes, then
        // every 30 (emails masked), instead of waiting silently.
        if (!s.consent && !s.signin && !s.status) {
            unknownSince = unknownSince || Date.now();
            if (Date.now()-unknownSince > 2*60*1000 && Date.now()-unknownLogged > 30*60*1000) {
                log(`waiting on a screen this shim doesn't handle: ${(s.text || '(no text)').replace(/[^\s|@]+@[^\s|]+/g, '<email>')}`);
                unknownLogged = Date.now();
            }
        } else
            unknownSince = 0;
        if (s.consent) {
            // The app shares nothing until its data-sharing consent is
            // accepted; running this image is that choice.
            if (await run(win, clickJS('consent-agree-button')))
                log("accepted the app's bandwidth-sharing consent prompt");
        } else if (s.signin) {
            if (signedIn) {
                log('signed out (session expired?): signing in again');
                signedIn = false;
            }
            if (failures >= 3) {
                // Don't hammer the account with a wrong password: Docker
                // restarts the container later.
                log('sign-in failed 3 times; check WIPTER_EMAIL / WIPTER_PASSWORD');
                await sleep(30*60*1000);
                return app.exit(1);
            }
            try {
                await signIn(win);
                failures = 0;
            } catch (err) {
                failures++;
                log(`sign-in failed (attempt ${failures}/3): ${err.message}`);
                await sleep(failures*60*1000);
                continue;
            }
        } else if (s.status) {
            if (!signedIn) {
                log('signed in');
                signedIn = true;
            }
            if (s.status != lastStatus)
                log(`status: ${s.status}`);
            lastStatus = s.status;
            // Sharing is off (auto-connect disabled, or switched off from
            // the account): switch it on, at most every 10 minutes.
            if (s.status.toLowerCase() == 'offline' && s.toggle) {
                offlineSince = offlineSince || Date.now();
                if (Date.now()-offlineSince > 90*1000 && Date.now()-lastToggle > 10*60*1000
                    && await run(win, clickJS('switch-status-button'))) {
                    log('sharing was off: turned it on');
                    lastToggle = Date.now();
                }
            } else
                offlineSince = 0;
        }
        await sleep(15000);
    }
}

if (debug || selftest)
    log('loading the app');
require(path.join(process.resourcesPath, 'wipter.asar', 'dist-electron', 'main', 'main.js'));
if (debug || selftest)
    log('the app loaded');
