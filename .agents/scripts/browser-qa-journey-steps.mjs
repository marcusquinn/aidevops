// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

function fail(message) { throw new Error(message); }

function isAllowedAuthRequest(request, origin, auth) {
  const url = new URL(request.url());
  return url.origin === origin.origin && url.pathname === auth.path && request.method() === auth.method;
}

export async function installNetworkGuard(page, origin, login, logout, report) {
  await page.route('**/*', async route => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.origin !== origin.origin && request.headers().cookie) return route.abort('blockedbyclient');
    if (!WRITE_METHODS.has(request.method()) || isAllowedAuthRequest(request, origin, login) || isAllowedAuthRequest(request, origin, logout)) return route.continue();
    report.blockedWrites += 1;
    return route.abort('blockedbyclient');
  });
}

async function runStep(page, step, origin, timeout) {
  switch (step.type) {
    case 'navigate':
      if (typeof step.path !== 'string' || !step.path.startsWith('/')) fail('navigate requires an absolute path');
      return page.goto(new URL(step.path, origin).href, { waitUntil: 'domcontentloaded', timeout });
    case 'click': return page.locator(step.selector).click({ timeout });
    case 'visible': return page.locator(step.selector).waitFor({ state: 'visible', timeout });
    case 'count':
      if (!Number.isInteger(step.equals) || await page.locator(step.selector).count() !== step.equals) fail('count assertion failed');
      return undefined;
    case 'text': {
      const text = await page.locator(step.selector).innerText({ timeout });
      if (typeof step.includes !== 'string' || !text.includes(step.includes)) fail('text assertion failed');
      return undefined;
    }
    case 'attribute':
      if (await page.locator(step.selector).getAttribute(step.name, { timeout }) !== step.equals) fail('attribute assertion failed');
      return undefined;
    case 'no-horizontal-overflow':
      if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)) fail('horizontal overflow detected');
      return undefined;
    default: fail(`unsupported journey step: ${step.type}`);
  }
}

export async function runSteps(page, steps, origin, timeout, result, report) {
  for (const step of steps) {
    const name = typeof step.name === 'string' ? step.name.slice(0, 80) : step.type;
    try {
      await runStep(page, step, origin, timeout);
      result.steps.push({ name, status: 'passed' });
      report.passed += 1;
    } catch (error) {
      result.steps.push({ name, status: 'failed', error: error.message.slice(0, 160) });
      report.failed += 1;
      return error;
    }
  }
  return null;
}
