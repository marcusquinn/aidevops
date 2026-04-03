// higgsfield-commands.mjs — Pipeline, asset chain, misc commands, and self-tests
// for the Higgsfield automation suite.
// Imported by playwright-automator.mjs (t1485 split).

import { readFileSync, writeFileSync, existsSync, copyFileSync, unlinkSync, statSync } from 'fs';
import { join, basename, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

import {
  BASE_URL,
  STATE_FILE,
  STATE_DIR,
  ROUTES_CACHE,
  GENERATED_IMAGE_SELECTOR,
  UNLIMITED_MODELS,
  UNLIMITED_SLUGS,
  CREDITS_CACHE_FILE,
  getDefaultOutputDir,
  ensureDir,
  findNewestFile,
  findNewestFileMatching,
  curlDownload,
  getCachedCredits,
  saveCreditCache,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  estimateCreditCost,
  checkCreditGuard,
  resolveOutputDir,
  safeJoin,
  sanitizePathSegment,
  parseArgs,
  launchBrowser,
  withBrowser,
  navigateTo,
  dismissAllModals,
  debugScreenshot,
  clickHistoryTab,
  clickGenerate,
  waitForGenerationResult,
  downloadLatestResult,
  forceCloseDialogs,
} from './higgsfield-common.mjs';

import { generateImage } from './higgsfield-image.mjs';
import {
  generateVideo,
  generateLipsync,
  downloadVideoFromHistory,
  submitVideoJobOnPage,
  pollAndDownloadVideos,
} from './higgsfield-video.mjs';

import {
  apiGenerateImage,
  apiGenerateVideo,
  apiStatus,
} from './higgsfield-api.mjs';

// ─── Shared command helpers ────────────────────────────────────────────────────

async function uploadFileToPage(page, filePath, label = 'file') {
  const fileInput = page.locator('input[type="file"]').first();
  if (await fileInput.count() > 0) {
    await fileInput.setInputFiles(filePath);
    await page.waitForTimeout(2000);
    console.log(`${label} uploaded: ${basename(filePath)}`);
    return true;
  }
  return false;
}

async function uploadSecondFileToPage(page, filePath, label = 'second file') {
  const fileInputs = page.locator('input[type="file"]');
  const count = await fileInputs.count();
  if (count > 1) {
    await fileInputs.nth(1).setInputFiles(filePath);
    await page.waitForTimeout(2000);
    console.log(`${label} uploaded: ${basename(filePath)}`);
    return true;
  }
  return false;
}

async function fillPromptField(page, prompt) {
  const promptInput = page.locator('textarea').first();
  if (await promptInput.count() > 0) {
    await promptInput.fill(prompt);
    console.log('Prompt entered');
    return true;
  }
  return false;
}

async function selectButtonOption(page, value, label) {
  const btn = page.locator(`button:has-text("${value}")`);
  if (await btn.count() > 0) {
    await btn.first().click();
    await page.waitForTimeout(500);
    console.log(`${label} set to ${value}`);
    return true;
  }
  return false;
}

async function navigateAndDismiss(page, path, waitMs = 3000) {
  await page.goto(`${BASE_URL}${path}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(waitMs);
  await dismissAllModals(page);
}

async function saveStateAndClose(context, browser) {
  await context.storageState({ path: STATE_FILE });
  await browser.close();
}

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

// ─── Pipeline ─────────────────────────────────────────────────────────────────

function loadPipelineBrief(options) {
  if (options.brief) {
    if (!existsSync(options.brief)) {
      console.error(`ERROR: Brief file not found: ${options.brief}`);
      process.exit(1);
    }
    return JSON.parse(readFileSync(options.brief, 'utf-8'));
  }
  return {
    title: 'Quick Pipeline',
    character: {
      description: options.prompt || 'A friendly young person',
      image: options.characterImage || options.imageFile || null,
    },
    scenes: [{
      prompt: options.prompt || 'Character speaks to camera with warm expression',
      duration: parseInt(options.duration, 10) || 5,
      dialogue: options.dialogue || null,
    }],
    imageModel: options.model || (options.preferUnlimited !== false && getUnlimitedModelForCommand('image')?.slug) || 'soul',
    videoModel: (options.preferUnlimited !== false && getUnlimitedModelForCommand('video')?.slug) || 'kling-2.6',
    aspect: options.aspect || '9:16',
  };
}

async function pipelineCharacterImage(brief, options, outputDir, pipelineState) {
  let characterImagePath = brief.character?.image;
  if (characterImagePath) {
    console.log(`\n--- Step 1: Using provided character image: ${characterImagePath} ---`);
    pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath, provided: true });
    return characterImagePath;
  }

  console.log(`\n--- Step 1: Generate character image ---`);
  const charPrompt = brief.character?.description || 'A photorealistic portrait of a friendly young person, neutral expression, studio lighting, high quality';
  console.log(`Prompt: "${charPrompt.substring(0, 80)}..."`);

  const charResult = await generateImage({
    ...options, prompt: charPrompt, model: brief.imageModel,
    aspect: '1:1', batch: 1, output: outputDir,
  });

  if (charResult?.success) {
    characterImagePath = findNewestFile(outputDir, ['.png', '.jpg', '.webp']);
    console.log(`Character image: ${characterImagePath || 'NOT FOUND'}`);
    pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath });
  } else {
    console.log('WARNING: Character image generation failed, continuing without it');
    pipelineState.steps.push({ step: 'character-image', success: false });
  }
  return characterImagePath;
}

async function pipelineSceneImages(brief, options, outputDir, pipelineState) {
  console.log(`\n--- Step 2: Generate scene images (${brief.scenes.length} scenes) ---`);
  if (brief.imagePrompts?.length > 0) {
    console.log(`Using separate imagePrompts for start frame generation`);
  }
  const sceneImages = [];

  for (let i = 0; i < brief.scenes.length; i++) {
    const imagePrompt = brief.imagePrompts?.[i] || brief.scenes[i].prompt;
    console.log(`\nScene ${i + 1}/${brief.scenes.length}: "${imagePrompt?.substring(0, 60)}..."`);

    const sceneResult = await generateImage({
      ...options, prompt: imagePrompt, model: brief.imageModel,
      aspect: brief.aspect, batch: 1, output: outputDir,
    });

    if (sceneResult?.success) {
      const scenePath = findNewestFileMatching(outputDir, ['.png', '.jpg', '.webp'], 'hf_');
      sceneImages.push(scenePath);
      console.log(`Scene ${i + 1} image: ${scenePath || 'NOT FOUND'}`);
    } else {
      sceneImages.push(null);
      console.log(`Scene ${i + 1} image generation failed`);
    }
  }
  pipelineState.steps.push({ step: 'scene-images', count: sceneImages.filter(Boolean).length, total: brief.scenes.length });
  return sceneImages;
}

async function submitPipelineVideoJobs(brief, sceneImages, options) {
  const validScenes = brief.scenes
    .map((scene, i) => ({ scene, index: i, image: sceneImages[i] }))
    .filter(s => s.image);
  const skippedScenes = brief.scenes.length - validScenes.length;
  if (skippedScenes > 0) console.log(`Skipping ${skippedScenes} scene(s) with no image`);

  console.log(`\n--- Step 3a: Submit ${validScenes.length} video job(s) in parallel ---`);

  if (validScenes.length === 0) return [];

  const { browser: videoBrowser, context: videoCtx, page: videoPage } = await launchBrowser(options);
  const submittedJobs = [];
  try {
    for (const { scene, index, image } of validScenes) {
      console.log(`\n  Submitting scene ${index + 1}/${brief.scenes.length}...`);
      const promptPrefix = await submitVideoJobOnPage(videoPage, {
        prompt: scene.prompt, imageFile: image,
        model: brief.videoModel, duration: String(scene.duration || 5),
      });
      if (promptPrefix) {
        submittedJobs.push({ sceneIndex: index, promptPrefix, model: brief.videoModel });
      }
    }
    await videoCtx.storageState({ path: STATE_FILE });
  } catch (err) {
    console.error('Error during parallel video submission:', err.message);
  }
  try { await videoBrowser.close(); } catch {}
  return submittedJobs;
}

async function pollPipelineVideoResults(brief, submittedJobs, outputDir, options, pipelineState) {
  const sceneVideos = new Array(brief.scenes.length).fill(null);
  if (submittedJobs.length === 0) return sceneVideos;

  const { browser: pollBrowser, context: pollCtx, page: pollPage } = await launchBrowser(options);
  try {
    console.log(`\n--- Step 3b: Polling for ${submittedJobs.length} video(s) ---`);
    const videoResults = await pollAndDownloadVideos(
      pollPage, submittedJobs, outputDir, options.timeout || 600000
    );
    for (const [sceneIndex, path] of videoResults) {
      sceneVideos[sceneIndex] = path;
    }
    await pollCtx.storageState({ path: STATE_FILE });
  } catch (err) {
    console.error('Error during video polling:', err.message);
  }
  try { await pollBrowser.close(); } catch {}

  const videoCount = sceneVideos.filter(Boolean).length;
  console.log(`\nVideo generation: ${videoCount}/${brief.scenes.length} scenes completed`);
  pipelineState.steps.push({ step: 'scene-videos', count: videoCount, total: brief.scenes.length });
  return sceneVideos;
}

async function pipelineAnimateScenes(brief, sceneImages, options, outputDir, pipelineState) {
  const submittedJobs = await submitPipelineVideoJobs(brief, sceneImages, options);
  return pollPipelineVideoResults(brief, submittedJobs, outputDir, options, pipelineState);
}

async function pipelineLipsync({ brief, sceneVideos, characterImagePath, options, outputDir, pipelineState }) {
  console.log(`\n--- Step 4: Add lipsync dialogue ---`);
  const lipsyncVideos = [];
  const scenesWithDialogue = brief.scenes.filter(s => s.dialogue);

  if (scenesWithDialogue.length > 0 && characterImagePath) {
    for (let i = 0; i < brief.scenes.length; i++) {
      const scene = brief.scenes[i];
      if (!scene.dialogue) {
        lipsyncVideos.push(sceneVideos[i]);
        continue;
      }

      console.log(`\nLipsync scene ${i + 1}: "${scene.dialogue.substring(0, 60)}..."`);
      const lipsyncResult = await generateLipsync({
        ...options, prompt: scene.dialogue, imageFile: characterImagePath, output: outputDir,
      });

      if (lipsyncResult?.success) {
        const lipsyncPath = findNewestFile(outputDir, ['.mp4']);
        lipsyncVideos.push(lipsyncPath);
        console.log(`Lipsync video: ${lipsyncPath || 'NOT FOUND'}`);
      } else {
        lipsyncVideos.push(sceneVideos[i]);
        console.log(`Lipsync failed, using original video for scene ${i + 1}`);
      }
    }
  } else {
    console.log('No dialogue scenes or no character image - skipping lipsync');
    lipsyncVideos.push(...sceneVideos);
  }
  pipelineState.steps.push({ step: 'lipsync', count: lipsyncVideos.filter(Boolean).length });
  return lipsyncVideos;
}

function runFfmpegConcat(concatList, finalPath) {
  const baseArgs = ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c', 'copy', finalPath];
  const reencodeArgs = ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c:v', 'libx264', '-c:a', 'aac', '-movflags', '+faststart', finalPath];
  try {
    execFileSync('ffmpeg', baseArgs, { timeout: 120000, stdio: 'pipe' });
    return { success: true, method: 'copy' };
  } catch {
    try {
      execFileSync('ffmpeg', reencodeArgs, { timeout: 300000, stdio: 'pipe' });
      return { success: true, method: 'reencode' };
    } catch (reencodeErr) {
      return { success: false, error: reencodeErr.message };
    }
  }
}

function addMusicToVideo(finalPath, musicPath) {
  const withMusicPath = finalPath.replace('-final.mp4', '-final-music.mp4');
  try {
    execFileSync('ffmpeg', ['-y', '-i', finalPath, '-i', musicPath, '-c:v', 'copy', '-c:a', 'aac', '-map', '0:v:0', '-map', '1:a:0', '-shortest', withMusicPath], {
      timeout: 120000, stdio: 'pipe',
    });
    console.log(`Final video with music: ${withMusicPath}`);
  } catch (musicErr) {
    console.log(`Adding music failed: ${musicErr.message}`);
  }
}

function assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState) {
  if (validVideos.length === 1) {
    copyFileSync(validVideos[0], finalPath);
    console.log(`Final video (single scene, ffmpeg copy): ${finalPath}`);
  } else {
    const concatList = safeJoin(outputDir, 'concat-list.txt');
    writeFileSync(concatList, validVideos.map(v => `file '${v}'`).join('\n'));

    const result = runFfmpegConcat(concatList, finalPath);
    if (!result.success) {
      console.log(`ffmpeg assembly failed: ${result.error}`);
      console.log(`Individual scene videos are in: ${outputDir}`);
      pipelineState.steps.push({ step: 'assembly', success: false, method: 'ffmpeg', reason: result.error });
      return;
    }
    console.log(`Final video (ffmpeg ${result.method}, ${validVideos.length} scenes): ${finalPath}`);
  }

  if (brief.music && existsSync(brief.music) && existsSync(finalPath)) {
    addMusicToVideo(finalPath, brief.music);
  }

  pipelineState.steps.push({ step: 'assembly', success: true, method: 'ffmpeg', path: finalPath });
}

function assembleWithRemotion({ validVideos, finalPath, brief, remotionDir, outputDir, pipelineState }) {
  console.log(`Using Remotion for assembly (${validVideos.length} scenes, ${brief.captions?.length || 0} captions)`);

  const publicDir = safeJoin(remotionDir, 'public');
  ensureDir(publicDir);
  const staticVideoNames = [];
  for (let i = 0; i < validVideos.length; i++) {
    const staticName = `scene-${i}.mp4`;
    const destPath = safeJoin(publicDir, sanitizePathSegment(staticName, `scene-${i}.mp4`));
    try { if (existsSync(destPath)) { unlinkSync(destPath); } } catch { /* ignore */ }
    copyFileSync(validVideos[i], destPath);
    staticVideoNames.push(staticName);
  }

  const remotionProps = {
    title: brief.title || 'Untitled', scenes: brief.scenes || [],
    aspect: brief.aspect || '9:16', captions: brief.captions || [],
    sceneVideos: staticVideoNames, transitionStyle: brief.transitionStyle || 'fade',
    transitionDuration: brief.transitionDuration || 15,
    musicPath: brief.music && existsSync(brief.music) ? brief.music : undefined,
  };

  const propsFile = safeJoin(outputDir, 'remotion-props.json');
  writeFileSync(propsFile, JSON.stringify(remotionProps));

  const remotionArgs = [
    'remotion', 'render', 'src/index.ts', 'FullVideo', finalPath,
    `--props=${propsFile}`, '--codec=h264', '--log=warn',
  ];

  try {
    execFileSync('npx', remotionArgs, { cwd: remotionDir, stdio: 'inherit', timeout: 600000 });
    console.log(`Final video (Remotion, ${validVideos.length} scenes + captions): ${finalPath}`);
    pipelineState.steps.push({ step: 'assembly', success: true, method: 'remotion', path: finalPath });
  } catch (remotionErr) {
    console.log(`Remotion render failed: ${remotionErr.message}`);
    console.log('Falling back to ffmpeg concat...');
    assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
  }
}

function pipelineAssemble(brief, validVideos, outputDir, pipelineState) {
  console.log(`\n--- Step 5: Assemble final video ---`);

  if (validVideos.length === 0) {
    console.log('No valid video clips to assemble');
    pipelineState.steps.push({ step: 'assembly', success: false, reason: 'no valid clips' });
    return;
  }

  const finalPath = safeJoin(outputDir, sanitizePathSegment(`${brief.title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-final.mp4`, 'pipeline-final.mp4'));
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const remotionDir = safeJoin(__dirname, 'remotion');
  const remotionInstalled = existsSync(safeJoin(remotionDir, 'node_modules', 'remotion'));
  const hasCaptions = brief.captions && brief.captions.length > 0;

  if (remotionInstalled && (hasCaptions || validVideos.length > 1)) {
    assembleWithRemotion({ validVideos, finalPath, brief, remotionDir, outputDir, pipelineState });
  } else if (validVideos.length === 1 && !hasCaptions) {
    copyFileSync(validVideos[0], finalPath);
    console.log(`Final video (single scene): ${finalPath}`);
    pipelineState.steps.push({ step: 'assembly', success: true, method: 'copy', path: finalPath });
  } else {
    if (!remotionInstalled) {
      console.log('Remotion not installed - using ffmpeg concat (no captions/transitions)');
      console.log(`Install with: cd ${remotionDir} && npm install`);
    }
    assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
  }
}

export async function pipeline(options = {}) {
  const brief = loadPipelineBrief(options);
  const outputDir = options.output || safeJoin(getDefaultOutputDir(options), `pipeline-${Date.now()}`);
  ensureDir(outputDir);

  console.log(`\n=== Video Production Pipeline ===`);
  console.log(`Title: ${brief.title}`);
  console.log(`Scenes: ${brief.scenes.length}`);
  console.log(`Image model: ${brief.imageModel}`);
  console.log(`Video model: ${brief.videoModel}`);
  console.log(`Aspect: ${brief.aspect}`);
  console.log(`Output: ${outputDir}`);

  const pipelineState = { brief, outputDir, steps: [], startTime: Date.now() };

  const characterImagePath = await pipelineCharacterImage(brief, options, outputDir, pipelineState);
  const sceneImages = await pipelineSceneImages(brief, options, outputDir, pipelineState);
  const sceneVideos = await pipelineAnimateScenes(brief, sceneImages, options, outputDir, pipelineState);
  const lipsyncVideos = await pipelineLipsync({ brief, sceneVideos, characterImagePath, options, outputDir, pipelineState });
  pipelineAssemble(brief, lipsyncVideos.filter(Boolean), outputDir, pipelineState);

  const elapsed = ((Date.now() - pipelineState.startTime) / 1000).toFixed(0);
  pipelineState.elapsed = `${elapsed}s`;
  writeFileSync(safeJoin(outputDir, 'pipeline-state.json'), JSON.stringify(pipelineState, null, 2));

  console.log(`\n=== Pipeline Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Output: ${outputDir}`);
  console.log(`Steps: ${pipelineState.steps.map(s => `${s.step}:${s.success !== false ? 'OK' : 'FAIL'}`).join(' -> ')}`);

  return pipelineState;
}

// ─── Misc Commands ────────────────────────────────────────────────────────────

export async function useApp(options = {}) {
  return withBrowser(options, async (page) => {
    const appSlug = options.effect || 'face-swap';
    console.log(`Navigating to app: ${appSlug}...`);
    await navigateTo(page, `/app/${appSlug}`);
    await debugScreenshot(page, `app-${appSlug}`);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply"), button[type="submit"]:visible');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked generate/apply button');
    }

    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for result...`);
    try {
      await page.waitForSelector(`${GENERATED_IMAGE_SELECTOR}, video`, { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for app result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await debugScreenshot(page, `app-${appSlug}-result`);

    if (options.wait !== false) {
      const baseOutput = options.output || getDefaultOutputDir(options);
      const outputDir = resolveOutputDir(baseOutput, options, 'apps');
      await downloadLatestResult(page, outputDir, true, options);
    }

    return { success: true };
  }).catch(error => {
    console.error('Error using app:', error.message);
    return { success: false, error: error.message };
  });
}

export async function screenshot(options = {}) {
  return withBrowser(options, async (page) => {
    const url = options.prompt || `${BASE_URL}/asset/all`;
    console.log(`Navigating to ${url}...`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    const outputPath = options.output || safeJoin(STATE_DIR, 'screenshot.png');
    await page.screenshot({ path: outputPath, fullPage: false });
    console.log(`Screenshot saved to: ${outputPath}`);

    const ariaSnapshot = await page.locator('body').ariaSnapshot();
    console.log('\n--- ARIA Snapshot ---');
    console.log(ariaSnapshot.substring(0, 3000));

    return { success: true, path: outputPath };
  }).catch(error => {
    console.error('Screenshot error:', error.message);
    return { success: false, error: error.message };
  });
}

async function scrapeSubscriptionCredits(page) {
  const rowsPerPageSelect = page.locator('select');
  if (await rowsPerPageSelect.count() > 0) {
    await rowsPerPageSelect.selectOption('50');
    await page.waitForTimeout(2000);
    console.log('Set rows per page to 50 to show all models');
  }

  return page.evaluate(() => {
    const text = document.body.innerText;

    const creditMatch = text.match(/([\d\s,]+)\/([\d\s,]+)/);
    const remaining = creditMatch ? creditMatch[1].trim().replace(/[\s,]/g, '') : 'unknown';
    const total = creditMatch ? creditMatch[2].trim().replace(/[\s,]/g, '') : 'unknown';

    const planMatch = text.match(/(Creator|Team|Enterprise|Free)\s*Plan/i);
    const plan = planMatch ? planMatch[1] : 'unknown';

    const rows = document.querySelectorAll('table tbody tr');
    const unlimitedModels = [];
    for (const row of rows) {
      const cells = [...row.querySelectorAll('td')];
      if (cells.length >= 4 && cells[3]?.textContent?.trim() === 'Active') {
        unlimitedModels.push({
          model: cells[0]?.textContent?.trim(),
          starts: cells[1]?.textContent?.trim(),
          expires: cells[2]?.textContent?.trim(),
        });
      }
    }

    const pageInfo = text.match(/Page (\d+) of (\d+)/);
    const currentPage = pageInfo ? parseInt(pageInfo[1], 10) : 1;
    const totalPages = pageInfo ? parseInt(pageInfo[2], 10) : 1;

    return { remaining, total, plan, unlimitedModels, currentPage, totalPages };
  });
}

export async function checkCredits(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Checking account credits...');
    await page.goto(`${BASE_URL}/me/settings/subscription`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(2000);

    const creditInfo = await scrapeSubscriptionCredits(page);

    console.log(`Plan: ${creditInfo.plan}`);
    console.log(`Credits: ${creditInfo.remaining} / ${creditInfo.total}`);
    console.log(`\nUnlimited models (${creditInfo.unlimitedModels.length}):`);
    creditInfo.unlimitedModels.forEach(m => {
      console.log(`  ${m.model} (expires: ${m.expires})`);
    });

    if (creditInfo.totalPages > 1) {
      console.log(`\nWARNING: Still showing page ${creditInfo.currentPage} of ${creditInfo.totalPages} - some models may be missing`);
    }

    saveCreditCache(creditInfo);

    await debugScreenshot(page, 'subscription', { fullPage: true });
    await saveStateAndClose(context, browser);
    return creditInfo;

  } catch (error) {
    console.error('Error checking credits:', error.message);
    await browser.close();
    return null;
  }
}

export async function listAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to assets page...');
    await page.goto(`${BASE_URL}/asset/all`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await debugScreenshot(page, 'assets-page');

    const assets = await page.evaluate(() => {
      const items = document.querySelectorAll('[class*="asset"], [class*="generation"], [class*="card"], [class*="grid"] > div');
      return Array.from(items).slice(0, 20).map((item, index) => {
        const img = item.querySelector('img');
        const video = item.querySelector('video');
        const link = item.querySelector('a');
        return {
          index,
          type: video ? 'video' : img ? 'image' : 'unknown',
          src: video?.src || img?.src || null,
          href: link?.href || null,
          text: item.textContent?.trim().substring(0, 100) || '',
        };
      });
    });

    console.log(`Found ${assets.length} assets:`);
    assets.forEach(a => {
      console.log(`  [${a.index}] ${a.type}: ${a.text || a.src || 'no info'}`);
    });

    await saveStateAndClose(context, browser);
    return assets;

  } catch (error) {
    console.error('Error listing assets:', error.message);
    await browser.close();
    return [];
  }
}

export async function seedBracket(options = {}) {
  const prompt = options.prompt;
  if (!prompt) {
    console.error('ERROR: --prompt is required for seed bracketing');
    process.exit(1);
  }

  let seeds = [];
  const range = options.seedRange || '1000-1010';
  if (range.includes('-')) {
    const [start, end] = range.split('-').map(Number);
    for (let s = start; s <= end; s++) seeds.push(s);
  } else {
    seeds = range.split(',').map(Number);
  }

  console.log(`Seed bracketing: testing ${seeds.length} seeds with prompt: "${prompt.substring(0, 60)}..."`);
  console.log(`Seeds: ${seeds.join(', ')}`);

  const model = options.model || (options.preferUnlimited !== false && getUnlimitedModelForCommand('image')?.slug) || 'soul';
  const outputDir = ensureDir(options.output || safeJoin(getDefaultOutputDir(options), `seed-bracket-${Date.now()}`));

  const results = [];

  for (const seed of seeds) {
    console.log(`\n--- Testing seed ${seed} ---`);
    const result = await generateImage({
      ...options,
      prompt: `${prompt} --seed ${seed}`,
      output: outputDir,
      batch: 1,
    });
    results.push({ seed, ...result });
    console.log(`Seed ${seed}: ${result?.success ? 'OK' : 'FAILED'}`);
  }

  console.log(`\n=== Seed Bracket Results ===`);
  console.log(`Prompt: "${prompt}"`);
  console.log(`Model: ${model}`);
  console.log(`Output: ${outputDir}`);
  console.log(`Results: ${results.filter(r => r.success).length}/${results.length} successful`);
  console.log(`\nReview the images in ${outputDir} and note the best seeds.`);
  console.log(`Then use --seed <number> with your chosen seed for consistent results.`);

  const manifest = {
    prompt, model,
    seeds: results.map(r => ({ seed: r.seed, success: r.success })),
    timestamp: new Date().toISOString(),
  };
  const bracketPath = safeJoin(outputDir, 'bracket-results.json');
  writeFileSync(bracketPath, JSON.stringify(manifest, null, 2));
  console.log(`Results saved to ${bracketPath}`);

  return results;
}

export async function cinemaStudio(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Cinema Studio...');
    await navigateAndDismiss(page, '/cinema-studio');

    const tabName = options.duration ? 'Video' : (options.tab || 'Image');
    const tab = page.locator(`[role="tab"]:has-text("${tabName}")`);
    if (await tab.count() > 0) {
      await tab.click();
      await page.waitForTimeout(1000);
      console.log(`Selected ${tabName} tab`);
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.prompt) await fillPromptField(page, options.prompt);
    if (options.quality) await selectButtonOption(page, options.quality, 'Quality');
    if (options.aspect) await selectButtonOption(page, options.aspect, 'Aspect');

    await debugScreenshot(page, 'cinema-studio-configured');
    await clickGenerate(page, 'Cinema Studio');
    await waitForGenerationResult(page, options, {
      screenshotName: 'cinema-studio-result', label: 'Cinema Studio', outputSubdir: 'cinema',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Cinema Studio error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function motionControl(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Motion Control...');
    await navigateAndDismiss(page, '/create/motion-control');

    if (options.videoFile || options.motionRef) {
      await uploadFileToPage(page, options.videoFile || options.motionRef, 'Motion reference');
    }
    if (options.imageFile) await uploadSecondFileToPage(page, options.imageFile, 'Character image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    if (options.unlimited) {
      const unlimitedToggle = page.locator('text=Unlimited mode').locator('..').locator('[role="switch"], input[type="checkbox"]');
      if (await unlimitedToggle.count() > 0) {
        const isChecked = await unlimitedToggle.getAttribute('aria-checked') === 'true' || await unlimitedToggle.isChecked().catch(() => false);
        if (!isChecked) {
          await unlimitedToggle.click();
          await page.waitForTimeout(500);
          console.log('Unlimited mode enabled');
        }
      }
    }

    await debugScreenshot(page, 'motion-control-configured');
    await clickGenerate(page, 'Motion Control');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'motion-control-result', label: 'Motion Control',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true, useHistoryPoll: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Motion Control error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function editImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const model = options.model || 'soul_inpaint';
    console.log(`Navigating to Edit (${model})...`);
    await navigateAndDismiss(page, `/edit?model=${model}`);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image for editing');
    if (options.imageFile2) await uploadSecondFileToPage(page, options.imageFile2, 'Second image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, `edit-${model}-configured`);
    await clickGenerate(page, 'edit');
    await waitForGenerationResult(page, options, {
      selector: GENERATED_IMAGE_SELECTOR, screenshotName: `edit-${model}-result`,
      label: 'edit', outputSubdir: 'edits', defaultTimeout: 120000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function upscale(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Upscale...');
    await navigateAndDismiss(page, '/upscale');

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media for upscaling');

    await debugScreenshot(page, 'upscale-configured');

    const upscaleBtn = page.locator('button:has-text("Upscale"), button:has-text("Generate"), button:has-text("Enhance")');
    if (await upscaleBtn.count() > 0) {
      await upscaleBtn.first().click();
      console.log('Clicked Upscale');
    }

    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, a[download]`, screenshotName: 'upscale-result',
      label: 'upscale', outputSubdir: 'upscaled',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Upscale error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

async function downloadAssetAtIndex(page, index, options) {
  const assetImg = page.locator('main img').nth(index);
  if (!await assetImg.isVisible({ timeout: 3000 }).catch(() => false)) return;
  await assetImg.click();
  await page.waitForTimeout(2500);
  await debugScreenshot(page, 'asset-detail');
  const baseOutput = options.output || getDefaultOutputDir(options);
  const dlDir = resolveOutputDir(baseOutput, options, 'misc');
  await downloadLatestResult(page, dlDir, false, options);
}

export async function manageAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const action = options.assetAction || 'list';
    console.log(`Asset Library: ${action}...`);
    await navigateAndDismiss(page, '/asset/all');

    const filter = options.filter || options.assetType;
    if (filter) {
      const filterMap = { image: 'Image', video: 'Video', lipsync: 'Lipsync', upscaled: 'Upscaled', liked: 'Liked' };
      const filterLabel = filterMap[filter.toLowerCase()] || filter;
      const filterBtn = page.locator(`button:has-text("${filterLabel}")`).last();
      if (await filterBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
        await filterBtn.click();
        await page.waitForTimeout(2000);
        console.log(`Filter applied: ${filterLabel}`);
      }
    }

    for (let i = 0; i < 3; i++) {
      await page.evaluate(() => window.scrollBy(0, 800));
      await page.waitForTimeout(1000);
    }

    const assetCount = await page.evaluate(() => document.querySelectorAll('main img').length);
    console.log(`Assets loaded: ${assetCount}`);

    if (action === 'list') {
      await debugScreenshot(page, 'asset-library');
      console.log(`Asset library screenshot saved. ${assetCount} assets visible.`);
      await saveStateAndClose(context, browser);
      return { success: true, count: assetCount };
    }

    if (action === 'download' || action === 'download-latest') {
      await downloadAssetAtIndex(page, options.assetIndex || 0, options);
      console.log('Asset downloaded');
    }

    if (action === 'download-all') {
      const maxDownloads = options.limit || 10;
      const baseOutput = options.output || getDefaultOutputDir(options);
      const dlDir = resolveOutputDir(baseOutput, options, 'misc');
      console.log(`Downloading up to ${maxDownloads} assets...`);

      for (let i = 0; i < Math.min(maxDownloads, assetCount); i++) {
        const assetImg = page.locator('main img').nth(i);
        if (await assetImg.isVisible({ timeout: 2000 }).catch(() => false)) {
          await assetImg.click();
          await page.waitForTimeout(2000);
          await downloadLatestResult(page, dlDir, false, options);
          await page.keyboard.press('Escape');
          await page.waitForTimeout(500);
          console.log(`Downloaded asset ${i + 1}/${maxDownloads}`);
        }
      }
    }

    await saveStateAndClose(context, browser);
    return { success: true, count: assetCount };
  } catch (error) {
    console.error('Asset Library error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

function resolvePresetUrl(presetName, presets) {
  const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
  let presetUrl = presets[presetKey];
  if (!presetUrl) {
    const match = Object.keys(presets).find(k => k.includes(presetKey) || presetKey.includes(k));
    if (match) {
      presetUrl = presets[match];
      console.log(`Fuzzy matched preset: ${presetName} → ${match}`);
    }
  }
  return presetUrl;
}

export async function mixedMediaPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset || 'sketch';

    const routesPath = join(dirname(fileURLToPath(import.meta.url)), 'routes.json');
    const routes = JSON.parse(readFileSync(routesPath, 'utf-8'));
    const presets = routes.mixed_media_presets || {};

    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
    const presetUrl = resolvePresetUrl(presetName, presets);

    if (!presetUrl) {
      console.log(`Available presets: ${Object.keys(presets).join(', ')}`);
      await browser.close();
      return { success: false, error: `Unknown preset: ${presetName}` };
    }

    console.log(`Navigating to Mixed Media preset: ${presetName}...`);
    await navigateAndDismiss(page, presetUrl);

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, `mixed-media-${presetKey}-configured`);
    await clickGenerate(page, 'mixed media preset');
    await waitForGenerationResult(page, options, {
      screenshotName: `mixed-media-${presetKey}-result`, label: 'mixed media', outputSubdir: 'mixed-media',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Mixed Media Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

function listMotionPresets() {
  if (!existsSync(ROUTES_CACHE)) {
    console.log('No discovery cache found. Run "discover" first.');
    return;
  }
  const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
  const motions = cache.motions || {};
  const names = Object.keys(motions);
  console.log(`Available motion presets (${names.length}):`);
  names.slice(0, 50).forEach(n => console.log(`  ${n} → ${motions[n]}`));
  if (names.length > 50) console.log(`  ... and ${names.length - 50} more`);
}

function resolveMotionPresetUrl(presetName) {
  let presetUrl = null;

  if (existsSync(ROUTES_CACHE)) {
    const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
    const motions = cache.motions || {};
    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');

    presetUrl = motions[presetKey];
    if (!presetUrl) {
      const match = Object.keys(motions).find(k =>
        k.includes(presetKey) || presetKey.includes(k) ||
        k.toLowerCase().includes(presetName.toLowerCase())
      );
      if (match) {
        presetUrl = motions[match];
        console.log(`Fuzzy matched: ${presetName} → ${match}`);
      }
    }
  }

  if (!presetUrl && presetName.includes('/')) {
    presetUrl = presetName.startsWith('/') ? presetName : `/motion/${presetName}`;
  }
  if (!presetUrl && presetName.match(/^[0-9a-f-]{36}$/i)) {
    presetUrl = `/motion/${presetName}`;
  }

  return presetUrl;
}

export async function motionPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset;

    if (!presetName) {
      listMotionPresets();
      await browser.close();
      return { success: true, action: 'list' };
    }

    const presetUrl = resolveMotionPresetUrl(presetName);
    if (!presetUrl) {
      console.error(`Motion preset not found: ${presetName}. Run "discover" to refresh cache.`);
      await browser.close();
      return { success: false, error: `Unknown preset: ${presetName}` };
    }

    console.log(`Navigating to motion preset: ${presetName}...`);
    await navigateAndDismiss(page, presetUrl);

    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) await uploadFileToPage(page, mediaFile, 'Media');
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, 'motion-preset-configured');
    await clickGenerate(page, 'motion preset');
    await waitForGenerationResult(page, options, {
      selector: `video, ${GENERATED_IMAGE_SELECTOR}`, screenshotName: 'motion-preset-result',
      label: 'motion preset', outputSubdir: 'motion-presets', defaultTimeout: 300000, isVideo: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Motion Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function editVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Video Edit...');
    await navigateAndDismiss(page, '/create/edit');

    if (options.videoFile) await uploadFileToPage(page, options.videoFile, 'Video');
    if (options.imageFile) {
      const uploaded = await uploadSecondFileToPage(page, options.imageFile, 'Character image');
      if (!uploaded && !options.videoFile) {
        await uploadFileToPage(page, options.imageFile, 'Image');
      }
    }
    if (options.prompt) await fillPromptField(page, options.prompt);

    await debugScreenshot(page, 'video-edit-configured');
    await clickGenerate(page, 'video edit');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'video-edit-result', label: 'video edit',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true, useHistoryPoll: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Video Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function storyboard(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Storyboard Generator...');
    await navigateAndDismiss(page, '/storyboard-generator');

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Reference image');
    if (options.prompt) await fillPromptField(page, options.prompt);

    if (options.scenes) {
      const scenesInput = page.locator('input[type="number"], input[placeholder*="scene" i], input[placeholder*="panel" i]');
      if (await scenesInput.count() > 0) {
        await scenesInput.first().fill(String(options.scenes));
        console.log(`Panels set to ${options.scenes}`);
      }
    }

    if (options.preset) await selectButtonOption(page, options.preset, 'Style');

    await debugScreenshot(page, 'storyboard-configured');
    await clickGenerate(page, 'storyboard');
    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, .storyboard-panel, [class*="storyboard"]`,
      screenshotName: 'storyboard-result', label: 'storyboard',
      outputSubdir: 'storyboards', defaultTimeout: 300000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Storyboard error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

function resolveVibeMotionSubtype(subtype) {
  const subtypeMap = {
    infographics: 'Infographics',
    'text-animation': 'Text Animation',
    text: 'Text Animation',
    posters: 'Posters',
    poster: 'Posters',
    presentation: 'Presentation',
    scratch: 'From Scratch',
    'from-scratch': 'From Scratch',
  };
  return subtypeMap[subtype.toLowerCase()] || subtype;
}

export async function vibeMotion(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Vibe Motion...');
    await navigateAndDismiss(page, '/vibe-motion');

    const subtypeLabel = resolveVibeMotionSubtype(options.tab || 'From Scratch');
    const subtypeTab = page.locator(`[role="tab"]:has-text("${subtypeLabel}"), button:has-text("${subtypeLabel}")`);
    if (await subtypeTab.count() > 0) {
      await subtypeTab.first().click();
      await page.waitForTimeout(1000);
      console.log(`Selected sub-type: ${subtypeLabel}`);
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image/logo');
    if (options.prompt) await fillPromptField(page, options.prompt);
    if (options.preset) await selectButtonOption(page, options.preset, 'Style');
    if (options.duration) await selectButtonOption(page, `${options.duration}s`, 'Duration');
    if (options.aspect) await selectButtonOption(page, options.aspect, 'Aspect');

    await debugScreenshot(page, 'vibe-motion-configured');
    await clickGenerate(page, 'Vibe Motion');
    await waitForGenerationResult(page, options, {
      selector: 'video', screenshotName: 'vibe-motion-result', label: 'Vibe Motion',
      outputSubdir: 'videos', defaultTimeout: 300000, isVideo: true,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Vibe Motion error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function aiInfluencer(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to AI Influencer Studio...');
    await navigateAndDismiss(page, '/ai-influencer-studio');

    if (options.preset) {
      const typeBtn = page.locator(`button:has-text("${options.preset}"), [role="option"]:has-text("${options.preset}")`);
      if (await typeBtn.count() > 0) {
        await typeBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Character type: ${options.preset}`);
      }
    }

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Reference image');

    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i], input[placeholder*="describe" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Description entered');
      }
    }

    await debugScreenshot(page, 'ai-influencer-configured');
    await clickGenerate(page, 'AI Influencer');
    await waitForGenerationResult(page, options, {
      selector: GENERATED_IMAGE_SELECTOR, screenshotName: 'ai-influencer-result',
      label: 'AI Influencer', outputSubdir: 'characters',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('AI Influencer error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

export async function createCharacter(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Character...');
    await navigateAndDismiss(page, '/character');

    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        const isMultiple = await fileInput.getAttribute('multiple');
        if (isMultiple !== null && options.imageFile2) {
          await fileInput.setInputFiles([options.imageFile, options.imageFile2]);
        } else {
          await fileInput.setInputFiles(options.imageFile);
        }
        await page.waitForTimeout(2000);
        console.log('Character photo(s) uploaded');
      }
    }

    if (options.prompt) {
      const nameInput = page.locator('input[placeholder*="name" i], input[placeholder*="label" i], textarea').first();
      if (await nameInput.count() > 0) {
        await nameInput.fill(options.prompt);
        console.log(`Character name/description: ${options.prompt}`);
      }
    }

    await debugScreenshot(page, 'character-configured');
    await clickGenerate(page, 'character');
    await waitForGenerationResult(page, options, {
      selector: `${GENERATED_IMAGE_SELECTOR}, [class*="character"]`, screenshotName: 'character-result',
      label: 'character creation', outputSubdir: 'characters', defaultTimeout: 120000,
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error('Character error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

const FEATURE_MAP = {
  'fashion-factory': { url: '/fashion-factory', name: 'Fashion Factory' },
  fashion: { url: '/fashion-factory', name: 'Fashion Factory' },
  'ugc-factory': { url: '/ugc-factory', name: 'UGC Factory' },
  ugc: { url: '/ugc-factory', name: 'UGC Factory' },
  'photodump-studio': { url: '/photodump-studio', name: 'Photodump Studio' },
  photodump: { url: '/photodump-studio', name: 'Photodump Studio' },
  'camera-controls': { url: '/camera-controls', name: 'Camera Controls' },
  camera: { url: '/camera-controls', name: 'Camera Controls' },
  effects: { url: '/effects', name: 'Effects' },
};

export async function featurePage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const featureKey = options.effect || options.feature || 'fashion-factory';
    const feature = FEATURE_MAP[featureKey.toLowerCase()] || { url: `/${featureKey}`, name: featureKey };

    console.log(`Navigating to ${feature.name}...`);
    await navigateAndDismiss(page, feature.url);

    if (options.imageFile) await uploadFileToPage(page, options.imageFile, 'Image');
    if (options.imageFile2) await uploadSecondFileToPage(page, options.imageFile2, 'Additional image');

    if (options.videoFile) {
      const fileInput = page.locator('input[type="file"][accept*="video"], input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.videoFile);
        await page.waitForTimeout(2000);
        console.log('Video uploaded');
      }
    }

    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    if (options.preset) await selectButtonOption(page, options.preset, 'Style/preset');

    await debugScreenshot(page, `feature-${featureKey}-configured`);
    await clickGenerate(page, feature.name);
    await waitForGenerationResult(page, options, {
      screenshotName: `feature-${featureKey}-result`, label: feature.name, outputSubdir: 'features',
    });

    await saveStateAndClose(context, browser);
    return { success: true };
  } catch (error) {
    console.error(`Feature page error: ${error.message}`);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// ─── Auth Health Check & Smoke Test ──────────────────────────────────────────

export async function authHealthCheck(options = {}) {
  console.log('[health-check] Verifying authentication state...');

  if (!existsSync(STATE_FILE)) {
    console.log('[health-check] No auth state found');
    console.log('[health-check] Run: higgsfield-helper.sh login');
    return { success: false, error: 'No auth state' };
  }

  const stats = statSync(STATE_FILE);
  const ageMs = Date.now() - stats.mtimeMs;
  const ageHours = Math.floor(ageMs / (1000 * 60 * 60));
  const ageDays = Math.floor(ageHours / 24);

  console.log(`[health-check] Auth state file: ${STATE_FILE}`);
  console.log(`[health-check] Age: ${ageDays}d ${ageHours % 24}h`);

  try {
    const { browser, page } = await launchBrowser({ ...options, headless: true });

    console.log('[health-check] Testing auth by navigating to /image/soul...');
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(3000);

    const currentUrl = page.url();

    if (currentUrl.includes('login') || currentUrl.includes('auth') || currentUrl.includes('sign-in')) {
      console.log('[health-check] Auth state is invalid (redirected to login)');
      console.log('[health-check] Run: higgsfield-helper.sh login');
      await browser.close();
      return { success: false, error: 'Auth expired or invalid' };
    }

    const userMenuSelectors = [
      '[data-testid="user-menu"]',
      'button[aria-label*="account" i]',
      'button[aria-label*="profile" i]',
      'img[alt*="avatar" i]',
      'div[class*="avatar"]',
    ];

    let foundUserIndicator = false;
    for (const selector of userMenuSelectors) {
      if (await page.locator(selector).count() > 0) {
        foundUserIndicator = true;
        break;
      }
    }

    await browser.close();

    if (foundUserIndicator) {
      console.log('[health-check] Auth state is valid');
      return { success: true, age: { hours: ageHours, days: ageDays } };
    }
    console.log('[health-check] Auth state uncertain (no user indicator found)');
    return { success: true, warning: 'Could not verify user indicator' };

  } catch (error) {
    console.error(`[health-check] Error during health check: ${error.message}`);
    return { success: false, error: error.message };
  }
}

async function smokeTestNavigation(page) {
  const testPages = [
    { url: `${BASE_URL}/image/soul`, name: 'Image Generation' },
    { url: `${BASE_URL}/video`, name: 'Video Generation' },
    { url: `${BASE_URL}/apps`, name: 'Apps' },
  ];

  let navSuccess = true;
  for (const testPage of testPages) {
    try {
      await page.goto(testPage.url, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForTimeout(2000);
      const currentUrl = page.url();

      if (currentUrl.includes('login') || currentUrl.includes('auth')) {
        console.log(`[smoke-test]   ${testPage.name}: Redirected to login`);
        navSuccess = false;
      } else {
        console.log(`[smoke-test]   ${testPage.name}: OK`);
      }
    } catch (error) {
      console.log(`[smoke-test]   ${testPage.name}: ${error.message}`);
      navSuccess = false;
    }
  }
  return navSuccess;
}

async function smokeTestCredits(page) {
  try {
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await page.waitForTimeout(2000);

    const creditSelectors = [
      'text=/\\d+\\s*(credits?|cr)/i',
      '[data-testid*="credit"]',
      'div:has-text("credits")',
    ];

    for (const selector of creditSelectors) {
      const el = page.locator(selector);
      if (await el.count() > 0) {
        const text = await el.first().textContent();
        console.log(`[smoke-test]   Credits visible: ${text?.trim()}`);
        return true;
      }
    }

    console.log('[smoke-test]   Could not find credit indicator (may still work)');
    return false;
  } catch (error) {
    console.log(`[smoke-test]   Credits check failed: ${error.message}`);
    return false;
  }
}

export async function smokeTest(options = {}) {
  console.log('[smoke-test] Running smoke test...');
  console.log('[smoke-test] This will verify: auth, navigation, UI elements (no generation)');

  const results = { auth: false, navigation: false, credits: false, discovery: false, overall: false };

  try {
    console.log('\n[smoke-test] Step 1/4: Auth health check...');
    const authResult = await authHealthCheck({ ...options, headless: true });
    results.auth = authResult.success;

    if (!results.auth) {
      console.log('[smoke-test] Auth check failed, aborting smoke test');
      return results;
    }

    console.log('\n[smoke-test] Step 2/4: Testing navigation...');
    const { browser, page } = await launchBrowser({ ...options, headless: true });
    results.navigation = await smokeTestNavigation(page);

    console.log('\n[smoke-test] Step 3/4: Checking credits...');
    results.credits = await smokeTestCredits(page);

    console.log('\n[smoke-test] Step 4/4: Checking discovery cache...');
    if (existsSync(ROUTES_CACHE)) {
      const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
      const modelCount = Object.keys(cache.models || {}).length;
      const appCount = Object.keys(cache.apps || {}).length;
      console.log(`[smoke-test]   Discovery cache: ${modelCount} models, ${appCount} apps`);
      results.discovery = true;
    } else {
      console.log('[smoke-test]   No discovery cache (run: higgsfield-helper.sh image "test")');
      results.discovery = false;
    }

    await browser.close();

    results.overall = results.auth && results.navigation;

    console.log('\n[smoke-test] ========== RESULTS ==========');
    console.log(`[smoke-test] Auth:       ${results.auth ? 'PASS' : 'FAIL'}`);
    console.log(`[smoke-test] Navigation: ${results.navigation ? 'PASS' : 'FAIL'}`);
    console.log(`[smoke-test] Credits:    ${results.credits ? 'PASS' : 'WARN'}`);
    console.log(`[smoke-test] Discovery:  ${results.discovery ? 'PASS' : 'WARN'}`);
    console.log(`[smoke-test] Overall:    ${results.overall ? 'PASS' : 'FAIL'}`);
    console.log('[smoke-test] ============================');

    return results;

  } catch (error) {
    console.error(`[smoke-test] Smoke test error: ${error.message}`);
    results.overall = false;
    return results;
  }
}

// ─── Self-Tests ───────────────────────────────────────────────────────────────

export async function runSelfTests() {
  let passed = 0;
  let failed = 0;

  function assert(condition, name) {
    if (condition) {
      console.log(`  PASS: ${name}`);
      passed++;
    } else {
      console.error(`  FAIL: ${name}`);
      failed++;
    }
  }

  const originalCache = existsSync(CREDITS_CACHE_FILE)
    ? readFileSync(CREDITS_CACHE_FILE, 'utf-8')
    : null;

  console.log('\n=== Unlimited Model Selection Tests ===\n');

  console.log('--- UNLIMITED_MODELS mapping ---');
  const imageModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'image');
  const videoModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'video');
  assert(imageModels.length === 12, `12 image models mapped (got ${imageModels.length})`);
  assert(videoModels.length === 3, `3 video models mapped (got ${videoModels.length})`);

  console.log('\n--- SOTA quality priority ordering ---');
  const imagePriorities = imageModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(imagePriorities[0][1].slug === 'nano-banana-pro', 'Nano Banana Pro is priority 1');
  assert(imagePriorities[1][1].slug === 'gpt', 'GPT Image is priority 2');
  assert(imagePriorities[2][1].slug === 'seedream-4-5', 'Seedream 4.5 is priority 3');
  assert(imagePriorities[3][1].slug === 'flux', 'FLUX.2 Pro is priority 4');
  assert(imagePriorities[11][1].slug === 'popcorn', 'Popcorn is last');

  const videoPriorities = videoModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(videoPriorities[0][1].slug === 'kling-2.6', 'Kling 2.6 is top video model');
  assert(videoPriorities[1][1].slug === 'kling-o1', 'Kling O1 is second');
  assert(videoPriorities[2][1].slug === 'kling-2.5', 'Kling 2.5 Turbo is third');

  console.log('\n--- No duplicate priorities ---');
  const types = ['image', 'video', 'video-edit', 'motion-control', 'app'];
  for (const type of types) {
    const models = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === type);
    const priorities = models.map(([, v]) => v.priority);
    const uniquePriorities = new Set(priorities);
    assert(priorities.length === uniquePriorities.size, `No duplicate priorities in type '${type}'`);
  }

  console.log('\n--- getUnlimitedModelForCommand with mock cache ---');
  const mockCache = {
    remaining: '5916',
    total: '6000',
    plan: 'Creator',
    unlimitedModels: [
      { model: 'Nano Banana Pro365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'GPT Image365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Higgsfield Soul365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Seedream 4.5365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'FLUX.2 Pro365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Kling 2.6 Video Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
      { model: 'Kling O1 Video Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
      { model: 'Kling 2.5 Turbo Unlimited', starts: 'Jan 21, 2026', expires: 'Feb 20, 2026' },
    ],
    timestamp: Date.now(),
  };
  saveCreditCache(mockCache);

  const bestImage = getUnlimitedModelForCommand('image');
  assert(bestImage !== null, 'Returns a model for image type');
  assert(bestImage.slug === 'nano-banana-pro', `Best image model is Nano Banana Pro (got: ${bestImage?.slug})`);
  assert(bestImage.name === 'Nano Banana Pro365 Unlimited', `Returns full model name`);

  const bestVideo = getUnlimitedModelForCommand('video');
  assert(bestVideo !== null, 'Returns a model for video type');
  assert(bestVideo.slug === 'kling-2.6', `Best video model is Kling 2.6 (got: ${bestVideo?.slug})`);

  console.log('\n--- Partial cache (limited models) ---');
  const partialCache = {
    remaining: '100',
    total: '6000',
    plan: 'Creator',
    unlimitedModels: [
      { model: 'Higgsfield Soul365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
      { model: 'Nano Banana365 Unlimited', starts: 'Auto-renewing', expires: 'Auto-renewing' },
    ],
    timestamp: Date.now(),
  };
  saveCreditCache(partialCache);

  const partialBest = getUnlimitedModelForCommand('image');
  assert(partialBest.slug === 'soul', `With only Soul+Nano active, Soul wins (got: ${partialBest?.slug})`);

  const noVideo = getUnlimitedModelForCommand('video');
  assert(noVideo === null, 'No video model when none are in cache');

  console.log('\n--- Empty/missing cache ---');
  const emptyCache = { remaining: '0', total: '0', plan: 'Free', unlimitedModels: [], timestamp: Date.now() };
  saveCreditCache(emptyCache);

  const emptyResult = getUnlimitedModelForCommand('image');
  assert(emptyResult === null, 'Returns null when no unlimited models in cache');

  console.log('\n--- isUnlimitedModel ---');
  saveCreditCache(mockCache);
  assert(isUnlimitedModel('gpt', 'image') === true, 'GPT is unlimited for image');
  assert(isUnlimitedModel('kling-2.6', 'video') === true, 'Kling 2.6 is unlimited for video');
  assert(isUnlimitedModel('soul', 'image') === true, 'Soul is unlimited for image');
  assert(isUnlimitedModel('sora', 'video') === false, 'Sora is NOT unlimited');
  assert(isUnlimitedModel('gpt', 'video') === false, 'GPT is NOT unlimited for video type');
  assert(isUnlimitedModel('kling-2.6', 'image') === false, 'Kling 2.6 is NOT unlimited for image type');

  console.log('\n--- estimateCreditCost with unlimited models ---');
  assert(estimateCreditCost('image', { model: 'gpt' }) === 0, 'GPT image costs 0 credits');
  assert(estimateCreditCost('video', { model: 'kling-2.6' }) === 0, 'Kling 2.6 video costs 0 credits');
  assert(estimateCreditCost('image', { model: 'sora' }) > 0, 'Non-unlimited model has credit cost');
  assert(estimateCreditCost('image', {}) === 0, 'No model + prefer-unlimited default = 0');
  assert(estimateCreditCost('image', { preferUnlimited: false }) > 0, 'prefer-unlimited=false has credit cost');
  assert(estimateCreditCost('video', {}) === 0, 'Video with auto-select = 0 credits');

  console.log('\n--- checkCreditGuard with unlimited models ---');
  const lowCreditCache = { ...mockCache, remaining: '1', timestamp: Date.now() };
  saveCreditCache(lowCreditCache);
  let guardPassed = false;
  try {
    checkCreditGuard('image', { model: 'gpt' });
    guardPassed = true;
  } catch { guardPassed = false; }
  assert(guardPassed, 'Credit guard passes for unlimited model even with 1 credit');

  let guardBlocked = false;
  try {
    checkCreditGuard('image', { model: 'sora', preferUnlimited: false });
    guardBlocked = false;
  } catch { guardBlocked = true; }
  assert(guardBlocked, 'Credit guard blocks non-unlimited model with 1 credit');

  console.log('\n--- UNLIMITED_SLUGS reverse lookup ---');
  assert(UNLIMITED_SLUGS.has('image:gpt'), 'Reverse lookup has image:gpt');
  assert(UNLIMITED_SLUGS.has('video:kling-2.6'), 'Reverse lookup has video:kling-2.6');
  assert(!UNLIMITED_SLUGS.has('video:gpt'), 'No reverse lookup for video:gpt');
  assert(UNLIMITED_SLUGS.get('image:gpt').includes('GPT Image365 Unlimited'), 'Reverse lookup maps to correct name');

  console.log('\n--- CLI flag parsing ---');
  const origArgv = process.argv;
  process.argv = ['node', 'test', 'image', '--prefer-unlimited'];
  let parsed = parseArgs();
  assert(parsed.options.preferUnlimited === true, '--prefer-unlimited sets true');

  process.argv = ['node', 'test', 'image', '--no-prefer-unlimited'];
  parsed = parseArgs();
  assert(parsed.options.preferUnlimited === false, '--no-prefer-unlimited sets false');

  process.argv = ['node', 'test', 'image'];
  parsed = parseArgs();
  assert(parsed.options.preferUnlimited === undefined, 'No flag leaves undefined');

  console.log('\n--- API flag parsing ---');
  process.argv = ['node', 'test', 'image', '--api'];
  parsed = parseArgs();
  assert(parsed.options.useApi === true, '--api sets useApi=true');
  assert(parsed.options.apiOnly === undefined, '--api does not set apiOnly');

  process.argv = ['node', 'test', 'image', '--api-only'];
  parsed = parseArgs();
  assert(parsed.options.useApi === true, '--api-only sets useApi=true');
  assert(parsed.options.apiOnly === true, '--api-only sets apiOnly=true');

  process.argv = ['node', 'test', 'image'];
  parsed = parseArgs();
  assert(parsed.options.useApi === undefined, 'No --api flag leaves useApi undefined');
  process.argv = origArgv;

  if (originalCache) {
    writeFileSync(CREDITS_CACHE_FILE, originalCache);
  }

  console.log(`\n=== Test Results: ${passed} passed, ${failed} failed ===\n`);
  if (failed > 0) {
    process.exit(1);
  }
}
