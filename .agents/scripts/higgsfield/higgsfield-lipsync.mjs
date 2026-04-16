// higgsfield-lipsync.mjs — Lipsync generation via the Higgsfield web UI.
// Extracted from higgsfield-video.mjs (t2127 file-complexity decomposition).

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  safeJoin,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  dismissAllModals,
  debugScreenshot,
  clickGenerate,
  getDefaultOutputDir,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
} from './higgsfield-output.mjs';

import { downloadVideoFromHistory } from './higgsfield-video.mjs';

async function uploadLipsyncCharacter(page, imageFile) {
  console.log(`Uploading character image: ${imageFile}`);
  const fileInput = page.locator('input[type="file"]');
  if (await fileInput.count() > 0) {
    await fileInput.first().setInputFiles(imageFile);
    await page.waitForTimeout(3000);
    console.log('Character image uploaded');
    return true;
  }
  const uploadBtn = page.locator('button:has-text("Upload"), [class*="upload"]');
  if (await uploadBtn.count() > 0) {
    await uploadBtn.first().click({ force: true });
    await page.waitForTimeout(1000);
    const fileInput2 = page.locator('input[type="file"]');
    if (await fileInput2.count() > 0) {
      await fileInput2.first().setInputFiles(imageFile);
      await page.waitForTimeout(3000);
      console.log('Character image uploaded (after clicking upload button)');
      return true;
    }
  }
  return false;
}

async function pollLipsyncHistory(page, historyTab, existingHistoryCount, options) {
  const timeout = options.timeout || 600000;
  console.log(`Waiting up to ${timeout / 1000}s for lipsync generation...`);
  const startTime = Date.now();

  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(1000);
  }

  const pollInterval = 10000;
  while (Date.now() - startTime < timeout) {
    await page.waitForTimeout(pollInterval);
    await dismissAllModals(page);

    const currentCount = await page.locator('main li').count();
    if (currentCount > existingHistoryCount) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      console.log(`Lipsync result detected! (${elapsed}s)`);
      return true;
    }

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    console.log(`  ${elapsed}s: waiting for lipsync result...`);
  }

  console.log('Timeout waiting for lipsync generation.');
  return false;
}

async function selectLipsyncModel(page, model) {
  if (!model) return;
  console.log(`Selecting lipsync model: ${model}`);
  const modelSelector = page.locator('button:has-text("Model"), [class*="model"]');
  if (await modelSelector.count() === 0) return;
  await modelSelector.first().click({ force: true });
  await page.waitForTimeout(1000);
  const modelOption = page.locator(`[role="option"]:has-text("${model}"), button:has-text("${model}")`);
  if (await modelOption.count() > 0) {
    await modelOption.first().click({ force: true });
    await page.waitForTimeout(500);
    console.log(`Selected model: ${model}`);
  }
}

async function fillLipsyncPrompt(page, prompt) {
  const textInput = page.locator('textarea, input[placeholder*="text" i], input[placeholder*="speak" i], input[placeholder*="say" i]');
  if (await textInput.count() === 0) return;
  await textInput.first().click({ force: true });
  await page.waitForTimeout(300);
  await textInput.first().fill(prompt, { force: true });
  console.log(`Entered text: "${prompt}"`);
}

async function recordLipsyncHistoryBaseline(page, historyTab) {
  if (await historyTab.count() === 0) return 0;
  await historyTab.click({ force: true });
  await page.waitForTimeout(1500);
  const existingHistoryCount = await page.locator('main li').count();
  console.log(`Existing History items: ${existingHistoryCount}`);
  const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:first-child');
  if (await createTab.count() > 0) {
    await createTab.first().click({ force: true });
    await page.waitForTimeout(1000);
  }
  return existingHistoryCount;
}

async function downloadLipsyncResult(page, options, prompt, generationComplete) {
  if (options.wait === false) return;
  const baseOutput = options.output || getDefaultOutputDir(options);
  const outputDir = resolveOutputDir(baseOutput, options, 'lipsync');
  const meta = { model: options.model || 'lipsync', promptSnippet: prompt.substring(0, 80) };
  const downloads = await downloadVideoFromHistory(page, outputDir, meta, options);
  if (downloads.length > 0) {
    console.log(`Lipsync video downloaded: ${downloads.join(', ')}`);
  } else if (!generationComplete) {
    console.log('Lipsync generation timed out and no completed video found. Try: download --model video');
  }
}

async function runLipsyncPipeline(page, options, prompt) {
  await page.goto(`${BASE_URL}/lipsync-studio`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(4000);
  await dismissAllModals(page);
  await debugScreenshot(page, 'lipsync-page');

  await uploadLipsyncCharacter(page, options.imageFile);
  await selectLipsyncModel(page, options.model);
  await fillLipsyncPrompt(page, prompt);

  const historyTab = page.locator('[role="tab"]:has-text("History")');
  const existingHistoryCount = await recordLipsyncHistoryBaseline(page, historyTab);

  await clickGenerate(page, 'lipsync');
  await page.waitForTimeout(3000);
  await debugScreenshot(page, 'lipsync-generate-clicked');

  const generationComplete = await pollLipsyncHistory(page, historyTab, existingHistoryCount, options);

  await page.waitForTimeout(2000);
  await dismissAllModals(page);
  await debugScreenshot(page, 'lipsync-result');

  await downloadLipsyncResult(page, options, prompt, generationComplete);
}

export async function generateLipsync(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Hello! Welcome to our channel. Today we have something amazing to show you.';
    console.log('Navigating to Lipsync Studio...');

    if (!options.imageFile) {
      console.log('WARNING: Lipsync requires a character image (--image-file)');
      await browser.close();
      return { success: false, error: 'Character image required. Use --image-file to provide one.' };
    }

    await runLipsyncPipeline(page, options, prompt);

    console.log('Lipsync generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: safeJoin(STATE_DIR, 'lipsync-result.png') };

  } catch (error) {
    console.error('Error during lipsync generation:', error.message);
    try { await debugScreenshot(page, 'error', { fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}
