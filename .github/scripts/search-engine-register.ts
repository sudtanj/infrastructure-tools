// Register every website served by Cloudflare Workers and Pages with Google and Bing.
//
// Run by .github/workflows/search-engine-register.yaml (Node 24 runs .ts directly);
// see that file for setup. No search engine credentials: the signed-in
// chrome-cdp-session Chrome profile (CHROME_CDP_URL) stands in for them.
//
//   1. discover  custom hostnames of Pages projects, Workers custom domains and Workers
//                routes. *.pages.dev, *.workers.dev and wildcard routes are skipped: their
//                DNS is not ours, so ownership cannot be proven.
//   2. inspect   keep a hostname only if https://<host>/ answers 200 with HTML, stays on
//                that host and is not noindex (drops APIs, proxies, redirects). Sitemaps
//                come from robots.txt, else /sitemap.xml and friends.
//   3. google    per zone, in Search Console in the browser: add the Domain property, put
//                the google-site-verification TXT record on the zone apex with the
//                Cloudflare API, Verify, then submit every host's sitemaps.
//   4. bing      the browser reads (or generates) the account's Webmaster API key from
//                Settings > API access; then per host over the API: AddSite, DNS-only
//                CNAME <code>.<host> -> verify.bing.com, VerifySite, SubmitFeed, and
//                SubmitUrlBatch within the daily quota. Yahoo, DuckDuckGo and Ecosia serve
//                Bing's index, so this covers them.
//
// Idempotent: existing records, verifications and properties are reused. Hostnames are
// logged as site-1 / zone-1 unless SHOW_HOSTNAMES is on: this runs in a public repo.

import { chromium, type Page } from "playwright-core";

const CF_API = "https://api.cloudflare.com/client/v4";
const BING_API = "https://ssl.bing.com/webmaster/api.svc/json";
// A browser UA: Cloudflare's bot protection may challenge a scripted one on our own sites.
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";
const HOST_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const SKIP_SUFFIXES = [".pages.dev", ".workers.dev"];
const NAV = { waitUntil: "domcontentloaded" as const, timeout: 60_000 };
const TXT_RE = /google-site-verification=[A-Za-z0-9_-]+/;
const VERIFIED_RE = /ownership (auto[- ]?)?verified/i;
const BING_KEY_RE = /\b[0-9a-f]{32}\b/i;

const env = (name: string) => (process.env[name] ?? "").trim();
const flag = (name: string) => ["1", "true", "yes", "on"].includes(env(name).toLowerCase());
const hostList = (name: string) =>
  env(name).split(/[\s,]+/).map((h) => h.toLowerCase().replace(/\.$/, "")).filter(Boolean);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const hostOf = (url: string) => {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
};

const DRY_RUN = flag("DRY_RUN");
const SHOW_HOSTNAMES = flag("SHOW_HOSTNAMES");

// ------------------------------------------------------------------ public-log redaction

const labels = new Map<string, string>();

function label(name: string, kind: string): string {
  if (!labels.has(name)) {
    const n = [...labels.values()].filter((v) => v.startsWith(kind + "-")).length + 1;
    labels.set(name, `${kind}-${n}`);
  }
  return SHOW_HOSTNAMES ? name : labels.get(name)!;
}

function redact(text: string): string {
  if (SHOW_HOSTNAMES) return text;
  for (const name of [...labels.keys()].sort((a, b) => b.length - a.length)) {
    text = text.split(name).join(labels.get(name)!);
  }
  return text;
}

const log = (msg: string) => console.log(redact(msg));
const warn = (msg: string) => console.log("::warning::" + redact(msg).replace(/\s*\n[\s\S]*/, ""));
// Playwright errors carry a multi-line call log; the first line is enough.
const brief = (e: unknown) => String(e instanceof Error ? e.message : e).split("\n")[0];

class ApiError extends Error {}

async function http(url: string, init: RequestInit = {}, timeoutMs = 30_000) {
  const headers = { "User-Agent": UA, ...((init.headers as Record<string, string>) ?? {}) };
  try {
    const res = await fetch(url, { ...init, headers, redirect: "follow", signal: AbortSignal.timeout(timeoutMs) });
    return { status: res.status, headers: res.headers, text: await res.text(), url: res.url };
  } catch (e) {
    return { status: 0, headers: new Headers(), text: brief(e), url };
  }
}

// ------------------------------------------------------------------ Cloudflare

class Cloudflare {
  token: string;
  account: string;

  constructor(token: string, account: string) {
    this.token = token;
    this.account = account;
  }

  async call(method: string, path: string, what: string, params?: Record<string, string | number>, body?: unknown) {
    const q = params ? "?" + new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])) : "";
    const res = await http(CF_API + path + q, {
      method,
      headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data: any = {};
    try {
      data = JSON.parse(res.text);
    } catch {}
    if (Math.floor(res.status / 100) !== 2 || !data.success) {
      const errs = (data.errors ?? []).map((e: any) => `${e.code}: ${e.message}`).join("; ");
      throw new ApiError(`Cloudflare ${what}: ${errs || `HTTP ${res.status}`}`);
    }
    return data;
  }

  async paged(path: string, what: string, params: Record<string, string> = {}, perPage = 50) {
    const out: any[] = [];
    for (let page = 1; ; page++) {
      const data = await this.call("GET", path, what, { ...params, page, per_page: perPage });
      const res: any[] = data.result ?? [];
      out.push(...res);
      const pages = data.result_info?.total_pages;
      if (!res.length || (pages && page >= pages) || (!pages && res.length < perPage)) return out;
    }
  }

  // Create the record unless one with this content exists; says what happened.
  async ensureRecord(zoneId: string, type: "TXT" | "CNAME", name: string, content: string) {
    const recs: any[] =
      (await this.call("GET", `/zones/${zoneId}/dns_records`, `list ${type} records`, { type, name })).result ?? [];
    const norm = (s: string) => (s ?? "").trim().replace(/^"|"$/g, "").replace(/\.$/, "").toLowerCase();
    if (recs.some((r) => norm(r.content) === norm(content))) return "exists";
    if (type === "CNAME" && recs.length) throw new ApiError(`a different CNAME already sits at ${name}`);
    if (DRY_RUN) return "would create";
    const body: Record<string, unknown> = {
      type, name, content, ttl: 1,
      comment: "search-engine-register: search engine ownership proof, keep",
    };
    // Bing must see the CNAME itself, not Cloudflare's proxy.
    if (type === "CNAME") body.proxied = false;
    await this.call("POST", `/zones/${zoneId}/dns_records`, `create ${type} record`, undefined, body);
    return "created";
  }
}

function routeHost(pattern: string): string | null {
  const host = (pattern ?? "").replace(/^https?:\/\//, "").split("/")[0].split(":")[0];
  return host.includes("*") ? null : host;
}

async function discover(cf: Cloudflare) {
  const zones = new Map<string, string>();
  try {
    for (const z of await cf.paged("/zones", "list zones", { "account.id": cf.account })) {
      if (z.status === "active") zones.set(z.name.toLowerCase(), z.id);
    }
  } catch (e) {
    warn(`Cannot list zones: ${brief(e)}. Give CLOUDFLARE_API_TOKEN Zone Read and DNS Edit.`);
  }

  const hosts = new Map<string, Set<string>>();
  const add = (host: string | null | undefined, source: string) => {
    const h = (host ?? "").trim().toLowerCase().replace(/\.$/, "");
    if (h && HOST_RE.test(h) && !SKIP_SUFFIXES.some((s) => h.endsWith(s))) {
      if (!hosts.has(h)) hosts.set(h, new Set());
      hosts.get(h)!.add(source);
    }
  };

  const sources: [string, () => Promise<void>][] = [
    ["Pages projects", async () => {
      for (const p of await cf.paged(`/accounts/${cf.account}/pages/projects`, "list Pages projects", {}, 10)) {
        for (const d of p.domains ?? []) add(d, "pages");
      }
    }],
    ["Workers custom domains", async () => {
      const data = await cf.call("GET", `/accounts/${cf.account}/workers/domains`, "list Workers custom domains");
      for (const d of data.result ?? []) add(d.hostname, "worker");
    }],
  ];
  for (const [zoneName, zoneId] of zones) {
    sources.push([`Workers routes of ${zoneName}`, async () => {
      const data = await cf.call("GET", `/zones/${zoneId}/workers/routes`, "list Workers routes");
      // A route without a script is an exclusion, not a site.
      for (const r of data.result ?? []) if (r.script) add(routeHost(r.pattern), "worker route");
    }]);
  }
  for (const [name, fetchSource] of sources) {
    try {
      await fetchSource();
    } catch (e) {
      warn(`Skipped ${name}: ${brief(e)} (does CLOUDFLARE_API_TOKEN have read access to it?)`);
    }
  }
  return { hosts, zones };
}

function zoneOf(host: string, zones: Map<string, string>) {
  const matches = [...zones.keys()].filter((z) => host === z || host.endsWith("." + z));
  return matches.sort((a, b) => b.length - a.length)[0] ?? null;
}

// ------------------------------------------------------------------ site checks

const NOINDEX_META = [
  /<meta[^>]+name=["']?(robots|googlebot|bingbot)["']?[^>]+content=["'][^"']*noindex/i,
  /<meta[^>]+content=["'][^"']*noindex[^"']*["'][^>]+name=["']?(robots|googlebot|bingbot)/i,
];

// null if the host is an indexable website, else why it is not.
async function inspectHome(host: string): Promise<string | null> {
  const res = await http(`https://${host}/`, { headers: { Accept: "text/html,application/xhtml+xml" } }, 20_000);
  if (res.status !== 200) return `home page answered HTTP ${res.status || "nothing"}`;
  if (hostOf(res.url) !== host) return "home page redirects to another host";
  if (!(res.headers.get("content-type") ?? "").toLowerCase().includes("html")) return "home page is not HTML";
  if ((res.headers.get("x-robots-tag") ?? "").toLowerCase().includes("noindex")) return "home page sends X-Robots-Tag: noindex";
  if (NOINDEX_META.some((r) => r.test(res.text))) return "home page has a noindex robots meta tag";
  return null;
}

// The sitemap body ("" for an unparsed .gz), or null if it is not one.
async function fetchSitemap(url: string, host: string): Promise<string | null> {
  if (hostOf(url) !== host) return null;
  const res = await http(url, { headers: { Accept: "application/xml,text/xml" } });
  if (res.status !== 200 || hostOf(res.url) !== host) return null;
  if (url.endsWith(".gz")) return "";
  return /<(\w+:)?(urlset|sitemapindex)\b/.test(res.text.slice(0, 4096)) ? res.text : null;
}

async function findSitemaps(host: string): Promise<string[]> {
  const listed: string[] = [];
  const robots = await http(`https://${host}/robots.txt`);
  if (robots.status === 200) {
    for (const line of robots.text.split(/\r?\n/)) {
      const m = line.match(/^\s*sitemap\s*:\s*(https:\/\/\S+)/i);
      if (m && !listed.includes(m[1])) listed.push(m[1]);
    }
  }
  const found: string[] = [];
  for (const u of listed) if ((await fetchSitemap(u, host)) !== null) found.push(u);
  if (!found.length) {
    for (const path of ["/sitemap.xml", "/sitemap_index.xml", "/sitemap-index.xml"]) {
      if ((await fetchSitemap(`https://${host}${path}`, host)) !== null) {
        found.push(`https://${host}${path}`);
        break;
      }
    }
  }
  return found;
}

const unescapeXml = (s: string) =>
  s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");

// Page URLs from the sitemaps (following sitemap indexes), home page first, then newest lastmod.
async function sitemapUrls(sitemaps: string[], host: string, limit: number): Promise<string[]> {
  const entries: [string, string][] = [];
  const queue = [...sitemaps];
  const seen = new Set<string>();
  while (queue.length && seen.size < 25) {
    const sm = queue.shift()!;
    if (seen.has(sm)) continue;
    seen.add(sm);
    const body = await fetchSitemap(sm, host);
    if (!body) continue;
    for (const m of body.matchAll(/<(?:\w+:)?(url|sitemap)\b[^>]*>([\s\S]*?)<\/(?:\w+:)?\1>/g)) {
      const loc = m[2].match(/<(?:\w+:)?loc>\s*([\s\S]*?)\s*<\//);
      if (!loc) continue;
      const url = unescapeXml(loc[1]);
      if (m[1] === "sitemap") queue.push(url);
      else if (hostOf(url) === host) entries.push([m[2].match(/<(?:\w+:)?lastmod>\s*([\s\S]*?)\s*<\//)?.[1] ?? "", url]);
    }
  }
  entries.sort((a, b) => (a[0] < b[0] ? 1 : a[0] > b[0] ? -1 : 0));
  const out = [`https://${host}/`];
  for (const [, url] of entries) if (!out.includes(url)) out.push(url);
  return out.slice(0, limit);
}

// ------------------------------------------------------------------ browser helpers

// Visible text plus form field values: tokens and keys often sit in read-only inputs.
async function pageText(page: Page): Promise<string> {
  try {
    return await page.evaluate(() => {
      const values = Array.from(document.querySelectorAll("input, textarea")).map((e) => (e as HTMLInputElement).value);
      return document.body.innerText + "\n" + values.join("\n");
    });
  } catch {
    return "";
  }
}

async function waitForText(page: Page, patterns: RegExp[], timeoutMs: number) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const text = await pageText(page);
    for (let i = 0; i < patterns.length; i++) {
      const m = text.match(patterns[i]);
      if (m) return { i, m };
    }
    await sleep(1000);
  }
  return null;
}

async function tryClick(page: Page, role: "button" | "tab" | "link" | "menuitem" | "option", name: RegExp, timeout = 5000) {
  try {
    await page.getByRole(role, { name }).first().click({ timeout });
    return true;
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------ Google Search Console

function signedOutOfGoogle(page: Page) {
  return /accounts\.google\.com|search\.google\.com\/search-console\/about/.test(page.url());
}

async function googleVerify(page: Page, cf: Cloudflare, zone: string, zoneId: string): Promise<string> {
  for (let attempt = 1; attempt <= 3; attempt++) {
    await page.goto("https://search.google.com/search-console/welcome?hl=en", NAV);
    if (signedOutOfGoogle(page)) {
      throw new ApiError("the saved Chrome profile is not signed in to Google; sign in over VNC in chrome-cdp-session");
    }
    // The Domain card's field; the URL prefix card's placeholder is https://www.example.com.
    const field = page.getByPlaceholder("example.com", { exact: true });
    await field.waitFor({ timeout: 30_000 });
    await field.fill(zone);
    await field.press("Enter");
    let seen = await waitForText(page, [TXT_RE, VERIFIED_RE], 15_000);
    if (!seen) {
      await tryClick(page, "button", /^continue$/i);
      seen = await waitForText(page, [TXT_RE, VERIFIED_RE], 30_000);
    }
    if (!seen) {
      // Cloudflare-hosted domains may get the Domain Connect flow first; ask for the plain TXT record.
      try {
        await page.getByRole("combobox").or(page.getByRole("listbox")).first().click({ timeout: 5000 });
        await tryClick(page, "option", /any dns provider/i);
      } catch {}
      seen = await waitForText(page, [TXT_RE, VERIFIED_RE], 15_000);
    }
    if (!seen) throw new ApiError("Search Console showed neither a TXT record nor a verified domain");
    if (seen.i === 1) return "already verified";

    log(`  google: TXT record on ${zone}: ${await cf.ensureRecord(zoneId, "TXT", zone, seen.m[0])}`);
    if (DRY_RUN) return "would verify";
    await page.getByRole("button", { name: /^verify$/i }).last().click({ timeout: 10_000 });
    const result = await waitForText(page, [VERIFIED_RE, /verification failed|couldn.t verify|could not verify/i], 90_000);
    if (result?.i === 0) return "verified";
    if (attempt < 3) await sleep(30_000);
  }
  throw new ApiError("Google did not verify the domain yet (the TXT record stays; the next run retries)");
}

async function googleSitemap(page: Page, zone: string, sitemap: string): Promise<boolean> {
  await page.goto(
    `https://search.google.com/search-console/sitemaps?resource_id=${encodeURIComponent("sc-domain:" + zone)}&hl=en`,
    NAV,
  );
  const field = page.getByRole("textbox", { name: /sitemap/i }).or(page.getByPlaceholder(/sitemap/i)).first();
  await field.waitFor({ timeout: 30_000 });
  await field.fill(sitemap);
  await page.getByRole("button", { name: /^submit$/i }).first().click({ timeout: 10_000 });
  const result = await waitForText(page, [/submitted successfully/i, /couldn.t fetch|invalid|error/i], 30_000);
  await tryClick(page, "button", /got it|ok/i, 3000);
  return result?.i === 0;
}

async function google(page: Page, cf: Cloudflare, zone: string, zoneId: string, sitemaps: string[]) {
  const state = await googleVerify(page, cf, zone, zoneId);
  log(`  google: ${zone} ${state}`);
  if (DRY_RUN) return `${state}; would submit ${sitemaps.length} sitemap(s)`;
  let ok = 0;
  for (const sm of sitemaps) {
    try {
      if (await googleSitemap(page, zone, sm)) ok++;
      else warn(`Google did not accept sitemap ${sm}`);
    } catch (e) {
      warn(`Google sitemap ${sm}: ${brief(e)}`);
    }
  }
  return `${state}, ${ok}/${sitemaps.length} sitemap(s) submitted`;
}

// ------------------------------------------------------------------ Bing Webmaster Tools

// The account's Webmaster API key, from Settings > API access (generated if there is none).
async function bingApiKey(page: Page): Promise<string> {
  await page.goto("https://www.bing.com/webmasters/?hl=en", NAV);
  await sleep(5000);
  if (/login\.(live|microsoftonline)\.com|\/webmasters\/about/.test(page.url())) {
    throw new ApiError("the saved Chrome profile is not signed in to Bing Webmaster Tools; sign in over VNC in chrome-cdp-session");
  }
  if (!(await tryClick(page, "button", /settings/i, 15_000)) && !(await tryClick(page, "link", /settings/i))) {
    throw new ApiError("Bing Webmaster Tools: no Settings button");
  }
  if (!(await tryClick(page, "menuitem", /api access/i)) && !(await tryClick(page, "link", /api access/i))) {
    await page.getByText(/^api access$/i).first().click({ timeout: 10_000 });
  }
  await sleep(3000);
  let found = await waitForText(page, [BING_KEY_RE], 5000);
  if (!found && !DRY_RUN) {
    // First use: the terms, then the key itself.
    try {
      await page.getByRole("checkbox").first().check({ timeout: 3000 });
    } catch {}
    await tryClick(page, "button", /accept|agree/i, 3000);
    await tryClick(page, "tab", /api key/i, 3000) || (await tryClick(page, "button", /^api key$/i, 3000));
    await tryClick(page, "button", /generate/i, 5000);
    await tryClick(page, "button", /view|show|reveal/i, 3000);
    found = await waitForText(page, [BING_KEY_RE], 20_000);
  }
  if (!found) throw new ApiError("Bing Webmaster Tools: no API key on the API access page");
  const key = found.m[0];
  console.log(`::add-mask::${key}`);
  return key;
}

class Bing {
  key: string;
  sitesCache: Map<string, any> | null = null;

  constructor(key: string) {
    this.key = key;
  }

  async call(method: string, name: string, body?: unknown, params: Record<string, string> = {}) {
    const q = new URLSearchParams({ ...params, apikey: this.key });
    const res = await http(`${BING_API}/${name}?${q}`, {
      method,
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: body === undefined ? (method === "POST" ? "" : undefined) : JSON.stringify(body),
    });
    let data: any = {};
    try {
      data = res.text.trim() ? JSON.parse(res.text) : {};
    } catch {}
    if (res.status !== 200) throw new ApiError(`Bing ${name}: HTTP ${res.status} ${data?.Message ?? ""}`.trim());
    return data?.d;
  }

  async sites(refresh = false) {
    if (!this.sitesCache || refresh) {
      this.sitesCache = new Map();
      for (const s of (await this.call("GET", "GetUserSites")) ?? []) {
        const h = hostOf(s.Url ?? "");
        if (h) this.sitesCache.set(h, s);
      }
    }
    return this.sitesCache;
  }
}

async function bing(api: Bing, cf: Cloudflare, host: string, zoneId: string, sitemaps: string[], urlLimit: number) {
  let site = (await api.sites()).get(host);
  if (!site) {
    if (DRY_RUN) return "would add, verify and submit";
    await api.call("POST", "AddSite", { siteUrl: `https://${host}/` });
    site = (await api.sites(true)).get(host);
    if (!site) throw new ApiError("Bing AddSite succeeded but the site is not listed");
    log(`  bing: ${host} added`);
  }
  const siteUrl: string = site.Url;

  if (!site.IsVerified) {
    const cname = String(site.DnsVerificationCode || `${String(site.AuthenticationCode ?? "").toLowerCase()}.${host}`)
      .toLowerCase().replace(/\.$/, "");
    if (!cname.endsWith("." + host)) throw new ApiError("Bing returned no usable DNS verification code");
    log(`  bing: CNAME record: ${await cf.ensureRecord(zoneId, "CNAME", cname, "verify.bing.com")}`);
    if (DRY_RUN) return "would verify and submit";
    let verified = false;
    for (let attempt = 1; attempt <= 5 && !verified; attempt++) {
      verified = Boolean(await api.call("POST", "VerifySite", { siteUrl }));
      if (!verified && attempt < 5) await sleep(20_000);
    }
    if (!verified) return "added, verification pending (the CNAME stays; the next run retries)";
    log(`  bing: ${host} verified`);
  } else if (DRY_RUN) {
    return "already verified; would submit";
  }

  for (const sm of sitemaps) await api.call("POST", "SubmitFeed", { siteUrl, feedUrl: sm });
  const quota = (await api.call("GET", "GetUrlSubmissionQuota", undefined, { siteUrl })) ?? {};
  const room = Math.min(urlLimit, quota.DailyQuota ?? 0, quota.MonthlyQuota ?? 0, 500);
  const urls = room > 0 ? await sitemapUrls(sitemaps, host, room) : [];
  if (urls.length) await api.call("POST", "SubmitUrlBatch", { siteUrl, urlList: urls });
  return `${sitemaps.length} sitemap(s) and ${urls.length} URL(s) submitted (daily quota ${quota.DailyQuota ?? "?"})`;
}

// ------------------------------------------------------------------ main

async function main(): Promise<number> {
  const token = env("CLOUDFLARE_API_TOKEN");
  const account = env("CLOUDFLARE_ACCOUNT_ID");
  const cdpUrl = env("CHROME_CDP_URL");
  if (!token || !account || !cdpUrl) {
    console.log("::error::CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID and CHROME_CDP_URL are required.");
    return 1;
  }
  const urlLimit = Number.parseInt(env("BING_URL_LIMIT"), 10) || 100;
  const engines = (env("ENGINES") || "google,bing").toLowerCase();
  if (DRY_RUN) log("Dry run: nothing is created, verified or submitted.");

  const cf = new Cloudflare(token, account);
  const { hosts, zones } = await discover(cf);
  for (const h of hostList("SEO_INCLUDE_HOSTS")) {
    if (!hosts.has(h)) hosts.set(h, new Set());
    hosts.get(h)!.add("included");
  }
  for (const h of hostList("SEO_EXCLUDE_HOSTS")) hosts.delete(h);
  for (const z of [...zones.keys()].sort()) label(z, "zone");
  const sorted = [...hosts.keys()].sort();
  for (const h of sorted) label(h, "site");
  log(`Found ${hosts.size} custom hostname(s) in ${zones.size} zone(s).`);

  const rows: [string, string, string][] = [];
  const sites = new Map<string, { zone: string; sitemaps: string[] }>();
  for (const host of sorted) {
    const zone = zoneOf(host, zones);
    let why = hosts.get(host)!.has("included") ? null : await inspectHome(host);
    if (!zone) why = "its DNS is not in a zone this token can see";
    if (why) {
      rows.push([label(host, "site"), "-", `skipped: ${why}`]);
      continue;
    }
    const sitemaps = await findSitemaps(host);
    sites.set(host, { zone: zone!, sitemaps });
    log(`${label(host, "site")} (${[...hosts.get(host)!].sort().join(", ")}): website, ${sitemaps.length} sitemap(s)`);
  }

  let failed = false;
  if (sites.size) {
    const browser = await chromium.connectOverCDP(cdpUrl, { timeout: 60_000 });
    const context = browser.contexts()[0] ?? (await browser.newContext());
    const page = await context.newPage();
    try {
      if (engines.includes("google")) {
        for (const zone of [...new Set([...sites.values()].map((s) => s.zone))].sort()) {
          log(`Google: ${zone}`);
          const sitemaps = [...sites.values()].filter((s) => s.zone === zone).flatMap((s) => s.sitemaps);
          try {
            rows.push([label(zone, "zone"), "google", await google(page, cf, zone, zones.get(zone)!, sitemaps)]);
          } catch (e) {
            warn(`Google, ${zone}: ${brief(e)}`);
            rows.push([label(zone, "zone"), "google", `failed: ${brief(e)}`]);
            failed = true;
          }
        }
      }

      if (engines.includes("bing")) {
        let api: Bing | null = null;
        try {
          api = new Bing(await bingApiKey(page));
          await api.sites();
        } catch (e) {
          warn(`Bing skipped: ${brief(e)}`);
          rows.push(["all", "bing", `skipped: ${brief(e)}`]);
          failed = true;
          api = null;
        }
        for (const [host, { zone, sitemaps }] of api ? [...sites].sort((a, b) => a[0].localeCompare(b[0])) : []) {
          log(`Bing: ${host}`);
          try {
            rows.push([label(host, "site"), "bing", await bing(api!, cf, host, zones.get(zone)!, sitemaps, urlLimit)]);
          } catch (e) {
            warn(`Bing, ${host}: ${brief(e)}`);
            rows.push([label(host, "site"), "bing", `failed: ${brief(e)}`]);
            failed = true;
          }
        }
      }
    } finally {
      // Only our tab: the browser may be the shared chrome-cdp-session one.
      await page.close().catch(() => {});
    }
  }

  const summary = [
    `## Search engine registration${DRY_RUN ? " (dry run)" : ""}`,
    "",
    `${sites.size} website(s) of ${hosts.size} hostname(s). Yahoo, DuckDuckGo and Ecosia serve Bing's index.`,
    "",
    "| Site / zone | Engine | Result |",
    "| --- | --- | --- |",
    ...rows.map(([a, b, c]) => `| ${a} | ${b} | ${c.replace(/\|/g, "/")} |`),
  ].join("\n");
  const text = redact(summary) + "\n";
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) {
    const { appendFileSync } = await import("node:fs");
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, text);
  }
  return failed ? 1 : 0;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.log("::error::" + redact(brief(e)));
    process.exit(1);
  },
);
