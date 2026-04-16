// higgsfield-asset-chain.mjs — Asset chain operations for the Higgsfield automation suite.
// Chain actions (animate, inpaint, upscale, relight, etc.) on existing assets.
// Extracted from higgsfield-commands.mjs (t2127 file-complexity decomposition).

import { basename } from 'path';

import {
  launchBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
  forceCloseDialogs,
  getDefaultOutputDir,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  downloadLatestResult,
} from './higgsfield-output.mjs';

import {
  BASE_URL,
  STATE_FILE,
  GENERATED_IMAGE_SELECTOR,
  safeJoin,
  sanitizePathSegment,
  curlDownload,
} from './higgsfield-common.mjs';

import { downloadVideoFromHistory } from './higgsfield-video.mjs';

// ─── Asset Chain ──────────────────────────────────────────────────────────────

const CHAIN_ACTION_MAP = {
  animate: 'Animate', inpaint: 'Inpaint', upscale: 'Upscale', relight: 'Relight',
  angles: 'Angles', shots: 'Shots', 'ai-stylist': 'AI Stylist',
  'skin-enhancer': 'Skin Enhancer', multishot: 'Multishot',
};

const CHAIN_TOOL_URL_MAP = {
  animate: '/create/video', inpaint: '/edit?model=soul_inpaint', upscale: '/upscale',
  relight: '/app/relight', angles: '/app/angles', shots: '/app/shots',
  'ai-stylist': '/app/ai-stylist', 'skin-enhancer': '/app/skin-enhancer', multishot: '/app/shots',
};

async function findAssetOnPage(page) {
  try {
    await page.waitForSelector('main img', { timeout: 15000, state: 'visible' });
  } catch {
    console.log('No images appeared after 15s, scrolling to trigger lazy load...');
  }

  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => window.scrollBy(0, 800));
    await page.waitForTimeout(1000);
  }
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(1000);

  let assetImg = page.locator('main img');
  let assetCount = await assetImg.count();
  if (assetCount === 0) {
    assetImg = page.locator(GENERATED_IMAGE_SELECTOR);
    assetCount = await assetImg.count();
  }
  if (assetCount === 0) {
    console.log('No assets found yet, waiting for lazy load...');
    await page.waitForTimeout(5000);
    assetImg = page.locator('main img');
    assetCount = await assetImg.count();
  }

  return { assetImg, assetCount };
}

async function openAssetDialog(page, targetAsset) {
  const clickStrategies = [
    { name: 'normal click', fn: () => targetAsset.click({ timeout: 5000 }) },
    { name: 'center-click', fn: async () => {
      const box = await targetAsset.boundingBox();
      if (box) await page.mouse.click(box.x + box.width * 0.5, box.y + box.height * 0.5);
      else throw new Error('no bounding box');
    }},
    { name: 'force click', fn: () => targetAsset.click({ force: true }) },
  ];

  for (const strategy of clickStrategies) {
    try {
      await strategy.fn();
      await page.waitForTimeout(2500);
      await dismissAllModals(page);
      const isOpen = await page.locator('[role="dialog"], dialog').count() > 0;
      if (isOpen) {
        console.log(`Dialog opened via ${strategy.name}`);
        return true;
      }
    } catch {
      console.log(`${strategy.name} failed, trying next...`);
    }
  }
  return false;
}

async function clickActionFromMenu(page, actionLabel) {
  const openInBtn = page.locator('[role="dialog"], dialog').locator('button:has-text("Open in")');
  if (await openInBtn.count() === 0) return false;

  await openInBtn.first().click({ force: true });
  await page.waitForTimeout(1000);
  console.log('Opened "Open in" menu');
  await debugScreenshot(page, 'asset-chain-openin-menu');

  const actionBtn = page.locator(`[role="menuitem"]:has-text("${actionLabel}"), [role="option"]:has-text("${actionLabel}"), [data-radix-popper-content-wrapper] button:has-text("${actionLabel}"), [data-radix-popper-content-wrapper] a:has-text("${actionLabel}")`);
  if (await actionBtn.count() > 0) {
    await actionBtn.first().click({ force: true });
    await page.waitForTimeout(3000);
    console.log(`Clicked "${actionLabel}" from Open in menu`);
    return true;
  }
  return false;
}

async function clickActionFromDialog(page, actionLabel) {
  const dialog = page.locator('[role="dialog"], dialog');
  const directBtn = dialog.locator(`button:has-text("${actionLabel}"), a:has-text("${actionLabel}")`);
  if (await directBtn.count() > 0) {
    await directBtn.first().click({ force: true });
    await page.waitForTimeout(3000);
    console.log(`Clicked "${actionLabel}" inside dialog`);
    return true;
  }
  return false;
}

async function clickActionFromOverflowMenu(page, actionLabel) {
  const dialog = page.locator('[role="dialog"], dialog');
  const moreBtn = dialog.locator('button[aria-label*="more" i], button[aria-label*="menu" i], button:has(svg[class*="dots"]), button:has(svg[class*="ellipsis"])');
  for (let m = 0; m < await moreBtn.count(); m++) {
    await moreBtn.nth(m).click({ force: true });
    await page.waitForTimeout(1000);
    const menuAction = page.locator(`[role="menuitem"]:has-text("${actionLabel}"), [role="option"]:has-text("${actionLabel}")`);
    if (await menuAction.count() > 0) {
      await menuAction.first().click({ force: true });
      await page.waitForTimeout(3000);
      console.log(`Clicked "${actionLabel}" from overflow menu`);
      return true;
    }
  }
  return false;
}

async function clickAssetAction(page, actionLabel) {
  return (
    await clickActionFromMenu(page, actionLabel) ||
    await clickActionFromDialog(page, actionLabel) ||
    await clickActionFromOverflowMenu(page, actionLabel)
  );
}

async function assetChainFallbackUpload(page, action, options) {
  console.log(`"${CHAIN_ACTION_MAP[action] || action}" not found in dialog. Downloading asset and navigating to tool...`);
  await debugScreenshot(page, 'asset-chain-fallback');

  const dlOutputDir = options.output || getDefaultOutputDir(options);
  const downloadedFiles = await downloadLatestResult(page, dlOutputDir, false, options);
  const downloadedFile = Array.isArray(downloadedFiles) ? downloadedFiles[0] : downloadedFiles;

  await forceCloseDialogs(page);

  const toolUrl = CHAIN_TOOL_URL_MAP[action] || `/app/${action}`;
  console.log(`Navigating to ${toolUrl}...`);
  await navigateTo(page, toolUrl);

  if (downloadedFile) {
    const fileInput = page.locator('input[type="file"]').first();
    if (await fileInput.count() > 0) {
      await fileInput.setInputFiles(downloadedFile);
      await page.waitForTimeout(3000);
      console.log(`Uploaded asset to ${action} tool: ${basename(downloadedFile)}`);
    }
  }
}

async function dismissMediaUploadAgreement(page) {
  const agreeBtn = page.locator('button:has-text("I agree, continue")');
  if (await agreeBtn.count() > 0) {
    await agreeBtn.first().click({ force: true });
    await page.waitForTimeout(2000);
    console.log('Dismissed "Media upload agreement" modal');
    return true;
  }
  return false;
}

async function clickToolActionButton(page) {
  const actionLabels = ['Generate', 'Apply', 'Create', 'Upscale', 'Enhance', 'Start', 'Submit'];
  const actionSelector = actionLabels.map(l => `button:has-text("${l}")`).join(', ');
  const generateBtn = page.locator(actionSelector);
  if (await generateBtn.count() > 0) {
    await generateBtn.last().click({ force: true });
    console.log(`Clicked action button on target tool`);
  }
}

async function waitForChainedResult(page, action, timeout = 300000) {
  console.log(`Waiting up to ${timeout / 1000}s for chained result...`);
  const startTime = Date.now();

  while (Date.now() - startTime < timeout) {
    await page.waitForTimeout(5000);

    const hasProgress = await page.locator('progress, [role="progressbar"], .animate-spin, [class*="loading"], [class*="spinner"]').count() > 0;
    if (hasProgress) {
      console.log(`Still processing... (${Math.round((Date.now() - startTime) / 1000)}s)`);
      continue;
    }

    const hasDownload = await page.locator('button:has-text("Download"), a:has-text("Download")').count() > 0;
    const hasCompare = await page.locator('button:has-text("Compare"), [class*="compare"]').count() > 0;
    const hasNewResult = await page.locator('img[alt*="upscal"], img[alt*="result"], [data-testid*="result"]').count() > 0;

    if (hasDownload || hasCompare || hasNewResult) {
      console.log('Result ready');
      return true;
    }

    const elapsed = Date.now() - startTime;
    if (elapsed > 30000) {
      await debugScreenshot(page, `asset-chain-${action}-waiting`);
      if (await dismissMediaUploadAgreement(page)) {
        console.log('Late media upload agreement dismissed, continuing...');
        continue;
      }
      if (elapsed > 60000) {
        console.log('No progress detected after 60s, checking result...');
        return false;
      }
    }
  }
  return false;
}

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
