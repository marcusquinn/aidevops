// higgsfield-image.mjs — Image generation via Higgsfield web UI (Playwright).
// Handles image model selection, page interaction, generation polling, and download.
// Imported by playwright-automator.mjs.

import {
  BASE_URL,
  debugScreenshot,
  dismissAllModals,
  downloadSpecificImages,
  finalizeBatch,
  GENERATED_IMAGE_SELECTOR,
  getDefaultOutputDir,
  getUnlimitedModelForCommand,
  initBatch,
  isUnlimitedModel,
  launchBrowser,
  resolveOutputDir,
  runBatchJob,
  runWithConcurrency,
  STATE_DIR,
  STATE_FILE,
  safeJoin,
} from './higgsfield-common.mjs';

import {
  clickAndVerifyGenerate,
  waitForImageGeneration,
} from './higgsfield-image-helpers.mjs';
import { configureImageOptions } from './higgsfield-image-options.mjs';

export { clickAndVerifyGenerate, waitForImageGeneration };
export { configureImageOptions, setAspectRatio, setEnhanceToggle } from './higgsfield-image-options.mjs';

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
