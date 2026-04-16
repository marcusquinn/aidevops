// higgsfield-batch-video.mjs — Batch video submission, polling, matching,
// and download operations for the Higgsfield automation suite.
// Extracted from higgsfield-video.mjs (t2127 file-complexity decomposition).

import {
  BASE_URL,
  STATE_FILE,
  ensureDir,
  safeJoin,
  sanitizePathSegment,
  curlDownload,
  runBatchJob,
  runWithConcurrency,
  initBatch,
  finalizeBatch,
  saveBatchState,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  withBrowser,
  dismissAllModals,
  clickHistoryTab,
  navigateTo,
  getDefaultOutputDir,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  buildDescriptiveFilename,
  downloadLatestResult,
} from './higgsfield-output.mjs';

// NOTE: VIDEO_MODEL_NAME_MAP, removeExistingStartFrame, tryUploadViaButton,
// tryUploadViaStartFrameArea, and findModelButtonInDropdown are currently
// internal to higgsfield-video.mjs and need to be exported from there for
// this import to work.
import {
  VIDEO_MODEL_NAME_MAP,
  removeExistingStartFrame,
  tryUploadViaButton,
  tryUploadViaStartFrameArea,
  findModelButtonInDropdown,
  downloadVideoFromHistory,
} from './higgsfield-video.mjs';

import { generateLipsync } from './higgsfield-lipsync.mjs';

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
