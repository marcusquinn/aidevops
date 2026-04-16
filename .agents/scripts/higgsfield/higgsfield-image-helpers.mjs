// higgsfield-image-helpers.mjs — Image generation detection, polling, and completion
// helpers for the Higgsfield automation suite.
// Extracted from higgsfield-image.mjs (t2127 file-complexity decomposition).

import {
  GENERATED_IMAGE_SELECTOR,
} from './higgsfield-common.mjs';

import {
  dismissAllModals,
  debugScreenshot,
} from './higgsfield-browser.mjs';

// ---------------------------------------------------------------------------
// Generation detection helpers
// ---------------------------------------------------------------------------

export async function clickAndVerifyGenerate(page, queueBefore, existingImageCount) {
  const generateBtn = page.locator('button:has-text("Generate"), button[type="submit"]');
  const genCount = await generateBtn.count();
  console.log(`Found ${genCount} generate button(s)`);

  const btnTextBefore = genCount > 0
    ? await generateBtn.last().textContent().catch(() => '')
    : '';

  if (genCount > 0) {
    await generateBtn.last().scrollIntoViewIfNeeded().catch(() => {});
    await page.waitForTimeout(300);
    await generateBtn.last().click({ force: true });
    console.log(`Clicked generate button (force). Button text was: "${btnTextBefore?.trim()}"`);
  } else {
    await page.evaluate(() => {
      const btn = document.querySelector('button[type="submit"]') ||
                  [...document.querySelectorAll('button')].find(b => b.textContent?.includes('Generate'));
      if (btn) btn.click();
    });
    console.log('Clicked generate button via JS');
  }

  await page.waitForTimeout(3000);
  const postClickState = await page.evaluate(({ prevQueue, prevImages, imgSelector }) => {
    const queueNow = (document.body.innerText.match(/In queue/g) || []).length;
    const imagesNow = document.querySelectorAll(imgSelector).length;
    const hasGeneratingIndicator = document.body.innerText.includes('Generating') ||
      document.body.innerText.includes('Processing') ||
      document.querySelectorAll('[class*="spinner"], [class*="loading"], [class*="progress"]').length > 0;
    const genBtns = [...document.querySelectorAll('button')].filter(b => b.textContent?.includes('Generate'));
    const btnDisabled = genBtns.some(b => b.disabled || b.getAttribute('aria-disabled') === 'true');
    const btnTextNow = genBtns.map(b => b.textContent?.trim()).join(', ');
    return { queueNow, imagesNow, hasGeneratingIndicator, btnDisabled, btnTextNow };
  }, { prevQueue: queueBefore, prevImages: existingImageCount, imgSelector: GENERATED_IMAGE_SELECTOR });

  const clickRegistered = postClickState.queueNow > queueBefore ||
    postClickState.imagesNow > existingImageCount ||
    postClickState.hasGeneratingIndicator ||
    postClickState.btnDisabled;

  if (!clickRegistered) {
    console.log(`Generate click may not have registered (queue=${postClickState.queueNow}, images=${postClickState.imagesNow}, btn="${postClickState.btnTextNow}"). Retrying...`);
    await dismissAllModals(page);
    if (genCount > 0) {
      await generateBtn.last().scrollIntoViewIfNeeded().catch(() => {});
      await page.waitForTimeout(500);
      await generateBtn.last().click({ force: true });
      console.log('Retried Generate click');
    }
    await page.waitForTimeout(3000);
    return false;
  }

  console.log(`Generate click confirmed (queue=${postClickState.queueNow}, indicator=${postClickState.hasGeneratingIndicator}, disabled=${postClickState.btnDisabled})`);
  return true;
}

export function checkImageGenCompletion(state, { existingImageCount, queueBefore, peakQueue, btnWasDisabled, elapsed }) {
  if (peakQueue > queueBefore && state.queueItems <= queueBefore) {
    return `Generation complete! ${state.images} images on page (${elapsed}s)`;
  }
  if (state.images > existingImageCount && state.queueItems === 0 && peakQueue === queueBefore) {
    return `Generation complete (fast)! ${state.images} images on page, ${state.images - existingImageCount} new (${elapsed}s)`;
  }
  if (btnWasDisabled && !state.btnDisabled && !state.hasSpinner) {
    return `Generation complete (button re-enabled)! ${state.images} images on page (${elapsed}s)`;
  }
  return null;
}

export async function retryGenerateIfStalled(page, { elapsed, state, queueBefore, existingImageCount, peakQueue, btnWasDisabled }) {
  if (parseInt(elapsed, 10) < 30) return false;
  if (state.queueItems !== queueBefore || state.images > existingImageCount) return false;
  if (peakQueue !== queueBefore || btnWasDisabled) return false;

  console.log('No activity detected after 30s - retrying Generate click...');
  await dismissAllModals(page);
  const retryBtn = page.locator('button:has-text("Generate")');
  if (await retryBtn.count() > 0) {
    await retryBtn.last().scrollIntoViewIfNeeded().catch(() => {});
    await page.waitForTimeout(300);
    await retryBtn.last().click({ force: true });
    console.log('Retried Generate click (30s safety)');
  }
  return true;
}

async function reloadAndCheckImages(page, { elapsed, existingImageCount, peakQueue, queueBefore, btnWasDisabled }) {
  if (parseInt(elapsed, 10) < 60) return null;
  if (peakQueue !== queueBefore || btnWasDisabled) return null;

  console.log('No queue or button activity after 60s - reloading to check for new images...');
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(5000);
  const freshCount = await page.evaluate((imgSelector) =>
    document.querySelectorAll(imgSelector).length
  , GENERATED_IMAGE_SELECTOR);
  if (freshCount > existingImageCount) {
    return `Generation complete (post-reload)! ${freshCount} images, ${freshCount - existingImageCount} new (${elapsed}s)`;
  }
  return null;
}

async function detectInitialQueueStart(page, queueBefore) {
  console.log('Waiting for generation to start...');
  try {
    await page.waitForFunction(
      (prevQueueCount) => (document.body.innerText.match(/In queue/g) || []).length > prevQueueCount,
      queueBefore,
      { timeout: 15000, polling: 1000 }
    );
    const count = await page.evaluate(() =>
      (document.body.innerText.match(/In queue/g) || []).length
    );
    console.log(`Generation started! ${count} item(s) in queue`);
    return count;
  } catch {
    console.log('Queue detection timed out - generation may have started differently');
    return queueBefore;
  }
}

async function readImageGenerationState(page) {
  return page.evaluate((imgSelector) => {
    const queueItems = (document.body.innerText.match(/In queue/g) || []).length;
    const images = document.querySelectorAll(imgSelector).length;
    const genBtns = [...document.querySelectorAll('button')].filter(b =>
      b.textContent.includes('Generate') || b.textContent.includes('Unlimited')
    );
    const genBtn = genBtns[genBtns.length - 1];
    const btnDisabled = genBtn ? (genBtn.disabled || genBtn.getAttribute('aria-disabled') === 'true') : false;
    const btnText = genBtn ? genBtn.textContent.trim() : '';
    const hasSpinner = document.querySelector('main svg[class*="animate"]') !== null ||
                      document.querySelector('main [class*="spinner"]') !== null ||
                      document.querySelector('main [class*="loading"]') !== null;
    return { queueItems, images, btnDisabled, btnText, hasSpinner };
  }, GENERATED_IMAGE_SELECTOR);
}

async function handleImageGenCompletion(page, state, ctx) {
  const completeMsg = checkImageGenCompletion(state, ctx);
  if (!completeMsg) return false;
  console.log(completeMsg);
  if (completeMsg.includes('button re-enabled')) await page.waitForTimeout(3000);
  return true;
}

async function handleImageGenReload(page, ctx, reloadAttempted) {
  if (reloadAttempted) return { done: false, attempted: reloadAttempted };
  const reloadMsg = await reloadAndCheckImages(page, ctx);
  if (reloadMsg) {
    console.log(reloadMsg);
    return { done: true, attempted: true };
  }
  const shouldMark = parseInt(ctx.elapsed, 10) >= 60 && ctx.peakQueue === ctx.queueBefore && !ctx.btnWasDisabled;
  return { done: false, attempted: shouldMark };
}

async function pollImageGenerationCycle(page, loopState, fixed) {
  const state = await readImageGenerationState(page);
  if (state.queueItems > loopState.peakQueue) loopState.peakQueue = state.queueItems;
  if (state.btnDisabled || state.hasSpinner) loopState.btnWasDisabled = true;

  const elapsed = ((Date.now() - fixed.startTime) / 1000).toFixed(0);
  console.log(`  ${elapsed}s: queue=${state.queueItems} images=${state.images} (peak=${loopState.peakQueue}) btn=${state.btnDisabled ? 'disabled' : 'enabled'}`);

  const ctx = {
    existingImageCount: fixed.existingImageCount,
    queueBefore: fixed.queueBefore,
    peakQueue: loopState.peakQueue,
    btnWasDisabled: loopState.btnWasDisabled,
    elapsed,
  };

  if (await handleImageGenCompletion(page, state, ctx)) return 'done';

  if (!loopState.retryAttempted) {
    loopState.retryAttempted = await retryGenerateIfStalled(page, { ...ctx, state });
  }

  const reloadResult = await handleImageGenReload(page, ctx, loopState.reloadAttempted);
  loopState.reloadAttempted = reloadResult.attempted;
  return reloadResult.done ? 'done' : 'continue';
}

export async function waitForImageGeneration(page, existingImageCount, queueBefore, options = {}) {
  const timeout = options.timeout || 300000;
  const startTime = Date.now();
  const pollInterval = 5000;

  const detectedQueueCount = await detectInitialQueueStart(page, queueBefore);
  console.log(`Waiting up to ${timeout / 1000}s for generation to complete...`);

  const fixed = { startTime, existingImageCount, queueBefore };
  const loopState = {
    peakQueue: Math.max(queueBefore, detectedQueueCount),
    retryAttempted: false,
    reloadAttempted: false,
    btnWasDisabled: false,
  };

  while (Date.now() - startTime < timeout) {
    await page.waitForTimeout(pollInterval);
    const status = await pollImageGenerationCycle(page, loopState, fixed);
    if (status === 'done') return true;
  }

  console.log('Timeout waiting for generation. Some items may still be processing.');
  return false;
}
