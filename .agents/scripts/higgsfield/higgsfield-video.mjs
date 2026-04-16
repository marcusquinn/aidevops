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
  sanitizePathSegment,
  curlDownload,
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
  buildDescriptiveFilename,
  finalizeDownload,
  downloadLatestResult,
} from './higgsfield-output.mjs';

import { ensureDir } from './higgsfield-common.mjs';

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
// Video download helpers
// ---------------------------------------------------------------------------

export async function extractVideoMetadata(page) {
  return page.evaluate(() => {
    const firstItem = document.querySelector('main li');
    if (!firstItem) return null;

    const textbox = firstItem.querySelector('[role="textbox"], textarea');
    const promptText = textbox?.textContent?.trim() || '';

    const actionWords = /^(cancel|rerun|retry|download|delete|remove|share|copy|edit)$/i;
    const buttons = [...firstItem.querySelectorAll('button')];
    let modelText = '';
    for (const btn of buttons) {
      const text = btn.textContent?.trim();
      const hasIcon = btn.querySelector('img, svg[class*="icon"]');
      const looksLikeModel = /kling|wan|sora|minimax|veo|flux|soul|nano|seedream|gpt|higgsfield|popcorn/i.test(text);
      const isAction = actionWords.test(text) || text.length <= 2;
      if ((hasIcon || looksLikeModel) && !isAction && text.length > 0) {
        modelText = text;
        break;
      }
    }
    if (!modelText) {
      const candidates = buttons
        .map(b => b.textContent?.trim())
        .filter(t => t && t.length > 3 && !actionWords.test(t));
      if (candidates.length > 0) {
        modelText = candidates.sort((a, b) => b.length - a.length)[0];
      }
    }

    return { promptText, modelText };
  });
}

function pickNewestCompletedCloudfrontJob(projectApiData) {
  for (const jobSet of projectApiData.job_sets) {
    for (const job of (jobSet.jobs || [])) {
      if (job.status !== 'completed' || !job.results?.raw?.url) continue;
      if (!job.results.raw.url.includes('cloudfront.net')) continue;
      return job;
    }
  }
  return null;
}

function logCloudfrontDownloadOutcome(httpCode, size, videoUrl) {
  const shortName = videoUrl.substring(videoUrl.lastIndexOf('/') + 1);
  if (httpCode === '200') {
    console.log(`CloudFront returned ${httpCode} but file too small (${size}B), skipping: ${shortName}`);
  } else {
    console.log(`CloudFront HTTP ${httpCode} for: ${shortName}`);
  }
}

function tryCloudfrontDownload(videoUrl, outputDir, combinedMeta, options) {
  const filename = buildDescriptiveFilename(combinedMeta, 'higgsfield-video.mp4', 0);
  const savePath = safeJoin(outputDir, sanitizePathSegment(filename, 'video.mp4'));
  try {
    const { httpCode, size } = curlDownload(videoUrl, savePath, { withHttpCode: true });
    if (httpCode === '200' && size > 10000) {
      const result = finalizeDownload(savePath, {
        command: 'video', type: 'video', ...combinedMeta,
        strategy: 'api-interception', cloudFrontUrl: videoUrl,
      }, outputDir, options);
      if (!result.skipped) {
        console.log(`Downloaded full-quality video (${(size / 1024 / 1024).toFixed(1)}MB, HTTP ${httpCode}): ${savePath}`);
      }
      return result.path;
    }
    logCloudfrontDownloadOutcome(httpCode, size, videoUrl);
  } catch (curlErr) {
    console.log(`CloudFront download error: ${curlErr.stderr || curlErr.message}`);
  }
  return null;
}

export function downloadVideoFromApiData(projectApiData, outputDir, combinedMeta, options) {
  const job = pickNewestCompletedCloudfrontJob(projectApiData);
  if (!job) return null;
  return tryCloudfrontDownload(job.results.raw.url, outputDir, combinedMeta, options);
}

async function downloadVideoViaCdnFallback(page, outputDir, combinedMeta, options) {
  console.log('Falling back to CDN video src (motion template quality)...');
  await clickHistoryTab(page);

  const videoSrc = await page.evaluate(() => {
    const firstItem = document.querySelector('main li');
    const video = firstItem?.querySelector('video');
    return video?.src || video?.querySelector('source')?.src || null;
  });

  if (!videoSrc) return null;

  const filename = buildDescriptiveFilename(combinedMeta, 'higgsfield-video.mp4', 0);
  const savePath = safeJoin(outputDir, sanitizePathSegment(filename, 'video.mp4'));
  try {
    curlDownload(videoSrc, savePath);
    const result = finalizeDownload(savePath, {
      command: 'video', type: 'video', ...combinedMeta,
      strategy: 'cdn-fallback', cdnUrl: videoSrc,
    }, outputDir, options);
    if (!result.skipped) {
      console.log(`Downloaded video (CDN fallback): ${savePath}`);
    }
    return result.path;
  } catch (curlErr) {
    console.log(`CDN video download failed: ${curlErr.message}`);
    return null;
  }
}

async function fetchProjectApiData(page) {
  let projectApiData = null;

  const apiHandler = async (response) => {
    const url = response.url();
    if (url.includes('fnf.higgsfield.ai/project')) {
      try { projectApiData = await response.json(); } catch {}
    }
  };
  page.on('response', apiHandler);
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(6000);
  page.off('response', apiHandler);

  if (!projectApiData) {
    try {
      projectApiData = await page.evaluate(async () => {
        const resp = await fetch('https://fnf.higgsfield.ai/project?job_set_type=image2video&limit=20&offset=0', {
          credentials: 'include',
          headers: { 'Accept': 'application/json' },
        });
        if (resp.ok) return await resp.json();
        return null;
      });
      if (projectApiData?.job_sets?.length > 0) {
        console.log(`Direct API fetch got ${projectApiData.job_sets.length} job set(s)`);
      }
    } catch (fetchErr) {
      console.log(`Direct API fetch failed: ${fetchErr.message}`);
    }
  }
  return projectApiData;
}

const PROCESSING_STATUSES = ['queued', 'processing', 'in_queue', 'pending', 'running'];

export function evaluateNewestJobStatus(projectApiData) {
  if (!projectApiData?.job_sets?.length) return { verdict: 'empty' };
  const newestJob = projectApiData.job_sets[0]?.jobs?.[0];
  const status = newestJob?.status;
  if (status === 'completed' && newestJob?.results?.raw?.url) return { verdict: 'done', newestJob };
  if (status === 'failed') return { verdict: 'failed', newestJob };
  const isProcessing = PROCESSING_STATUSES.includes(status) || !status;
  return { verdict: isProcessing ? 'processing' : 'unknown', status, newestJob };
}

export async function fetchProjectApiWithPolling(page, { shouldWait = true, maxWaitMs = 300000 } = {}) {
  const startTime = Date.now();
  let pollDelay = 10000;
  let attempt = 0;

  while (true) {
    attempt++;
    const projectApiData = await fetchProjectApiData(page);
    const jobStatus = evaluateNewestJobStatus(projectApiData);

    if (jobStatus.verdict === 'done') {
      if (attempt > 1) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
        console.log(`Video ready after ${elapsed}s of polling (${attempt} attempts)`);
      }
      return projectApiData;
    }

    if (jobStatus.verdict === 'failed') {
      console.log(`Newest video job failed: ${jobStatus.newestJob?.error || 'unknown error'}`);
      return projectApiData;
    }

    if (jobStatus.verdict === 'processing') {
      const elapsed = Date.now() - startTime;
      if (shouldWait && elapsed < maxWaitMs) {
        const elapsedSec = (elapsed / 1000).toFixed(0);
        const remainingSec = ((maxWaitMs - elapsed) / 1000).toFixed(0);
        console.log(`  Video still processing (status: ${jobStatus.status || 'unknown'}, ${elapsedSec}s elapsed, ${remainingSec}s remaining)...`);
        await page.waitForTimeout(pollDelay);
        pollDelay = Math.min(pollDelay + 5000, 30000);
        continue;
      }
      const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);
      console.log(`Video still processing after ${elapsedSec}s. Use 'download --model video' to retry later.`);
    }

    return projectApiData;
  }
}

export async function downloadVideoFromHistory(page, outputDir, metadata = {}, options = {}) {
  const downloaded = [];
  const shouldWait = options.wait !== false;
  const maxWaitMs = options.timeout || 300000;

  try {
    await clickHistoryTab(page);
    await dismissAllModals(page);

    const listCount = await page.locator('main li').count();
    console.log(`Found ${listCount} item(s) in History tab`);
    if (listCount === 0) {
      console.log('No history items found to download');
      return downloaded;
    }

    const videoInfo = await extractVideoMetadata(page);
    const combinedMeta = {
      ...metadata,
      model: videoInfo?.modelText || metadata.model,
      promptSnippet: videoInfo?.promptText?.substring(0, 80) || metadata.promptSnippet,
    };

    console.log('Extracting full-quality video URL from API data...');
    const projectApiData = await fetchProjectApiWithPolling(page, { shouldWait, maxWaitMs });

    if (projectApiData?.job_sets?.length > 0) {
      ensureDir(outputDir);
      const path = downloadVideoFromApiData(projectApiData, outputDir, combinedMeta, options);
      if (path) downloaded.push(path);
    }

    if (downloaded.length === 0) {
      console.log('API interception did not yield a video URL');
    }

    if (downloaded.length === 0) {
      const path = await downloadVideoViaCdnFallback(page, outputDir, combinedMeta, options);
      if (path) downloaded.push(path);
    }

    await debugScreenshot(page, 'video-download-result');
  } catch (error) {
    console.log(`Video download error: ${error.message}`);
  }

  return downloaded;
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
