// higgsfield-video.mjs — Video generation and download via the Higgsfield web UI (Playwright).
// Imported by playwright-automator.mjs.
//
// Lipsync → higgsfield-lipsync.mjs
// Batch video/lipsync → higgsfield-batch-video.mjs
// (t2127 file-complexity decomposition)

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  safeJoin,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
  clickHistoryTab,
  getDefaultOutputDir,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  downloadLatestResult,
} from './higgsfield-output.mjs';

import { downloadVideoFromHistory } from './higgsfield-video-download.mjs';
export { downloadVideoFromHistory };

export {
  extractVideoMetadata,
  downloadVideoFromApiData,
  evaluateNewestJobStatus,
  fetchProjectApiWithPolling,
} from './higgsfield-video-download.mjs';

// ---------------------------------------------------------------------------
// Video model mapping
// ---------------------------------------------------------------------------

export const VIDEO_MODEL_NAME_MAP = {
  'kling-3.0':    'Kling 3.0',
  'kling-2.6':    'Kling 2.6',
  'kling-2.5':    'Kling 2.5',
  'kling-2.1':    'Kling 2.1',
  'kling-motion': 'Kling Motion Control',
  'seedance':     'Seedance',
  'grok':         'Grok Imagine',
  'minimax':      'Minimax Hailuo',
  'wan-2.1':      'Wan 2.1',
  'sora':         'Sora',
  'veo':          'Veo',
  'veo-3':        'Veo 3',
};

function selectVideoModel(options) {
  let model = options.model || 'kling-2.6';
  if (!options.model && options.preferUnlimited !== false) {
    const unlimited = getUnlimitedModelForCommand('video');
    if (unlimited) {
      model = unlimited.slug;
      console.log(`[unlimited] Auto-selected unlimited video model: ${unlimited.name} (${unlimited.slug})`);
    }
  } else if (options.model && isUnlimitedModel(options.model, 'video')) {
    console.log(`[unlimited] Model "${options.model}" is unlimited (no credit cost)`);
  }
  return model;
}

// ---------------------------------------------------------------------------
// Video page interaction helpers (exported for batch-video.mjs)
// ---------------------------------------------------------------------------

export async function removeExistingStartFrame(page) {
  const existingFrame = page.getByRole('button', { name: 'Uploaded image' });
  if (await existingFrame.count() === 0) return;
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

export async function tryUploadViaButton(page, imageFile) {
  const uploadBtn = page.getByRole('button', { name: /Upload image/ });
  if (await uploadBtn.count() === 0) return false;
  try {
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 10000 }),
      uploadBtn.click({ force: true }),
    ]);
    await fileChooser.setFiles(imageFile);
    await page.waitForTimeout(3000);
    console.log('Start frame uploaded via Upload button');
    return true;
  } catch (uploadErr) {
    console.log(`Upload button approach failed: ${uploadErr.message}`);
    return false;
  }
}

export async function tryUploadViaStartFrameArea(page, imageFile) {
  const startFrameBtn = page.locator('text=Start frame').first();
  if (await startFrameBtn.count() === 0) return false;
  try {
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 10000 }),
      startFrameBtn.click({ force: true }),
    ]);
    await fileChooser.setFiles(imageFile);
    await page.waitForTimeout(3000);
    console.log('Start frame uploaded via Start frame area');
    return true;
  } catch (err) {
    console.log(`Start frame area click failed: ${err.message}`);
    return false;
  }
}

async function tryUploadViaFileInput(page, imageFile) {
  const fileInput = page.locator('input[type="file"]');
  if (await fileInput.count() === 0) return false;
  try {
    await fileInput.first().setInputFiles(imageFile);
    await page.waitForTimeout(3000);
    console.log('Start frame uploaded via hidden file input');
    return true;
  } catch (err) {
    console.log(`Hidden file input failed: ${err.message}`);
    return false;
  }
}

async function tryUploadViaCoordinates(page, imageFile) {
  try {
    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 5000 }),
      page.mouse.click(97, 310),
    ]);
    await fileChooser.setFiles(imageFile);
    await page.waitForTimeout(3000);
    console.log('Start frame uploaded via coordinate click');
    return true;
  } catch {
    console.log('WARNING: Could not upload start frame image (all strategies failed)');
    return false;
  }
}

export async function uploadStartFrame(page, imageFile) {
  console.log(`Uploading start frame: ${imageFile}`);
  await removeExistingStartFrame(page);
  return (
    await tryUploadViaButton(page, imageFile) ||
    await tryUploadViaStartFrameArea(page, imageFile) ||
    await tryUploadViaFileInput(page, imageFile) ||
    await tryUploadViaCoordinates(page, imageFile)
  );
}

export async function findModelButtonInDropdown(page, uiModelName) {
  const matchingBtns = await page.evaluate((modelName) => {
    return [...document.querySelectorAll('button')]
      .filter(b => b.textContent?.includes(modelName) && b.offsetParent !== null)
      .map(b => {
        const r = b.getBoundingClientRect();
        return { x: r.x, y: r.y, w: r.width, h: r.height, text: b.textContent?.trim()?.substring(0, 60) };
      })
      .filter(b => b.x < 800 && b.x > 100);
  }, uiModelName);
  return matchingBtns;
}

async function selectModelViaSearch(page, uiModelName) {
  const searchBox = page.locator('input[placeholder*="Search"]');
  if (await searchBox.count() === 0) return false;
  await searchBox.fill(uiModelName);
  await page.waitForTimeout(1000);
  const filtered = await findModelButtonInDropdown(page, uiModelName);
  if (filtered.length > 0) {
    await page.mouse.click(filtered[0].x + filtered[0].w / 2, filtered[0].y + filtered[0].h / 2);
    await page.waitForTimeout(1500);
    console.log(`Selected model via search: ${uiModelName}`);
    return true;
  }
  return false;
}

async function selectVideoModelFromDropdown(page, model) {
  const uiModelName = VIDEO_MODEL_NAME_MAP[model] || model;
  console.log(`Selecting model: ${model} (UI: "${uiModelName}")`);

  const modelSelector = page.getByRole('button', { name: 'Model' });
  if (await modelSelector.count() === 0) return;

  const currentModel = await modelSelector.textContent().catch(() => '');
  if (currentModel.includes(uiModelName)) {
    console.log(`Model already set to ${uiModelName}`);
    return;
  }

  await modelSelector.click({ force: true });
  await page.waitForTimeout(1500);

  const matchingBtns = await findModelButtonInDropdown(page, uiModelName);
  let selected = false;

  if (matchingBtns.length > 0) {
    const btn = matchingBtns[0];
    await page.mouse.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
    await page.waitForTimeout(1500);
    selected = true;
    console.log(`Selected model from dropdown: ${btn.text}`);
  }

  if (!selected) {
    selected = await selectModelViaSearch(page, uiModelName);
  }

  if (!selected) {
    await page.keyboard.press('Escape');
    console.log(`Model "${uiModelName}" not found in dropdown, using default`);
  }

  const verifyModel = page.getByRole('button', { name: 'Model' });
  if (await verifyModel.count() > 0) {
    const finalModel = await verifyModel.textContent().catch(() => '');
    console.log(`Model now set to: ${finalModel?.replace('Model', '').trim()}`);
  }
}

async function enableVideoUnlimitedMode(page) {
  const unlimitedSwitch = page.getByRole('switch', { name: 'Unlimited mode' });
  if (await unlimitedSwitch.count() === 0) {
    console.log('No Unlimited mode switch found on this page');
    return;
  }
  const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
  if (isChecked) {
    console.log('Unlimited mode already enabled');
    return;
  }
  await unlimitedSwitch.click({ force: true });
  await page.waitForTimeout(500);
  const nowChecked = await unlimitedSwitch.isChecked().catch(() => false);
  console.log(nowChecked ? 'Enabled Unlimited mode' : 'WARNING: Could not enable Unlimited mode');
}

async function fillVideoPrompt(page, prompt) {
  const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
  if (await promptByRole.count() > 0) {
    await promptByRole.click({ force: true });
    await page.waitForTimeout(300);
    await promptByRole.fill(prompt, { force: true });
    console.log(`Entered prompt via ARIA textbox: "${prompt.substring(0, 60)}..."`);
    return true;
  }
  const promptInput = page.locator('textarea, input[placeholder*="Describe" i], input[placeholder*="prompt" i]');
  if (await promptInput.count() > 0) {
    await promptInput.first().click({ force: true });
    await page.waitForTimeout(300);
    await promptInput.first().fill(prompt, { force: true });
    console.log(`Entered prompt via textarea: "${prompt.substring(0, 60)}..."`);
    return true;
  }
  const editable = page.locator('[contenteditable="true"], [role="textbox"]');
  if (await editable.count() > 0) {
    await editable.first().click({ force: true });
    await page.waitForTimeout(300);
    await page.keyboard.press('Meta+a');
    await page.keyboard.type(prompt);
    console.log(`Entered prompt via contenteditable: "${prompt.substring(0, 60)}..."`);
    return true;
  }
  console.log('WARNING: Could not find prompt input field');
  return false;
}

async function captureVideoHistoryState(page) {
  const historyTab = page.locator('[role="tab"]:has-text("History")');
  let count = 0;
  let newestPrompt = '';

  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(1500);
    count = await page.locator('main li').count();
    newestPrompt = await page.evaluate(() => {
      const firstItem = document.querySelector('main li');
      const textbox = firstItem?.querySelector('[role="textbox"], textarea');
      return textbox?.textContent?.trim()?.substring(0, 100) || '';
    });
    console.log(`Existing History items: ${count}`);
    if (newestPrompt) {
      console.log(`Existing newest prompt: "${newestPrompt.substring(0, 60)}..."`);
    }

    const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:has-text("Generate")');
    if (await createTab.count() > 0) {
      await createTab.first().click({ force: true });
      await page.waitForTimeout(1000);
    }
  }

  return { count, newestPrompt, historyTab };
}

// ---------------------------------------------------------------------------
// Video generation completion polling
// ---------------------------------------------------------------------------

export async function logVideoPollingProgress(page, state, { elapsedSec, wasProcessing, lastRefreshTime, historyTab }) {
  if (state.isProcessing) {
    console.log(`  ${elapsedSec}s: processing (${state.currentCount} items)...`);
    return { wasProcessing: true, lastRefreshTime };
  }
  if (wasProcessing && !state.matchesOurPrompt && !state.isNewItem) {
    if (Date.now() - lastRefreshTime > 30000) {
      console.log(`  ${elapsedSec}s: processing ended, refreshing History...`);
      const settingsTab = page.locator('[role="tab"]:has-text("Settings")');
      if (await settingsTab.count() > 0) {
        await settingsTab.click({ force: true });
        await page.waitForTimeout(1000);
      }
      if (await historyTab.count() > 0) {
        await historyTab.click({ force: true });
        await page.waitForTimeout(2000);
      }
      return { wasProcessing, lastRefreshTime: Date.now() };
    }
    console.log(`  ${elapsedSec}s: waiting for result (${state.currentCount} items)...`);
    return { wasProcessing, lastRefreshTime };
  }
  console.log(`  ${elapsedSec}s: waiting (${state.currentCount} items, prompt: "${state.promptText?.substring(0, 40)}...")...`);
  return { wasProcessing, lastRefreshTime };
}

export async function waitForVideoGeneration(page, historyState, prompt, options = {}) {
  const timeout = options.timeout || 600000;
  const startTime = Date.now();
  const pollInterval = 10000;
  const { count: existingCount, newestPrompt: existingNewestPrompt, historyTab } = historyState;
  const submittedPromptPrefix = prompt.substring(0, 60);

  console.log(`Waiting up to ${timeout / 1000}s for video generation...`);

  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(1000);
  }

  let lastRefreshTime = Date.now();
  let wasProcessing = false;

  while (Date.now() - startTime < timeout) {
    await page.waitForTimeout(pollInterval);
    await dismissAllModals(page);

    const rawState = await page.evaluate(({ prevCount, prevPrompt, ourPrompt }) => {
      const items = document.querySelectorAll('main li');
      const currentCount = items.length;
      const firstItem = items[0];
      if (!firstItem) return { currentCount, isComplete: false, isProcessing: false };

      const itemText = firstItem.textContent || '';
      const isProcessing = itemText.includes('In queue') || itemText.includes('Processing') || itemText.includes('Cancel');

      const textbox = firstItem.querySelector('[role="textbox"], textarea');
      const promptText = textbox?.textContent?.trim() || '';
      const promptPrefix = promptText.substring(0, 60);

      const matchesOurPrompt = ourPrompt && promptPrefix.includes(ourPrompt.substring(0, 40));
      const isNewItem = prevPrompt && promptPrefix !== prevPrompt.substring(0, 60);
      const countIncreased = currentCount > prevCount;
      const isComplete = !isProcessing && (matchesOurPrompt || isNewItem || countIncreased);

      return { currentCount, isProcessing, promptText: promptPrefix, matchesOurPrompt, isNewItem, countIncreased, isComplete };
    }, { prevCount: existingCount, prevPrompt: existingNewestPrompt, ourPrompt: submittedPromptPrefix });

    const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);

    if (rawState.isComplete) {
      const reason = rawState.matchesOurPrompt ? 'prompt match' : rawState.isNewItem ? 'new item' : 'count increase';
      console.log(`Video generation complete! (${elapsedSec}s, ${rawState.currentCount} items, ${reason}, prompt: "${rawState.promptText}...")`);
      return true;
    }

    ({ wasProcessing, lastRefreshTime } = await logVideoPollingProgress(
      page, rawState, { elapsedSec, wasProcessing, lastRefreshTime, historyTab }
    ));
  }

  console.log('Timeout waiting for video generation. The video may still be processing.');
  console.log('Check back later with: node playwright-automator.mjs download --model video');
  return false;
}

// ---------------------------------------------------------------------------
// Main entry point: generateVideo
// ---------------------------------------------------------------------------

export async function generateVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Camera slowly pans across a beautiful landscape as clouds drift overhead';
    const model = selectVideoModel(options);

    console.log('Navigating to video creation page...');
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);
    await debugScreenshot(page, 'video-page');

    if (options.imageFile) {
      await uploadStartFrame(page, options.imageFile);
    } else {
      console.log('No start frame image provided. Some models support text-to-video.');
      console.log('For best results, provide --image-file with a start frame.');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await debugScreenshot(page, 'video-after-upload');

    await selectVideoModelFromDropdown(page, model);
    await enableVideoUnlimitedMode(page);
    await fillVideoPrompt(page, prompt);

    const historyState = await captureVideoHistoryState(page);

    if (options.dryRun) {
      console.log('[DRY-RUN] Configuration complete. Skipping Generate click.');
      await debugScreenshot(page, 'dry-run-configured');
      await context.storageState({ path: STATE_FILE });
      await browser.close();
      return { success: true, dryRun: true };
    }

    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      console.log('Clicked Generate button');
    } else {
      console.log('WARNING: Generate button not found');
      await debugScreenshot(page, 'video-no-generate-btn');
    }

    await page.waitForTimeout(3000);
    await debugScreenshot(page, 'video-generate-clicked');

    const generationComplete = await waitForVideoGeneration(page, historyState, prompt, options);

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await debugScreenshot(page, 'video-result');

    if (options.wait !== false) {
      const baseOutput = options.output || getDefaultOutputDir(options);
      const outputDir = resolveOutputDir(baseOutput, options, 'videos');
      const videoMeta = { model, promptSnippet: prompt.substring(0, 80) };
      const downloads = await downloadVideoFromHistory(page, outputDir, videoMeta, options);
      if (downloads.length > 0) {
        console.log(`Video downloaded successfully: ${downloads.join(', ')}`);
      } else if (generationComplete) {
        console.log('Video appeared in History but download failed. Try manually or re-run download command.');
      } else {
        console.log('Video generation timed out and no completed video found. Try: download --model video');
      }
    }

    console.log('Video generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: safeJoin(STATE_DIR, 'video-result.png') };

  } catch (error) {
    console.error('Error during video generation:', error.message);
    try { await debugScreenshot(page, 'error', { fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}
