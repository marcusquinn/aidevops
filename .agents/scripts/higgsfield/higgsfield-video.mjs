// higgsfield-video.mjs — Video generation and download via the Higgsfield web UI (Playwright).
// Imported by playwright-automator.mjs.
//
// Lipsync → higgsfield-lipsync.mjs
// Batch video/lipsync → higgsfield-batch-video.mjs
// (t2127 file-complexity decomposition)


import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';

import {
  debugScreenshot,
  dismissAllModals,
  getDefaultOutputDir,
  launchBrowser,
} from './higgsfield-browser.mjs';
import {
  BASE_URL,
  getUnlimitedModelForCommand,
  isUnlimitedModel,
  STATE_DIR,
  STATE_FILE,
  safeJoin,
} from './higgsfield-common.mjs';

import {
  resolveOutputDir,
} from './higgsfield-output.mjs';

import { downloadVideoFromHistory } from './higgsfield-video-download.mjs';
import { logVideoPollingProgress } from './higgsfield-video-history.mjs';
export { logVideoPollingProgress };

export {
  downloadVideoFromApiData,
  evaluateNewestJobStatus,
  extractVideoMetadata,
  fetchProjectApiWithPolling,
} from './higgsfield-video-download.mjs';
export { downloadVideoFromHistory };

// ---------------------------------------------------------------------------
// Video model mapping
// ---------------------------------------------------------------------------

export const VIDEO_MODEL_NAME_MAP = {
  'kling-3.0':    'Kling 3.0',
  'kling-2.6':    'Kling 2.6',
  'kling-2.5':    'Kling 2.5 Turbo',
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

// The generator moved from /create/video (now redirects to the /ai-video
// marketing page) to /ai/video?model=<slug>. Unmapped models are chosen in the
// Model dialog instead.
export const VIDEO_GENERATOR_PATH = '/ai/video';
export const VIDEO_MODEL_SLUG_MAP = {
  'kling-2.5': 'kling-v2-5-turbo',
};

export function buildVideoGeneratorUrl(model, baseUrl = BASE_URL) {
  const slug = VIDEO_MODEL_SLUG_MAP[model];
  return `${baseUrl}${VIDEO_GENERATOR_PATH}${slug ? `?model=${slug}` : ''}`;
}

/** Unlimited is requested explicitly, or implied by an unlimited model unless opted out. */
export function isUnlimitedRequested(options, model) {
  if (options.preferUnlimited === false) return false;
  return options.preferUnlimited === true || isUnlimitedModel(model, 'video');
}

/** The only Generate label that is safe to click when unlimited was requested. */
export function isUnlimitedGenerateLabel(label) {
  return /^\s*Generate\s+Unlimited\s*$/i.test(label || '');
}

async function readGenerateLabel(page) {
  return page.evaluate(() => {
    const labels = [...document.querySelectorAll('button')]
      .filter(b => b.offsetParent !== null)
      .map(b => (b.textContent || '').replace(/\s+/g, ' ').trim())
      .filter(t => /^Generate\b/i.test(t));
    return labels[labels.length - 1] || '';
  });
}

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
    await tryUploadViaFileInput(page, imageFile) ||
    await tryUploadViaButton(page, imageFile) ||
    await tryUploadViaStartFrameArea(page, imageFile) ||
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
  // Unlimited needs Quality = std (720p); at pro the page offers this button.
  const toStd = page.getByRole('button', { name: /Change to std for Unlimited/i });
  if (await toStd.count() > 0) {
    await toStd.first().click({ force: true });
    await page.waitForTimeout(800);
    console.log('Switched quality to std (720p) for Unlimited');
  }
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
// Opt-in session mode: drive the user's paired everyday browser (OpenCode browse)
// ---------------------------------------------------------------------------

/** Self-contained Playwright body for `opencode-browse run -- execute --file`. Returns no media URLs. */
export function buildBrowseVideoScript(params) {
  return `const P = ${JSON.stringify(params)};
await page.goto(P.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
await page.waitForTimeout(4000);
if (P.imageFile) {
  await page.locator('input[type="file"]').first().setInputFiles(P.imageFile);
  await page.waitForTimeout(3000);
}
const modelBtn = page.getByRole('button', { name: 'Model' });
if (!P.modelSlugInUrl && P.uiModelName && !((await modelBtn.textContent().catch(() => '')) || '').includes(P.uiModelName)) {
  await modelBtn.click();
  const search = page.locator('input[placeholder*="Search"]');
  if (await search.count() > 0) await search.fill(P.uiModelName);
  await page.waitForTimeout(1000);
  await page.getByRole('dialog').getByRole('button', { name: new RegExp(P.uiModelName, 'i') }).first().click();
  await page.waitForTimeout(1500);
}
if (P.unlimited) {
  const toStd = page.getByRole('button', { name: /Change to std for Unlimited/i });
  if (await toStd.count() > 0) { await toStd.first().click(); await page.waitForTimeout(800); }
  const sw = page.getByRole('switch', { name: 'Unlimited mode' });
  if (await sw.count() > 0 && !(await sw.isChecked())) { await sw.click(); await page.waitForTimeout(500); }
}
await page.getByRole('textbox', { name: 'Prompt' }).fill(P.prompt);
const label = await page.evaluate(() => {
  const l = [...document.querySelectorAll('button')].filter(b => b.offsetParent !== null)
    .map(b => (b.textContent || '').replace(/\\s+/g, ' ').trim()).filter(t => /^Generate\\b/i.test(t));
  return l[l.length - 1] || '';
});
if (P.dryRun) return { dryRun: true, generateLabel: label };
if (P.unlimited && !/^Generate\\s+Unlimited$/i.test(label)) return { refused: true, generateLabel: label };
await page.getByRole('button', { name: label, exact: true }).last().click();
return { submitted: true, generateLabel: label };
`;
}

function runVideoViaOpencodeBrowse(options, model, prompt) {
  const uiModelName = VIDEO_MODEL_NAME_MAP[model] || model;
  const tempRoot = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), '.aidevops', '.agent-workspace', 'tmp');
  const workDir = mkdtempSync(join(tempRoot, 'higgsfield-browse-'));
  try {
    let imageFile = null;
    if (options.imageFile) {
      // browse uploads only from temp roots: stage a copy there.
      imageFile = join(workDir, basename(options.imageFile));
      copyFileSync(options.imageFile, imageFile);
    }
    const scriptPath = join(workDir, 'video.browse.js');
    writeFileSync(scriptPath, buildBrowseVideoScript({
      url: buildVideoGeneratorUrl(model),
      modelSlugInUrl: Boolean(VIDEO_MODEL_SLUG_MAP[model]),
      uiModelName, imageFile, prompt,
      unlimited: isUnlimitedRequested(options, model),
      dryRun: Boolean(options.dryRun),
    }));
    const run = spawnSync('aidevops', ['opencode-browse', 'run', '--', 'execute', '--file', scriptPath], { encoding: 'utf8' });
    if (run.status !== 0) {
      return { success: false, error: `opencode-browse failed: ${(run.stderr || run.stdout || '').trim().slice(0, 300)}` };
    }
    console.log(`[opencode-browse] ${(run.stdout || '').trim().slice(0, 500)}`);
    return { success: true, sessionMode: 'opencode-browse', dryRun: Boolean(options.dryRun) };
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
}

function isBrowseSessionMode(options) {
  return (options.sessionMode || process.env.HIGGSFIELD_SESSION_MODE) === 'opencode-browse';
}

async function downloadGeneratedVideo(page, { model, prompt, generationComplete }, options) {
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

/** Dry-run and unlimited guard: returns a final result when Generate must not be clicked, else null. */
async function checkGenerateGate(page, context, browser, options, wantUnlimited) {
  const generateLabel = await readGenerateLabel(page);
  console.log(`Generate button reads: "${generateLabel}"`);

  if (options.dryRun) {
    console.log('[DRY-RUN] Configuration complete. Skipping Generate click.');
    await debugScreenshot(page, 'dry-run-configured');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, dryRun: true, generateLabel };
  }

  if (wantUnlimited && !isUnlimitedGenerateLabel(generateLabel)) {
    const error = `Unlimited requested but Generate button reads "${generateLabel}"; refusing to spend credits`;
    console.error(error);
    await debugScreenshot(page, 'video-unlimited-refused');
    await browser.close();
    return { success: false, error, generateLabel };
  }
  return null;
}

// ---------------------------------------------------------------------------
// Main entry point: generateVideo
// ---------------------------------------------------------------------------

export async function generateVideo(options = {}) {
  if (isBrowseSessionMode(options)) {
    return runVideoViaOpencodeBrowse(options, selectVideoModel(options),
      options.prompt || 'Camera slowly pans across a beautiful landscape as clouds drift overhead');
  }
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Camera slowly pans across a beautiful landscape as clouds drift overhead';
    const model = selectVideoModel(options);
    const wantUnlimited = isUnlimitedRequested(options, model);

    console.log('Navigating to video generator page...');
    await page.goto(buildVideoGeneratorUrl(model), { waitUntil: 'domcontentloaded', timeout: 60000 });
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
    if (options.preferUnlimited !== false) await enableVideoUnlimitedMode(page);
    await fillVideoPrompt(page, prompt);

    const historyState = await captureVideoHistoryState(page);
    const early = await checkGenerateGate(page, context, browser, options, wantUnlimited);
    if (early) return early;

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
      await downloadGeneratedVideo(page, { model, prompt, generationComplete }, options);
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
