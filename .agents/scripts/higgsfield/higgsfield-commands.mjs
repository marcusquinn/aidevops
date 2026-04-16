// higgsfield-commands.mjs — Misc UI commands (screenshot, credits, apps, assets, seed-bracket)
// for the Higgsfield automation suite.
// Imported by playwright-automator.mjs (t1485 split).
//
// Asset chain → higgsfield-asset-chain.mjs
// Pipeline → higgsfield-pipeline.mjs
// Studio/tools → higgsfield-studio-commands.mjs
// Tests → higgsfield-tests.mjs
// (t2127 file-complexity decomposition)

import {
  BASE_URL,
  STATE_DIR,
  GENERATED_IMAGE_SELECTOR,
  getUnlimitedModelForCommand,
  ensureDir,
  safeJoin,
} from './higgsfield-common.mjs';

import {
  getDefaultOutputDir,
  launchBrowser,
  withBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  downloadLatestResult,
} from './higgsfield-output.mjs';

import {
  saveCreditCache,
} from './higgsfield-common.mjs';

import { generateImage } from './higgsfield-image.mjs';

import {
  uploadFileToPage,
  fillPromptField,
  navigateAndDismiss,
  saveStateAndClose,
} from './higgsfield-studio-commands.mjs';

// ─── Misc Commands ────────────────────────────────────────────────────────────

export async function useApp(options = {}) {
  return withBrowser(options, async (page) => {
    const appSlug = options.effect || 'face-swap';
    console.log(`Navigating to app: ${appSlug}...`);
    await navigateTo(page, `/app/${appSlug}`);
    await debugScreenshot(page, `app-${appSlug}`);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply"), button[type="submit"]:visible');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked generate/apply button');
    }

    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for result...`);
    try {
      await page.waitForSelector(`${GENERATED_IMAGE_SELECTOR}, video`, { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for app result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await debugScreenshot(page, `app-${appSlug}-result`);

    if (options.wait !== false) {
      const baseOutput = options.output || getDefaultOutputDir(options);
      const outputDir = resolveOutputDir(baseOutput, options, 'apps');
      await downloadLatestResult(page, outputDir, true, options);
    }

    return { success: true };
  }).catch(error => {
    console.error('Error using app:', error.message);
    return { success: false, error: error.message };
  });
}

export async function screenshot(options = {}) {
  return withBrowser(options, async (page) => {
    const url = options.prompt || `${BASE_URL}/asset/all`;
    console.log(`Navigating to ${url}...`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    const outputPath = options.output || safeJoin(STATE_DIR, 'screenshot.png');
    await page.screenshot({ path: outputPath, fullPage: false });
    console.log(`Screenshot saved to: ${outputPath}`);

    const ariaSnapshot = await page.locator('body').ariaSnapshot();
    console.log('\n--- ARIA Snapshot ---');
    console.log(ariaSnapshot.substring(0, 3000));

    return { success: true, path: outputPath };
  }).catch(error => {
    console.error('Screenshot error:', error.message);
    return { success: false, error: error.message };
  });
}

async function scrapeSubscriptionCredits(page) {
  const rowsPerPageSelect = page.locator('select');
  if (await rowsPerPageSelect.count() > 0) {
    await rowsPerPageSelect.selectOption('50');
    await page.waitForTimeout(2000);
    console.log('Set rows per page to 50 to show all models');
  }

  return page.evaluate(() => {
    const text = document.body.innerText;

    const creditMatch = text.match(/([\d\s,]+)\/([\d\s,]+)/);
    const remaining = creditMatch ? creditMatch[1].trim().replace(/[\s,]/g, '') : 'unknown';
    const total = creditMatch ? creditMatch[2].trim().replace(/[\s,]/g, '') : 'unknown';

    const planMatch = text.match(/(Creator|Team|Enterprise|Free)\s*Plan/i);
    const plan = planMatch ? planMatch[1] : 'unknown';

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

    const pageInfo = text.match(/Page (\d+) of (\d+)/);
    const currentPage = pageInfo ? parseInt(pageInfo[1], 10) : 1;
    const totalPages = pageInfo ? parseInt(pageInfo[2], 10) : 1;

    return { remaining, total, plan, unlimitedModels, currentPage, totalPages };
  });
}

export async function checkCredits(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Checking account credits...');
    await page.goto(`${BASE_URL}/me/settings/subscription`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(2000);

    const creditInfo = await scrapeSubscriptionCredits(page);

    console.log(`Plan: ${creditInfo.plan}`);
    console.log(`Credits: ${creditInfo.remaining} / ${creditInfo.total}`);
    console.log(`\nUnlimited models (${creditInfo.unlimitedModels.length}):`);
    creditInfo.unlimitedModels.forEach(m => {
      console.log(`  ${m.model} (expires: ${m.expires})`);
    });

    if (creditInfo.totalPages > 1) {
      console.log(`\nWARNING: Still showing page ${creditInfo.currentPage} of ${creditInfo.totalPages} - some models may be missing`);
    }

    saveCreditCache(creditInfo);

    await debugScreenshot(page, 'subscription', { fullPage: true });
    await saveStateAndClose(context, browser);
    return creditInfo;

  } catch (error) {
    console.error('Error checking credits:', error.message);
    await browser.close();
    return null;
  }
}

export async function listAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to assets page...');
    await page.goto(`${BASE_URL}/asset/all`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await debugScreenshot(page, 'assets-page');

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

    await saveStateAndClose(context, browser);
    return assets;

  } catch (error) {
    console.error('Error listing assets:', error.message);
    await browser.close();
    return [];
  }
}

export async function seedBracket(options = {}) {
  const prompt = options.prompt;
  if (!prompt) {
    console.error('ERROR: --prompt is required for seed bracketing');
    process.exit(1);
  }

  let seeds = [];
  const range = options.seedRange || '1000-1010';
  if (range.includes('-')) {
    const [start, end] = range.split('-').map(Number);
    for (let s = start; s <= end; s++) seeds.push(s);
  } else {
    seeds = range.split(',').map(Number);
  }

  console.log(`Seed bracketing: testing ${seeds.length} seeds with prompt: "${prompt.substring(0, 60)}..."`);
  console.log(`Seeds: ${seeds.join(', ')}`);

  const model = options.model || (options.preferUnlimited !== false && getUnlimitedModelForCommand('image')?.slug) || 'soul';
  const outputDir = ensureDir(options.output || safeJoin(getDefaultOutputDir(options), `seed-bracket-${Date.now()}`));

  const results = [];

  for (const seed of seeds) {
    console.log(`\n--- Testing seed ${seed} ---`);
    const result = await generateImage({
      ...options,
      prompt: `${prompt} --seed ${seed}`,
      output: outputDir,
      batch: 1,
    });
    results.push({ seed, ...result });
    console.log(`Seed ${seed}: ${result?.success ? 'OK' : 'FAILED'}`);
  }

  console.log(`\n=== Seed Bracket Results ===`);
  console.log(`Prompt: "${prompt}"`);
  console.log(`Model: ${model}`);
  console.log(`Output: ${outputDir}`);
  console.log(`Results: ${results.filter(r => r.success).length}/${results.length} successful`);
  console.log(`\nReview the images in ${outputDir} and note the best seeds.`);
  console.log(`Then use --seed <number> with your chosen seed for consistent results.`);

  const { writeFileSync } = await import('fs');
  const manifest = {
    prompt, model,
    seeds: results.map(r => ({ seed: r.seed, success: r.success })),
    timestamp: new Date().toISOString(),
  };
  const bracketPath = safeJoin(outputDir, 'bracket-results.json');
  writeFileSync(bracketPath, JSON.stringify(manifest, null, 2));
  console.log(`Results saved to ${bracketPath}`);

  return results;
}

async function downloadAssetAtIndex(page, index, options) {
  const assetImg = page.locator('main img').nth(index);
  if (!await assetImg.isVisible({ timeout: 3000 }).catch(() => false)) return;
  await assetImg.click();
  await page.waitForTimeout(2500);
  await debugScreenshot(page, 'asset-detail');
  const baseOutput = options.output || getDefaultOutputDir(options);
  const dlDir = resolveOutputDir(baseOutput, options, 'misc');
  await downloadLatestResult(page, dlDir, false, options);
}

export async function manageAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const action = options.assetAction || 'list';
    console.log(`Asset Library: ${action}...`);
    await navigateAndDismiss(page, '/asset/all');

    const filter = options.filter || options.assetType;
    if (filter) {
      const filterMap = { image: 'Image', video: 'Video', lipsync: 'Lipsync', upscaled: 'Upscaled', liked: 'Liked' };
      const filterLabel = filterMap[filter.toLowerCase()] || filter;
      const filterBtn = page.locator(`button:has-text("${filterLabel}")`).last();
      if (await filterBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
        await filterBtn.click();
        await page.waitForTimeout(2000);
        console.log(`Filter applied: ${filterLabel}`);
      }
    }

    for (let i = 0; i < 3; i++) {
      await page.evaluate(() => window.scrollBy(0, 800));
      await page.waitForTimeout(1000);
    }

    const assetCount = await page.evaluate(() => document.querySelectorAll('main img').length);
    console.log(`Assets loaded: ${assetCount}`);

    if (action === 'list') {
      await debugScreenshot(page, 'asset-library');
      console.log(`Asset library screenshot saved. ${assetCount} assets visible.`);
      await saveStateAndClose(context, browser);
      return { success: true, count: assetCount };
    }

    if (action === 'download' || action === 'download-latest') {
      await downloadAssetAtIndex(page, options.assetIndex || 0, options);
      console.log('Asset downloaded');
    }

    if (action === 'download-all') {
      const maxDownloads = options.limit || 10;
      const baseOutput = options.output || getDefaultOutputDir(options);
      const dlDir = resolveOutputDir(baseOutput, options, 'misc');
      console.log(`Downloading up to ${maxDownloads} assets...`);

      for (let i = 0; i < Math.min(maxDownloads, assetCount); i++) {
        const assetImg = page.locator('main img').nth(i);
        if (await assetImg.isVisible({ timeout: 2000 }).catch(() => false)) {
          await assetImg.click();
          await page.waitForTimeout(2000);
          await downloadLatestResult(page, dlDir, false, options);
          await page.keyboard.press('Escape');
          await page.waitForTimeout(500);
          console.log(`Downloaded asset ${i + 1}/${maxDownloads}`);
        }
      }
    }

    await saveStateAndClose(context, browser);
    return { success: true, count: assetCount };
  } catch (error) {
    console.error('Asset Library error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}
