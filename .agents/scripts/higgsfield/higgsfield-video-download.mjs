// higgsfield-video-download.mjs — Video download helpers (API interception, CDN fallback,
// project API polling) for the Higgsfield automation suite.
// Extracted from higgsfield-video.mjs (t2127 file-complexity decomposition).

import {
  safeJoin,
  sanitizePathSegment,
  curlDownload,
  ensureDir,
} from './higgsfield-common.mjs';

import {
  dismissAllModals,
  debugScreenshot,
  clickHistoryTab,
} from './higgsfield-browser.mjs';

import {
  buildDescriptiveFilename,
  finalizeDownload,
} from './higgsfield-output.mjs';

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
