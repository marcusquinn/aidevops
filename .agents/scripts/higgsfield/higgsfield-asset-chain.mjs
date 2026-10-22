// higgsfield-asset-chain.mjs — Asset chain operations for the Higgsfield automation suite.
// Chain actions (animate, inpaint, upscale, relight, etc.) on existing assets.
// Extracted from higgsfield-commands.mjs (t2127 file-complexity decomposition).

import {
  debugScreenshot,
  dismissAllModals,
  getDefaultOutputDir,
  launchBrowser,
  navigateTo,
} from './higgsfield-browser.mjs';
import {
  assetChainFallbackUpload,
  CHAIN_ACTION_MAP,
  clickAssetAction,
  clickToolActionButton,
  dismissMediaUploadAgreement,
  findAssetOnPage,
  openAssetDialog,
  waitForChainedResult,
} from './higgsfield-asset-chain-interactions.mjs';
import {
  BASE_URL,
  curlDownload,
  safeJoin,
  sanitizePathSegment,
} from './higgsfield-common.mjs';
import {
  downloadLatestResult,
  resolveOutputDir,
} from './higgsfield-output.mjs';

import { downloadVideoFromHistory } from './higgsfield-video.mjs';

// ─── Asset Chain ──────────────────────────────────────────────────────────────


async function extractLargestImageSrc(page) {
  return page.evaluate(() => {
    const imgs = [...document.querySelectorAll('main img, img')];
    let best = null;
    let bestArea = 0;
    for (const img of imgs) {
      const rect = img.getBoundingClientRect();
      const area = rect.width * rect.height;
      if (area > bestArea && rect.width > 200 && img.src?.startsWith('http')) {
        bestArea = area;
        best = img.src;
      }
    }
    if (best) {
      const cfMatch = best.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
      return cfMatch ? cfMatch[1] : best;
    }
    return null;
  });
}

async function downloadChainedImageResult(page, outputDir, action, options) {
  const downloaded = await downloadLatestResult(page, outputDir, true, options);
  const hasDownloaded = Array.isArray(downloaded) ? downloaded.length > 0 : !!downloaded;
  if (hasDownloaded) return;

  console.log('Standard download failed, trying download icon...');
  const dlIcon = page.locator('button:has(svg), a[download]').filter({ has: page.locator('svg') });

  for (let di = 0; di < Math.min(await dlIcon.count(), 5); di++) {
    const btn = dlIcon.nth(di);
    const ariaLabel = await btn.getAttribute('aria-label').catch(() => '');
    const title = await btn.getAttribute('title').catch(() => '');
    if (ariaLabel?.toLowerCase().includes('download') || title?.toLowerCase().includes('download')) {
      const [dl] = await Promise.all([
        page.waitForEvent('download', { timeout: 10000 }).catch(() => null),
        btn.click({ force: true }),
      ]);
      if (dl) {
        const savePath = safeJoin(outputDir, sanitizePathSegment(dl.suggestedFilename() || `chained-${action}-${Date.now()}.png`, 'chained-download.png'));
        await dl.saveAs(savePath);
        console.log(`Downloaded via icon: ${savePath}`);
        return;
      }
    }
  }

  console.log('Icon download failed, trying CDN extraction...');
  const imgSrc = await extractLargestImageSrc(page);
  if (imgSrc) {
    const ext = imgSrc.includes('.png') ? 'png' : 'webp';
    const savePath = safeJoin(outputDir, sanitizePathSegment(`chained-${action}-${Date.now()}.${ext}`, `chained-${ext}`));
    try {
      curlDownload(imgSrc, savePath, { timeout: 60000 });
      console.log(`Downloaded via CDN: ${savePath}`);
    } catch (curlErr) {
      console.log(`CDN download failed: ${curlErr.message}`);
    }
  }
}

export async function assetChain(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const action = options.chainAction || 'animate';
    const actionLabel = CHAIN_ACTION_MAP[action] || action;
    console.log(`Asset Chain: ${actionLabel}...`);

    const sourceUrl = options.prompt || `${BASE_URL}/asset/all`;
    await navigateTo(page, sourceUrl);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Source image');

    const { assetImg, assetCount } = await findAssetOnPage(page);
    if (assetCount === 0) {
      console.error('No assets found on page');
      await debugScreenshot(page, 'asset-chain-no-assets');
      await browser.close();
      return { success: false, error: 'No assets found' };
    }

    const targetIndex = options.assetIndex || 0;
    console.log(`Found ${assetCount} assets, clicking index ${targetIndex}...`);
    const dialogOpen = await openAssetDialog(page, assetImg.nth(targetIndex));
    await debugScreenshot(page, 'asset-chain-dialog');

    if (dialogOpen) {
      await page.evaluate(() => {
        document.querySelectorAll('.absolute.top-0.left-0.w-full').forEach(el => {
          if (el.style) el.style.pointerEvents = 'none';
        });
      });
    }

    const actionClicked = await clickAssetAction(page, actionLabel);
    if (!actionClicked) await assetChainFallbackUpload(page, action, options);

    await debugScreenshot(page, `asset-chain-${action}`);

    if (options.prompt && !options.prompt.startsWith('http')) {
      await fillPromptField(page, options.prompt);
    }

    await page.waitForTimeout(2000);
    await dismissMediaUploadAgreement(page);
    await page.waitForTimeout(1000);
    await clickToolActionButton(page);
    await page.waitForTimeout(3000);
    const dismissed = await dismissMediaUploadAgreement(page);
    if (dismissed) await page.waitForTimeout(2000);

    await waitForChainedResult(page, action, options.timeout || 300000);

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await debugScreenshot(page, `asset-chain-${action}-result`);

    if (options.wait !== false) {
      const baseOutput = options.output || getDefaultOutputDir(options);
      const outputDir = resolveOutputDir(baseOutput, options, 'chained');
      if (action === 'animate') {
        await downloadVideoFromHistory(page, outputDir, {}, options);
      } else {
        await downloadChainedImageResult(page, outputDir, action, options);
      }
    }

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Asset Chain error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}
