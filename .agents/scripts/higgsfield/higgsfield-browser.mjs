// higgsfield-browser.mjs — Browser launch, navigation, modal dismissal, and 
// page interaction helpers for the Higgsfield automation suite.
// Extracted from higgsfield-common.mjs (t2127 file-complexity decomposition).

import { chromium } from 'playwright';
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  WORKSPACE_OUTPUT_DIR,
  USER_DOWNLOADS_DIR,
  sanitizePathSegment,
  safeJoin,
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
                   options.headed ? false : true;

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

const KNOWN_INTERRUPTIONS_FILE = join(STATE_DIR, 'known-interruptions.json');

export function loadKnownInterruptions() {
  try {
    if (existsSync(KNOWN_INTERRUPTIONS_FILE)) {
      return JSON.parse(readFileSync(KNOWN_INTERRUPTIONS_FILE, 'utf-8'));
    }
  } catch {}
  return { types: [] };
}

export function logNewInterruption(type, selector, detail) {
  const data = loadKnownInterruptions();
  const exists = data.types.some(t => t.type === type);
  if (!exists) {
    data.types.push({ type, selector, detail, firstSeen: new Date().toISOString() });
    try {
      writeFileSync(KNOWN_INTERRUPTIONS_FILE, JSON.stringify(data, null, 2));
    } catch {}
  }
}

export async function dismissModalsAndBanners(page) {
  return page.evaluate(() => {
    const dismissed = [];

    document.querySelectorAll('.react-aria-ModalOverlay, [data-rac].react-aria-ModalOverlay')
      .forEach(o => { o.remove(); dismissed.push('react-aria-modal'); });
    document.querySelectorAll('button[aria-label="Dismiss"]')
      .forEach(b => { b.click(); dismissed.push('dismiss-button'); });

    for (const sel of ['[class*="cookie"]','[id*="cookie"]','[class*="consent"]','[id*="consent"]','[class*="gdpr"]','[id*="gdpr"]','[class*="CookieBanner"]']) {
      document.querySelectorAll(sel).forEach(el => {
        const ab = el.querySelector('button');
        if (ab) { ab.click(); dismissed.push('cookie-accept'); }
        else { el.remove(); dismissed.push('cookie-remove'); }
      });
    }

    document.querySelectorAll('[role="alert"],[class*="toast"],[class*="Toast"],[class*="notification"],[class*="Notification"],[class*="snackbar"]')
      .forEach(el => { const cb = el.querySelector('button'); if (cb) { cb.click(); dismissed.push('toast-close'); } });

    document.querySelectorAll('[class*="tooltip"][class*="onboard"],[class*="tour"],[class*="walkthrough"],[class*="Popover"][class*="guide"]')
      .forEach(el => { const sb = el.querySelector('button:last-child') || el.querySelector('button'); if (sb) { sb.click(); dismissed.push('onboarding-skip'); } else { el.remove(); dismissed.push('onboarding-remove'); } });

    return dismissed;
  });
}

export async function dismissOverlaysAndAgreements(page) {
  return page.evaluate(() => {
    const dismissed = [];

    document.querySelectorAll('[class*="upgrade"],[class*="paywall"],[class*="subscribe"]')
      .forEach(el => { if (el.style.position==='fixed'||el.style.position==='absolute'||getComputedStyle(el).position==='fixed') { el.remove(); dismissed.push('upgrade-overlay'); } });

    document.querySelectorAll('[role="dialog"]').forEach(d => { const p=d.parentElement; if(p&&(p.classList.contains('react-aria-ModalOverlay')||getComputedStyle(p).position==='fixed')){p.remove();dismissed.push('generic-dialog');} });

    document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => { if(!el.querySelector('textarea,input,button[type="submit"],form')&&el.children.length<=2){el.remove();dismissed.push('loading-overlay');} });

    document.querySelectorAll('[role="dialog"],dialog').forEach(dialog => {
      const t=dialog.textContent||'';
      if(t.includes('Media upload agreement')||t.includes('I agree, continue')||t.includes('terms of service')||t.includes('Terms of Service')){
        for(const btn of dialog.querySelectorAll('button')){if(btn.textContent.includes('agree')||btn.textContent.includes('continue')||btn.textContent.includes('Accept')||btn.textContent.includes('OK')){btn.click();dismissed.push('media-upload-agreement');break;}}
      }
    });

    if(document.body.style.overflow==='hidden'||document.body.style.pointerEvents==='none'){document.body.style.overflow='';document.body.style.pointerEvents='';dismissed.push('body-unlock');}

    return dismissed;
  });
}

async function tryDismissEscapeKey(page) {
  const remaining = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (remaining === 0) return;
  await page.keyboard.press('Escape');
  await page.waitForTimeout(500);
  const afterEsc = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (afterEsc < remaining) {
    console.log(`Escape dismissed ${remaining - afterEsc} more modal(s)`);
  }
}

export async function dismissInterruptions(page) {
  const part1 = await dismissModalsAndBanners(page);
  const part2 = await dismissOverlaysAndAgreements(page);
  const results = [...(Array.isArray(part1) ? part1 : []), ...(Array.isArray(part2) ? part2 : [])];

  if (results.length > 0) {
    console.log(`Cleared ${results.length} interruption(s): ${[...new Set(results)].join(', ')}`);
    for (const type of new Set(results)) {
      logNewInterruption(type, 'auto-detected', `Dismissed via comprehensive sweep`);
    }
  }

  await tryDismissEscapeKey(page);
  return results.length;
}

export async function dismissAllModals(page) {
  let totalDismissed = 0;
  for (let i = 0; i < 3; i++) {
    const count = await dismissInterruptions(page);
    totalDismissed += count;
    if (count === 0) break;
    await page.waitForTimeout(500);
  }
  return totalDismissed;
}

export async function forceCloseDialogs(page) {
  await page.keyboard.press('Escape');
  await page.waitForTimeout(500);
  const stillOpen = await page.locator('[role="dialog"]').count();
  if (stillOpen === 0) return;
  await page.evaluate(() => {
    document.querySelectorAll('[role="dialog"]').forEach(d => {
      const overlay = d.closest('.react-aria-ModalOverlay') || d.parentElement;
      if (overlay) overlay.remove();
      else d.remove();
    });
    document.body.style.overflow = '';
    document.body.style.pointerEvents = '';
  });
}
