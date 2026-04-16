// higgsfield-commands.mjs — Misc UI commands (screenshot, credits, apps, studio tools)
// for the Higgsfield automation suite.
// Imported by playwright-automator.mjs (t1485 split).
//
// Asset chain → higgsfield-asset-chain.mjs
// Pipeline → higgsfield-pipeline.mjs
// Tests → higgsfield-tests.mjs
// (t2127 file-complexity decomposition)

import { readFileSync, existsSync } from 'fs';
import { join, basename, dirname } from 'path';
import { fileURLToPath } from 'url';

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  ROUTES_CACHE,
  GENERATED_IMAGE_SELECTOR,
  CREDITS_CACHE_FILE,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  ensureDir,
  safeJoin,
  sanitizePathSegment,
} from './higgsfield-common.mjs';

import {
  getDefaultOutputDir,
  launchBrowser,
  withBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
  clickGenerate,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  downloadLatestResult,
} from './higgsfield-output.mjs';

import {
  saveCreditCache,
  waitForGenerationResult,
} from './higgsfield-common.mjs';

import { generateImage } from './higgsfield-image.mjs';

// ─── Shared command helpers ────────────────────────────────────────────────────

async function uploadFileToPage(page, filePath, label = 'file') {
  const fileInput = page.locator('input[type="file"]').first();
  if (await fileInput.count() > 0) {
    await fileInput.setInputFiles(filePath);
    await page.waitForTimeout(2000);
    console.log(`${label} uploaded: ${basename(filePath)}`);
    return true;
  }
  return false;
}

async function uploadSecondFileToPage(page, filePath, label = 'second file') {
  const fileInputs = page.locator('input[type="file"]');
  const count = await fileInputs.count();
  if (count > 1) {
    await fileInputs.nth(1).setInputFiles(filePath);
    await page.waitForTimeout(2000);
    console.log(`${label} uploaded: ${basename(filePath)}`);
    return true;
  }
  return false;
}

async function fillPromptField(page, prompt) {
  const promptInput = page.locator('textarea').first();
  if (await promptInput.count() > 0) {
    await promptInput.fill(prompt);
    console.log('Prompt entered');
    return true;
  }
  return false;
}

async function selectButtonOption(page, value, label) {
  const btn = page.locator(`button:has-text("${value}")`);
  if (await btn.count() > 0) {
    await btn.first().click();
    await page.waitForTimeout(500);
    console.log(`${label} set to ${value}`);
    return true;
  }
  return false;
}

async function navigateAndDismiss(page, path, waitMs = 3000) {
  await page.goto(`${BASE_URL}${path}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(waitMs);
  await dismissAllModals(page);
}

async function saveStateAndClose(context, browser) {
  await context.storageState({ path: STATE_FILE });
  await browser.close();
}

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

export async function cinemaStudio(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Cinema Studio...');
    await navigateAndDismiss(page, '/cinema-studio');

    const tabName = options.duration ? 'Video' : (options.tab || 'Image');
    const tab = page.locator(`[role="tab"]:has-text("${tabName}")`);
    if (await tab.count() > 0) {
      await tab.click();
      await page.waitForTimeout(1000);
      console.log(`Selected ${tabName} tab`);
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.prompt) await fillPromptField(page, options.prompt);
    if (options.quality) await selectButtonOption(page, options.quality, 'Quality');
    if (options.aspect) await selectButtonOption(page, options.aspect, 'Aspect');

    await debugScreenshot(page, 'cinema-studio-configured');
    await clickGenerate(page, 'Cinema Studio');
    await waitForGenerationResult(page, options, {
      screenshotName: 'cinema-studio-result', label: 'Cinema Studio', outputSubdir: 'cinema',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Cinema Studio error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function motionControl(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Motion Control...');
    await navigateAndDismiss(page, '/create/motion-control');

    if (options.videoFile || options.motionRef) {
      await uploadFileToPage(page, options.videoFile || options.motionRef, 'Motion reference');
    }
    if (options.imageFile) await uploadSecondFileToPage(page, options.imageFile, 'Character image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    if (options.unlimited) {
      const unlimitedToggle = page.locator('text=Unlimited mode').locator('..').locator('[role="switch"], input[type="checkbox"]');
      if (await unlimitedToggle.count() > 0) {
        const isChecked = await unlimitedToggle.getAttribute('aria-checked') === 'true' || await unlimitedToggle.isChecked().catch(() => false);
        if (!isChecked) {
          await unlimitedToggle.click();
          await page.waitForTimeout(500);
          console.log('Unlimited mode enabled');
        }
      }
    }

    await debugScreenshot(page, 'motion-control-configured');
    await clickGenerate(page, 'Motion Control');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'motion-control-result', label: 'Motion Control',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true, useHistoryPoll: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Motion Control error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function editImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const model = options.model || 'soul_inpaint';
    console.log(`Navigating to Edit (${model})...`);
    await navigateAndDismiss(page, `/edit?model=${model}`);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image for editing');
    if (options.imageFile2) await uploadSecondFileToPage(page, options.imageFile2, 'Second image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, `edit-${model}-configured`);
    await clickGenerate(page, 'edit');
    await waitForGenerationResult(page, options, {
      selector: GENERATED_IMAGE_SELECTOR, screenshotName: `edit-${model}-result`,
      label: 'edit', outputSubdir: 'edits', defaultTimeout: 120000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function upscale(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Upscale...');
    await navigateAndDismiss(page, '/upscale');

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media for upscaling');

    await debugScreenshot(page, 'upscale-configured');

    const upscaleBtn = page.locator('button:has-text("Upscale"), button:has-text("Generate"), button:has-text("Enhance")');
    if (await upscaleBtn.count() > 0) {
      await upscaleBtn.first().click();
      console.log('Clicked Upscale');
    }

    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, a[download]`, screenshotName: 'upscale-result',
      label: 'upscale', outputSubdir: 'upscaled',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Upscale error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
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

function resolvePresetUrl(presetName, presets) {
  const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
  let presetUrl = presets[presetKey];
  if (!presetUrl) {
    const match = Object.keys(presets).find(k => k.includes(presetKey) || presetKey.includes(k));
    if (match) {
      presetUrl = presets[match];
      console.log(`Fuzzy matched preset: ${presetName} → ${match}`);
    }
  }
  return presetUrl;
}

export async function mixedMediaPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset || 'sketch';

    const routesPath = join(dirname(fileURLToPath(import.meta.url)), 'routes.json');
    const routes = JSON.parse(readFileSync(routesPath, 'utf-8'));
    const presets = routes.mixed_media_presets || {};

    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
    const presetUrl = resolvePresetUrl(presetName, presets);

    if (!presetUrl) {
      console.log(`Available presets: ${Object.keys(presets).join(', ')}`);
      await browser.close();
      return { success: false, error: `Unknown preset: ${presetName}` };
    }

    console.log(`Navigating to Mixed Media preset: ${presetName}...`);
    await navigateAndDismiss(page, presetUrl);

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, `mixed-media-${presetKey}-configured`);
    await clickGenerate(page, 'mixed media preset');
    await waitForGenerationResult(page, options, {
      screenshotName: `mixed-media-${presetKey}-result`, label: 'mixed media', outputSubdir: 'mixed-media',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Mixed Media Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

function listMotionPresets() {
  if (!existsSync(ROUTES_CACHE)) {
    console.log('No discovery cache found. Run "discover" first.');
    return;
  }
  const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
  const motions = cache.motions || {};
  const names = Object.keys(motions);
  console.log(`Available motion presets (${names.length}):`);
  names.slice(0, 50).forEach(n => console.log(`  ${n} → ${motions[n]}`));
  if (names.length > 50) console.log(`  ... and ${names.length - 50} more`);
}

function resolveMotionPresetUrl(presetName) {
  let presetUrl = null;

  if (existsSync(ROUTES_CACHE)) {
    const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
    const motions = cache.motions || {};
    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');

    presetUrl = motions[presetKey];
    if (!presetUrl) {
      const match = Object.keys(motions).find(k =>
        k.includes(presetKey) || presetKey.includes(k) ||
        k.toLowerCase().includes(presetName.toLowerCase())
      );
      if (match) {
        presetUrl = motions[match];
        console.log(`Fuzzy matched: ${presetName} → ${match}`);
      }
    }
  }

  if (!presetUrl && presetName.includes('/')) {
    presetUrl = presetName.startsWith('/') ? presetName : `/motion/${presetName}`;
  }
  if (!presetUrl && presetName.match(/^[0-9a-f-]{36}$/i)) {
    presetUrl = `/motion/${presetName}`;
  }

  return presetUrl;
}

export async function motionPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset;

    if (!presetName) {
      listMotionPresets();
      await browser.close();
      return { success: true, action: 'list' };
    }

    const presetUrl = resolveMotionPresetUrl(presetName);
    if (!presetUrl) {
      console.error(`Motion preset not found: ${presetName}. Run "discover" to refresh cache.`);
      await browser.close();
      return { success: false, error: `Unknown preset: ${presetName}` };
    }

    console.log(`Navigating to motion preset: ${presetName}...`);
    await navigateAndDismiss(page, presetUrl);

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, 'motion-preset-configured');
    await clickGenerate(page, 'motion preset');
    await waitForGenerationResult(page, options, {
      selector: `video, ${GENERATED_IMAGE_SELECTOR}`, screenshotName: 'motion-preset-result',
      label: 'motion preset', outputSubdir: 'motion-presets', defaultTimeout: 300000, isVideo: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Motion Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function editVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Video Edit...');
    await navigateAndDismiss(page, '/create/edit');

    if (options.videoFile) await uploadFileToPage(page, options.videoFile, 'Video');
    if (options.imageFile) {
      const uploaded = await uploadSecondFileToPage(page, options.imageFile, 'Character image');
      if (!uploaded && !options.videoFile) {
        await uploadFileToPage(page, options.imageFile, 'Image');
      }
    }
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, 'video-edit-configured');
    await clickGenerate(page, 'video edit');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'video-edit-result', label: 'video edit',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true, useHistoryPoll: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Video Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function storyboard(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Storyboard Generator...');
    await navigateAndDismiss(page, '/storyboard-generator');

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Reference image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    if (options.scenes) {
      const scenesInput = page.locator('input[type="number"], input[placeholder*="scene" i], input[placeholder*="panel" i]');
      if (await scenesInput.count() > 0) {
        await scenesInput.first().fill(String(options.scenes));
        console.log(`Panels set to ${options.scenes}`);
      }
    }

    if (options.preset) await selectButtonOption(page, options.preset, 'Style');

    await debugScreenshot(page, 'storyboard-configured');
    await clickGenerate(page, 'storyboard');
    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, .storyboard-panel, [class*="storyboard"]`,
      screenshotName: 'storyboard-result', label: 'storyboard',
      outputSubdir: 'storyboards', defaultTimeout: 300000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Storyboard error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

function resolveVibeMotionSubtype(subtype) {
  const subtypeMap = {
    infographics: 'Infographics',
    'text-animation': 'Text Animation',
    text: 'Text Animation',
    posters: 'Posters',
    poster: 'Posters',
    presentation: 'Presentation',
    scratch: 'From Scratch',
    'from-scratch': 'From Scratch',
  };
  return subtypeMap[subtype.toLowerCase()] || subtype;
}

export async function vibeMotion(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Vibe Motion...');
    await navigateAndDismiss(page, '/vibe-motion');

    const subtypeLabel = resolveVibeMotionSubtype(options.tab || 'From Scratch');
    const subtypeTab = page.locator(`[role="tab"]:has-text("${subtypeLabel}"), button:has-text("${subtypeLabel}")`);
    if (await subtypeTab.count() > 0) {
      await subtypeTab.first().click();
      await page.waitForTimeout(1000);
      console.log(`Selected sub-type: ${subtypeLabel}`);
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image/logo');
    if (options.prompt) await fillPromptField(page, options.prompt);
    if (options.preset) await selectButtonOption(page, options.preset, 'Style');
    if (options.duration) await selectButtonOption(page, `${options.duration}s`, 'Duration');
    if (options.aspect) await selectButtonOption(page, options.aspect, 'Aspect');

    await debugScreenshot(page, 'vibe-motion-configured');
    await clickGenerate(page, 'Vibe Motion');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'vibe-motion-result', label: 'Vibe Motion',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Vibe Motion error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function aiInfluencer(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to AI Influencer Studio...');
    await navigateAndDismiss(page, '/ai-influencer-studio');

    if (options.preset) {
      const typeBtn = page.locator(`button:has-text("${options.preset}"), [role="option"]:has-text("${options.preset}")`);
      if (await typeBtn.count() > 0) {
        await typeBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Character type: ${options.preset}`);
      }
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Reference image');

    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i], input[placeholder*="describe" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Description entered');
      }
    }

    await debugScreenshot(page, 'ai-influencer-configured');
    await clickGenerate(page, 'AI Influencer');
    await waitForGenerationResult(page, options, {
      selector: GENERATED_IMAGE_SELECTOR, screenshotName: 'ai-influencer-result',
      label: 'AI Influencer', outputSubdir: 'characters',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('AI Influencer error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function createCharacter(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Character...');
    await navigateAndDismiss(page, '/character');

    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        const isMultiple = await fileInput.getAttribute('multiple');
        if (isMultiple !== null && options.imageFile2) {
          await fileInput.setInputFiles([options.imageFile, options.imageFile2]);
        } else {
          await fileInput.setInputFiles(options.imageFile);
        }
        await page.waitForTimeout(2000);
        console.log('Character photo(s) uploaded');
      }
    }

    if (options.prompt) {
      const nameInput = page.locator('input[placeholder*="name" i], input[placeholder*="label" i], textarea').first();
      if (await nameInput.count() > 0) {
        await nameInput.fill(options.prompt);
        console.log(`Character name/description: ${options.prompt}`);
      }
    }

    await debugScreenshot(page, 'character-configured');
    await clickGenerate(page, 'character');
    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, [class*="character"]`, screenshotName: 'character-result',
      label: 'character creation', outputSubdir: 'characters', defaultTimeout: 120000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Character error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

const FEATURE_MAP = {
  'fashion-factory': { url: '/fashion-factory', name: 'Fashion Factory' },
  fashion: { url: '/fashion-factory', name: 'Fashion Factory' },
  'ugc-factory': { url: '/ugc-factory', name: 'UGC Factory' },
  ugc: { url: '/ugc-factory', name: 'UGC Factory' },
  'photodump-studio': { url: '/photodump-studio', name: 'Photodump Studio' },
  photodump: { url: '/photodump-studio', name: 'Photodump Studio' },
  'camera-controls': { url: '/camera-controls', name: 'Camera Controls' },
  camera: { url: '/camera-controls', name: 'Camera Controls' },
  effects: { url: '/effects', name: 'Effects' },
};

export async function featurePage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const featureKey = options.effect || options.feature || 'fashion-factory';
    const feature = FEATURE_MAP[featureKey.toLowerCase()] || { url: `/${featureKey}`, name: featureKey };

    console.log(`Navigating to ${feature.name}...`);
    await navigateAndDismiss(page, feature.url);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.imageFile2) await uploadSecondFileToPage(page, options.imageFile2, 'Additional image');

    if (options.videoFile) {
      const fileInput = page.locator('input[type="file"][accept*="video"], input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.videoFile);
        await page.waitForTimeout(2000);
        console.log('Video uploaded');
      }
    }

    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    if (options.preset) await selectButtonOption(page, options.preset, 'Style/preset');

    await debugScreenshot(page, `feature-${featureKey}-configured`);
    await clickGenerate(page, feature.name);
    await waitForGenerationResult(page, options, {
      screenshotName: `feature-${featureKey}-result`, label: feature.name, outputSubdir: 'features',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error(`Feature page error: ${error.message}`);
    await browser.close();
    return { success: false, error: error.message };
  }
}
