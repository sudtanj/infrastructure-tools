// Loaded by Electron from resources/app/ (which it prefers over app.asar),
// before the app's own, unchanged main process. It does what a user would do
// in the window nobody sees: sign in, accept the consent prompt, turn
// sharing on, and it reports status on stdout as "wipter-shim: ..." lines.
// Everything happens inside the app's process: no DevTools port or pipe.
//
// Env: WIPTER_EMAIL, WIPTER_PASSWORD (removed from the environment before the
// app starts, so neither its page nor wipter-tunnel sees them);
// WIPTER_SELFTEST=1 exits 0 once the sign-in form shows (1 after 4 minutes).
'use strict';
const path = require('path');
const { app } = require('electron');

const email = process.env.WIPTER_EMAIL || '';
const password = process.env.WIPTER_PASSWORD || '';
const selftest = process.env.WIPTER_SELFTEST === '1';
for (const k of ['WIPTER_EMAIL', 'WIPTER_PASSWORD', 'WIPTER_SELFTEST', 'VITE_DEV_SERVER_URL'])
    delete process.env[k];

const log = msg => process.stdout.write(`wipter-shim: ${msg}\n`);
const sleep = ms => new Promise(r => setTimeout(r, ms));

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
    win.webContents.once('did-finish-load', () => {
        if (watching || !win.webContents.getURL().includes('index.html'))
            return;
        watching = true;
        (selftest ? runSelftest : supervise)(win).catch(err => {
            log(`stopped: ${err && err.message || err}`);
            app.exit(1);
        });
    });
});

async function probe(win) {
    if (win.isDestroyed())
        throw new Error('the app window closed');
    return win.webContents.executeJavaScript(probeJS);
}

async function runSelftest(win) {
    const end = Date.now() + 4*60*1000;
    while (Date.now() < end) {
        const s = await probe(win).catch(() => ({}));
        if (s.ready && s.signin) {
            log('selftest: the sign-in form loaded');
            return app.exit(0);
        }
        await sleep(2000);
    }
    log('selftest: no sign-in form after 4 minutes');
    app.exit(1);
}

async function signIn(win) {
    log('signing in');
    for (const [id, value] of [['email-input', email], ['password-input', password]]) {
        if (!await win.webContents.executeJavaScript(fillJS(id, value)))
            throw new Error(`the sign-in form changed: no ${id}`);
    }
    for (let i = 0; !(await probe(win)).signinEnabled; i++) {
        if (i == 10)
            throw new Error('the sign-in button stays disabled (is WIPTER_EMAIL a valid address?)');
        await sleep(1000);
    }
    await win.webContents.executeJavaScript(clickJS('sign-in-button'));
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
    for (;;) {
        const s = await probe(win).catch(() => ({}));
        if (!s.ready) {
            await sleep(3000);
            continue;
        }
        if (s.consent) {
            // The app shares nothing until its data-sharing consent is
            // accepted; running this image is that choice.
            if (await win.webContents.executeJavaScript(clickJS('consent-agree-button')))
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
                    && await win.webContents.executeJavaScript(clickJS('switch-status-button'))) {
                    log('sharing was off: turned it on');
                    lastToggle = Date.now();
                }
            } else
                offlineSince = 0;
        }
        await sleep(15000);
    }
}

require(path.join(process.resourcesPath, 'app.asar', 'dist-electron', 'main', 'main.js'));
