#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Opt-in authenticated read-only browser journey runner (GH#32375).
// Usage: browser-qa-journey.mjs CONFIG ENVIRONMENT
// Prints one redacted JSON report on stdout. It never writes screenshots, traces,
// recordings, storage state, cookies or page bodies. Each viewport runs in its own
// isolated context: sign in -> declarative steps -> sign out -> close.

import fs from 'node:fs/promises';
import { SCHEMA_VERSION, VIEWPORTS, validateJourney } from './browser-qa-journey-config.mjs';
import { assertGuardClean, createGuard, guardViolations, installGuard } from './browser-qa-journey-guard.mjs';
import { resolvePath, runSteps } from './browser-qa-journey-steps.mjs';
import { loadPlaywright } from './playwright-runtime.mjs';

const SIGN_OUT_TIMEOUT_MS = 10000;
const HARD_FUSE_GRACE_MS = 30000;
const MAX_ERROR_LENGTH = 160;
const MIN_REDACTED_SECRET_LENGTH = 3;

function firstLine(error) {
  return String(error?.message ?? error).split('\n')[0];
}

// Error text keeps only its first line, drops URL query strings and masks credential values.
function makeRedactor(credentials) {
  const secrets = [credentials.username, credentials.password].filter((value) => value.length >= MIN_REDACTED_SECRET_LENGTH);
  return (error) => {
    let text = firstLine(error).replace(/\?\S*/g, '?[redacted]');
    for (const secret of secrets) text = text.split(secret).join('[redacted]');
    return text.slice(0, MAX_ERROR_LENGTH);
  };
}

// Returns the per-action timeout, bounded by what remains of the whole-run budget.
function makeBudget(journey) {
  const deadline = Date.now() + journey.runTimeoutMs;
  return () => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('run timeout exceeded');
    return Math.min(journey.actionTimeoutMs, remaining);
  };
}

function watchDiagnostics(context) {
  const counts = { consoleErrors: 0, pageErrors: 0, dialogsDismissed: 0 };
  context.on('console', (message) => {
    if (message.type() === 'error') counts.consoleErrors += 1;
  });
  context.on('weberror', () => {
    counts.pageErrors += 1;
  });
  context.on('dialog', (dialog) => {
    counts.dialogsDismissed += 1;
    dialog.dismiss().catch(() => undefined);
  });
  return counts;
}

async function signIn(run, journey) {
  const { login, credentials } = journey;
  const { page } = run;
  run.guard.phase = 'login';
  try {
    await page.goto(resolvePath(run.origin, login.pagePath), { waitUntil: 'domcontentloaded', timeout: run.budget() });
    await page.locator(login.usernameSelector).fill(credentials.username, { timeout: run.budget() });
    await page.locator(login.passwordSelector).fill(credentials.password, { timeout: run.budget() });
    run.signInAttempted = true;
    await page.locator(login.submitSelector).click({ timeout: run.budget() });
    await page.waitForURL((url) => url.origin === run.origin && url.pathname === login.successPath, { timeout: run.budget() });
    assertGuardClean(run.guard);
    return { status: 'passed' };
  } catch (error) {
    return { status: 'failed', error: run.redact(error) };
  } finally {
    run.guard.phase = 'journey';
  }
}

// Sign-out uses the context's own request client (same cookies, no page code, no
// redirects followed). It always runs once sign-in was attempted, even after a
// failed step or an exhausted run budget.
async function signOut(run, journey) {
  if (!run.signInAttempted) return { status: 'skipped' };
  try {
    const response = await run.context.request.fetch(resolvePath(run.origin, journey.logout.path), {
      method: journey.logout.method,
      headers: { origin: run.origin },
      // Object data makes Playwright send JSON with the matching Content-Type.
      // GET sign-out endpoints retain their bodyless request behavior.
      ...(journey.logout.method === 'GET' ? {} : { data: {} }),
      maxRedirects: 0,
      timeout: SIGN_OUT_TIMEOUT_MS,
    });
    const status = response.status();
    return status < 400 ? { status: 'passed' } : { status: 'failed', error: `sign-out returned HTTP ${status}` };
  } catch (error) {
    return { status: 'failed', error: run.redact(error) };
  }
}

async function exerciseViewport(run, journey) {
  let stepsPassed = false;
  try {
    run.result.signIn = await signIn(run, journey);
    stepsPassed = run.result.signIn.status === 'passed' && (await runSteps(run, journey.steps));
  } finally {
    run.result.signOut = await signOut(run, journey);
  }
  const clean = guardViolations(run.guard) === 0 && run.result.signOut.status !== 'failed';
  run.result.status = stepsPassed && clean ? 'passed' : 'failed';
}

async function runViewport(session, viewportName) {
  const { browser, journey } = session;
  const context = await browser.newContext({
    viewport: VIEWPORTS[viewportName],
    serviceWorkers: 'block',
    acceptDownloads: false,
  });
  const guard = createGuard(journey);
  const diagnostics = watchDiagnostics(context);
  const result = { viewport: viewportName, status: 'failed', steps: [] };
  try {
    await installGuard(context, guard);
    const page = await context.newPage();
    const run = { ...session, context, page, guard, result, origin: journey.origin, signInAttempted: false };
    await exerciseViewport(run, journey);
  } finally {
    await context.close().catch(() => undefined);
  }
  return Object.assign(result, diagnostics, guard.counts, { webSocketsBlocked: guard.webSocketsBlocked });
}

async function launchBrowser() {
  const playwright = await loadPlaywright(process.env.AIDEVOPS_PLAYWRIGHT_MODULE || null);
  const executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE || undefined;
  return playwright.chromium.launch({ headless: true, executablePath });
}

async function runJourney(journey) {
  const report = {
    schemaVersion: SCHEMA_VERSION,
    environment: journey.environmentName,
    origin: journey.origin,
    status: 'failed',
    viewports: [],
  };
  const browser = await launchBrowser();
  const session = { browser, journey, budget: makeBudget(journey), redact: makeRedactor(journey.credentials) };
  try {
    for (const viewportName of journey.viewports) {
      const result = await runViewport(session, viewportName);
      report.viewports.push(result);
      if (result.status !== 'passed') break;
    }
  } finally {
    await browser.close();
  }
  const passed = report.viewports.filter((result) => result.status === 'passed').length;
  report.status = passed === journey.viewports.length ? 'passed' : 'failed';
  return report;
}

// Last-resort fuse in case a browser call ignores its own timeout.
function armHardFuse(runTimeoutMs) {
  const timer = setTimeout(() => {
    process.stderr.write('Journey failed: hard run timeout exceeded\n');
    process.exit(1);
  }, runTimeoutMs + HARD_FUSE_GRACE_MS);
  timer.unref();
}

async function main(argv) {
  const [configPath, environmentName] = argv;
  if (!configPath || !environmentName) throw new Error('usage: browser-qa-journey.mjs CONFIG ENVIRONMENT');
  const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
  const journey = validateJourney(config, environmentName);
  armHardFuse(journey.runTimeoutMs);
  const report = await runJourney(journey);
  process.stdout.write(`${JSON.stringify(report)}\n`);
  if (report.status !== 'passed') throw new Error('journey did not pass; see the JSON report');
}

main(process.argv.slice(2)).catch((error) => {
  process.stderr.write(`Journey failed: ${firstLine(error).slice(0, MAX_ERROR_LENGTH)}\n`);
  process.exitCode = 1;
});
