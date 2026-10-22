// higgsfield-output.mjs — Output directory resolution, JSON sidecars, dedup,
// filename building, and image download helpers for the Higgsfield automation suite.
// Extracted from higgsfield-common.mjs (t2127 file-complexity decomposition).

import { execFileSync } from 'node:child_process';
import {
  dismissAllModals,
  forceCloseDialogs,
} from './higgsfield-browser.mjs';
import {
  GENERATED_IMAGE_SELECTOR,
  safeJoin,
} from './higgsfield-common.mjs';
import { buildDescriptiveFilename, finalizeDownload } from './higgsfield-output-metadata.mjs';

// Preserve output's public API while keeping filesystem metadata out of downloads.
export {
  resolveOutputDir,
  inferOutputType,
  writeJsonSidecar,
  computeFileHash,
  checkDuplicate,
  finalizeDownload,
  buildDescriptiveFilename,
} from './higgsfield-output-metadata.mjs';

// ---------------------------------------------------------------------------
// Image download helpers (used by image and download modules)
// ---------------------------------------------------------------------------

async function clickDownloadButton(page) {
  const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
  if (await dlBtn.count() === 0) return null;
  const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
  await dlBtn.first().click({ force: true });
  return downloadPromise;
}

export async function downloadImageViaDialog({ page, imgLocator, index, outputDir, extraMeta, options }) {
  await imgLocator.click({ force: true });
  await page.waitForTimeout(1500);

  const dialog = page.locator('dialog, [role="dialog"]');
  if (await dialog.count() === 0) return null;

  const metadata = await extractDialogMetadata(page);
  const download = await clickDownloadButton(page);

  if (!download) {
    await page.waitForTimeout(2000);
    console.log(`Download button clicked but no download event for image ${index + 1} - trying CDN fallback`);
    await forceCloseDialogs(page);
    return null;
  }

  const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${index}.png`;
  const descriptiveName = buildDescriptiveFilename(metadata, origFilename, index);
  const savePath = safeJoin(outputDir, descriptiveName);
  await download.saveAs(savePath);
  const result = finalizeDownload(savePath, {
    ...extraMeta, type: 'image', ...metadata, originalFilename: origFilename,
  }, outputDir, options);

  await forceCloseDialogs(page);
  return result.skipped ? null : result.path;
}

async function extractCdnVideoUrls(page) {
  return page.evaluate(() => {
    const videos = document.querySelectorAll('video source[src], video[src]');
    return [...videos].map(v => v.src || v.getAttribute('src')).filter(Boolean);
  });
}

export async function downloadImagesByCDN(page, indices, outputDir, extraMeta, options) {
  const downloaded = [];
  const cdnUrls = await page.evaluate(({ idxList, imgSelector }) => {
    const imgs = document.querySelectorAll(imgSelector);
    const targets = idxList != null ? idxList : [...Array(imgs.length).keys()];
    return targets.map(idx => {
      const img = imgs[idx];
      if (!img) return null;
      const cfMatch = img.src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
      return { url: cfMatch ? cfMatch[1] : img.src, idx };
    }).filter(Boolean);
  }, { idxList: indices, imgSelector: GENERATED_IMAGE_SELECTOR });

  if (indices == null) {
    const videoUrls = await extractCdnVideoUrls(page);
    for (const url of videoUrls) {
      cdnUrls.push({ url, idx: cdnUrls.length });
    }
  }

  for (const { url, idx } of cdnUrls) {
    const isVideo = url.includes('.mp4') || url.includes('video');
    const ext = isVideo ? '.mp4' : '.webp';
    const cdnMeta = { promptSnippet: 'cdn-fallback' };
    const filename = buildDescriptiveFilename(cdnMeta, `higgsfield-cdn-${Date.now()}${ext}`, downloaded.length);
    const savePath = safeJoin(outputDir, filename);
    try {
      execFileSync('curl', ['-sL', '-o', savePath, url], { timeout: 60000 });
      const result = finalizeDownload(savePath, {
        ...extraMeta, type: isVideo ? 'video' : 'image',
        cdnUrl: url, strategy: 'cdn-fallback', imageIndex: idx,
      }, outputDir, options);
      if (!result.skipped) {
        console.log(`Downloaded via CDN [${downloaded.length + 1}]: ${savePath}`);
      }
      downloaded.push(result.path);
    } catch (curlErr) {
      console.log(`CDN download failed for ${url}: ${curlErr.message}`);
    }
  }
  return downloaded;
}

async function downloadImagesViaDialog(page, generatedImgs, toDownload, outputDir, options) {
  const downloaded = [];
  for (let i = 0; i < toDownload; i++) {
    try {
      const path = await downloadImageViaDialog({
        page, imgLocator: generatedImgs.nth(i), index: i, outputDir,
        extraMeta: { command: 'download' }, options,
      });
      if (path) {
        console.log(`Downloaded [${i + 1}/${toDownload}]: ${path}`);
        downloaded.push(path);
      }
    } catch (imgErr) {
      console.log(`Error downloading image ${i + 1}: ${imgErr.message}`);
    }
  }
  return downloaded;
}

export async function downloadLatestResult(page, outputDir, count = 4, options = {}) {
  const downloaded = [];

  try {
    await dismissAllModals(page);

    const generatedImgs = page.locator(GENERATED_IMAGE_SELECTOR);
    const imgCount = await generatedImgs.count();
    console.log(`Found ${imgCount} generated image(s) on page`);

    if (imgCount > 0) {
      const toDownload = count === 0 ? imgCount : Math.min(count, imgCount);
      const dialogDownloads = await downloadImagesViaDialog(page, generatedImgs, toDownload, outputDir, options);
      downloaded.push(...dialogDownloads);
    }

    if (downloaded.length === 0) {
      console.log('Falling back to direct CDN URL extraction...');
      const cdnDownloads = await downloadImagesByCDN(page, null, outputDir, { command: 'download' }, options);
      downloaded.push(...(count === 0 ? cdnDownloads : cdnDownloads.slice(0, count)));
    }

    if (downloaded.length === 0) {
      console.log('No downloadable content found');
    } else {
      console.log(`Successfully downloaded ${downloaded.length} file(s)`);
    }

    return downloaded.length === 1 ? downloaded[0] : downloaded;

  } catch (error) {
    console.log('Download attempt failed:', error.message);
    return downloaded.length > 0 ? downloaded : null;
  }
}

export async function downloadSpecificImages(page, outputDir, indices, options = {}) {
  const downloaded = [];
  const generatedImgs = page.locator(GENERATED_IMAGE_SELECTOR);

  for (const idx of indices) {
    try {
      const path = await downloadImageViaDialog({
        page, imgLocator: generatedImgs.nth(idx), index: downloaded.length, outputDir,
        extraMeta: { command: 'image', imageIndex: idx }, options,
      });
      if (path) {
        console.log(`Downloaded [${downloaded.length + 1}/${indices.length}]: ${path}`);
        downloaded.push(path);
      }
    } catch (err) {
      console.log(`Error downloading image at index ${idx}: ${err.message}`);
    }
  }

  if (downloaded.length < indices.length) {
    console.log(`Dialog download got ${downloaded.length}/${indices.length}, trying CDN fallback for remainder...`);
    const cdnDownloads = await downloadImagesByCDN(page, indices.slice(downloaded.length), outputDir, { command: 'image' }, options);
    downloaded.push(...cdnDownloads);
  }

  console.log(`Successfully downloaded ${downloaded.length} file(s)`);
  return downloaded;
}

// ---------------------------------------------------------------------------
// Dialog metadata extraction
// ---------------------------------------------------------------------------

export async function extractDialogMetadata(page) {
  return page.evaluate(() => {
    const dialog = document.querySelector('[role="dialog"], dialog');
    if (!dialog) return {};

    const metadata = {};

    const textbox = dialog.querySelector('[role="textbox"], textarea');
    if (textbox) metadata.promptSnippet = textbox.textContent?.trim()?.substring(0, 80);

    const modelText = dialog.textContent || '';
    const modelMatch = modelText.match(/Model:\s*([^\n]+)/i) || modelText.match(/via\s+([A-Z][^\n]+)/);
    if (modelMatch) metadata.model = modelMatch[1].trim().substring(0, 40);

    return metadata;
  });
}
