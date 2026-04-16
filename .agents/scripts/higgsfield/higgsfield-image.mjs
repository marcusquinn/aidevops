// higgsfield-image.mjs — Image generation via Higgsfield web UI (Playwright).
// Handles image model selection, page interaction, generation polling, and download.
// Imported by playwright-automator.mjs.

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  GENERATED_IMAGE_SELECTOR,
  getDefaultOutputDir,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  launchBrowser,
  dismissAllModals,
  debugScreenshot,
  resolveOutputDir,
  safeJoin,
  downloadSpecificImages,
  withRetry,
  runBatchJob,
  runWithConcurrency,
  initBatch,
  finalizeBatch,
} from './higgsfield-common.mjs';

import {
  clickAndVerifyGenerate,
  waitForImageGeneration,
} from './higgsfield-image-helpers.mjs';
export { clickAndVerifyGenerate, waitForImageGeneration };

// ---------------------------------------------------------------------------
// Model → URL mapping
// ---------------------------------------------------------------------------

// Map of image model slugs to their URL paths on the Higgsfield UI.
// Models with "365" unlimited subscriptions use feature pages (e.g. /nano-banana-pro)
// which have an "Unlimited" toggle switch. Standard /image/ routes cost credits.
const IMAGE_MODEL_URL_MAP = {
  'soul':           '/image/soul',
  'nano_banana':    '/image/nano_banana',
  'nano-banana':    '/image/nano_banana',
  'nano_banana_pro':'/nano-banana-pro',
  'nano-banana-pro':'/nano-banana-pro',
  'seedream':       '/image/seedream',
  'seedream-4':     '/image/seedream',
  'seedream-4.5':   '/seedream-4-5',
  'seedream-4-5':   '/seedream-4-5',
  'wan2':           '/image/wan2',
  'wan':            '/image/wan2',
  'gpt':            '/image/gpt',
  'gpt-image':      '/image/gpt',
  'kontext':        '/image/kontext',
  'flux-kontext':   '/image/kontext',
  'flux':           '/image/flux',
  'flux-pro':       '/image/flux',
};

// ---------------------------------------------------------------------------
// Model selection
// ---------------------------------------------------------------------------

function selectImageModel(options) {
  let model = options.model || 'soul';
  if (!options.model && options.preferUnlimited !== false) {
    const unlimited = getUnlimitedModelForCommand('image');
    if (unlimited) {
      model = unlimited.slug;
      console.log(`[unlimited] Auto-selected unlimited image model: ${unlimited.name} (${unlimited.slug})`);
    }
  } else if (options.model && isUnlimitedModel(options.model, 'image')) {
    console.log(`[unlimited] Model "${options.model}" is unlimited (no credit cost)`);
  }
  return model;
}

// ---------------------------------------------------------------------------
// Page interaction helpers
// ---------------------------------------------------------------------------

async function adjustBatchSize(page, targetBatch) {
  console.log(`Setting batch size: ${targetBatch}`);
  const currentBatch = await page.evaluate(() => {
    const batchMatch = document.body.innerText.match(/(\d)\/4/);
    return batchMatch ? parseInt(batchMatch[1], 10) : 4;
  });
  console.log(`Current batch size: ${currentBatch}, target: ${targetBatch}`);

  if (currentBatch === targetBatch) {
    console.log(`Batch size already at ${targetBatch}`);
    return;
  }

  const diff = targetBatch - currentBatch;
  const btnName = diff < 0 ? 'Decrement' : 'Increment';
  const btn = page.getByRole('button', { name: btnName, exact: true });
  if (await btn.count() === 0) {
    console.log(`Could not find ${btnName} button for batch size`);
    return;
  }

  for (let clicks = 0; clicks < Math.abs(diff); clicks++) {
    await btn.click({ force: true });
    await page.waitForTimeout(200);
  }
  console.log(`Clicked ${btnName} ${Math.abs(diff)} time(s) to set batch to ${targetBatch}`);

  const newBatch = await page.evaluate(() => {
    const batchMatch = document.body.innerText.match(/(\d)\/4/);
    return batchMatch ? parseInt(batchMatch[1], 10) : -1;
  });
  console.log(newBatch === targetBatch
    ? `Batch size confirmed: ${newBatch}`
    : `WARNING: Batch size may not have changed (showing ${newBatch})`);
}

export async function setAspectRatio(page, aspect) {
  console.log(`Setting aspect ratio: ${aspect}`);
  const aspectBtn = page.locator(`button:has-text("${aspect}")`);
  if (await aspectBtn.count() > 0) {
    await aspectBtn.first().click({ force: true });
    await page.waitForTimeout(300);
    console.log(`Selected aspect ratio: ${aspect}`);
    return;
  }
  const aspectSelector = page.locator('button:has-text("Aspect"), [class*="aspect"]');
  if (await aspectSelector.count() > 0) {
    await aspectSelector.first().click({ force: true });
    await page.waitForTimeout(500);
    const option = page.locator(`[role="option"]:has-text("${aspect}"), button:has-text("${aspect}")`);
    if (await option.count() > 0) {
      await option.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected aspect ratio: ${aspect}`);
    }
  }
}

export async function setEnhanceToggle(page, enhance) {
  const enhanceLabel = page.locator('label:has-text("Enhance"), button:has-text("Enhance")');
  if (await enhanceLabel.count() === 0) return;
  const isChecked = await page.evaluate(() => {
    const el = document.querySelector('label:has(input) span:has-text("Enhance")');
    const input = el?.closest('label')?.querySelector('input');
    return input?.checked || false;
  });
  if (isChecked !== enhance) {
    await enhanceLabel.first().click({ force: true });
    await page.waitForTimeout(300);
    console.log(`${enhance ? 'Enabled' : 'Disabled'} enhance`);
  }
}

export async function configureImageOptions(page, options) {
  if (options.aspect) await setAspectRatio(page, options.aspect);

  if (options.quality) {
    console.log(`Setting quality: ${options.quality}`);
    const qualityBtn = page.locator(`button:has-text("${options.quality}")`);
    if (await qualityBtn.count() > 0) {
      await qualityBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected quality: ${options.quality}`);
    }
  }

  if (options.enhance !== undefined) await setEnhanceToggle(page, options.enhance);

  if (options.batch && options.batch >= 1 && options.batch <= 4) {
    await adjustBatchSize(page, options.batch);
  }

  if (options.preset) {
    console.log(`Selecting preset: ${options.preset}`);
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

export async function fillPromptInput(page, prompt) {
  const promptInput = page.locator('textarea, [contenteditable="true"], input[placeholder*="prompt" i], input[placeholder*="describe" i], input[placeholder*="Describe" i], input[placeholder*="Upload" i]');
  const promptCount = await promptInput.count();
  console.log(`Found ${promptCount} prompt input(s)`);

  if (promptCount > 0) {
    await promptInput.first().click({ force: true });
    await page.waitForTimeout(300);
    await promptInput.first().fill('', { force: true });
    await promptInput.first().fill(prompt, { force: true });
    console.log(`Entered prompt: "${prompt}"`);
    await page.waitForTimeout(500);
    return true;
  }

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

  if (filled) {
    console.log('Entered prompt via JS fallback');
    return true;
  }
  console.error('Could not find prompt input field');
  return false;
}

export async function enableUnlimitedMode(page) {
  const unlimitedSwitch = page.getByRole('switch');
  if (await unlimitedSwitch.count() === 0) return;

  const hasUnlimitedLabel = await page.evaluate(() => document.body.innerText.includes('Unlimited'));
  if (!hasUnlimitedLabel) return;

  const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
  if (isChecked) {
    console.log('Unlimited mode already enabled (image)');
    return;
  }

  const switchParent = page.locator('button:has(switch), *:has(> switch)').first();
  if (await switchParent.count() > 0) {
    await switchParent.click({ force: true });
  } else {
    await unlimitedSwitch.click({ force: true });
  }
  await page.waitForTimeout(500);
  const nowChecked = await unlimitedSwitch.isChecked().catch(() => false);
  console.log(nowChecked ? 'Enabled Unlimited mode (image)' : 'WARNING: Could not enable Unlimited mode');
}

async function downloadNewImages(page, options, existingImageCount, generationComplete) {
  if (options.wait === false) return;

  const currentImageCount = await page.evaluate((imgSelector) =>
    document.querySelectorAll(imgSelector).length
  , GENERATED_IMAGE_SELECTOR);
  const newCount = currentImageCount - existingImageCount;
  const newImageIndices = [];
  for (let i = 0; i < newCount; i++) newImageIndices.push(i);
  console.log(`New images: ${newImageIndices.length} of ${currentImageCount} total (indices: ${newImageIndices.join(', ')})`);

  const baseOutput = options.output || getDefaultOutputDir(options);
  const outputDir = resolveOutputDir(baseOutput, options, 'images');

  if (newImageIndices.length > 0) {
    await downloadSpecificImages(page, outputDir, newImageIndices, options);
  } else if (generationComplete) {
    const batchSize = options.batch || 4;
    const downloadCount = Math.min(batchSize, currentImageCount);
    console.log(`Count-based detection missed new images. Downloading top ${downloadCount} (batch=${batchSize})...`);
    const fallbackIndices = [];
    for (let i = 0; i < downloadCount; i++) fallbackIndices.push(i);
    await downloadSpecificImages(page, outputDir, fallbackIndices, options);
  } else {
    console.log('No new images detected. Generation may still be in progress.');
    console.log('Try: node playwright-automator.mjs download');
  }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

export async function generateImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'A serene mountain landscape at golden hour, photorealistic, 8k';
    const model = selectImageModel(options);

    const modelPath = IMAGE_MODEL_URL_MAP[model] || `/image/${model}`;
    const imageUrl = `${BASE_URL}${modelPath}`;
    console.log(`Navigating to ${imageUrl}...`);
    await page.goto(imageUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await dismissAllModals(page);
    await debugScreenshot(page, 'image-page');

    await page.waitForTimeout(2000);
    await page.evaluate(() => {
      document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => {
        if (el.children.length <= 1) el.remove();
      });
    });

    const promptFilled = await fillPromptInput(page, prompt);
    if (!promptFilled) {
      await debugScreenshot(page, 'no-prompt-field', { fullPage: true });
      await browser.close();
      return null;
    }

    await configureImageOptions(page, options);
    await enableUnlimitedMode(page);

    const existingImageCount = await page.evaluate((imgSelector) =>
      document.querySelectorAll(imgSelector).length
    , GENERATED_IMAGE_SELECTOR);
    const queueBefore = await page.evaluate(() =>
      (document.body.innerText.match(/In queue/g) || []).length
    );
    console.log(`Existing images: ${existingImageCount}, queue: ${queueBefore}`);

    if (options.dryRun) {
      console.log('[DRY-RUN] Configuration complete. Skipping Generate click.');
      await debugScreenshot(page, 'dry-run-configured');
      await context.storageState({ path: STATE_FILE });
      await browser.close();
      return { success: true, dryRun: true };
    }

    await clickAndVerifyGenerate(page, queueBefore, existingImageCount);
    const generationComplete = await waitForImageGeneration(page, existingImageCount, queueBefore, options);

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await debugScreenshot(page, 'generation-result');

    await downloadNewImages(page, options, existingImageCount, generationComplete);

    console.log('Image generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: safeJoin(STATE_DIR, 'generation-result.png') };

  } catch (error) {
    console.error('Error during image generation:', error.message);
    try { await debugScreenshot(page, 'error', { fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}

// ---------------------------------------------------------------------------
// Batch image generation
// ---------------------------------------------------------------------------

export async function batchImage(options = {}) {
  const { jobs, defaults, concurrency, outputDir, completedIndices, batchState } =
    initBatch('batch-image', options, 2);

  console.log(`\n=== Batch Image Generation ===`);
  console.log(`Jobs: ${jobs.length}, Concurrency: ${concurrency}, Output: ${outputDir}`);
  console.log(`Defaults: ${JSON.stringify(defaults)}`);

  const startTime = Date.now();
  const tasks = jobs.map((job, index) => async () => {
    if (completedIndices.has(index)) {
      console.log(`[${index + 1}/${jobs.length}] Skipping (already completed)`);
      return { success: true, index, skipped: true };
    }

    const jobOptions = { ...defaults, ...job, output: outputDir };
    console.log(`\n[${index + 1}/${jobs.length}] Generating: "${(jobOptions.prompt || '').substring(0, 60)}..."`);

    return runBatchJob({
      generatorFn: generateImage,
      jobOptions,
      index,
      jobCount: jobs.length,
      batchState,
      outputDir,
      retryLabel: `batch-image-${index + 1}`,
    });
  });

  const results = await runWithConcurrency(tasks, concurrency);
  return finalizeBatch({ type: 'batch-image', batchState, results, startTime, outputDir, jobCount: jobs.length });
}
