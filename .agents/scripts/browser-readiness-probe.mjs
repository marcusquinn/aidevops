// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import { loadPlaywright } from './playwright-runtime.mjs';

const result = {
  schema: 'aidevops.playwright-readiness/v1',
  packageImportable: false,
  runnerAvailable: false,
  roundTrip: false,
  closed: false,
  reason: 'package_unavailable',
};
let browser;
try {
  const require = createRequire(join(process.cwd(), 'package.json'));
  let modulePath;
  try {
    modulePath = require.resolve('playwright');
  } catch {
    // pnpm keeps @playwright/test's dependency out of the package's top level.
    modulePath = createRequire(require.resolve('@playwright/test')).resolve('playwright');
  }
  const runtime = await loadPlaywright(pathToFileURL(modulePath).href);
  result.packageImportable = true;
  result.runnerAvailable = typeof runtime.chromium?.launch === 'function';
  result.reason = 'browser_failed';
  browser = await runtime.chromium.launch({ headless: true, timeout: 10_000 });
  const context = await browser.newContext({ serviceWorkers: 'block' });
  await context.route('**/*', (route) => route.abort());
  const page = await context.newPage();
  page.setDefaultTimeout(5_000);
  await page.setContent('<main>readiness</main>');
  result.roundTrip = await page.locator('main').textContent() === 'readiness';
} catch {
  // Never print launch arguments, paths, browser logs or provider errors.
} finally {
  if (browser) {
    try {
      await browser.close();
      result.closed = true;
    } catch {
      result.reason = 'cleanup_failed';
    }
  }
}
if (result.roundTrip && result.closed) result.reason = 'ready';
process.stdout.write(`${JSON.stringify(result)}\n`);
process.exitCode = result.reason === 'ready' ? 0 : 1;
