// higgsfield-video-download.mjs — Video download helpers (API interception, CDN fallback,
// project API polling) for the Higgsfield automation suite.
// Extracted from higgsfield-video.mjs (t2127 file-complexity decomposition).


import {
  clickHistoryTab,
  debugScreenshot,
  dismissAllModals,
} from './higgsfield-browser.mjs';
import {
  curlDownload,
  ensureDir,
  safeJoin,
  sanitizePathSegment,
} from './higgsfield-common.mjs';

import {
  buildDescriptiveFilename,
  finalizeDownload,
} from './higgsfield-output.mjs';
import {
  fetchProjectApiWithPolling,
} from './higgsfield-video-history.mjs';
export { evaluateNewestJobStatus, fetchProjectApiWithPolling } from './higgsfield-video-history.mjs';

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
  const shortName = redactMediaUrl(videoUrl).split('/').pop();
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
        strategy: 'api-interception', cloudFrontUrl: redactMediaUrl(videoUrl),
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

const PRESET_THUMBNAIL_HOST = 'cdn.higgsfield.ai';

/** Strip query/fragment so signed media URLs are never logged or stored. */
export function redactMediaUrl(url) {
  return String(url || '').split(/[?#]/)[0];
}

/**
 * Choose the generated output among a history card's <video> elements.
 * Every card also holds a portrait "General" preset thumbnail on
 * cdn.higgsfield.ai; the output is the CloudFront MP4 loaded after "Play video".
 * Prefers an exact width/height match, then the largest loaded CloudFront video.
 */
export function pickOutputVideo(candidates, target = { width: 1280, height: 720 }) {
  const usable = (candidates || []).filter(c => (c?.src || '').startsWith('https://')
    && !c.src.startsWith(`https://${PRESET_THUMBNAIL_HOST}/`));
  const area = c => c.width * c.height;
  const ranked = [...usable].sort((a, b) =>
    (b.src.includes('cloudfront.net') - a.src.includes('cloudfront.net')) || (area(b) - area(a)));
  const exact = ranked.find(c => c.width === target.width && c.height === target.height);
  return exact || ranked[0] || null;
}

async function loadCardOutputVideo(page) {
  const play = page.locator('main li').first().getByRole('button', { name: /Play video/i });
  await play.first().click({ force: true, timeout: 3000 }).catch(() => {});
  const cardVideos = () => [...document.querySelectorAll('main li:first-child video')].map(v => ({
    src: v.currentSrc || v.src, width: v.videoWidth, height: v.videoHeight,
  }));
  await page.waitForFunction(
    `(${cardVideos})().some(c => c.src.includes('cloudfront.net') && c.width > 0)`,
    null, { timeout: 15000 },
  ).catch(() => {});
  return page.evaluate(cardVideos);
}

async function downloadVideoViaCdnFallback(page, outputDir, combinedMeta, options) {
  console.log('Falling back to loaded history card video (after Play video)...');
  await clickHistoryTab(page);

  const picked = pickOutputVideo(await loadCardOutputVideo(page), options.videoTarget);
  if (!picked) return null;
  console.log(`Selected card video ${picked.width}x${picked.height} (not the preset thumbnail)`);

  const filename = buildDescriptiveFilename(combinedMeta, 'higgsfield-video.mp4', 0);
  const savePath = safeJoin(outputDir, sanitizePathSegment(filename, 'video.mp4'));
  try {
    ensureDir(outputDir);
    curlDownload(picked.src, savePath);
    const result = finalizeDownload(savePath, {
      command: 'video', type: 'video', ...combinedMeta,
      strategy: 'card-video', cdnUrl: redactMediaUrl(picked.src),
      width: picked.width, height: picked.height,
    }, outputDir, options);
    if (!result.skipped) {
      console.log(`Downloaded video (card video): ${savePath}`);
    }
    return result.path;
  } catch (curlErr) {
    console.log(`Card video download failed: ${curlErr.message}`);
    return null;
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
