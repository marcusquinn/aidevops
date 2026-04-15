// higgsfield-video.mjs — Video generation, lipsync, and batch video operations
// via the Higgsfield web UI (Playwright).
// Imported by playwright-automator.mjs.

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  getDefaultOutputDir,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  launchBrowser,
  withBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
  clickHistoryTab,
  clickGenerate,
  resolveOutputDir,
  downloadLatestResult,
  buildDescriptiveFilename,
  curlDownload,
  finalizeDownload,
  ensureDir,
  safeJoin,
  sanitizePathSegment,
  withRetry,
  runBatchJob,
  runWithConcurrency,
  initBatch,
  finalizeBatch,
  saveBatchState,
} from './higgsfield-common.mjs';

// ---------------------------------------------------------------------------
// Video model mapping
// ---------------------------------------------------------------------------

const VIDEO_MODEL_NAME_MAP = {
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
// Video page interaction helpers
// ---------------------------------------------------------------------------

async function removeExistingStartFrame(page) {
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

async function tryUploadViaButton(page, imageFile) {
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

async function tryUploadViaStartFrameArea(page, imageFile) {
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

async function findModelButtonInDropdown(page, uiModelName) {
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

function evaluateHistoryState(items, prevCount, prevPrompt, ourPrompt) {
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

    const state = await page.evaluate(
      ({ prevCount, prevPrompt, ourPrompt }) => {
        const items = [...document.querySelectorAll('main li')];
        return evaluateHistoryState(items, prevCount, prevPrompt, ourPrompt);
      },
      { prevCount: existingCount, prevPrompt: existingNewestPrompt, ourPrompt: submittedPromptPrefix }
    ).catch(() => ({ currentCount: 0, isComplete: false, isProcessing: false }));

    // evaluateHistoryState runs in page context, so we inline it here
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

// ---------------------------------------------------------------------------
// Lipsync generation
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Batch video submission helpers
// ---------------------------------------------------------------------------

async function uploadJobStartFrame(page, imageFile, promptSnippet) {
  await removeExistingStartFrame(page);

  const uploaded = await tryUploadViaButton(page, imageFile) ||
    await tryUploadViaStartFrameArea(page, imageFile);

  if (!uploaded) {
    console.log(`  WARNING: Could not upload start frame for: "${promptSnippet}"`);
  }
  return uploaded;
}

async function selectJobVideoModel(page, model) {
  const uiModelName = VIDEO_MODEL_NAME_MAP[model] || model;
  const modelSelector = page.getByRole('button', { name: 'Model' });
  if (await modelSelector.count() === 0) return;

  const currentModel = await modelSelector.textContent().catch(() => '');
  if (currentModel.includes(uiModelName)) return;

  await modelSelector.click({ force: true });
  await page.waitForTimeout(1500);
  const matchingBtns = await findModelButtonInDropdown(page, uiModelName);
  if (matchingBtns.length > 0) {
    await page.mouse.click(matchingBtns[0].x + matchingBtns[0].w / 2, matchingBtns[0].y + matchingBtns[0].h / 2);
    await page.waitForTimeout(1500);
  } else {
    await page.keyboard.press('Escape');
  }
}

export async function submitVideoJobOnPage(page, sceneOptions) {
  const prompt = sceneOptions.prompt || '';
  const model = sceneOptions.model || 'kling-2.6';

  try {
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);

    if (sceneOptions.imageFile) {
      await uploadJobStartFrame(page, sceneOptions.imageFile, prompt.substring(0, 40));
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await selectJobVideoModel(page, model);

    const unlimitedSwitch = page.getByRole('switch', { name: 'Unlimited mode' });
    if (await unlimitedSwitch.count() > 0) {
      const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
      if (!isChecked) {
        await unlimitedSwitch.click({ force: true });
        await page.waitForTimeout(500);
      }
    }

    const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
    if (await promptByRole.count() > 0) {
      await promptByRole.click({ force: true });
      await page.waitForTimeout(300);
      await promptByRole.fill(prompt, { force: true });
    }

    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      await page.waitForTimeout(3000);
      console.log(`  Submitted: "${prompt.substring(0, 60)}..."`);
      return prompt.substring(0, 60);
    }

    console.log(`  Failed to submit: "${prompt.substring(0, 40)}..." (no Generate button)`);
    return null;
  } catch (err) {
    console.log(`  Submit error: ${err.message}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Batch video polling helpers
// ---------------------------------------------------------------------------

async function scrapeHistoryItems(page) {
  return page.evaluate(() => {
    const items = document.querySelectorAll('main li');
    return [...items].map((item, i) => {
      const textbox = item.querySelector('[role="textbox"], textarea');
      const promptText = textbox?.textContent?.trim()?.substring(0, 80) || '';
      const itemText = item.textContent || '';
      const isProcessing = itemText.includes('In queue') || itemText.includes('Processing') || itemText.includes('Cancel');
      return { index: i, promptText, isProcessing };
    });
  });
}

function countJobStatuses(submittedJobs, historyItems, results) {
  let completedThisPoll = 0;
  let processingCount = 0;

  for (const job of submittedJobs) {
    if (results.has(job.sceneIndex)) continue;
    const match = historyItems.find(h =>
      h.promptText.substring(0, 40).includes(job.promptPrefix.substring(0, 40)) ||
      job.promptPrefix.substring(0, 40).includes(h.promptText.substring(0, 40))
    );
    if (match && !match.isProcessing) completedThisPoll++;
    else if (match && match.isProcessing) processingCount++;
  }

  return { completedThisPoll, processingCount };
}

async function interceptVideoApiData(page) {
  let projectApiData = null;
  const apiHandler = async (response) => {
    const url = response.url();
    if (url.includes('fnf.higgsfield.ai/project') ||
        url.includes('fnf.higgsfield.ai/job') ||
        url.includes('higgsfield.ai/api/')) {
      try {
        const data = await response.json();
        if (data?.job_sets?.length > 0) projectApiData = data;
      } catch {}
    }
  };
  page.on('response', apiHandler);

  await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(4000);
  await clickHistoryTab(page, { waitMs: 4000 });

  if (!projectApiData) {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(6000);
  }
  page.off('response', apiHandler);

  if (!projectApiData) {
    console.log(`  API interception missed. Trying direct fetch...`);
    try {
      projectApiData = await page.evaluate(async () => {
        const resp = await fetch('https://fnf.higgsfield.ai/project?job_set_type=image2video&limit=20&offset=0', {
          credentials: 'include',
          headers: { 'Accept': 'application/json' },
        });
        return resp.ok ? await resp.json() : null;
      });
      if (projectApiData?.job_sets?.length > 0) {
        console.log(`  Direct fetch got ${projectApiData.job_sets.length} job set(s)`);
      }
    } catch (fetchErr) {
      console.log(`  Direct fetch failed: ${fetchErr.message}`);
    }
  }

  return projectApiData;
}

function scorePromptMatch(promptA, promptB) {
  let score = 0;
  const minLen = Math.min(promptA.length, promptB.length, 60);
  for (let c = 0; c < minLen; c++) {
    if (promptA[c] === promptB[c]) score++;
    else break;
  }
  return score;
}

function jobSetKey(jobSet) {
  return jobSet.id || jobSet.prompt;
}

function findBestPromptMatch(job, completedJobSets, matchedJobSetIds) {
  let bestMatch = null;
  let bestScore = 0;
  for (const jobSet of completedJobSets) {
    if (matchedJobSetIds.has(jobSetKey(jobSet))) continue;
    const score = scorePromptMatch(jobSet.prompt || '', job.promptPrefix || '');
    if (score >= 20 && score > bestScore) {
      bestMatch = jobSet;
      bestScore = score;
    }
  }
  return bestMatch;
}

function assignPromptMatches(submittedJobs, completedJobSets, results, matchedJobSetIds) {
  for (const job of submittedJobs) {
    if (results.has(job.sceneIndex)) continue;
    const bestMatch = findBestPromptMatch(job, completedJobSets, matchedJobSetIds);
    if (bestMatch) {
      matchedJobSetIds.add(jobSetKey(bestMatch));
      job._matchedJobSet = bestMatch;
      job._matchMethod = 'prompt';
    }
  }
}

function assignOrderFallbackMatches(submittedJobs, completedJobSets, results, matchedJobSetIds) {
  const unmatchedJobs = submittedJobs.filter(j => !results.has(j.sceneIndex) && !j._matchedJobSet);
  if (unmatchedJobs.length === 0) return;

  const unmatchedJobSets = completedJobSets.filter(js => !matchedJobSetIds.has(jobSetKey(js)));
  const reversedJobSets = [...unmatchedJobSets].reverse();

  const pairCount = Math.min(unmatchedJobs.length, reversedJobSets.length);
  for (let i = 0; i < pairCount; i++) {
    const job = unmatchedJobs[i];
    const jobSet = reversedJobSets[i];
    matchedJobSetIds.add(jobSetKey(jobSet));
    job._matchedJobSet = jobSet;
    job._matchMethod = 'order';
    console.log(`  Scene ${job.sceneIndex + 1}: order-based match (empty prompt fallback)`);
  }
}

export function matchJobSetsToSubmittedJobs(submittedJobs, completedJobSets, results) {
  const matchedJobSetIds = new Set();
  assignPromptMatches(submittedJobs, completedJobSets, results, matchedJobSetIds);
  assignOrderFallbackMatches(submittedJobs, completedJobSets, results, matchedJobSetIds);
}

function findCompletedJobWithUrl(jobSet) {
  for (const j of (jobSet.jobs || [])) {
    if (j.status === 'completed' && j.results?.raw?.url?.includes('cloudfront.net')) {
      return j;
    }
  }
  return null;
}

function downloadSingleMatchedVideo(job, bestMatch, matchMethod, outputDir, results) {
  const completedJob = findCompletedJobWithUrl(bestMatch);
  if (!completedJob) return;

  const videoUrl = completedJob.results.raw.url;
  const meta = { model: job.model, promptSnippet: job.promptPrefix };
  const filename = buildDescriptiveFilename(meta, `scene-${job.sceneIndex + 1}.mp4`, job.sceneIndex);
  const savePath = safeJoin(outputDir, sanitizePathSegment(filename, `scene-${job.sceneIndex + 1}.mp4`));

  try {
    const { httpCode, size } = curlDownload(videoUrl, savePath, { withHttpCode: true });
    if (httpCode === '200' && size > 10000) {
      console.log(`  Scene ${job.sceneIndex + 1}: downloaded (${(size / 1024 / 1024).toFixed(1)}MB) ${filename}`);
      console.log(`    Match method: ${matchMethod}, prompt: "${(bestMatch.prompt || '(empty)').substring(0, 60)}"`);
      results.set(job.sceneIndex, savePath);
    }
  } catch {
    /* download failures are reported by the poller's missing-scenes log */
  }
}

export function downloadMatchedVideos(submittedJobs, outputDir, results) {
  for (const job of submittedJobs) {
    if (results.has(job.sceneIndex)) continue;
    const bestMatch = job._matchedJobSet;
    if (!bestMatch) continue;
    const matchMethod = job._matchMethod || 'prompt';
    delete job._matchedJobSet;
    delete job._matchMethod;
    downloadSingleMatchedVideo(job, bestMatch, matchMethod, outputDir, results);
  }
}

export async function pollAndDownloadVideos(page, submittedJobs, outputDir, timeout = 600000) {
  const results = new Map();
  const startTime = Date.now();
  const pollInterval = 15000;

  console.log(`Polling for ${submittedJobs.length} video(s) (timeout: ${timeout / 1000}s)...`);
  const historyTab = await clickHistoryTab(page);

  while (Date.now() - startTime < timeout && results.size < submittedJobs.length) {
    await page.waitForTimeout(pollInterval);
    await dismissAllModals(page);

    const historyItems = await scrapeHistoryItems(page);
    const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);
    const { completedThisPoll, processingCount } = countJobStatuses(submittedJobs, historyItems, results);
    const pendingCount = submittedJobs.length - results.size;
    console.log(`  ${elapsedSec}s: ${results.size} done, ${processingCount} processing, ${pendingCount - processingCount - completedThisPoll} waiting`);

    if (completedThisPoll > 0) {
      console.log(`  ${completedThisPoll} new completion(s) detected, downloading via API...`);
      const projectApiData = await interceptVideoApiData(page);

      if (!projectApiData) {
        console.log(`  WARNING: No API data captured. API interception may need updating.`);
      }

      if (projectApiData?.job_sets?.length > 0) {
        ensureDir(outputDir);
        const completedJobSets = projectApiData.job_sets.filter(js =>
          (js.jobs || []).some(j => j.status === 'completed' && j.results?.raw?.url?.includes('cloudfront.net'))
        );
        matchJobSetsToSubmittedJobs(submittedJobs, completedJobSets, results);
        downloadMatchedVideos(submittedJobs, outputDir, results);
      }

      await clickHistoryTab(page);
    }
  }

  if (results.size < submittedJobs.length) {
    const missing = submittedJobs.filter(j => !results.has(j.sceneIndex)).map(j => j.sceneIndex + 1);
    console.log(`Timeout: ${results.size}/${submittedJobs.length} videos downloaded. Missing scenes: ${missing.join(', ')}`);
  } else {
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    console.log(`All ${results.size} videos downloaded in ${elapsed}s`);
  }

  return results;
}

// ---------------------------------------------------------------------------
// Batch video/lipsync
// ---------------------------------------------------------------------------

async function submitVideoBatch(page, batch, defaults, totalJobCount, batchState) {
  const submittedJobs = [];
  for (const { job, index } of batch) {
    const jobOptions = { ...defaults, ...job };
    const model = jobOptions.model || 'kling-2.6';

    console.log(`  Submitting [${index + 1}/${totalJobCount}]: "${(job.prompt || '').substring(0, 50)}..." (model: ${model})`);

    const promptPrefix = await submitVideoJobOnPage(page, {
      prompt: jobOptions.prompt || '',
      imageFile: jobOptions.imageFile,
      model,
      duration: String(jobOptions.duration || 5),
    });

    if (promptPrefix) {
      submittedJobs.push({ sceneIndex: index, promptPrefix, model });
    } else {
      batchState.failed.push({ index, error: 'Failed to submit job' });
    }
  }
  return submittedJobs;
}

async function pollAndRecordVideoResults({ page, submittedJobs, batch, batchState, outputDir, totalJobCount, options }) {
  if (submittedJobs.length === 0) return;
  console.log(`\n  Polling for ${submittedJobs.length} video(s)...`);
  const timeout = options.timeout || 600000;
  const videoResults = await pollAndDownloadVideos(page, submittedJobs, outputDir, timeout);

  for (const { index } of batch) {
    if (videoResults.has(index)) {
      batchState.completed.push(index);
      console.log(`  [${index + 1}/${totalJobCount}] Downloaded: ${videoResults.get(index)}`);
    } else if (!batchState.failed.some(f => f.index === index)) {
      batchState.failed.push({ index, error: 'Generation timed out or download failed' });
    }
  }
}

export async function batchVideo(options = {}) {
  const { jobs, defaults, concurrency, outputDir, completedIndices, batchState } =
    initBatch('batch-video', options, 3);

  console.log(`\n=== Batch Video Generation ===`);
  console.log(`Jobs: ${jobs.length}, Concurrency (submit batch size): ${concurrency}, Output: ${outputDir}`);

  const startTime = Date.now();

  const pendingJobs = jobs
    .map((job, index) => ({ job, index }))
    .filter(({ index }) => !completedIndices.has(index));

  if (pendingJobs.length === 0) {
    console.log('All jobs already completed!');
    return batchState;
  }

  for (let batchStart = 0; batchStart < pendingJobs.length; batchStart += concurrency) {
    const batch = pendingJobs.slice(batchStart, batchStart + concurrency);
    const batchNum = Math.floor(batchStart / concurrency) + 1;
    const totalBatches = Math.ceil(pendingJobs.length / concurrency);

    console.log(`\n--- Batch ${batchNum}/${totalBatches}: submitting ${batch.length} video job(s) ---`);

    const { browser, context, page } = await launchBrowser(options);

    try {
      const submittedJobs = await submitVideoBatch(page, batch, defaults, jobs.length, batchState);
      await pollAndRecordVideoResults({ page, submittedJobs, batch, batchState, outputDir, totalJobCount: jobs.length, options });
      saveBatchState(outputDir, batchState);
      await context.storageState({ path: STATE_FILE });
    } catch (error) {
      console.error(`Batch ${batchNum} error: ${error.message}`);
      for (const { index } of batch) {
        if (!batchState.completed.includes(index) && !batchState.failed.some(f => f.index === index)) {
          batchState.failed.push({ index, error: error.message });
        }
      }
      saveBatchState(outputDir, batchState);
    }

    try { await browser.close(); } catch {}
  }

  const results = jobs.map((_, i) => ({
    success: batchState.completed.includes(i),
    index: i,
  }));
  return finalizeBatch({ type: 'batch-video', batchState, results, startTime, outputDir, jobCount: jobs.length });
}

export async function batchLipsync(options = {}) {
  const { jobs, defaults, concurrency, outputDir, completedIndices, batchState } =
    initBatch('batch-lipsync', options, 1);

  console.log(`\n=== Batch Lipsync Generation ===`);
  console.log(`Jobs: ${jobs.length}, Concurrency: ${concurrency}, Output: ${outputDir}`);

  const startTime = Date.now();
  const tasks = jobs.map((job, index) => async () => {
    if (completedIndices.has(index)) {
      console.log(`[${index + 1}/${jobs.length}] Skipping (already completed)`);
      return { success: true, skipped: true, index };
    }

    const jobOptions = { ...options, ...defaults, ...job, output: outputDir, batchFile: undefined };

    if (!jobOptions.imageFile) {
      const msg = `Job ${index + 1} missing imageFile (character face required for lipsync)`;
      console.error(`[${index + 1}/${jobs.length}] ${msg}`);
      batchState.failed.push({ index, error: msg });
      saveBatchState(outputDir, batchState);
      return { success: false, index, error: msg };
    }

    console.log(`[${index + 1}/${jobs.length}] Generating lipsync: "${(job.prompt || '').substring(0, 60)}..."`);

    return runBatchJob({
      generatorFn: generateLipsync,
      jobOptions,
      index,
      jobCount: jobs.length,
      batchState,
      outputDir,
      retryLabel: `batch-lipsync[${index}]`,
    });
  });

  const results = await runWithConcurrency(tasks, concurrency);
  return finalizeBatch({ type: 'batch-lipsync', batchState, results, startTime, outputDir, jobCount: jobs.length });
}

// ---------------------------------------------------------------------------
// downloadFromHistory — used by CLI 'download' command
// ---------------------------------------------------------------------------

export async function downloadFromHistory(options) {
  const dlModel = options.model || 'soul';
  const isVideoDownload = dlModel === 'video' || options.duration;

  return withBrowser(options, async (page) => {
    if (isVideoDownload) {
      console.log('Navigating to video page to download from History...');
      await navigateTo(page, '/create/video', { waitMs: 5000 });
      const dlDir = resolveOutputDir(options.output || getDefaultOutputDir(options), options, 'videos');
      await downloadVideoFromHistory(page, dlDir, {}, options);
    } else {
      const count = options.count !== undefined ? options.count : 4;
      console.log(`Navigating to image/${dlModel} to download ${count === 0 ? 'all' : count} latest generation(s)...`);
      await navigateTo(page, `/image/${dlModel}`, { waitMs: 5000 });
      const dlDir = resolveOutputDir(options.output || getDefaultOutputDir(options), options, 'images');
      await downloadLatestResult(page, dlDir, count, options);
    }
  });
}
