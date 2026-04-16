// higgsfield-tests.mjs — Auth health check, smoke test, and self-tests
// for the Higgsfield automation suite.
// Extracted from higgsfield-commands.mjs (t2127 file-complexity decomposition).

import { readFileSync, writeFileSync, existsSync, statSync } from 'fs';

import {
  BASE_URL,
  STATE_FILE,
  ROUTES_CACHE,
  CREDITS_CACHE_FILE,
  UNLIMITED_MODELS,
  UNLIMITED_SLUGS,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  estimateCreditCost,
  checkCreditGuard,
  getCachedCredits,
  saveCreditCache,
  parseArgs,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  dismissAllModals,
  debugScreenshot,
} from './higgsfield-browser.mjs';

// ─── Auth Health Check & Smoke Test ──────────────────────────────────────────

export async function authHealthCheck(options = {}) {
  console.log('[health-check] Verifying authentication state...');

  if (!existsSync(STATE_FILE)) {
    console.log('[health-check] No auth state found');
    console.log('[health-check] Run: higgsfield-helper.sh login');
    return { success: false, error: 'No auth state' };
  }

  const stats = statSync(STATE_FILE);
  const ageMs = Date.now() - stats.mtimeMs;
  const ageHours = Math.floor(ageMs / (1000 * 60 * 60));
  const ageDays = Math.floor(ageHours / 24);

  console.log(`[health-check] Auth state file: ${STATE_FILE}`);
  console.log(`[health-check] Age: ${ageDays}d ${ageHours % 24}h`);

  try {
    const { browser, page } = await launchBrowser({ ...options, headless: true });

    console.log('[health-check] Testing auth by navigating to /image/soul...');
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(3000);

    const currentUrl = page.url();

    if (currentUrl.includes('login') || currentUrl.includes('auth') || currentUrl.includes('sign-in')) {
      console.log('[health-check] Auth state is invalid (redirected to login)');
      console.log('[health-check] Run: higgsfield-helper.sh login');
      await browser.close();
      return { success: false, error: 'Auth expired or invalid' };
    }

    const userMenuSelectors = [
      '[data-testid="user-menu"]',
      'button[aria-label*="account" i]',
      'button[aria-label*="profile" i]',
      'img[alt*="avatar" i]',
      'div[class*="avatar"]',
    ];

    let foundUserIndicator = false;
    for (const selector of userMenuSelectors) {
      if (await page.locator(selector).count() > 0) {
        foundUserIndicator = true;
        break;
      }
    }

    await browser.close();

    if (foundUserIndicator) {
      console.log('[health-check] Auth state is valid');
      return { success: true, age: { hours: ageHours, days: ageDays } };
    }
    console.log('[health-check] Auth state uncertain (no user indicator found)');
    return { success: true, warning: 'Could not verify user indicator' };

  } catch (error) {
    console.error(`[health-check] Error during health check: ${error.message}`);
    return { success: false, error: error.message };
  }
}

async function smokeTestNavigation(page) {
  const testPages = [
    { url: `${BASE_URL}/image/soul`, name: 'Image Generation' },
    { url: `${BASE_URL}/video`, name: 'Video Generation' },
    { url: `${BASE_URL}/apps`, name: 'Apps' },
  ];

  let navSuccess = true;
  for (const testPage of testPages) {
    try {
      await page.goto(testPage.url, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForTimeout(2000);
      const currentUrl = page.url();

      if (currentUrl.includes('login') || currentUrl.includes('auth')) {
        console.log(`[smoke-test]   ${testPage.name}: Redirected to login`);
        navSuccess = false;
      } else {
        console.log(`[smoke-test]   ${testPage.name}: OK`);
      }
    } catch (error) {
      console.log(`[smoke-test]   ${testPage.name}: ${error.message}`);
      navSuccess = false;
    }
  }
  return navSuccess;
}

async function smokeTestCredits(page) {
  try {
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForTimeout(2000);

    const creditSelectors = [
      'text=/\\d+\\s*(credits?|cr)/i',
      '[data-testid*="credit"]',
      'div:has-text("credits")',
    ];

    for (const selector of creditSelectors) {
      const el = page.locator(selector);
      if (await el.count() > 0) {
        const text = await el.first().textContent();
        console.log(`[smoke-test]   Credits visible: ${text?.trim()}`);
        return true;
      }
    }

    console.log('[smoke-test]   Could not find credit indicator (may still work)');
    return false;
  } catch (error) {
    console.log(`[smoke-test]   Credits check failed: ${error.message}`);
    return false;
  }
}

export async function smokeTest(options = {}) {
  console.log('[smoke-test] Running smoke test...');
  console.log('[smoke-test] This will verify: auth, navigation, UI elements (no generation)');

  const results = { auth: false, navigation: false, credits: false, discovery: false, overall: false };

  try {
    console.log('\n[smoke-test] Step 1/4: Auth health check...');
    const authResult = await authHealthCheck({ ...options, headless: true });
    results.auth = authResult.success;

    if (!results.auth) {
      console.log('[smoke-test] Auth check failed, aborting smoke test');
      return results;
    }

    console.log('\n[smoke-test] Step 2/4: Testing navigation...');
    const { browser, page } = await launchBrowser({ ...options, headless: true });
    results.navigation = await smokeTestNavigation(page);

    console.log('\n[smoke-test] Step 3/4: Checking credits...');
    results.credits = await smokeTestCredits(page);

    console.log('\n[smoke-test] Step 4/4: Checking discovery cache...');
    if (existsSync(ROUTES_CACHE)) {
      const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
      const modelCount = Object.keys(cache.models || {}).length;
      const appCount = Object.keys(cache.apps || {}).length;
      console.log(`[smoke-test]   Discovery cache: ${modelCount} models, ${appCount} apps`);
      results.discovery = true;
    } else {
      console.log('[smoke-test]   No discovery cache (run: higgsfield-helper.sh image "test")');
      results.discovery = false;
    }

    await browser.close();

    results.overall = results.auth && results.navigation;

    console.log('\n[smoke-test] ========== RESULTS ==========');
    console.log(`[smoke-test] Auth:       ${results.auth ? 'PASS' : 'FAIL'}`);
    console.log(`[smoke-test] Navigation: ${results.navigation ? 'PASS' : 'FAIL'}`);
    console.log(`[smoke-test] Credits:    ${results.credits ? 'PASS' : 'WARN'}`);
    console.log(`[smoke-test] Discovery:  ${results.discovery ? 'PASS' : 'WARN'}`);
    console.log(`[smoke-test] Overall:    ${results.overall ? 'PASS' : 'FAIL'}`);
    console.log('[smoke-test] ============================');

    return results;

  } catch (error) {
    console.error(`[smoke-test] Smoke test error: ${error.message}`);
    results.overall = false;
    return results;
  }
}

// ─── Self-Tests ───────────────────────────────────────────────────────────────

export async function runSelfTests() {
  let passed = 0;
  let failed = 0;

  function assert(condition, name) {
    if (condition) {
      console.log(`  PASS: ${name}`);
      passed++;
    } else {
      console.error(`  FAIL: ${name}`);
      failed++;
    }
  }

  const originalCache = existsSync(CREDITS_CACHE_FILE)
    ? readFileSync(CREDITS_CACHE_FILE, 'utf-8')
    : null;

  console.log('\n=== Unlimited Model Selection Tests ===\n');

  console.log('--- UNLIMITED_MODELS mapping ---');
  const imageModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'image');
  const videoModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'video');
  assert(imageModels.length === 12, `12 image models mapped (got ${imageModels.length})`);
  assert(videoModels.length === 3, `3 video models mapped (got ${videoModels.length})`);

  console.log('\n--- SOTA quality priority ordering ---');
  const imagePriorities = imageModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(imagePriorities[0][1].slug === 'nano-banana-pro', 'Nano Banana Pro is priority 1');
  assert(imagePriorities[1][1].slug === 'gpt', 'GPT Image is priority 2');
  assert(imagePriorities[2][1].slug === 'seedream-4-5', 'Seedream 4.5 is priority 3');
  assert(imagePriorities[3][1].slug === 'flux', 'FLUX.2 Pro is priority 4');
  assert(imagePriorities[11][1].slug === 'popcorn', 'Popcorn is last');

  const videoPriorities = videoModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(videoPriorities[0][1].slug === 'kling-2.6', 'Kling 2.6 is top video model');
  assert(videoPriorities[1][1].slug === 'kling-o1', 'Kling O1 is second');
  assert(videoPriorities[2][1].slug === 'kling-2.5', 'Kling 2.5 Turbo is third');

  console.log('\n--- No duplicate priorities ---');
  const types = ['image', 'video', 'video-edit', 'motion-control', 'app'];
  for (const type of types) {
    const models = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === type);
    const priorities = models.map(([, v]) => v.priority);
    const uniquePriorities = new Set(priorities);
    assert(priorities.length === uniquePriorities.size, `No duplicate priorities in type '${type}'`);
  }

  console.log('\n--- getUnlimitedModelForCommand with mock cache ---');
  const mockCache = {
    remaining: '5916',
    total: '6000',
    plan: 'Creator',
    unlimitedModels: [
      { model: 'Nano Banana Pro365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'GPT Image365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Higgsfield Soul365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Seedream 4.5365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'FLUX.2 Pro365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Kling 2.6 Video Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
      { model: 'Kling O1 Video Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
      { model: 'Kling 2.5 Turbo Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
    ],
    timestamp: Date.now(),
  };
  saveCreditCache(mockCache);

  const bestImage = getUnlimitedModelForCommand('image');
  assert(bestImage !== null, 'Returns a model for image type');
  assert(bestImage.slug === 'nano-banana-pro', `Best image model is Nano Banana Pro (got: ${bestImage?.slug})`);
  assert(bestImage.name === 'Nano Banana Pro365 Unlimited', `Returns full model name`);

  const bestVideo = getUnlimitedModelForCommand('video');
  assert(bestVideo !== null, 'Returns a model for video type');
  assert(bestVideo.slug === 'kling-2.6', `Best video model is Kling 2.6 (got: ${bestVideo?.slug})`);

  console.log('\n--- Partial cache (limited models) ---');
  const partialCache = {
    remaining: '100',
    total: '6000',
    plan: 'Creator',
    unlimitedModels: [
      { model: 'Higgsfield Soul365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Nano Banana365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
    ],
    timestamp: Date.now(),
  };
  saveCreditCache(partialCache);

  const partialBest = getUnlimitedModelForCommand('image');
  assert(partialBest.slug === 'soul', `With only Soul+Nano active, Soul wins (got: ${partialBest?.slug})`);

  const noVideo = getUnlimitedModelForCommand('video');
  assert(noVideo === null, 'No video model when none are in cache');

  console.log('\n--- Empty/missing cache ---');
  const emptyCache = { remaining: '0', total: '0', plan: 'Free', unlimitedModels: [], timestamp: Date.now() };
  saveCreditCache(emptyCache);

  const emptyResult = getUnlimitedModelForCommand('image');
  assert(emptyResult === null, 'Returns null when no unlimited models in cache');

  console.log('\n--- isUnlimitedModel ---');
  saveCreditCache(mockCache);
  assert(isUnlimitedModel('gpt', 'image') === true, 'GPT is unlimited for image');
  assert(isUnlimitedModel('kling-2.6', 'video') === true, 'Kling 2.6 is unlimited for video');
  assert(isUnlimitedModel('soul', 'image') === true, 'Soul is unlimited for image');
  assert(isUnlimitedModel('sora', 'video') === false, 'Sora is NOT unlimited');
  assert(isUnlimitedModel('gpt', 'video') === false, 'GPT is NOT unlimited for video type');
  assert(isUnlimitedModel('kling-2.6', 'image') === false, 'Kling 2.6 is NOT unlimited for image type');

  console.log('\n--- estimateCreditCost with unlimited models ---');
  assert(estimateCreditCost('image', { model: 'gpt' }) === 0, 'GPT image costs 0 credits');
  assert(estimateCreditCost('video', { model: 'kling-2.6' }) === 0, 'Kling 2.6 video costs 0 credits');
  assert(estimateCreditCost('image', { model: 'sora' }) > 0, 'Non-unlimited model has credit cost');
  assert(estimateCreditCost('image', {}) === 0, 'No model + prefer-unlimited default = 0');
  assert(estimateCreditCost('image', { preferUnlimited: false }) > 0, 'prefer-unlimited=false has credit cost');
  assert(estimateCreditCost('video', {}) === 0, 'Video with auto-select = 0 credits');

  console.log('\n--- checkCreditGuard with unlimited models ---');
  const lowCreditCache = { ...mockCache, remaining: '1', timestamp: Date.now() };
  saveCreditCache(lowCreditCache);
  let guardPassed = false;
  try {
    checkCreditGuard('image', { model: 'gpt' });
    guardPassed = true;
  } catch { guardPassed = false; }
  assert(guardPassed, 'Credit guard passes for unlimited model even with 1 credit');

  let guardBlocked = false;
  try {
    checkCreditGuard('image', { model: 'sora', preferUnlimited: false });
    guardBlocked = false;
  } catch { guardBlocked = true; }
  assert(guardBlocked, 'Credit guard blocks non-unlimited model with 1 credit');

  console.log('\n--- UNLIMITED_SLUGS reverse lookup ---');
  assert(UNLIMITED_SLUGS.has('image:gpt'), 'Reverse lookup has image:gpt');
  assert(UNLIMITED_SLUGS.has('video:kling-2.6'), 'Reverse lookup has video:kling-2.6');
  assert(!UNLIMITED_SLUGS.has('video:gpt'), 'No reverse lookup for video:gpt');
  assert(UNLIMITED_SLUGS.get('image:gpt').includes('GPT Image365 Unlimited'), 'Reverse lookup maps to correct name');

  console.log('\n--- CLI flag parsing ---');
  const origArgv = process.argv;
  process.argv = ['node', 'test', 'image', '--prefer-unlimited'];
  let parsed = parseArgs();
  assert(parsed.options.preferUnlimited === true, '--prefer-unlimited sets true');

  process.argv = ['node', 'test', 'image', '--no-prefer-unlimited'];
  parsed = parseArgs();
  assert(parsed.options.preferUnlimited === false, '--no-prefer-unlimited sets false');

  process.argv = ['node', 'test', 'image'];
  parsed = parseArgs();
  assert(parsed.options.preferUnlimited === undefined, 'No flag leaves undefined');

  console.log('\n--- API flag parsing ---');
  process.argv = ['node', 'test', 'image', '--api'];
  parsed = parseArgs();
  assert(parsed.options.useApi === true, '--api sets useApi=true');
  assert(parsed.options.apiOnly === undefined, '--api does not set apiOnly');

  process.argv = ['node', 'test', 'image', '--api-only'];
  parsed = parseArgs();
  assert(parsed.options.useApi === true, '--api-only sets useApi=true');
  assert(parsed.options.apiOnly === true, '--api-only sets apiOnly=true');

  process.argv = ['node', 'test', 'image'];
  parsed = parseArgs();
  assert(parsed.options.useApi === undefined, 'No --api flag leaves useApi undefined');
  process.argv = origArgv;

  if (originalCache) {
    writeFileSync(CREDITS_CACHE_FILE, originalCache);
  }

  console.log(`\n=== Test Results: ${passed} passed, ${failed} failed ===\n`);
  if (failed > 0) {
    process.exit(1);
  }
}
