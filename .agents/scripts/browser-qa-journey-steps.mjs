// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Declarative read-only journey steps. Each handler receives the per-viewport run
// state ({ page, origin, budget, guard, redact }) and one validated step.

import { assertGuardClean } from './browser-qa-journey-guard.mjs';

const POLL_INTERVAL_MS = 100;
const PROBE_TIMEOUT_MS = 1000;

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export function resolvePath(origin, path) {
  const url = new URL(path, origin);
  if (url.origin !== origin) throw new Error('path resolves outside the allowed origin');
  return url.href;
}

// Report only a coarse same-origin route: numeric and long hex/uuid segments become :id.
export function routePattern(origin, value) {
  let url = null;
  try {
    url = new URL(value);
  } catch {
    url = null;
  }
  if (url === null || url.origin !== origin) return 'off-origin';
  return url.pathname
    .split('/')
    .map((segment) => (/^(\d+|[0-9a-f-]{16,})$/i.test(segment) ? ':id' : segment))
    .join('/');
}

// Re-probe until the assertion holds or the action budget is spent.
async function pollUntil(run, probe, message) {
  const deadline = Date.now() + run.budget();
  while (!(await probe())) {
    if (Date.now() >= deadline) throw new Error(message);
    await sleep(POLL_INTERVAL_MS);
  }
}

function probeTimeout(run) {
  return Math.min(PROBE_TIMEOUT_MS, run.budget());
}

async function readText(run, selector) {
  return run.page.locator(selector).first().innerText({ timeout: probeTimeout(run) }).catch(() => '');
}

async function readAttribute(run, step) {
  return run.page.locator(step.selector).first().getAttribute(step.name, { timeout: probeTimeout(run) }).catch(() => null);
}

async function hasHorizontalOverflow(page) {
  return page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
}

const HANDLERS = {
  navigate: (run, step) => run.page.goto(resolvePath(run.origin, step.path), { waitUntil: 'domcontentloaded', timeout: run.budget() }),
  // Strict locator: an ambiguous click target fails instead of guessing.
  click: (run, step) => run.page.locator(step.selector).click({ timeout: run.budget() }),
  visible: (run, step) => run.page.locator(step.selector).first().waitFor({ state: 'visible', timeout: run.budget() }),
  count: (run, step) => pollUntil(run, async () => (await run.page.locator(step.selector).count()) === step.equals, 'count assertion failed'),
  text: (run, step) => pollUntil(run, async () => (await readText(run, step.selector)).includes(step.includes), 'text assertion failed'),
  attribute: (run, step) => pollUntil(run, async () => (await readAttribute(run, step)) === step.equals, 'attribute assertion failed'),
  'no-horizontal-overflow': async (run) => {
    if (await hasHorizontalOverflow(run.page)) throw new Error('horizontal overflow detected');
  },
};

async function runStep(run, step) {
  try {
    await HANDLERS[step.type](run, step);
    assertGuardClean(run.guard);
    return { status: 'passed' };
  } catch (error) {
    return { status: 'failed', error: run.redact(error) };
  }
}

// Runs steps in order and stops at the first failure. Returns true when all pass.
export async function runSteps(run, steps) {
  for (const [index, step] of steps.entries()) {
    const outcome = await runStep(run, step);
    run.result.steps.push({
      step: index + 1,
      name: step.name ?? step.type,
      type: step.type,
      route: routePattern(run.origin, run.page.url()),
      ...outcome,
    });
    if (outcome.status !== 'passed') return false;
  }
  return true;
}
