#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Paced, human-like public search-result collection that measures how many
// searches one browser identity completes before a CAPTCHA/challenge.
// It never solves CAPTCHAs: it stops, or waits for a human in headed mode.
// Policy: .agents/aidevops/reach-capture.md "Public Search-result Collection".

import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

import { loadPlaywright, resolvePlaywrightBrowserExecutable } from './playwright-runtime.mjs';

const SCHEMA = 'aidevops.serp-probe/v1';
const WORKSPACE = process.env.AIDEVOPS_SERP_PROBE_DIR?.trim()
  || join(homedir(), '.aidevops', '.agent-workspace', 'serp-probe');
const NAV_TIMEOUT_MS = 30_000;
const CONSENT_WAIT_MS = 180_000;
const HUMAN_SOLVE_WAIT_MS = 600_000;

const ENGINES = {
  google: {
    home: ({ gl, hl }) => `https://www.google.com/?hl=${encodeURIComponent(hl)}&gl=${encodeURIComponent(gl)}`,
    input: 'textarea[name="q"], input[name="q"]',
    results: '#search, #rso',
    // Organic links may be direct, /url?q=<dest>, or opaque /goto?url=<token>
    // (seen 2026-10-05). For opaque links, fall back to the displayed <cite>
    // (domain + breadcrumb path), which is what a person sees.
    organic: () => [...document.querySelectorAll('#search a h3')]
      .map((h3) => {
        const a = h3.closest('a');
        if (!a?.href) return null;
        const url = new URL(a.href, location.href);
        if (!/(^|\.)google\./.test(url.hostname)) return url.href;
        const q = url.searchParams.get('q') || url.searchParams.get('url');
        if (q && /^https?:\/\//.test(q)) return q;
        const cite = a.closest('.MjjYud, [data-hveid]')?.querySelector('cite') || a.querySelector('cite');
        return cite?.textContent?.split(' · ')[0].trim().replace(/\s*›\s*/g, '/') || null;
      })
      .filter(Boolean),
  },
  bing: {
    home: ({ gl, hl }) => `https://www.bing.com/?cc=${encodeURIComponent(gl)}&setlang=${encodeURIComponent(hl)}`,
    input: 'textarea[name="q"], input[name="q"]',
    results: '#b_results',
    // Bing wraps links as /ck/a?...&u=a1<base64url destination>.
    organic: () => [...document.querySelectorAll('#b_results li.b_algo h2 a')]
      .map((a) => {
        if (!a.href) return null;
        const url = new URL(a.href, location.href);
        const u = url.searchParams.get('u');
        if (!/(^|\.)bing\.com$/.test(url.hostname) || !u?.startsWith('a1')) return url.href;
        try {
          const b64 = u.slice(2).replace(/-/g, '+').replace(/_/g, '/');
          const dest = atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4));
          return /^https?:\/\//.test(dest) ? dest : url.href;
        } catch {
          return url.href;
        }
      })
      .filter(Boolean),
  },
};

function usage() {
  return `Usage: serp-captcha-probe.mjs --keywords-file <file> | --keyword <kw> [--keyword <kw> ...]
  --engine google|bing      Search engine (default: google)
  --max <n>                 Maximum searches (default: 20, max: 200)
  --min-delay <s>           Minimum gap between searches (default: 45, min: 10)
  --max-delay <s>           Maximum gap between searches (default: 120)
  --gl <cc> --hl <lang>     Country and interface language (default: us, en)
  --headless                Run headless (default: headed)
  --hidden                  macOS: run headed but hidden (Cmd-H style); shown only when you must act
  --on-captcha stop|wait    stop (default) or wait for a human solve (headed only)
  --consent manual|reject   Cookie-consent prompt: wait for you (default) or click "Reject all"
  --fresh-profile           Use a new temporary profile instead of the persistent probe profile
  --no-evidence             Do not keep result HTML
  --shuffle                 Randomize keyword order
  --dry-run                 Validate and print the plan without opening a browser
Proxy: set SERP_PROBE_PROXY in the environment (the wrapper resolves it from aidevops secrets).`;
}

const CLI_OPTIONS = {
  'keywords-file': { type: 'string' },
  keyword: { type: 'string', multiple: true },
  engine: { type: 'string', default: 'google' },
  max: { type: 'string', default: '20' },
  'min-delay': { type: 'string', default: '45' },
  'max-delay': { type: 'string', default: '120' },
  gl: { type: 'string', default: 'us' },
  hl: { type: 'string', default: 'en' },
  locale: { type: 'string' },
  timezone: { type: 'string' },
  headless: { type: 'boolean', default: false },
  hidden: { type: 'boolean', default: false },
  'on-captcha': { type: 'string', default: 'stop' },
  consent: { type: 'string', default: 'manual' },
  'fresh-profile': { type: 'boolean', default: false },
  'no-evidence': { type: 'boolean', default: false },
  shuffle: { type: 'boolean', default: false },
  'dry-run': { type: 'boolean', default: false },
  help: { type: 'boolean', default: false },
};

const fail = (message) => { throw new Error(message); };

function validateChoices(values) {
  const rules = [
    [!Object.hasOwn(ENGINES, values.engine), '--engine must be google or bing'],
    [!['stop', 'wait'].includes(values['on-captcha']), '--on-captcha must be stop or wait'],
    [values['on-captcha'] === 'wait' && values.headless, '--on-captcha wait requires a headed browser'],
    [!['manual', 'reject'].includes(values.consent), '--consent must be manual or reject'],
    [values.hidden && values.headless, '--hidden and --headless are mutually exclusive'],
    [values.hidden && process.platform !== 'darwin', '--hidden is macOS-only'],
    [!/^[a-z]{2}$/i.test(values.gl), '--gl must be a two-letter country code such as us'],
    [!/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/i.test(values.hl), '--hl must be a language code such as en'],
  ];
  const broken = rules.find(([failed]) => failed);
  if (broken) fail(broken[1]);
}

function loadKeywords(values) {
  const raw = [...(values.keyword || [])];
  if (values['keywords-file']) raw.push(...readFileSync(values['keywords-file'], 'utf8').split('\n'));
  const keywords = raw.map((kw) => kw.trim()).filter((kw) => kw && !kw.startsWith('#'));
  if (keywords.length === 0) fail('Provide --keyword or --keywords-file with at least one keyword');
  if (values.shuffle) {
    for (let i = keywords.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [keywords[i], keywords[j]] = [keywords[j], keywords[i]];
    }
  }
  return keywords;
}

function parseOptions(argv) {
  const { values } = parseArgs({ args: argv, options: CLI_OPTIONS, strict: true });
  if (values.help) return { help: true };
  const int = (name, min, max) => {
    const value = Number(values[name]);
    if (!Number.isInteger(value) || value < min || value > max) fail(`--${name} must be an integer from ${min} to ${max}`);
    return value;
  };
  validateChoices(values);
  const keywords = loadKeywords(values);

  const minDelay = int('min-delay', 10, 3600);
  const maxDelay = int('max-delay', minDelay, 7200);
  const max = int('max', 1, 200);
  return {
    engine: values.engine,
    keywords: keywords.slice(0, max),
    minDelay,
    maxDelay,
    gl: values.gl.toLowerCase(),
    hl: values.hl,
    locale: values.locale || `${values.hl}-${values.gl.toUpperCase()}`,
    timezone: values.timezone,
    headless: values.headless,
    hidden: values.hidden,
    onCaptcha: values['on-captcha'],
    consent: values.consent,
    freshProfile: values['fresh-profile'],
    keepEvidence: !values['no-evidence'],
    dryRun: values['dry-run'],
  };
}

const log = (message) => process.stderr.write(`[serp-probe] ${message}\n`);
const randomBetween = (min, max) => min + Math.random() * (max - min);
const tildePath = (path) => path.replace(homedir(), '~');

// macOS window control for --hidden. Hiding the app (like Cmd-H) returns focus
// to the previous app, and pages still report visibilityState "visible" with
// animation frames running (verified 2026-10-05), so behaviour matches headed.
function macApp(pid, action) {
  const call = { hide: 'a.hide', show: '(a.unhide, a.activateWithOptions(0))', hidden: 'a.hidden' }[action];
  try {
    return execFileSync('osascript', ['-l', 'JavaScript', '-e',
      `ObjC.import('AppKit'); var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${Number(pid)}); a.isNil() ? 'none' : String(${call})`],
    { encoding: 'utf8', timeout: 10_000 }).trim();
  } catch {
    return 'error';
  }
}

function findBrowserPid() {
  let children = [];
  try {
    children = execFileSync('pgrep', ['-P', String(process.pid)], { encoding: 'utf8' }).trim().split('\n').filter(Boolean);
  } catch {
    return null;
  }
  return children.find((pid) => !['none', 'error'].includes(macApp(pid, 'hidden'))) || null;
}

async function hideBrowser(pid) {
  for (let i = 0; i < 40; i += 1) {
    if (macApp(pid, 'hidden') === 'true') return true;
    macApp(pid, 'hide');
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

let stopRequested = false;
async function sleep(ms) {
  const end = Date.now() + ms;
  while (!stopRequested && Date.now() < end) {
    await new Promise((resolve) => setTimeout(resolve, Math.min(1000, end - Date.now())));
  }
}

function proxyFromEnv() {
  const raw = process.env.SERP_PROBE_PROXY?.trim();
  if (!raw) return undefined;
  const url = new URL(raw);
  return {
    server: `${url.protocol}//${url.host}`,
    username: url.username ? decodeURIComponent(url.username) : undefined,
    password: url.password ? decodeURIComponent(url.password) : undefined,
  };
}

async function detectBlock(page) {
  return page.evaluate(() => {
    const text = (document.body?.innerText || '').slice(0, 6000).toLowerCase();
    if (location.pathname.startsWith('/sorry') || document.querySelector('#captcha-form, form[action*="sorry"]')) return 'google_sorry';
    if (document.querySelector('iframe[src*="recaptcha"], iframe[title*="reCAPTCHA"]')) return 'recaptcha';
    if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) return 'turnstile';
    if (text.includes('unusual traffic from your computer network')) return 'unusual_traffic';
    if (text.includes('verify you are human') || text.includes('solve the challenge')) return 'challenge';
    return null;
  }).catch(() => null);
}

async function detectConsent(page) {
  if (page.url().includes('consent.')) return true;
  return page.evaluate(() => [...document.querySelectorAll('button, [role="button"]')]
    .some((el) => /^(reject all|accept all|i agree)$/i.test((el.textContent || '').trim()))).catch(() => false);
}

async function waitUntil(predicate, timeoutMs) {
  const end = Date.now() + timeoutMs;
  while (!stopRequested && Date.now() < end) {
    if (await predicate()) return true;
    await sleep(2000);
  }
  return false;
}

async function humanType(page, selector, text) {
  const input = page.locator(selector).first();
  await input.click({ timeout: NAV_TIMEOUT_MS });
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+A' : 'Control+A');
  await page.keyboard.press('Backspace');
  await sleep(randomBetween(300, 900));
  for (const char of text) {
    await page.keyboard.type(char);
    await sleep(randomBetween(60, 190));
  }
  await sleep(randomBetween(250, 800));
  await page.keyboard.press('Enter');
}

async function dwell(page) {
  const scrolls = 1 + Math.floor(Math.random() * 3);
  for (let i = 0; i < scrolls && !stopRequested; i += 1) {
    await page.mouse.wheel(0, randomBetween(250, 700)).catch(() => {});
    await sleep(randomBetween(1200, 3500));
  }
}

function createRun(options, proxy) {
  const runId = new Date().toISOString().replace(/[:.]/g, '-');
  const runDir = join(WORKSPACE, 'runs', runId);
  mkdirSync(runDir, { recursive: true, mode: 0o700 });
  for (const dir of [WORKSPACE, join(WORKSPACE, 'runs'), runDir]) chmodSync(dir, 0o700);
  const report = {
    schema: SCHEMA,
    run_id: runId,
    engine: options.engine,
    gl: options.gl,
    hl: options.hl,
    headless: options.headless,
    egress: proxy ? 'proxy' : 'direct',
    profile: options.freshProfile ? 'fresh' : 'persistent',
    pacing_seconds: { min: options.minDelay, max: options.maxDelay },
    on_captcha: options.onCaptcha,
    started_at: new Date().toISOString(),
    ended_at: null,
    planned: options.keywords.length,
    attempted: 0,
    succeeded: 0,
    first_block: null,
    blocks: [],
    stop_reason: 'completed',
    queries: [],
    run_dir: tildePath(runDir),
  };
  const save = () => {
    report.ended_at = new Date().toISOString();
    writeFileSync(join(runDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  };
  return { runDir, report, save };
}

async function launchBrowser(options, runDir, proxy) {
  const runtime = await loadPlaywright();
  const executablePath = resolvePlaywrightBrowserExecutable(runtime) || undefined;
  const profileDir = options.freshProfile ? join(runDir, 'profile') : join(WORKSPACE, `profile-${options.engine}`);
  mkdirSync(profileDir, { recursive: true, mode: 0o700 });
  chmodSync(profileDir, 0o700);
  const context = await runtime.chromium.launchPersistentContext(profileDir, {
    headless: options.headless,
    executablePath,
    proxy,
    locale: options.locale,
    timezoneId: options.timezone,
    viewport: null,
    // Present as an ordinary browser: without these, navigator.webdriver is true
    // and Google serves /sorry/ on the first query (observed 2026-10-05).
    ignoreDefaultArgs: ['--enable-automation'],
    args: ['--disable-blink-features=AutomationControlled'],
  });
  return { context, browser: executablePath?.includes('Brave') ? 'brave' : 'chromium' };
}

// Returns window controls; showForHuman/rehide are no-ops unless --hidden worked.
async function setupWindow(options, report) {
  report.window = options.headless ? 'headless' : 'visible';
  const browserPid = options.hidden ? findBrowserPid() : null;
  if (options.hidden) {
    report.window = browserPid && await hideBrowser(browserPid) ? 'hidden' : 'visible';
    if (report.window !== 'hidden') log('Could not hide the browser window; continuing visible');
  }
  const hidden = report.window === 'hidden';
  return {
    showForHuman: () => { if (hidden) macApp(browserPid, 'show'); },
    rehide: async () => { if (hidden) await hideBrowser(browserPid); },
  };
}

// Returns null when searching can proceed, or a stop reason.
async function handleConsent(page, options, win) {
  if (await detectConsent(page) && options.consent === 'reject') {
    await sleep(randomBetween(1500, 3500));
    await page.getByRole('button', { name: /^reject all$/i }).first().click({ timeout: 10_000 }).catch(() => {});
    await page.waitForLoadState('domcontentloaded').catch(() => {});
    await sleep(randomBetween(1500, 3000));
  }
  if (!await detectConsent(page)) return null;
  if (options.headless) return 'consent_required';
  log('Consent prompt shown: choose an option in the browser window (waiting up to 3 minutes)');
  win.showForHuman();
  if (!await waitUntil(async () => !(await detectConsent(page)), CONSENT_WAIT_MS)) return 'consent_required';
  await win.rehide();
  return null;
}

const evidenceName = (n, suffix = '') => `q${String(n).padStart(3, '0')}${suffix}.html`;

async function searchOnce(page, engine, keyword, entry) {
  const existing = await detectBlock(page);
  if (existing) return existing;
  try {
    await humanType(page, engine.input, keyword);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector(engine.results, { timeout: NAV_TIMEOUT_MS }).catch(() => {});
  } catch (error) {
    entry.error = error.name || 'error';
  }
  return detectBlock(page);
}

// Records a challenge; returns a stop reason, or null after a human solve.
async function handleBlock(ctx, page, entry, block) {
  const { options, report, runDir, win } = ctx;
  const event = { at_query: entry.n, kind: block, elapsed_seconds: Math.round((Date.now() - ctx.startedMs) / 1000) };
  report.blocks.push(event);
  report.first_block ??= event;
  entry.blocked = block;
  if (options.keepEvidence) {
    entry.evidence = evidenceName(entry.n, '-block');
    writeFileSync(join(runDir, entry.evidence), await page.content().catch(() => ''), { mode: 0o600 });
  }
  log(`Query ${entry.n}: ${block} after ${report.succeeded} successful searches`);
  if (options.onCaptcha === 'stop') return 'captcha';
  log('Waiting for a human to solve the challenge in the browser window (up to 10 minutes)');
  win.showForHuman();
  if (!await waitUntil(async () => !(await detectBlock(page)), HUMAN_SOLVE_WAIT_MS)) return 'captcha_unsolved';
  event.human_solved = true;
  await win.rehide();
  // Engines usually return to the pending results after a solve.
  await page.waitForSelector(ctx.engine.results, { timeout: NAV_TIMEOUT_MS }).catch(() => {});
  return null;
}

async function recordResults(ctx, page, entry) {
  const { options, report } = ctx;
  const organic = [...new Set(await page.evaluate(ctx.engine.organic).catch(() => []))];
  entry.organic = organic.length;
  entry.top = organic.slice(0, 10);
  entry.ok = organic.length > 0;
  if (entry.ok) report.succeeded += 1;
  if (options.keepEvidence) {
    entry.evidence = evidenceName(entry.n);
    writeFileSync(join(ctx.runDir, entry.evidence), await page.content(), { mode: 0o600 });
  }
  log(`Query ${entry.n}/${options.keywords.length}: ${entry.ok ? `${organic.length} organic results` : 'no organic results parsed'}`);
  ctx.save();
}

// Returns the stop reason for the query loop.
async function runQueries(ctx, page) {
  const { options, report } = ctx;
  for (const [index, keyword] of options.keywords.entries()) {
    if (stopRequested) return 'interrupted';
    const entry = { n: index + 1, at: new Date().toISOString(), ok: false, organic: 0, top: [] };
    report.attempted = entry.n;
    report.queries.push(entry);
    const block = await searchOnce(page, ctx.engine, keyword, entry);
    const stop = block ? await handleBlock(ctx, page, entry, block) : null;
    if (stop) return stop;
    await recordResults(ctx, page, entry);
    if (entry.n < options.keywords.length) {
      await dwell(page);
      const gap = randomBetween(options.minDelay, options.maxDelay) * 1000;
      log(`Next search in ${Math.round(gap / 1000)} s`);
      await sleep(gap);
    }
  }
  return stopRequested ? 'interrupted' : 'completed';
}

async function run(options) {
  const proxy = proxyFromEnv();
  const { runDir, report, save } = createRun(options, proxy);
  const engine = ENGINES[options.engine];
  const { context, browser } = await launchBrowser(options, runDir, proxy);
  const ctx = { options, engine, report, runDir, save, startedMs: Date.now() };
  try {
    ctx.win = await setupWindow(options, report);
    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(NAV_TIMEOUT_MS);
    await page.goto(engine.home(options), { waitUntil: 'domcontentloaded' });
    await ctx.win.rehide();
    report.browser = browser;
    report.automation_signals = await page.evaluate(() => ({
      webdriver: navigator.webdriver === true,
      visibility: document.visibilityState,
    })).catch(() => null);
    await sleep(randomBetween(2000, 5000));
    report.stop_reason = await handleConsent(page, options, ctx.win) || await runQueries(ctx, page);
  } catch (error) {
    report.stop_reason = 'error';
    report.error = error.name || 'error';
  } finally {
    save();
    await context.close().catch(() => {});
  }
  return report;
}

function printPlan(options) {
  const gaps = Math.max(0, options.keywords.length - 1);
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    dry_run: true,
    engine: options.engine,
    planned: options.keywords.length,
    pacing_seconds: { min: options.minDelay, max: options.maxDelay },
    estimated_minutes: { min: Math.round((gaps * options.minDelay) / 60), max: Math.round((gaps * options.maxDelay) / 60) },
    headless: options.headless,
    hidden: options.hidden,
    gl: options.gl,
    on_captcha: options.onCaptcha,
    egress: process.env.SERP_PROBE_PROXY ? 'proxy' : 'direct',
    contacted_targets: false,
  })}\n`);
}

async function main() {
  let options;
  try {
    options = parseOptions(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n${usage()}\n`);
    return 2;
  }
  if (options.help) { process.stdout.write(`${usage()}\n`); return 0; }
  if (options.dryRun) { printPlan(options); return 0; }

  process.on('SIGINT', () => { stopRequested = true; log('Stopping after the current step'); });
  const report = await run(options);
  const { queries, ...summary } = report;
  process.stdout.write(`${JSON.stringify(summary)}\n`);
  return ['completed', 'captcha', 'interrupted'].includes(report.stop_reason) ? 0 : 1;
}

main().then((code) => { process.exitCode = code; }).catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
