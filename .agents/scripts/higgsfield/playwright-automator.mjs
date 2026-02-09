#!/usr/bin/env node
// Higgsfield UI Automator - Playwright-based browser automation
// Uses the Higgsfield web UI to generate images/videos using subscription credits
// Part of AI DevOps Framework

import { chromium } from 'playwright';
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'fs';
import { join, basename, extname } from 'path';
import { homedir } from 'os';
import { execSync } from 'child_process';

// Constants
const BASE_URL = 'https://higgsfield.ai';
const STATE_DIR = join(homedir(), '.aidevops', '.agent-workspace', 'work', 'higgsfield');
const STATE_FILE = join(STATE_DIR, 'auth-state.json');
const ROUTES_CACHE = join(STATE_DIR, 'routes-cache.json');
const DISCOVERY_TIMESTAMP = join(STATE_DIR, 'last-discovery.txt');
const DOWNLOAD_DIR = join(homedir(), 'Downloads');
const DISCOVERY_MAX_AGE_HOURS = 24;

// Ensure state directory exists
if (!existsSync(STATE_DIR)) {
  mkdirSync(STATE_DIR, { recursive: true });
}

// Load credentials from credentials.sh
function loadCredentials() {
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

// Parse CLI arguments
function parseArgs() {
  const args = process.argv.slice(2);
  const command = args[0];
  const options = {};

  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--prompt' || args[i] === '-p') {
      options.prompt = args[++i];
    } else if (args[i] === '--model' || args[i] === '-m') {
      options.model = args[++i];
    } else if (args[i] === '--aspect' || args[i] === '-a') {
      options.aspect = args[++i];
    } else if (args[i] === '--output' || args[i] === '-o') {
      options.output = args[++i];
    } else if (args[i] === '--headed') {
      options.headed = true;
    } else if (args[i] === '--headless') {
      options.headless = true;
    } else if (args[i] === '--duration' || args[i] === '-d') {
      options.duration = args[++i];
    } else if (args[i] === '--image-url' || args[i] === '-i') {
      options.imageUrl = args[++i];
    } else if (args[i] === '--image-file') {
      options.imageFile = args[++i];
    } else if (args[i] === '--wait') {
      options.wait = true;
    } else if (args[i] === '--timeout') {
      options.timeout = parseInt(args[++i], 10);
    } else if (args[i] === '--effect') {
      options.effect = args[++i];
    } else if (args[i] === '--quality' || args[i] === '-q') {
      options.quality = args[++i];
    } else if (args[i] === '--enhance') {
      options.enhance = true;
    } else if (args[i] === '--no-enhance') {
      options.enhance = false;
    } else if (args[i] === '--sound') {
      options.sound = true;
    } else if (args[i] === '--no-sound') {
      options.sound = false;
    } else if (args[i] === '--batch' || args[i] === '-b') {
      options.batch = parseInt(args[++i], 10);
    } else if (args[i] === '--unlimited') {
      options.unlimited = true;
    } else if (args[i] === '--preset' || args[i] === '-s') {
      options.preset = args[++i];
    }
  }

  return { command, options };
}

// Launch browser with persistent context
async function launchBrowser(options = {}) {
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

  // Use persistent context if auth state exists
  if (existsSync(STATE_FILE)) {
    const browser = await chromium.launch(launchOptions);
    const context = await browser.newContext({
      storageState: STATE_FILE,
      viewport: { width: 1440, height: 900 },
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    });
    const page = await context.newPage();
    return { browser, context, page };
  }

  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  });
  const page = await context.newPage();
  return { browser, context, page };
}

// Check if site discovery is needed (stale or missing cache)
function discoveryNeeded() {
  if (!existsSync(DISCOVERY_TIMESTAMP)) return true;
  try {
    const lastRun = parseInt(readFileSync(DISCOVERY_TIMESTAMP, 'utf-8').trim(), 10);
    const ageHours = (Date.now() - lastRun) / (1000 * 60 * 60);
    return ageHours > DISCOVERY_MAX_AGE_HOURS;
  } catch {
    return true;
  }
}

// Run site discovery - crawl all nav links and cache routes + UI structure
async function runDiscovery(options = {}) {
  console.log('Running site discovery (checking for new/changed features)...');
  const { browser, context, page } = await launchBrowser({ ...options, headless: true });

  try {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    // Collect all internal links
    const links = await page.evaluate(() => {
      const allLinks = [...document.querySelectorAll('a[href]')];
      const map = {};
      allLinks.forEach(a => {
        const href = a.getAttribute('href');
        // Clean the text: strip "Your browser does not support the video." prefix
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

    // Categorise routes
    const routes = { image: {}, video: {}, edit: {}, apps: {}, features: {}, account: {}, motions: {}, mixed_media: {}, other: {} };
    for (const [path, label] of Object.entries(links)) {
      if (path.startsWith('/image/'))                    routes.image[path] = label;
      else if (path.startsWith('/create/'))              routes.video[path] = label;
      else if (path.startsWith('/edit'))                 routes.edit[path] = label;
      else if (path.startsWith('/app/'))                 routes.apps[path] = label;
      else if (path.startsWith('/motion/'))              routes.motions[path] = label;
      else if (path.startsWith('/mixed-media-presets/')) routes.mixed_media[path] = label;
      else if (['/asset/all','/library/image','/profile','/pricing','/auth/'].some(p => path.startsWith(p)))
                                                         routes.account[path] = label;
      else if (['/cinema-studio','/vibe-motion','/lipsync-studio','/character',
                '/ai-influencer-studio','/upscale','/fashion-factory','/chat',
                '/ugc-factory','/photodump-studio','/storyboard-generator',
                '/nano-banana-pro','/seedream-4-5','/kling','/sora','/wan','/veo','/minimax',
               ].some(p => path.startsWith(p)))
                                                         routes.features[path] = label;
      else                                               routes.other[path] = label;
    }

    // Also snapshot the image page to capture current model options
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    const imageAria = await page.locator('body').ariaSnapshot();

    // Extract model selector options if visible
    const imageModels = await page.evaluate(() => {
      // Look for model selector buttons/dropdowns
      const modelBtns = [...document.querySelectorAll('button')].filter(b =>
        b.textContent?.match(/soul|nano|seedream|flux|gpt|wan|kontext/i)
      );
      return modelBtns.map(b => b.textContent?.trim().substring(0, 60));
    });

    // Diff against previous cache
    let changes = [];
    if (existsSync(ROUTES_CACHE)) {
      try {
        const prev = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
        const prevApps = new Set(Object.keys(prev.apps || {}));
        const prevImage = new Set(Object.keys(prev.image || {}));
        const prevFeatures = new Set(Object.keys(prev.features || {}));

        for (const path of Object.keys(routes.apps)) {
          if (!prevApps.has(path)) changes.push(`NEW APP: ${path} → ${routes.apps[path]}`);
        }
        for (const path of Object.keys(routes.image)) {
          if (!prevImage.has(path)) changes.push(`NEW IMAGE MODEL: ${path} → ${routes.image[path]}`);
        }
        for (const path of Object.keys(routes.features)) {
          if (!prevFeatures.has(path)) changes.push(`NEW FEATURE: ${path} → ${routes.features[path]}`);
        }
        // Check for removed items
        for (const path of prevApps) {
          if (!routes.apps[path]) changes.push(`REMOVED APP: ${path}`);
        }
      } catch { /* first run or corrupt cache */ }
    }

    // Save cache
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

    // Report
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

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return cacheData;

  } catch (error) {
    console.error('Discovery error:', error.message);
    await browser.close();
    return null;
  }
}

// Ensure discovery has run (call at start of each command)
async function ensureDiscovery(options = {}) {
  if (discoveryNeeded()) {
    return await runDiscovery(options);
  }
  return null;
}

// Known modal/interruption log - append new types as we encounter them
const KNOWN_INTERRUPTIONS_FILE = join(STATE_DIR, 'known-interruptions.json');

function loadKnownInterruptions() {
  if (!existsSync(KNOWN_INTERRUPTIONS_FILE)) return [];
  try { return JSON.parse(readFileSync(KNOWN_INTERRUPTIONS_FILE, 'utf-8')); }
  catch { return []; }
}

function logNewInterruption(type, selector, detail) {
  const known = loadKnownInterruptions();
  const exists = known.some(k => k.type === type && k.selector === selector);
  if (!exists) {
    known.push({ type, selector, detail, firstSeen: new Date().toISOString() });
    writeFileSync(KNOWN_INTERRUPTIONS_FILE, JSON.stringify(known, null, 2));
    console.log(`Logged new interruption type: ${type} (${detail})`);
  }
}

// Comprehensive interruption dismissal - handles all known Higgsfield UI popups
async function dismissInterruptions(page) {
  const results = await page.evaluate(() => {
    const dismissed = [];

    // --- 1. React-Aria modal overlays (promo dialogs, offers) ---
    const overlays = document.querySelectorAll(
      '.react-aria-ModalOverlay, [data-rac].react-aria-ModalOverlay'
    );
    overlays.forEach(overlay => {
      overlay.remove();
      dismissed.push('react-aria-modal');
    });

    // --- 2. Dismiss buttons (off-screen react-aria dismiss) ---
    document.querySelectorAll('button[aria-label="Dismiss"]').forEach(btn => {
      btn.click();
      dismissed.push('dismiss-button');
    });

    // --- 3. Cookie consent / GDPR banners ---
    const cookieSelectors = [
      '[class*="cookie"]', '[id*="cookie"]',
      '[class*="consent"]', '[id*="consent"]',
      '[class*="gdpr"]', '[id*="gdpr"]',
      '[class*="CookieBanner"]',
    ];
    for (const sel of cookieSelectors) {
      document.querySelectorAll(sel).forEach(el => {
        // Click accept/close button inside, or remove the banner
        const acceptBtn = el.querySelector(
          'button:has-text("Accept"), button:has-text("OK"), button:has-text("Got it"), button[class*="accept"]'
        );
        if (acceptBtn) { acceptBtn.click(); dismissed.push('cookie-accept'); }
        else { el.remove(); dismissed.push('cookie-remove'); }
      });
    }

    // --- 4. Notification toasts (credit alerts, system messages) ---
    // The ARIA snapshot showed: heading "10 daily credits added" + paragraph
    document.querySelectorAll(
      '[role="alert"], [class*="toast"], [class*="Toast"], [class*="notification"], [class*="Notification"], [class*="snackbar"]'
    ).forEach(el => {
      const closeBtn = el.querySelector('button');
      if (closeBtn) { closeBtn.click(); dismissed.push('toast-close'); }
    });

    // --- 5. Onboarding tooltips / guided tours ---
    document.querySelectorAll(
      '[class*="tooltip"][class*="onboard"], [class*="tour"], [class*="walkthrough"], [class*="Popover"][class*="guide"]'
    ).forEach(el => {
      const skipBtn = el.querySelector('button:last-child') || el.querySelector('button');
      if (skipBtn) { skipBtn.click(); dismissed.push('onboarding-skip'); }
      else { el.remove(); dismissed.push('onboarding-remove'); }
    });

    // --- 6. Upgrade/pricing nag overlays ---
    document.querySelectorAll(
      '[class*="upgrade"], [class*="paywall"], [class*="subscribe"]'
    ).forEach(el => {
      // Only remove if it's an overlay/modal, not inline content
      if (el.style.position === 'fixed' || el.style.position === 'absolute' ||
          getComputedStyle(el).position === 'fixed') {
        el.remove();
        dismissed.push('upgrade-overlay');
      }
    });

    // --- 7. Generic dialog/modal elements ---
    document.querySelectorAll('[role="dialog"]').forEach(dialog => {
      // Check if it's a blocking modal (has an overlay parent or fixed position)
      const parent = dialog.parentElement;
      if (parent && (parent.classList.contains('react-aria-ModalOverlay') ||
          getComputedStyle(parent).position === 'fixed')) {
        parent.remove();
        dismissed.push('generic-dialog');
      }
    });

    // --- 8. Full-screen loading overlays inside main ---
    document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => {
      // Only remove if it looks like a loading spinner (few/no children with content)
      const hasRealContent = el.querySelector('textarea, input, button[type="submit"], form');
      if (!hasRealContent && el.children.length <= 2) {
        el.remove();
        dismissed.push('loading-overlay');
      }
    });

    // --- 9. Restore body scroll/pointer if modals locked it ---
    if (document.body.style.overflow === 'hidden' ||
        document.body.style.pointerEvents === 'none') {
      document.body.style.overflow = '';
      document.body.style.pointerEvents = '';
      dismissed.push('body-unlock');
    }

    return dismissed;
  });

  if (results.length > 0) {
    console.log(`Cleared ${results.length} interruption(s): ${[...new Set(results)].join(', ')}`);
    // Log any new types we haven't seen before
    for (const type of new Set(results)) {
      logNewInterruption(type, 'auto-detected', `Dismissed via comprehensive sweep`);
    }
  }

  // Also try Escape key for any remaining react-aria modals
  const remaining = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (remaining > 0) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
    const afterEsc = await page.evaluate(() =>
      document.querySelectorAll('.react-aria-ModalOverlay').length
    );
    if (afterEsc < remaining) {
      console.log(`Escape dismissed ${remaining - afterEsc} more modal(s)`);
    }
  }

  return results.length;
}

// Dismiss all interruptions (retry for stacked/delayed popups)
async function dismissAllModals(page) {
  let totalDismissed = 0;
  for (let i = 0; i < 3; i++) {
    const count = await dismissInterruptions(page);
    totalDismissed += count;
    if (count === 0) break;
    await page.waitForTimeout(500);
  }
  return totalDismissed;
}

// Login to Higgsfield
async function login(options = {}) {
  const { user, pass } = loadCredentials();
  const { browser, context, page } = await launchBrowser({ ...options, headed: true });

  // Go directly to the email sign-in page
  const loginUrl = `${BASE_URL}/auth/email/sign-in?rp=%2F`;
  console.log(`Navigating to ${loginUrl}...`);
  await page.goto(loginUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);

  // Check if already logged in (redirected away from auth)
  const currentUrl = page.url();
  if (!currentUrl.includes('login') && !currentUrl.includes('auth')) {
    console.log('Already logged in! Saving state...');
    await context.storageState({ path: STATE_FILE });
    console.log(`Auth state saved to ${STATE_FILE}`);
    await browser.close();
    return;
  }

  // Dismiss any promo modals/overlays that may block the form
  await dismissAllModals(page);

  // Take a screenshot to see what we're working with
  await page.screenshot({ path: join(STATE_DIR, 'login-page.png'), fullPage: true });
  console.log('Login page screenshot saved');

  // Get ARIA snapshot for understanding the page structure
  const ariaSnap = await page.locator('body').ariaSnapshot();
  console.log('Page structure:', ariaSnap.substring(0, 2000));

  // Try multiple strategies to find and fill the email field
  const emailSelectors = [
    'input[type="email"]',
    'input[name="email"]',
    'input[placeholder*="email" i]',
    'input[placeholder*="Email" i]',
    'input[autocomplete="email"]',
    'input[id*="email" i]',
    'input:not([type="hidden"]):not([type="password"])',
  ];

  let emailFilled = false;
  for (const selector of emailSelectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found email field with selector: ${selector} (${count} matches)`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(user);
      emailFilled = true;
      console.log('Email entered');
      break;
    }
  }

  if (!emailFilled) {
    console.log('Could not find email field automatically');
    // List all visible inputs for debugging
    const inputs = await page.evaluate(() => {
      return [...document.querySelectorAll('input:not([type="hidden"])')].map(el => ({
        type: el.type, name: el.name, id: el.id,
        placeholder: el.placeholder, className: el.className.substring(0, 80),
      }));
    });
    console.log('Visible inputs:', JSON.stringify(inputs, null, 2));
  }

  await page.waitForTimeout(1000);

  // Try to find and fill password field
  const passwordSelectors = [
    'input[type="password"]',
    'input[name="password"]',
    'input[placeholder*="password" i]',
    'input[autocomplete="current-password"]',
  ];

  let passFilled = false;
  for (const selector of passwordSelectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found password field with selector: ${selector}`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(pass);
      passFilled = true;
      console.log('Password entered');
      break;
    }
  }

  if (!passFilled) {
    console.log('No password field found yet - may appear after email submission');
  }

  await page.waitForTimeout(500);

  // Click submit/continue button
  const submitSelectors = [
    'button[type="submit"]',
    'button:has-text("Sign in")',
    'button:has-text("Log in")',
    'button:has-text("Continue")',
    'button:has-text("Next")',
    'input[type="submit"]',
  ];

  let submitted = false;
  for (const selector of submitSelectors) {
    const el = page.locator(selector).filter({ hasNotText: /google|apple|discord/i });
    const count = await el.count();
    if (count > 0) {
      console.log(`Clicking submit button: ${selector}`);
      await el.first().click();
      submitted = true;
      break;
    }
  }

  if (!submitted) {
    console.log('No submit button found, trying Enter key...');
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(3000);

  // Check if we need to enter password on a second page
  const currentUrl2 = page.url();
  console.log('Current URL after submit:', currentUrl2);

  if (!passFilled) {
    // Password might appear on a second step
    for (const selector of passwordSelectors) {
      const el = page.locator(selector);
      const count = await el.count();
      if (count > 0) {
        console.log(`Found password field on step 2: ${selector}`);
        await el.first().click();
        await page.waitForTimeout(300);
        await el.first().fill(pass);
        passFilled = true;
        console.log('Password entered on step 2');

        // Submit again
        for (const subSelector of submitSelectors) {
          const subEl = page.locator(subSelector).filter({ hasNotText: /google|apple|discord/i });
          if (await subEl.count() > 0) {
            await subEl.first().click();
            break;
          }
        }
        break;
      }
    }
  }

  // Wait for redirect after login
  console.log('Waiting for login to complete...');
  try {
    await page.waitForURL(url => {
      const u = url.toString();
      return !u.includes('/auth/') && !u.includes('/login');
    }, { timeout: 30000 });
    console.log('Login successful! Redirected to:', page.url());
  } catch {
    console.log('Still on auth page. Current URL:', page.url());
    await page.screenshot({ path: join(STATE_DIR, 'login-result.png'), fullPage: true });

    // Check if there's an error message
    const errorText = await page.evaluate(() => {
      const errors = document.querySelectorAll('[class*="error"], [class*="alert"], [role="alert"]');
      return [...errors].map(e => e.textContent?.trim()).filter(Boolean).join('; ');
    });
    if (errorText) {
      console.log('Error message:', errorText);
    }

    // Wait for manual intervention if headed
    if (options.headed) {
      console.log('Waiting 60s for manual login completion...');
      try {
        await page.waitForURL(url => {
          const u = url.toString();
          return !u.includes('/auth/') && !u.includes('/login');
        }, { timeout: 60000 });
        console.log('Login completed manually! URL:', page.url());
      } catch {
        console.log('Timeout. Saving current state anyway...');
      }
    }
  }

  // Save auth state regardless
  await context.storageState({ path: STATE_FILE });
  console.log(`Auth state saved to ${STATE_FILE}`);
  await browser.close();
}

// Check if logged in
async function checkAuth(page) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(2000);

  // Check for profile/avatar indicator or login button
  const profileIndicator = page.locator('[data-testid="profile"], .avatar, .user-menu, a[href="/profile"]');
  const loginBtn = page.locator('a:has-text("Log in"), button:has-text("Log in"), a:has-text("Sign in")');

  const isLoggedIn = await profileIndicator.count() > 0 || await loginBtn.count() === 0;
  return isLoggedIn;
}

// Configure image generation options on the page (aspect ratio, quality, enhance, batch, preset)
async function configureImageOptions(page, options) {
  // Select aspect ratio if specified
  if (options.aspect) {
    console.log(`Setting aspect ratio: ${options.aspect}`);
    // Aspect ratio buttons are typically in a button group
    const aspectBtn = page.locator(`button:has-text("${options.aspect}")`);
    if (await aspectBtn.count() > 0) {
      await aspectBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected aspect ratio: ${options.aspect}`);
    } else {
      // Try clicking the aspect ratio dropdown/selector first
      const aspectSelector = page.locator('button:has-text("Aspect"), [class*="aspect"]');
      if (await aspectSelector.count() > 0) {
        await aspectSelector.first().click({ force: true });
        await page.waitForTimeout(500);
        const option = page.locator(`[role="option"]:has-text("${options.aspect}"), button:has-text("${options.aspect}")`);
        if (await option.count() > 0) {
          await option.first().click({ force: true });
          await page.waitForTimeout(300);
          console.log(`Selected aspect ratio: ${options.aspect}`);
        }
      }
    }
  }

  // Select quality if specified
  if (options.quality) {
    console.log(`Setting quality: ${options.quality}`);
    const qualityBtn = page.locator(`button:has-text("${options.quality}")`);
    if (await qualityBtn.count() > 0) {
      await qualityBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected quality: ${options.quality}`);
    }
  }

  // Toggle enhance on/off
  if (options.enhance !== undefined) {
    const enhanceLabel = page.locator('label:has-text("Enhance"), button:has-text("Enhance")');
    if (await enhanceLabel.count() > 0) {
      const isChecked = await page.evaluate(() => {
        const el = document.querySelector('label:has(input) span:has-text("Enhance")');
        const input = el?.closest('label')?.querySelector('input');
        return input?.checked || false;
      });
      if (isChecked !== options.enhance) {
        await enhanceLabel.first().click({ force: true });
        await page.waitForTimeout(300);
        console.log(`${options.enhance ? 'Enabled' : 'Disabled'} enhance`);
      }
    }
  }

  // Set batch size if specified (1-4 images)
  if (options.batch && options.batch >= 1 && options.batch <= 4) {
    console.log(`Setting batch size: ${options.batch}`);
    const batchBtn = page.locator(`button:has-text("${options.batch}")`);
    // Batch buttons are typically small numbered buttons (1, 2, 3, 4)
    // We need to be more specific to avoid matching other buttons
    const batchGroup = page.locator('[class*="batch"], [class*="count"]');
    if (await batchGroup.count() > 0) {
      const btn = batchGroup.locator(`button:has-text("${options.batch}")`);
      if (await btn.count() > 0) {
        await btn.first().click({ force: true });
        await page.waitForTimeout(300);
        console.log(`Selected batch size: ${options.batch}`);
      }
    }
  }

  // Select style preset if specified
  if (options.preset) {
    console.log(`Selecting preset: ${options.preset}`);
    // Presets are shown as a scrollable list of style cards
    const presetBtn = page.locator(`button:has-text("${options.preset}"), [class*="preset"]:has-text("${options.preset}")`);
    if (await presetBtn.count() > 0) {
      await presetBtn.first().click({ force: true });
      await page.waitForTimeout(500);
      console.log(`Selected preset: ${options.preset}`);
    } else {
      console.log(`Preset "${options.preset}" not found on page`);
    }
  }
}

// Generate image via UI
async function generateImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'A serene mountain landscape at golden hour, photorealistic, 8k';
    const model = options.model || 'soul';

    // Navigate to image creation page - map model names to URL slugs
    const modelUrlMap = {
      'soul': '/image/soul',
      'nano_banana': '/image/nano_banana',
      'nano-banana': '/image/nano_banana',
      'nano_banana_pro': '/image/nano_banana_2',
      'nano-banana-pro': '/image/nano_banana_2',
      'seedream': '/image/seedream',
      'seedream-4': '/image/seedream',
      'wan2': '/image/wan2',
      'wan': '/image/wan2',
      'gpt': '/image/gpt',
      'gpt-image': '/image/gpt',
      'kontext': '/image/kontext',
      'flux-kontext': '/image/kontext',
      'flux': '/image/flux',
      'flux-pro': '/image/flux',
    };
    const modelPath = modelUrlMap[model] || `/image/${model}`;
    const imageUrl = `${BASE_URL}${modelPath}`;

    console.log(`Navigating to ${imageUrl}...`);
    await page.goto(imageUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    // Dismiss any promo modals
    await dismissAllModals(page);

    // Take screenshot to see current state
    await page.screenshot({ path: join(STATE_DIR, 'image-page.png'), fullPage: false });

    // Wait for the page content to fully load (dismiss loading overlays)
    await page.waitForTimeout(2000);
    // Remove any loading overlays that intercept pointer events
    await page.evaluate(() => {
      // Remove full-screen loading overlays inside main
      document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => {
        if (el.children.length <= 1) el.remove();
      });
    });

    // Find and fill the prompt textarea using force to bypass overlays
    const promptInput = page.locator('textarea, [contenteditable="true"], input[placeholder*="prompt" i], input[placeholder*="describe" i], input[placeholder*="Describe" i], input[placeholder*="Upload" i]');
    const promptCount = await promptInput.count();
    console.log(`Found ${promptCount} prompt input(s)`);

    if (promptCount > 0) {
      // Use force click to bypass any remaining overlays
      await promptInput.first().click({ force: true });
      await page.waitForTimeout(300);
      await promptInput.first().fill('', { force: true });
      await promptInput.first().fill(prompt, { force: true });
      console.log(`Entered prompt: "${prompt}"`);
      await page.waitForTimeout(500);
    } else {
      // Fallback: fill via JS
      const filled = await page.evaluate((p) => {
        const inputs = document.querySelectorAll('textarea, input[type="text"]');
        for (const input of inputs) {
          if (input.offsetParent !== null) {
            const nativeSetter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value'
            )?.set || Object.getOwnPropertyDescriptor(
              window.HTMLTextAreaElement.prototype, 'value'
            )?.set;
            if (nativeSetter) nativeSetter.call(input, p);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          }
        }
        return false;
      }, prompt);

      if (!filled) {
        console.error('Could not find prompt input field');
        await page.screenshot({ path: join(STATE_DIR, 'no-prompt-field.png'), fullPage: true });
        await browser.close();
        return null;
      }
      console.log('Entered prompt via JS fallback');
    }

    // Configure generation options (aspect ratio, quality, enhance, batch, preset)
    await configureImageOptions(page, options);

    // Snapshot existing image src URLs before generating (to identify new ones later)
    const existingSrcs = await page.evaluate(() => {
      const imgs = document.querySelectorAll('img[alt="image generation"]');
      return new Set([...imgs].map(img => img.src));
    });
    // Note: existingSrcs is serialized as an array, convert back to Set in page context
    const existingSrcArray = await page.evaluate(() => {
      return [...document.querySelectorAll('img[alt="image generation"]')].map(img => img.src);
    });
    console.log(`Existing images on page: ${existingSrcArray.length}`);

    // Count "In queue" items before generating
    const queueBefore = await page.evaluate(() => {
      return (document.body.innerText.match(/In queue/g) || []).length;
    });
    console.log(`Items already in queue: ${queueBefore}`);

    // Click generate button - use force to bypass overlays
    const generateBtn = page.locator('button:has-text("Generate"), button[type="submit"]');
    const genCount = await generateBtn.count();
    console.log(`Found ${genCount} generate button(s)`);

    if (genCount > 0) {
      const btn = generateBtn.last();
      await btn.click({ force: true });
      console.log('Clicked generate button (force)');
    } else {
      await page.evaluate(() => {
        const btn = document.querySelector('button[type="submit"]') ||
                    [...document.querySelectorAll('button')].find(b => b.textContent?.includes('Generate'));
        if (btn) btn.click();
      });
      console.log('Clicked generate button via JS');
    }

    // Wait for generation: the page adds "In queue" placeholders at the top,
    // then replaces them with img[alt="image generation"] when done.
    // Strategy: wait for new queue items to appear, then wait for them to resolve.
    const timeout = options.timeout || 300000; // 5 min default (images can take 2+ min)
    const startTime = Date.now();

    // Phase 1: Wait for new "In queue" items to confirm generation started
    console.log('Waiting for generation to start...');
    try {
      await page.waitForFunction(
        (prevQueueCount) => {
          return (document.body.innerText.match(/In queue/g) || []).length > prevQueueCount;
        },
        queueBefore,
        { timeout: 15000, polling: 1000 }
      );
      const newQueueCount = await page.evaluate(() =>
        (document.body.innerText.match(/In queue/g) || []).length
      );
      console.log(`Generation started! ${newQueueCount} item(s) in queue`);
    } catch {
      // Generation may have started and already completed, or the queue text differs
      console.log('Queue detection timed out - generation may have started differently');
    }

    // Phase 2: Poll until our queue items resolve to images.
    // Track the peak queue count (our items + any pre-existing), then wait for
    // the queue to drop back to the pre-existing level (or zero).
    console.log(`Waiting up to ${timeout / 1000}s for generation to complete...`);
    const pollInterval = 5000;
    let generationComplete = false;
    let peakQueue = queueBefore;

    while (Date.now() - startTime < timeout) {
      await page.waitForTimeout(pollInterval);

      const state = await page.evaluate(() => {
        const queueItems = (document.body.innerText.match(/In queue/g) || []).length;
        const images = document.querySelectorAll('img[alt="image generation"]').length;
        return { queueItems, images };
      });

      if (state.queueItems > peakQueue) peakQueue = state.queueItems;

      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      console.log(`  ${elapsed}s: queue=${state.queueItems} images=${state.images}`);

      // Our generation is complete when the queue has dropped back to at most
      // the pre-existing level AND we've seen it go higher (peak > before).
      if (peakQueue > queueBefore && state.queueItems <= queueBefore) {
        console.log(`Generation complete! ${state.images} images on page (${elapsed}s)`);
        generationComplete = true;
        break;
      }
    }

    if (!generationComplete) {
      console.log('Timeout waiting for generation. Some items may still be processing.');
    }

    // Allow images to fully load
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'generation-result.png'), fullPage: false });

    // Identify which images are new by comparing src URLs
    const newImageIndices = await page.evaluate((oldSrcs) => {
      const oldSet = new Set(oldSrcs);
      const imgs = document.querySelectorAll('img[alt="image generation"]');
      const indices = [];
      [...imgs].forEach((img, idx) => {
        if (!oldSet.has(img.src)) {
          indices.push(idx);
        }
      });
      return indices;
    }, existingSrcArray);
    console.log(`New images: ${newImageIndices.length} (indices: ${newImageIndices.join(', ')})`);

    // Download only the new results
    if (options.wait !== false) {
      const outputDir = options.output || DOWNLOAD_DIR;
      if (newImageIndices.length > 0) {
        await downloadSpecificImages(page, outputDir, newImageIndices);
      } else if (generationComplete) {
        // All images are new (page was refreshed during generation)
        console.log('All images appear new, downloading all...');
        await downloadLatestResult(page, outputDir, true);
      } else {
        console.log('No new images detected. Generation may still be in progress.');
        console.log('Try: node playwright-automator.mjs download');
      }
    }

    console.log('Image generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'generation-result.png') };

  } catch (error) {
    console.error('Error during image generation:', error.message);
    await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true });
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Download a video from the History tab on /create/video or /lipsync-studio
// History items are <li> elements containing <video> with direct CDN MP4 URLs.
// Primary strategy: extract video src directly. Fallback: click figure to open dialog.
async function downloadVideoFromHistory(page, outputDir, metadata = {}) {
  const downloaded = [];

  try {
    // Switch to History tab if not already there
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(2000);
    }

    await dismissAllModals(page);

    // Strategy: Extract video URL directly from the first (newest) history list item.
    // History items contain <video> elements with direct CDN MP4 URLs.
    // This is more reliable than clicking to open a dialog.
    const historyListItems = page.locator('main li');
    const listCount = await historyListItems.count();
    console.log(`Found ${listCount} item(s) in History tab`);

    if (listCount === 0) {
      console.log('No history items found to download');
      return downloaded;
    }

    // Extract video URL from the first (newest) list item
    const videoInfo = await page.evaluate(() => {
      const firstItem = document.querySelector('main li');
      if (!firstItem) return null;

      // Get video URL from <video> element
      const video = firstItem.querySelector('video');
      const videoSrc = video?.src || video?.querySelector('source')?.src || null;

      // Get prompt text
      const textbox = firstItem.querySelector('[role="textbox"], textarea');
      const promptText = textbox?.textContent?.trim() || '';

      // Get model name
      const modelBtn = firstItem.querySelector('button');
      const modelText = modelBtn?.textContent?.trim() || '';

      return { videoSrc, promptText, modelText };
    });

    if (videoInfo?.videoSrc) {
      const combinedMeta = {
        ...metadata,
        model: videoInfo.modelText || metadata.model,
        promptSnippet: videoInfo.promptText?.substring(0, 80) || metadata.promptSnippet,
      };
      const filename = buildDescriptiveFilename(combinedMeta, `higgsfield-video-${Date.now()}.mp4`, 0);
      const savePath = join(outputDir, filename);
      try {
        execSync(`curl -sL -o "${savePath}" "${videoInfo.videoSrc}"`, { timeout: 120000 });
        console.log(`Downloaded video: ${savePath}`);
        downloaded.push(savePath);
      } catch (curlErr) {
        console.log(`Video download failed: ${curlErr.message}`);
      }
    }

    // Fallback: try clicking the first item to open a dialog with Download button
    if (downloaded.length === 0) {
      console.log('Direct URL extraction failed, trying dialog approach...');
      const firstFigure = page.locator('main li figure').first();
      if (await firstFigure.count() > 0) {
        await firstFigure.click({ force: true });
        await page.waitForTimeout(2000);

        const dialog = page.locator('[role="dialog"]');
        if (await dialog.count() > 0) {
          const dialogMeta = await extractDialogMetadata(page);
          const combinedMeta = { ...metadata, ...dialogMeta };

          const dlBtn = page.locator('[role="dialog"] button:has-text("Download")');
          if (await dlBtn.count() > 0) {
            const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
            await dlBtn.first().click({ force: true });
            const download = await downloadPromise;
            if (download) {
              const origFilename = download.suggestedFilename() || `higgsfield-video-${Date.now()}.mp4`;
              const descriptiveName = buildDescriptiveFilename(combinedMeta, origFilename, 0);
              const savePath = join(outputDir, descriptiveName);
              await download.saveAs(savePath);
              console.log(`Downloaded video via dialog: ${savePath}`);
              downloaded.push(savePath);
            }
          }

          // Close dialog
          await page.keyboard.press('Escape');
          await page.waitForTimeout(500);
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
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'video-download-result.png'), fullPage: false });
  } catch (error) {
    console.log(`Video download error: ${error.message}`);
  }

  return downloaded;
}

// Generate video via UI
// Supports two flows:
//   1. Upload start frame image (--image-file) + prompt
//   2. Direct navigation to /create/video with prompt only (some models support text-to-video)
// Results appear in the History tab, not as inline <video> elements.
async function generateVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Camera slowly pans across a beautiful landscape as clouds drift overhead';
    const model = options.model || 'kling-2.6'; // Default to unlimited model

    // Navigate to video creation page
    console.log('Navigating to video creation page...');
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-page.png'), fullPage: false });

    // Upload start frame image if provided
    if (options.imageFile) {
      console.log(`Uploading start frame: ${options.imageFile}`);

      // Step 1: If there's an existing start frame, remove it first
      // The existing frame shows as button "Uploaded image" with a small X button nearby
      const existingFrame = page.getByRole('button', { name: 'Uploaded image' });
      if (await existingFrame.count() > 0) {
        // The X/remove button is a small 20x20 button below the start frame area
        // Find it by looking for a small button near the uploaded image
        const smallButtons = await page.evaluate(() => {
          const btns = [...document.querySelectorAll('main button')];
          return btns
            .filter(b => {
              const r = b.getBoundingClientRect();
              return r.width <= 24 && r.height <= 24 && r.y > 200 && r.y < 300;
            })
            .map(b => ({ x: b.getBoundingClientRect().x + 10, y: b.getBoundingClientRect().y + 10 }));
        });
        if (smallButtons.length > 0) {
          await page.mouse.click(smallButtons[0].x, smallButtons[0].y);
          await page.waitForTimeout(1500);
          console.log('Removed existing start frame');
        }
      }

      // Step 2: Click the "Upload image or generate it" button and handle file chooser
      const uploadBtn = page.getByRole('button', { name: /Upload image/ });
      if (await uploadBtn.count() > 0) {
        try {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 10000 }),
            uploadBtn.click({ force: true }),
          ]);
          await fileChooser.setFiles(options.imageFile);
          await page.waitForTimeout(3000);
          console.log('Start frame uploaded successfully');
        } catch (uploadErr) {
          console.log(`Start frame upload failed: ${uploadErr.message}`);
        }
      } else {
        // Fallback: try clicking the start frame area directly
        try {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 5000 }),
            page.mouse.click(160, 200),
          ]);
          await fileChooser.setFiles(options.imageFile);
          await page.waitForTimeout(3000);
          console.log('Start frame uploaded via area click');
        } catch {
          console.log('WARNING: Could not upload start frame image');
        }
      }
    } else {
      console.log('No start frame image provided. Some models support text-to-video.');
      console.log('For best results, provide --image-file with a start frame.');
    }

    // Wait for page to stabilize after upload and dismiss any new modals
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-after-upload.png'), fullPage: false });

    // Select model if specified (click model selector, find matching option)
    if (options.model) {
      console.log(`Selecting model: ${options.model}`);
      // The model selector is typically a dropdown/button group
      const modelSelector = page.locator('button:has-text("Model"), [class*="model-select"]');
      if (await modelSelector.count() > 0) {
        await modelSelector.first().click({ force: true });
        await page.waitForTimeout(1000);

        // Find the model option matching the requested model
        const modelOption = page.locator(`[role="option"]:has-text("${options.model}"), button:has-text("${options.model}")`);
        if (await modelOption.count() > 0) {
          await modelOption.first().click({ force: true });
          await page.waitForTimeout(500);
          console.log(`Selected model: ${options.model}`);
        } else {
          console.log(`Model "${options.model}" not found in selector, using default`);
        }
      }
    }

    // Enable "Unlimited mode" switch if available (saves credits on supported models)
    const unlimitedSwitch = page.locator('[role="switch"][aria-label="Unlimited mode"], switch[name="Unlimited mode"]');
    if (await unlimitedSwitch.count() > 0) {
      const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
      if (!isChecked) {
        await unlimitedSwitch.click({ force: true });
        await page.waitForTimeout(500);
        const nowChecked = await unlimitedSwitch.isChecked().catch(() => false);
        console.log(nowChecked ? 'Enabled Unlimited mode' : 'WARNING: Could not enable Unlimited mode');
      } else {
        console.log('Unlimited mode already enabled');
      }
    } else {
      console.log('No Unlimited mode switch found on this page');
    }

    // Fill the prompt - try multiple selectors
    let promptFilled = false;
    // Strategy 1: ARIA textbox named "Prompt"
    const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
    if (await promptByRole.count() > 0) {
      await promptByRole.click({ force: true });
      await page.waitForTimeout(300);
      await promptByRole.fill(prompt, { force: true });
      promptFilled = true;
      console.log(`Entered prompt via ARIA textbox: "${prompt.substring(0, 60)}..."`);
    }
    // Strategy 2: textarea or input with placeholder
    if (!promptFilled) {
      const promptInput = page.locator('textarea, input[placeholder*="Describe" i], input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().click({ force: true });
        await page.waitForTimeout(300);
        await promptInput.first().fill(prompt, { force: true });
        promptFilled = true;
        console.log(`Entered prompt via textarea: "${prompt.substring(0, 60)}..."`);
      }
    }
    // Strategy 3: contenteditable div
    if (!promptFilled) {
      const editable = page.locator('[contenteditable="true"], [role="textbox"]');
      if (await editable.count() > 0) {
        await editable.first().click({ force: true });
        await page.waitForTimeout(300);
        await page.keyboard.press('Meta+a');
        await page.keyboard.type(prompt);
        promptFilled = true;
        console.log(`Entered prompt via contenteditable: "${prompt.substring(0, 60)}..."`);
      }
    }
    if (!promptFilled) {
      console.log('WARNING: Could not find prompt input field');
    }

    // Count existing History items BEFORE generating (to detect new ones)
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    let existingHistoryCount = 0;
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1500);
      // Count list items in History (more reliable than img alt matching)
      existingHistoryCount = await page.locator('main li').count();
      console.log(`Existing History items: ${existingHistoryCount}`);

      // Switch back to the generation tab to click Generate
      const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:has-text("Generate")');
      if (await createTab.count() > 0) {
        await createTab.first().click({ force: true });
        await page.waitForTimeout(1000);
      }
    }

    // Click generate button
    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      console.log('Clicked Generate button');
    } else {
      console.log('WARNING: Generate button not found');
      await page.screenshot({ path: join(STATE_DIR, 'video-no-generate-btn.png'), fullPage: false });
    }

    await page.waitForTimeout(3000);
    await page.screenshot({ path: join(STATE_DIR, 'video-generate-clicked.png'), fullPage: false });

    // Wait for video generation by polling the History tab for new list items
    const timeout = options.timeout || 600000; // 10 minutes default (videos can take 5-10 min)
    console.log(`Waiting up to ${timeout / 1000}s for video generation...`);
    const startTime = Date.now();

    // Switch to History tab to monitor progress
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1000);
    }

    let generationComplete = false;
    const pollInterval = 10000; // Check every 10 seconds

    while (Date.now() - startTime < timeout) {
      await page.waitForTimeout(pollInterval);
      await dismissAllModals(page);

      // Check if the newest list item has a completed video (with src URL)
      // A new item appears immediately as "In queue" but only gets a <video src> when done
      const state = await page.evaluate((prevCount) => {
        const items = document.querySelectorAll('main li');
        const currentCount = items.length;
        // Check if the first (newest) item has a video with a src
        const firstItem = items[0];
        const video = firstItem?.querySelector('video');
        const videoSrc = video?.src || video?.querySelector('source')?.src || '';
        const hasCompletedVideo = videoSrc.includes('.mp4') || videoSrc.includes('cdn.');
        // Check for processing indicators in the first item
        const itemText = firstItem?.textContent || '';
        const isProcessing = itemText.includes('In queue') || itemText.includes('Processing') || itemText.includes('Cancel');
        return { currentCount, hasCompletedVideo, isProcessing, videoSrc: videoSrc.substring(0, 80) };
      }, existingHistoryCount);

      const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);

      if (state.currentCount > existingHistoryCount && state.hasCompletedVideo && !state.isProcessing) {
        console.log(`Video generation complete! (${elapsedSec}s, ${state.currentCount} items, video ready)`);
        generationComplete = true;
        break;
      }

      // Log progress
      if (state.isProcessing) {
        console.log(`  ${elapsedSec}s: processing (${state.currentCount} items)...`);
      } else {
        console.log(`  ${elapsedSec}s: waiting for result (${state.currentCount} items, video=${state.hasCompletedVideo})...`);
      }
    }

    if (!generationComplete) {
      console.log('Timeout waiting for video generation. The video may still be processing.');
      console.log('Check back later with: node playwright-automator.mjs download --model video');
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-result.png'), fullPage: false });

    // Download the video from History
    if (generationComplete && options.wait !== false) {
      const outputDir = options.output || DOWNLOAD_DIR;
      const videoMeta = { model, promptSnippet: prompt.substring(0, 80) };
      const downloads = await downloadVideoFromHistory(page, outputDir, videoMeta);
      if (downloads.length > 0) {
        console.log(`Video downloaded successfully: ${downloads.join(', ')}`);
      } else {
        console.log('Video appeared in History but download failed. Try manually or re-run download command.');
      }
    }

    console.log('Video generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'video-result.png') };

  } catch (error) {
    console.error('Error during video generation:', error.message);
    await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true });
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Generate lipsync video via UI
// Requires an image (--image-file) and text prompt or audio file
async function generateLipsync(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Hello! Welcome to our channel. Today we have something amazing to show you.';

    console.log('Navigating to Lipsync Studio...');
    await page.goto(`${BASE_URL}/lipsync-studio`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-page.png'), fullPage: false });

    // Upload character image
    if (options.imageFile) {
      console.log(`Uploading character image: ${options.imageFile}`);
      const fileInput = page.locator('input[type="file"]');
      if (await fileInput.count() > 0) {
        await fileInput.first().setInputFiles(options.imageFile);
        await page.waitForTimeout(3000);
        console.log('Character image uploaded');
      } else {
        // Try clicking an upload button first
        const uploadBtn = page.locator('button:has-text("Upload"), [class*="upload"]');
        if (await uploadBtn.count() > 0) {
          await uploadBtn.first().click({ force: true });
          await page.waitForTimeout(1000);
          const fileInput2 = page.locator('input[type="file"]');
          if (await fileInput2.count() > 0) {
            await fileInput2.first().setInputFiles(options.imageFile);
            await page.waitForTimeout(3000);
            console.log('Character image uploaded (after clicking upload button)');
          }
        }
      }
    } else {
      console.log('WARNING: Lipsync requires a character image (--image-file)');
      await browser.close();
      return { success: false, error: 'Character image required. Use --image-file to provide one.' };
    }

    // Select model if specified
    if (options.model) {
      console.log(`Selecting lipsync model: ${options.model}`);
      const modelSelector = page.locator('button:has-text("Model"), [class*="model"]');
      if (await modelSelector.count() > 0) {
        await modelSelector.first().click({ force: true });
        await page.waitForTimeout(1000);
        const modelOption = page.locator(`[role="option"]:has-text("${options.model}"), button:has-text("${options.model}")`);
        if (await modelOption.count() > 0) {
          await modelOption.first().click({ force: true });
          await page.waitForTimeout(500);
          console.log(`Selected model: ${options.model}`);
        }
      }
    }

    // Fill the text prompt (for text-to-speech lipsync)
    const textInput = page.locator('textarea, input[placeholder*="text" i], input[placeholder*="speak" i], input[placeholder*="say" i]');
    if (await textInput.count() > 0) {
      await textInput.first().click({ force: true });
      await page.waitForTimeout(300);
      await textInput.first().fill(prompt, { force: true });
      console.log(`Entered text: "${prompt}"`);
    }

    // Count existing History items before generating
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    let existingHistoryCount = 0;
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1500);
      existingHistoryCount = await page.locator('main li').count();
      console.log(`Existing History items: ${existingHistoryCount}`);
      // Switch back
      const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:first-child');
      if (await createTab.count() > 0) {
        await createTab.first().click({ force: true });
        await page.waitForTimeout(1000);
      }
    }

    // Click generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      console.log('Clicked Generate button');
    }

    await page.waitForTimeout(3000);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-generate-clicked.png'), fullPage: false });

    // Wait for result in History tab
    const timeout = options.timeout || 600000; // 10 min default
    console.log(`Waiting up to ${timeout / 1000}s for lipsync generation...`);
    const startTime = Date.now();

    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1000);
    }

    let generationComplete = false;
    const pollInterval = 10000;

    while (Date.now() - startTime < timeout) {
      await page.waitForTimeout(pollInterval);
      await dismissAllModals(page);

      const currentCount = await page.locator('main li').count();
      if (currentCount > existingHistoryCount) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        console.log(`Lipsync result detected! (${elapsed}s)`);
        generationComplete = true;
        break;
      }

      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      console.log(`  ${elapsed}s: waiting for lipsync result...`);
    }

    if (!generationComplete) {
      console.log('Timeout waiting for lipsync generation.');
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-result.png'), fullPage: false });

    // Download from History
    if (generationComplete && options.wait !== false) {
      const outputDir = options.output || DOWNLOAD_DIR;
      const meta = { model: options.model || 'lipsync', promptSnippet: prompt.substring(0, 80) };
      const downloads = await downloadVideoFromHistory(page, outputDir, meta);
      if (downloads.length > 0) {
        console.log(`Lipsync video downloaded: ${downloads.join(', ')}`);
      }
    }

    console.log('Lipsync generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'lipsync-result.png') };

  } catch (error) {
    console.error('Error during lipsync generation:', error.message);
    await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true });
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Navigate to assets page and list recent generations
async function listAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to assets page...');
    await page.goto(`${BASE_URL}/asset/all`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await page.screenshot({ path: join(STATE_DIR, 'assets-page.png'), fullPage: false });

    // Extract asset information
    const assets = await page.evaluate(() => {
      const items = document.querySelectorAll('[class*="asset"], [class*="generation"], [class*="card"], [class*="grid"] > div');
      return Array.from(items).slice(0, 20).map((item, index) => {
        const img = item.querySelector('img');
        const video = item.querySelector('video');
        const link = item.querySelector('a');
        return {
          index,
          type: video ? 'video' : img ? 'image' : 'unknown',
          src: video?.src || img?.src || null,
          href: link?.href || null,
          text: item.textContent?.trim().substring(0, 100) || '',
        };
      });
    });

    console.log(`Found ${assets.length} assets:`);
    assets.forEach(a => {
      console.log(`  [${a.index}] ${a.type}: ${a.text || a.src || 'no info'}`);
    });

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return assets;

  } catch (error) {
    console.error('Error listing assets:', error.message);
    await browser.close();
    return [];
  }
}

// Extract metadata from the open Asset showcase dialog
// Returns { model, preset, quality, promptSnippet } or null
async function extractDialogMetadata(page) {
  try {
    return await page.evaluate(() => {
      const dialog = document.querySelector('[role="dialog"]');
      if (!dialog) return null;

      const paragraphs = [...dialog.querySelectorAll('p, span, paragraph')];
      const getText = (label) => {
        for (let i = 0; i < paragraphs.length; i++) {
          if (paragraphs[i].textContent?.trim() === label && paragraphs[i + 1]) {
            return paragraphs[i + 1].textContent?.trim();
          }
        }
        return null;
      };

      // The dialog structure: "Model" paragraph followed by model name paragraph,
      // "Preset" followed by preset name, "Quality" followed by quality value
      const model = getText('Model');
      const preset = getText('Preset');
      const quality = getText('Quality');

      // Get prompt text from the tabpanel
      // Structure: p"Prompt", p"{actual prompt text}", p"See all", ...
      const tabpanel = dialog.querySelector('[role="tabpanel"]');
      let promptText = '';
      if (tabpanel) {
        const allP = [...tabpanel.querySelectorAll('p')];
        for (let i = 0; i < allP.length; i++) {
          if (allP[i].textContent?.trim() === 'Prompt' && allP[i + 1]) {
            promptText = allP[i + 1].textContent?.trim() || '';
            break;
          }
        }
        if (!promptText) {
          // Fallback: longest paragraph (likely the prompt)
          promptText = allP
            .map(p => p.textContent?.trim())
            .filter(t => t && t.length > 30)
            .sort((a, b) => b.length - a.length)[0] || '';
        }
      }

      return { model, preset, quality, promptSnippet: promptText.substring(0, 80) };
    });
  } catch {
    return null;
  }
}

// Build a descriptive filename from metadata
// Format: hf_{model}_{quality}_{aspect}_{promptSlug}_{index}.{ext}
function buildDescriptiveFilename(metadata, originalFilename, index) {
  const ext = extname(originalFilename) || '.png';
  const parts = ['hf'];

  if (metadata?.model) {
    parts.push(metadata.model.toLowerCase().replace(/[\s.]+/g, '-').replace(/[^a-z0-9-]/g, ''));
  }
  if (metadata?.quality) {
    parts.push(metadata.quality.toLowerCase());
  }
  if (metadata?.preset && metadata.preset !== 'General') {
    parts.push(metadata.preset.toLowerCase().replace(/[\s.]+/g, '-').replace(/[^a-z0-9-]/g, ''));
  }
  if (metadata?.promptSnippet) {
    const slug = metadata.promptSnippet
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .trim()
      .split(/\s+/)
      .slice(0, 6)
      .join('-');
    if (slug) parts.push(slug);
  }

  // Add timestamp and index for uniqueness
  const ts = new Date().toISOString().replace(/[-:T]/g, '').substring(0, 14);
  parts.push(ts);
  if (index !== undefined) parts.push(String(index + 1));

  return parts.join('_') + ext;
}

// Download generated results from the current page
// Strategy: click each generated image to open the "Asset showcase" dialog,
// then click the Download button in the dialog. Falls back to extracting
// CloudFront CDN URLs directly from img[alt="image generation"] elements.
async function downloadLatestResult(page, outputDir, downloadAll = true) {
  const downloaded = [];

  try {
    // Dismiss any lingering modals first
    await dismissAllModals(page);

    // Strategy 1: Click generated images to open detail dialog with Download button
    // On image generation pages: img[alt="image generation"]
    // On assets page: img[alt*="media asset by id"]
    const generatedImgs = page.locator('img[alt="image generation"], img[alt*="media asset by id"]');
    const imgCount = await generatedImgs.count();
    console.log(`Found ${imgCount} generated image(s) on page`);

    if (imgCount > 0) {
      const toDownload = downloadAll ? imgCount : 1;

      for (let i = 0; i < toDownload; i++) {
        try {
          // Click the image to open the Asset showcase dialog
          await generatedImgs.nth(i).click({ force: true });
          await page.waitForTimeout(1500);

          // Wait for the dialog to appear
          const dialog = page.locator('dialog, [role="dialog"]');
          const dialogVisible = await dialog.count() > 0;

          if (dialogVisible) {
            // Extract metadata from dialog before downloading
            const metadata = await extractDialogMetadata(page);

            // Look for Download button inside the dialog
            const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
            const dlBtnCount = await dlBtn.count();

            if (dlBtnCount > 0) {
              // Set up download event handler before clicking
              const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
              await dlBtn.first().click({ force: true });

              const download = await downloadPromise;
              if (download) {
                const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${i}.png`;
                const descriptiveName = buildDescriptiveFilename(metadata, origFilename, i);
                const savePath = join(outputDir, descriptiveName);
                await download.saveAs(savePath);
                console.log(`Downloaded [${i + 1}/${toDownload}]: ${savePath}`);
                downloaded.push(savePath);
              } else {
                // Download event didn't fire - the button may trigger a blob/fetch download
                // Wait a moment and check if a file appeared
                await page.waitForTimeout(2000);
                console.log(`Download button clicked but no download event for image ${i + 1} - trying CDN fallback`);
              }
            }

            // Close the dialog (press Escape or click outside)
            await page.keyboard.press('Escape');
            await page.waitForTimeout(500);

            // Verify dialog closed, force-remove if not
            const stillOpen = await page.locator('[role="dialog"]').count();
            if (stillOpen > 0) {
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
          }
        } catch (imgErr) {
          console.log(`Error downloading image ${i + 1}: ${imgErr.message}`);
        }
      }
    }

    // Strategy 2: If dialog-based download didn't work, extract CDN URLs directly
    if (downloaded.length === 0) {
      console.log('Falling back to direct CDN URL extraction...');

      const cdnUrls = await page.evaluate(() => {
        const imgs = document.querySelectorAll('img[alt="image generation"], img[alt*="media asset by id"]');
        return [...imgs].map(img => {
          const src = img.src;
          // Extract the raw CloudFront URL from the cdn-cgi wrapper
          // Format: https://higgsfield.ai/cdn-cgi/image/.../https://d8j0ntlcm91z4.cloudfront.net/...
          const cfMatch = src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
          return cfMatch ? cfMatch[1] : src;
        });
      });

      // Also check for video elements
      const videoUrls = await page.evaluate(() => {
        const videos = document.querySelectorAll('video source[src], video[src]');
        return [...videos].map(v => v.src || v.getAttribute('src')).filter(Boolean);
      });

      const allUrls = [...cdnUrls, ...videoUrls];
      const toDownload = downloadAll ? allUrls : allUrls.slice(0, 1);

      for (let i = 0; i < toDownload.length; i++) {
        const url = toDownload[i];
        const isVideo = url.includes('.mp4') || url.includes('video');
        const ext = isVideo ? '.mp4' : '.webp';
        const filename = `higgsfield-${Date.now()}-${i}${ext}`;
        const savePath = join(outputDir, filename);

        try {
          execSync(`curl -sL -o "${savePath}" "${url}"`, { timeout: 60000 });
          console.log(`Downloaded via CDN [${i + 1}/${toDownload.length}]: ${savePath}`);
          downloaded.push(savePath);
        } catch (curlErr) {
          console.log(`CDN download failed for ${url}: ${curlErr.message}`);
        }
      }
    }

    if (downloaded.length === 0) {
      console.log('No downloadable content found');
    } else {
      console.log(`Successfully downloaded ${downloaded.length} file(s)`);
    }

    return downloaded.length === 1 ? downloaded[0] : downloaded;

  } catch (error) {
    console.log('Download attempt failed:', error.message);
    return downloaded.length > 0 ? downloaded : null;
  }
}

// Download specific images by their index on the page
// Uses the same dialog-based approach as downloadLatestResult but only for specified indices
async function downloadSpecificImages(page, outputDir, indices) {
  const downloaded = [];
  const generatedImgs = page.locator('img[alt="image generation"], img[alt*="media asset by id"]');

  for (const idx of indices) {
    try {
      // Click the image to open the Asset showcase dialog
      await generatedImgs.nth(idx).click({ force: true });
      await page.waitForTimeout(1500);

      // Wait for dialog
      const dialog = page.locator('[role="dialog"]');
      if (await dialog.count() > 0) {
        // Extract metadata for descriptive filename
        const metadata = await extractDialogMetadata(page);

        const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
        if (await dlBtn.count() > 0) {
          const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
          await dlBtn.first().click({ force: true });

          const download = await downloadPromise;
          if (download) {
            const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${idx}.png`;
            const descriptiveName = buildDescriptiveFilename(metadata, origFilename, downloaded.length);
            const savePath = join(outputDir, descriptiveName);
            await download.saveAs(savePath);
            console.log(`Downloaded [${downloaded.length + 1}/${indices.length}]: ${savePath}`);
            downloaded.push(savePath);
          }
        }

        // Close dialog
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        const stillOpen = await page.locator('[role="dialog"]').count();
        if (stillOpen > 0) {
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
      }
    } catch (err) {
      console.log(`Error downloading image at index ${idx}: ${err.message}`);
    }
  }

  // CDN fallback for any that failed
  if (downloaded.length < indices.length) {
    console.log(`Dialog download got ${downloaded.length}/${indices.length}, trying CDN fallback for remainder...`);
    const cdnUrls = await page.evaluate((idxList) => {
      const imgs = document.querySelectorAll('img[alt="image generation"], img[alt*="media asset by id"]');
      return idxList.map(idx => {
        const img = imgs[idx];
        if (!img) return null;
        const cfMatch = img.src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
        return cfMatch ? cfMatch[1] : img.src;
      }).filter(Boolean);
    }, indices.slice(downloaded.length));

    for (let i = 0; i < cdnUrls.length; i++) {
      const ext = cdnUrls[i].includes('.mp4') ? '.mp4' : '.webp';
      const filename = `higgsfield-${Date.now()}-cdn-${i}${ext}`;
      const savePath = join(outputDir, filename);
      try {
        execSync(`curl -sL -o "${savePath}" "${cdnUrls[i]}"`, { timeout: 60000 });
        console.log(`Downloaded via CDN [${downloaded.length + 1}]: ${savePath}`);
        downloaded.push(savePath);
      } catch (curlErr) {
        console.log(`CDN download failed: ${curlErr.message}`);
      }
    }
  }

  console.log(`Successfully downloaded ${downloaded.length} file(s)`);
  return downloaded;
}

// Use a specific app/effect
async function useApp(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const appSlug = options.effect || 'face-swap';
    console.log(`Navigating to app: ${appSlug}...`);
    await page.goto(`${BASE_URL}/app/${appSlug}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    // Dismiss any promo modals
    await dismissAllModals(page);

    await page.screenshot({ path: join(STATE_DIR, `app-${appSlug}.png`), fullPage: false });

    // Upload image if provided
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]');
      if (await fileInput.count() > 0) {
        await fileInput.first().setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Image uploaded to app');
      }
    }

    // Fill prompt if available
    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    // Click generate/create
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply"), button[type="submit"]:visible');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click();
      console.log('Clicked generate/apply button');
    }

    // Wait for result
    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], video', {
        timeout,
        state: 'visible'
      });
    } catch {
      console.log('Timeout waiting for app result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `app-${appSlug}-result.png`), fullPage: false });

    if (options.wait !== false) {
      await downloadLatestResult(page, options.output || DOWNLOAD_DIR, true);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };

  } catch (error) {
    console.error('Error using app:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Take a screenshot of any Higgsfield page
async function screenshot(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const url = options.prompt || `${BASE_URL}/asset/all`;
    console.log(`Navigating to ${url}...`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    const outputPath = options.output || join(STATE_DIR, 'screenshot.png');
    await page.screenshot({ path: outputPath, fullPage: false });
    console.log(`Screenshot saved to: ${outputPath}`);

    // Also get ARIA snapshot for AI understanding
    const ariaSnapshot = await page.locator('body').ariaSnapshot();
    console.log('\n--- ARIA Snapshot ---');
    console.log(ariaSnapshot.substring(0, 3000));

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, path: outputPath };

  } catch (error) {
    console.error('Screenshot error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Check account credits/status via the subscription settings page
async function checkCredits(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Checking account credits...');
    await page.goto(`${BASE_URL}/me/settings/subscription`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    // Scroll down to load the unlimited models table
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(2000);

    // Change rows-per-page to 50 so all models are visible on one page
    const rowsPerPageSelect = page.locator('select');
    if (await rowsPerPageSelect.count() > 0) {
      await rowsPerPageSelect.selectOption('50');
      await page.waitForTimeout(2000);
      console.log('Set rows per page to 50 to show all models');
    }

    // Extract credit info
    const creditInfo = await page.evaluate(() => {
      const text = document.body.innerText;

      // Parse "6 004/ 6 000" or "6,004/ 6,000" format
      const creditMatch = text.match(/([\d\s,]+)\/([\d\s,]+)/);
      const remaining = creditMatch ? creditMatch[1].trim().replace(/[\s,]/g, '') : 'unknown';
      const total = creditMatch ? creditMatch[2].trim().replace(/[\s,]/g, '') : 'unknown';

      // Parse plan name
      const planMatch = text.match(/(Creator|Team|Enterprise|Free)\s*Plan/i);
      const plan = planMatch ? planMatch[1] : 'unknown';

      // Parse unlimited models from the table (all rows now visible)
      const rows = document.querySelectorAll('table tbody tr');
      const unlimitedModels = [];
      for (const row of rows) {
        const cells = [...row.querySelectorAll('td')];
        if (cells.length >= 4 && cells[3]?.textContent?.trim() === 'Active') {
          unlimitedModels.push({
            model: cells[0]?.textContent?.trim(),
            starts: cells[1]?.textContent?.trim(),
            expires: cells[2]?.textContent?.trim(),
          });
        }
      }

      // Parse pagination info for verification
      const pageInfo = text.match(/Page (\d+) of (\d+)/);
      const currentPage = pageInfo ? parseInt(pageInfo[1], 10) : 1;
      const totalPages = pageInfo ? parseInt(pageInfo[2], 10) : 1;

      return { remaining, total, plan, unlimitedModels, currentPage, totalPages };
    });

    console.log(`Plan: ${creditInfo.plan}`);
    console.log(`Credits: ${creditInfo.remaining} / ${creditInfo.total}`);
    console.log(`\nUnlimited models (${creditInfo.unlimitedModels.length}):`);
    creditInfo.unlimitedModels.forEach(m => {
      console.log(`  ${m.model} (expires: ${m.expires})`);
    });

    if (creditInfo.totalPages > 1) {
      console.log(`\nWARNING: Still showing page ${creditInfo.currentPage} of ${creditInfo.totalPages} - some models may be missing`);
    }

    await page.screenshot({ path: join(STATE_DIR, 'subscription.png'), fullPage: true });
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return creditInfo;

  } catch (error) {
    console.error('Error checking credits:', error.message);
    await browser.close();
    return null;
  }
}

// Main CLI handler
async function main() {
  const { command, options } = parseArgs();

  if (!command) {
    console.log(`
Higgsfield UI Automator - Browser-based generation using subscription credits

Usage: node playwright-automator.mjs <command> [options]

Commands:
  login              Login and save auth state
  discover           Force re-scan site for new features/models/apps
  image              Generate an image from text prompt
  video              Generate a video (text-to-video or image-to-video)
  lipsync            Generate a lipsync video (image + text/audio)
  app                Use a Higgsfield app/effect
  assets             List recent generations
  credits            Check account credits/plan
  screenshot         Take screenshot of any page
  download           Download latest generation (use --model video for videos)

Options:
  --prompt, -p       Text prompt for generation
  --model, -m        Model to use (soul, nano_banana, seedream, kling-2.6, etc.)
  --aspect, -a       Aspect ratio (16:9, 9:16, 1:1, 3:4, 4:3, 2:3, 3:2)
  --quality, -q      Quality setting (1K, 1.5K, 2K, 4K)
  --output, -o       Output directory or file path
  --headed           Run browser in headed mode (visible)
  --headless         Run browser in headless mode (default)
  --duration, -d     Video duration in seconds (5, 10, 15)
  --image-file       Path to image file for upload
  --image-url, -i    URL of image for image-to-video
  --wait             Wait for generation to complete
  --timeout          Timeout in milliseconds
  --effect           App/effect slug (e.g., face-swap, 3d-render)
  --enhance          Enable prompt enhancement
  --no-enhance       Disable prompt enhancement
  --sound            Enable sound/audio for video
  --no-sound         Disable sound/audio
  --batch, -b        Number of images to generate (1-4)
  --unlimited        Prefer unlimited models only
  --preset, -s       Style preset name (e.g., "Sunset beach", "CCTV")

Examples:
  node playwright-automator.mjs login --headed
  node playwright-automator.mjs image -p "A cyberpunk city at night, neon lights"
  node playwright-automator.mjs video -p "Camera pans across landscape" --image-file photo.jpg
  node playwright-automator.mjs lipsync -p "Hello world!" --image-file face.jpg
  node playwright-automator.mjs app --effect face-swap --image-file face.jpg
  node playwright-automator.mjs credits
  node playwright-automator.mjs download --model video
  node playwright-automator.mjs screenshot -p "https://higgsfield.ai/image/soul"
`);
    return;
  }

  // Run site discovery if cache is stale (skips login and discovery commands)
  if (command !== 'login' && command !== 'discover') {
    await ensureDiscovery(options);
  }

  switch (command) {
    case 'login':
      await login(options);
      break;
    case 'discover':
      await runDiscovery(options);
      break;
    case 'image':
      await generateImage(options);
      break;
    case 'video':
      await generateVideo(options);
      break;
    case 'lipsync':
      await generateLipsync(options);
      break;
    case 'app':
      await useApp(options);
      break;
    case 'assets':
      await listAssets(options);
      break;
    case 'credits':
      await checkCredits(options);
      break;
    case 'screenshot':
      await screenshot(options);
      break;
    case 'download': {
      const dlModel = options.model || 'soul';
      const isVideoDownload = dlModel === 'video' || options.duration;
      const { browser: dlBrowser, context: dlCtx, page: dlPage } = await launchBrowser(options);

      if (isVideoDownload) {
        // Download latest video from /create/video History tab
        console.log('Navigating to video page to download from History...');
        await dlPage.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
        await dlPage.waitForTimeout(5000);
        await dismissAllModals(dlPage);
        await downloadVideoFromHistory(dlPage, options.output || DOWNLOAD_DIR);
      } else {
        // Download latest image from image page
        const dlUrl = `${BASE_URL}/image/${dlModel}`;
        console.log(`Navigating to ${dlUrl} to download latest generations...`);
        await dlPage.goto(dlUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
        await dlPage.waitForTimeout(5000);
        await dismissAllModals(dlPage);
        await downloadLatestResult(dlPage, options.output || DOWNLOAD_DIR, true);
      }

      await dlCtx.storageState({ path: STATE_FILE });
      await dlBrowser.close();
      break;
    }
    default:
      console.error(`Unknown command: ${command}`);
      process.exit(1);
  }
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
