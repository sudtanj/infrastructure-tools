// paseo-wake: a Cloudflare Worker in front of paseo-lite's Instabox public URL.
//
// A paused Instabox machine answers its public URL with "Sandbox offline", and
// nothing on the machine can wake it. This Worker proxies "/" and "/ws" to the
// daemon and, when the machine is asleep and the caller proved it knows the
// Paseo password, wakes it through the Instabox API first.
//
// Secrets (Worker secrets, set by .github/workflows/cloudflare-paseo-wake.yaml
// from GitHub secrets; none of them is ever logged or sent to a client):
//   UPSTREAM_URL         the machine's public port URL (https://16768-....)
//   INSTABOX_MACHINE_ID  the machine to wake
//   INSTABOX_WAKE_KEY    an Instabox API key, used only for the wake call
//   PASSWORD_SALT        random, regenerated on every deploy
//   PASSWORD_SHA256      hex sha256("<salt>:<PASEO_PASSWORD>"); the password itself is not stored
// Binding AUTH_LIMIT (wrangler.toml): password attempts per client IP.

const INSTABOX_API = "https://api.instabox.sh";
const WAKE_WAIT_MS = 45_000;
const BEARER_PREFIX = "paseo.bearer.";
const SECURITY_HEADERS = {
  "Cache-Control": "no-store",
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
};
const REQUIRED = ["UPSTREAM_URL", "INSTABOX_MACHINE_ID", "INSTABOX_WAKE_KEY", "PASSWORD_SALT", "PASSWORD_SHA256"];

export default {
  async fetch(request, env) {
    // Fail closed while the secrets are missing (e.g. between deploy and `secret bulk`).
    if (REQUIRED.some((k) => !env[k])) return text(503, "Not configured.");
    const url = new URL(request.url);
    const ip = request.headers.get("cf-connecting-ip") || "unknown";

    if (url.pathname === "/__wake" && request.method === "POST") return wakeForm(request, env, ip);
    if (url.pathname !== "/" && url.pathname !== "/ws") return text(404, "Not found.");
    if (request.method !== "GET") return text(405, "Method not allowed.");

    const isWs = (request.headers.get("upgrade") || "").toLowerCase() === "websocket";
    // The Paseo app sends its password in the subprotocol and the Authorization header.
    // The pairing page sends it inside the socket instead, so it has none here.
    const password = offeredPassword(request.headers);
    // Every socket counts, so password guesses inside the socket are throttled too.
    if ((isWs || password !== null) && !(await allowAttempt(env, ip))) return text(429, "Too many attempts, wait a minute.");
    const authed = password !== null && (await passwordOk(env, password));
    if (password !== null && !authed) return text(401, "Wrong password.");

    let res = await proxy(request, env, url, isWs);
    if (isUp(res, isWs)) return res;
    res.body?.cancel();
    if (authed && (await wake(env))) {
      res = await proxy(request, env, url, isWs);
      if (isUp(res, isWs)) return res;
    }
    if (isWs) return text(503, "Paseo is asleep.");
    return sleepingPage(url.searchParams.get("e"));
  },
};

function offeredPassword(headers) {
  const protocols = (headers.get("sec-websocket-protocol") || "").split(",").map((p) => p.trim());
  const bearer = protocols.find((p) => p.startsWith(BEARER_PREFIX) && p.length > BEARER_PREFIX.length);
  if (bearer) return bearer.slice(BEARER_PREFIX.length);
  const auth = headers.get("authorization") || "";
  return /^Bearer\s+\S/i.test(auth) ? auth.replace(/^Bearer\s+/i, "") : null;
}

async function allowAttempt(env, ip) {
  if (!env.AUTH_LIMIT) return true;
  const { success } = await env.AUTH_LIMIT.limit({ key: ip });
  return success;
}

async function passwordOk(env, password) {
  const data = new TextEncoder().encode(`${env.PASSWORD_SALT}:${password}`);
  const got = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  const want = hexToBytes(env.PASSWORD_SHA256);
  return want !== null && want.length === got.length && crypto.subtle.timingSafeEqual(got, want);
}

function hexToBytes(hex) {
  if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
  return Uint8Array.from(hex.match(/../g), (b) => parseInt(b, 16));
}

function proxy(request, env, url, isWs) {
  const target = new URL(url.pathname + url.search, env.UPSTREAM_URL);
  const headers = new Headers(request.headers);
  for (const h of ["host", "cookie", "cf-connecting-ip", "x-forwarded-for", "x-real-ip"]) headers.delete(h);
  return fetch(target, { method: "GET", headers, redirect: "manual" }).catch(() => new Response(null, { status: 502 }));
}

// The daemon answers the socket with 101, and "/" with its pairing page, which sets
// X-Frame-Options: DENY. Instabox's "Sandbox offline" page does neither.
function isUp(res, isWs) {
  if (isWs) return res.status === 101;
  return res.status === 200 && (res.headers.get("x-frame-options") || "").toUpperCase() === "DENY";
}

// Resumes a machine Instabox paused for being idle (one you paused or stopped
// yourself stays so), then waits until the daemon answers.
async function wake(env) {
  const api = `${INSTABOX_API}/v1/machines/${encodeURIComponent(env.INSTABOX_MACHINE_ID)}/wake`;
  const r = await fetch(api, { method: "POST", headers: { "X-API-Key": env.INSTABOX_WAKE_KEY } }).catch(() => null);
  console.log(`wake: instabox answered ${r ? r.status : "no response"}`);
  // Other answers (e.g. "already running" or "resuming") still mean waiting may pay off.
  if (!r || [401, 403, 404, 405].includes(r.status)) return false;
  const deadline = Date.now() + WAKE_WAIT_MS;
  while (Date.now() < deadline) {
    const probe = await fetch(new URL("/", env.UPSTREAM_URL), { redirect: "manual" }).catch(() => null);
    probe?.body?.cancel();
    if (probe && isUp(probe, false)) return true;
    await new Promise((resolve) => setTimeout(resolve, 1500));
  }
  return false;
}

async function wakeForm(request, env, ip) {
  if (!(await allowAttempt(env, ip))) return seeOther("/?e=limit");
  const form = await request.formData().catch(() => null);
  const password = form && form.get("password");
  if (typeof password !== "string" || !(await passwordOk(env, password))) return seeOther("/?e=password");
  return seeOther((await wake(env)) ? "/" : "/?e=wake");
}

function seeOther(location) {
  return new Response(null, { status: 303, headers: { Location: location, ...SECURITY_HEADERS } });
}

function text(status, body) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...SECURITY_HEADERS } });
}

const ERRORS = {
  password: "Wrong password.",
  limit: "Too many attempts, wait a minute.",
  wake: "Could not wake the machine. Try again, or start it from Instabox.",
};

function sleepingPage(error) {
  const message = ERRORS[error] || "";
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>Paseo Lite</title>
<style>
body{margin:0;font:14px/1.45 system-ui,sans-serif;background:#0f1115;color:#e6e8ec;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}
.card{width:min(400px,100%);background:#171a21;border:1px solid #262a33;border-radius:12px;padding:22px}
h1{font-size:17px;margin:0 0 4px}p{color:#8b93a1}.err{color:#f85149;min-height:1.45em}
input,button{font:inherit;color:#e6e8ec;background:#0c0e12;border:1px solid #262a33;border-radius:6px;padding:8px 10px;width:100%;box-sizing:border-box}
button{margin-top:12px;cursor:pointer;background:#6aa6ff;color:#0b1020;border-color:#6aa6ff}
</style></head><body><main class="card"><h1>Paseo Lite</h1>
<p>The machine is asleep. Enter the password to wake it (up to a minute).</p>
<form method="post" action="/__wake"><input type="password" name="password" autocomplete="current-password" placeholder="Password" required autofocus>
<p class="err" role="alert">${message}</p><button>Wake</button></form></main></body></html>`;
  return new Response(html, { status: 503, headers: { "Content-Type": "text/html; charset=utf-8", "Retry-After": "30", ...SECURITY_HEADERS } });
}
