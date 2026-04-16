// higgsfield-discovery.mjs — Site discovery, route caching, and login for
// the Higgsfield automation suite.
// Extracted from higgsfield-common.mjs (t2127 file-complexity decomposition).

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  ROUTES_CACHE,
  DISCOVERY_TIMESTAMP,
  DISCOVERY_MAX_AGE_HOURS,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  dismissAllModals,
  debugScreenshot,
} from './higgsfield-browser.mjs';

// ---------------------------------------------------------------------------
// Credentials (only used by login)
// ---------------------------------------------------------------------------

export function loadCredentials() {
  const credFile = join(homedir(), '.config', 'aidevops', 'credentials.sh');
  if (!existsSync(credFile)) {
    console.error('ERROR: Credentials file not found at', credFile);
    process.exit(1);
  }
  const content = readFileSync(credFile, 'utf-8');
  const user = content.match(/HIGGSFIELD_USER="([^"]+)"/)?.[1];
  const pass = content.match(/HIGGSFIELD_PASS="([^"]+)"/)?.[1];
  if (!user || !pass) {
    console.error('ERROR: HIGGSFIELD_USER or HIGGSFIELD_PASS not found in credentials.sh');
    process.exit(1);
  }
  return { user, pass };
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export const ROUTE_PREFIXES = [
  { prefix: '/image/',              bucket: 'image' },
  { prefix: '/create/',             bucket: 'video' },
  { prefix: '/edit',                bucket: 'edit' },
  { prefix: '/app/',                bucket: 'apps' },
  { prefix: '/motion/',             bucket: 'motions' },
  { prefix: '/mixed-media-presets/',bucket: 'mixed_media' },
];

export const ACCOUNT_PREFIXES = ['/asset/all', '/library/image', '/profile', '/pricing', '/auth/'];
export const FEATURE_PREFIXES = [
  '/cinema-studio', '/vibe-motion', '/lipsync-studio', '/character',
  '/ai-influencer-studio', '/upscale', '/fashion-factory', '/chat',
  '/ugc-factory', '/photodump-studio', '/storyboard-generator',
  '/nano-banana-pro', '/seedream-4-5', '/kling', '/sora', '/wan', '/veo', '/minimax',
];

export function categoriseRoutes(links) {
  const routes = { image: {}, video: {}, edit: {}, apps: {}, features: {}, account: {}, motions: {}, mixed_media: {}, other: {} };
  for (const [path, label] of Object.entries(links)) {
    const match = ROUTE_PREFIXES.find(r => path.startsWith(r.prefix));
    if (match) {
      routes[match.bucket][path] = label;
    } else if (ACCOUNT_PREFIXES.some(p => path.startsWith(p))) {
      routes.account[path] = label;
    } else if (FEATURE_PREFIXES.some(p => path.startsWith(p))) {
      routes.features[path] = label;
    } else {
      routes.other[path] = label;
    }
  }
  return routes;
}

const DIFF_BUCKETS = [
  { key: 'apps', label: 'APP' },
  { key: 'image', label: 'IMAGE MODEL' },
  { key: 'features', label: 'FEATURE' },
];

function collectAddedPaths(label, currentBucket, prevKeys) {
  const added = [];
  for (const path of Object.keys(currentBucket)) {
    if (!prevKeys.has(path)) added.push(`NEW ${label}: ${path} → ${currentBucket[path]}`);
  }
  return added;
}

function collectRemovedApps(currentApps, prevAppKeys) {
  const removed = [];
  for (const path of prevAppKeys) {
    if (!currentApps[path]) removed.push(`REMOVED APP: ${path}`);
  }
  return removed;
}

function diffBucket(prev, routes, { key, label }) {
  const prevKeys = new Set(Object.keys(prev[key] || {}));
  const changes = collectAddedPaths(label, routes[key], prevKeys);
  if (key === 'apps') changes.push(...collectRemovedApps(routes.apps, prevKeys));
  return changes;
}

function loadPreviousRoutes() {
  if (!existsSync(ROUTES_CACHE)) return null;
  try {
    return JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
  } catch {
    return null; // first run or corrupt cache
  }
}

export function diffRoutesAgainstCache(routes) {
  const prev = loadPreviousRoutes();
  if (!prev) return [];
  const changes = [];
  for (const bucket of DIFF_BUCKETS) {
    changes.push(...diffBucket(prev, routes, bucket));
  }
  return changes;
}

export function discoveryNeeded() {
  if (!existsSync(DISCOVERY_TIMESTAMP)) return true;
  try {
    const lastRun = parseInt(readFileSync(DISCOVERY_TIMESTAMP, 'utf-8').trim(), 10);
    const ageHours = (Date.now() - lastRun) / (1000 * 60 * 60);
    return ageHours > DISCOVERY_MAX_AGE_HOURS;
  } catch {
    return true;
  }
}

async function scrapeDiscoveryLinks(page) {
  return page.evaluate(() => {
    const allLinks = [...document.querySelectorAll('a[href]')];
    const map = {};
    allLinks.forEach(a => {
      const href = a.getAttribute('href');
      let text = a.textContent?.trim()
        .replace(/Your browser does not support the video\.\s*/g, '')
        .replace(/\s+/g, ' ')
        .substring(0, 80) || '';
      if (href && href.startsWith('/') && !href.startsWith('//') && text) {
        if (!map[href]) map[href] = text;
      }
    });
    return map;
  });
}

async function scrapeImageModels(page) {
  await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(3000);
  await dismissAllModals(page);
  return page.evaluate(() => {
    const modelBtns = [...document.querySelectorAll('button')].filter(b =>
      b.textContent?.match(/soul|nano|seedream|flux|gpt|wan|kontext/i)
    );
    return modelBtns.map(b => b.textContent?.trim().substring(0, 60));
  });
}

function logDiscoverySummary(links, routes, changes) {
  console.log(`Discovery complete: ${Object.keys(links).length} paths found`);
  console.log(`  Images: ${Object.keys(routes.image).length} models`);
  console.log(`  Video: ${Object.keys(routes.video).length} tools`);
  console.log(`  Apps: ${Object.keys(routes.apps).length} apps`);
  console.log(`  Motions: ${Object.keys(routes.motions).length} presets`);
  console.log(`  Features: ${Object.keys(routes.features).length} features`);
  if (changes.length > 0) {
    console.log(`\n  CHANGES since last discovery:`);
    changes.forEach(c => console.log(`    ${c}`));
  } else if (existsSync(ROUTES_CACHE)) {
    console.log('  No changes since last discovery');
  }
}

export async function runDiscovery(options = {}) {
  console.log('Running site discovery (checking for new/changed features)...');
  const { browser, context, page } = await launchBrowser({ ...options, headless: true });

  try {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    const links = await scrapeDiscoveryLinks(page);
    const routes = categoriseRoutes(links);
    const imageModels = await scrapeImageModels(page);
    const changes = diffRoutesAgainstCache(routes);

    const cacheData = {
      ...routes,
      _meta: {
        timestamp: new Date().toISOString(),
        totalPaths: Object.keys(links).length,
        imageModelsOnPage: imageModels,
        changes,
      }
    };
    writeFileSync(ROUTES_CACHE, JSON.stringify(cacheData, null, 2));
    writeFileSync(DISCOVERY_TIMESTAMP, String(Date.now()));

    logDiscoverySummary(links, routes, changes);

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return cacheData;

  } catch (error) {
    console.error('Discovery error:', error.message);
    await browser.close();
    return null;
  }
}

export async function ensureDiscovery(options = {}) {
  if (discoveryNeeded()) {
    return await runDiscovery(options);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------

async function waitForLoginRedirect(page, options) {
  try {
    await page.waitForURL(isNonAuthUrl, { timeout: 30000 });
    console.log('Login successful! Redirected to:', page.url());
  } catch {
    console.log('Still on auth page. Current URL:', page.url());
    await debugScreenshot(page, 'login-result', { fullPage: true });

    const errorText = await page.evaluate(() => {
      const errors = document.querySelectorAll('[class*="error"], [class*="alert"], [role="alert"]');
      return [...errors].map(e => e.textContent?.trim()).filter(Boolean).join('; ');
    });
    if (errorText) console.log('Error message:', errorText);

    if (options.headed) {
      console.log('Waiting 60s for manual login completion...');
      try {
        await page.waitForURL(isNonAuthUrl, { timeout: 60000 });
        console.log('Login completed manually! URL:', page.url());
      } catch {
        console.log('Timeout. Saving current state anyway...');
      }
    }
  }
}

async function performLoginSteps(page, user, pass) {
  const emailSelectors = [
    'input[type="email"]',
    'input[name="email"]',
    'input[placeholder*="email" i]',
    'input[autocomplete="email"]',
    'input[id*="email" i]',
    'input:not([type="hidden"]):not([type="password"])',
  ];

  const emailFilled = await tryFillField(page, emailSelectors, user, 'Email');

  if (!emailFilled) {
    console.log('Could not find email field automatically');
    const inputs = await page.evaluate(() => {
      return [...document.querySelectorAll('input:not([type="hidden"])')].map(el => ({
        type: el.type, name: el.name, id: el.id,
        placeholder: el.placeholder, className: el.className.substring(0, 80),
      }));
    });
    console.log('Visible inputs:', JSON.stringify(inputs, null, 2));
  }

  await page.waitForTimeout(1000);

  const passwordSelectors = [
    'input[type="password"]',
    'input[name="password"]',
    'input[placeholder*="password" i]',
    'input[autocomplete="current-password"]',
  ];

  let passFilled = await tryFillField(page, passwordSelectors, pass, 'Password');
  if (!passFilled) console.log('No password field found yet - may appear after email submission');

  await page.waitForTimeout(500);

  const submitSelectors = [
    'button[type="submit"]',
    'button:has-text("Sign in")',
    'button:has-text("Log in")',
    'button:has-text("Continue")',
    'button:has-text("Next")',
    'input[type="submit"]',
  ];

  const submitted = await tryClickSubmit(page, submitSelectors);
  if (!submitted) {
    console.log('No submit button found, trying Enter key...');
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(3000);
  console.log('Current URL after submit:', page.url());

  if (!passFilled) {
    passFilled = await tryFillField(page, passwordSelectors, pass, 'Password (step 2)');
    if (passFilled) await tryClickSubmit(page, submitSelectors);
  }
}

export async function login(options = {}) {
  const { user, pass } = loadCredentials();
  const { browser, context, page } = await launchBrowser({ ...options, headed: true });

  const loginUrl = `${BASE_URL}/auth/email/sign-in?rp=%2F`;
  console.log(`Navigating to ${loginUrl}...`);
  await page.goto(loginUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);

  const currentUrl = page.url();
  if (!currentUrl.includes('login') && !currentUrl.includes('auth')) {
    console.log('Already logged in! Saving state...');
    await context.storageState({ path: STATE_FILE });
    console.log(`Auth state saved to ${STATE_FILE}`);
    await browser.close();
    return;
  }

  await dismissAllModals(page);
  await debugScreenshot(page, 'login-page', { fullPage: true });
  console.log('Login page screenshot saved');

  const ariaSnap = await page.locator('body').ariaSnapshot();
  console.log('Page structure:', ariaSnap.substring(0, 2000));

  await performLoginSteps(page, user, pass);

  console.log('Waiting for login to complete...');
  await waitForLoginRedirect(page, options);

  await context.storageState({ path: STATE_FILE });
  console.log(`Auth state saved to ${STATE_FILE}`);
  await browser.close();
}

// Helper: try multiple selectors to fill a form field.
export async function tryFillField(page, selectors, value, fieldName) {
  for (const selector of selectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found ${fieldName} field with selector: ${selector}${count > 1 ? ` (${count} matches)` : ''}`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(value);
      console.log(`${fieldName} entered`);
      return true;
    }
  }
  return false;
}

// Helper: try multiple selectors to click a submit button.
export async function tryClickSubmit(page, selectors) {
  for (const selector of selectors) {
    const el = page.locator(selector).filter({ hasNotText: /google|apple|discord/i });
    const count = await el.count();
    if (count > 0) {
      console.log(`Clicking submit button: ${selector}`);
      await el.first().click();
      return true;
    }
  }
  return false;
}

// Helper: check if URL is not an auth/login URL.
export function isNonAuthUrl(url) {
  const u = url.toString();
  return !u.includes('/auth/') && !u.includes('/login');
}
