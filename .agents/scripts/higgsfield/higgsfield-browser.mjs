// higgsfield-browser.mjs — Browser launch, navigation, modal dismissal, and 
// page interaction helpers for the Higgsfield automation suite.
// Extracted from higgsfield-common.mjs (t2127 file-complexity decomposition).

import { existsSync } from 'node:fs';
import { chromium } from 'playwright';

import { dismissAllModals } from './higgsfield-interruptions.mjs';

import {
  BASE_URL,
  STATE_DIR,
  STATE_FILE,
  safeJoin,
  sanitizePathSegment,
  USER_DOWNLOADS_DIR,
  WORKSPACE_OUTPUT_DIR,
} from './higgsfield-common.mjs';

// ---------------------------------------------------------------------------
// Browser helpers
// ---------------------------------------------------------------------------

export function getDefaultOutputDir(options = {}) {
  if (options.headless || (!process.stdout.isTTY && !options.headed)) {
    return WORKSPACE_OUTPUT_DIR;
  }
  return USER_DOWNLOADS_DIR;
}

export async function launchBrowser(options = {}) {
  const headless = options.headless !== undefined ? options.headless :
                   !
                   options.headed;

  const launchOptions = {
    headless,
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-sandbox',
    ],
    viewport: { width: 1440, height: 900 },
  };

  const ctxOptions = {
    viewport: { width: 1440, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  };

  const browser = await chromium.launch(launchOptions);
  if (existsSync(STATE_FILE)) {
    ctxOptions.storageState = STATE_FILE;
  }
  const context = await browser.newContext(ctxOptions);
  const page = await context.newPage();
  return { browser, context, page };
}

export async function withBrowser(options, fn) {
  const { browser, context, page } = await launchBrowser(options);
  try {
    const result = await fn(page, context);
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return result;
  } catch (error) {
    try { await browser.close(); } catch {}
    throw error;
  }
}

export async function navigateTo(page, path, { waitMs = 3000, timeout = 60000 } = {}) {
  const url = path.startsWith('http') ? path : `${BASE_URL}${path}`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
  await page.waitForTimeout(waitMs);
  await dismissAllModals(page);
}

export async function debugScreenshot(page, name, { fullPage = false } = {}) {
  const safeName = sanitizePathSegment(name, 'debug');
  await page.screenshot({ path: safeJoin(STATE_DIR, `${safeName}.png`), fullPage });
}

export async function clickHistoryTab(page, { waitMs = 2000 } = {}) {
  const historyTab = page.locator('[role="tab"]:has-text("History")');
  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(waitMs);
  }
  return historyTab;
}

export async function clickGenerate(page, label = '') {
  const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply")');
  if (await generateBtn.count() > 0) {
    await generateBtn.last().click({ force: true });
    console.log(`Clicked Generate${label ? ` for ${label}` : ''}`);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Modal dismissal
// ---------------------------------------------------------------------------

export {
  dismissAllModals,
  dismissInterruptions,
  dismissModalsAndBanners,
  dismissOverlaysAndAgreements,
  forceCloseDialogs,
  loadKnownInterruptions,
  logNewInterruption,
} from './higgsfield-interruptions.mjs';
