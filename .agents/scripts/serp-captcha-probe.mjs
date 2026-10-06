#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Paced, human-like public search-result collection that measures how many
// searches one browser identity completes before a CAPTCHA/challenge.
// It never solves CAPTCHAs: it stops, or waits for a human in headed mode.
// Policy: .agents/aidevops/reach-capture.md "Public Search-result Collection".
// Modules in serp-probe/: engines.mjs (engines, detectors), options.mjs (CLI),
// session.mjs (proxy, run report, browser launch), window.mjs (macOS --hidden).

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { describeZeroResults, detectBlock, detectConsent, ENGINES } from './serp-probe/engines.mjs';
import { parseOptions, printPlan, usage } from './serp-probe/options.mjs';
import { createRun, launchBrowser, proxyFromEnv } from './serp-probe/session.mjs';
import { setupWindow } from './serp-probe/window.mjs';

const NAV_TIMEOUT_MS = 30_000;
const CONSENT_WAIT_MS = 180_000;
const HUMAN_SOLVE_WAIT_MS = 600_000;

const log = (message) => process.stderr.write(`[serp-probe] ${message}\n`);
const randomBetween = (min, max) => min + Math.random() * (max - min);

let stopRequested = false;
async function sleep(ms) {
  const end = Date.now() + ms;
  while (!stopRequested && Date.now() < end) {
    await new Promise((resolve) => setTimeout(resolve, Math.min(1000, end - Date.now())));
  }
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
  const organic = [...new Set(await page.evaluate(ctx.engine.organic).catch(() => {
    entry.note = 'organic_parse_error';
    return [];
  }))];
  entry.organic = organic.length;
  entry.top = organic.slice(0, 10);
  entry.ok = organic.length > 0;
  if (entry.ok) report.succeeded += 1;
  else entry.note ??= entry.error ? 'search_error' : await describeZeroResults(page, ctx.engine);
  if (options.keepEvidence) {
    entry.evidence = evidenceName(entry.n);
    writeFileSync(join(ctx.runDir, entry.evidence), await page.content(), { mode: 0o600 });
  }
  const outcome = entry.ok ? `${organic.length} organic results` : `no organic results parsed (${entry.note})`;
  log(`Query ${entry.n}/${options.keywords.length}: ${outcome}`);
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
    ctx.win = await setupWindow(options, report, log);
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
