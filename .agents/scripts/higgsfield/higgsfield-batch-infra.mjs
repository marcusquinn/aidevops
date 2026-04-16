// higgsfield-batch-infra.mjs — Batch operations infrastructure and generation result
// waiter for the Higgsfield automation suite.
// Extracted from higgsfield-common.mjs (t2127 file-complexity decomposition).

import { readFileSync, writeFileSync, existsSync } from 'fs';

import {
  GENERATED_IMAGE_SELECTOR,
  ensureDir,
  safeJoin,
  withRetry,
} from './higgsfield-common.mjs';

import {
  getDefaultOutputDir,
  dismissAllModals,
  debugScreenshot,
} from './higgsfield-browser.mjs';

import {
  resolveOutputDir,
  downloadLatestResult,
} from './higgsfield-output.mjs';

// ---------------------------------------------------------------------------
// Batch operations infrastructure
// ---------------------------------------------------------------------------

export function loadBatchManifest(filePath) {
  if (!existsSync(filePath)) {
    throw new Error(`Batch manifest not found: ${filePath}`);
  }
  const raw = JSON.parse(readFileSync(filePath, 'utf-8'));

  if (Array.isArray(raw)) {
    return { jobs: raw.map(item => typeof item === 'string' ? { prompt: item } : item), defaults: {} };
  }

  if (raw.jobs && Array.isArray(raw.jobs)) {
    return { jobs: raw.jobs, defaults: raw.defaults || {} };
  }

  throw new Error('Invalid manifest format. Expected { "jobs": [...] } or ["prompt1", "prompt2", ...]');
}

export function saveBatchState(outputDir, state) {
  writeFileSync(safeJoin(outputDir, 'batch-state.json'), JSON.stringify(state, null, 2));
}

export function loadBatchState(outputDir) {
  const stateFile = safeJoin(outputDir, 'batch-state.json');
  if (existsSync(stateFile)) {
    return JSON.parse(readFileSync(stateFile, 'utf-8'));
  }
  return null;
}

export async function runWithConcurrency(tasks, concurrency) {
  const results = new Array(tasks.length).fill(null);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < tasks.length) {
      const idx = nextIndex++;
      try {
        results[idx] = await tasks[idx]();
      } catch (error) {
        results[idx] = { success: false, error: error.message, index: idx };
      }
    }
    return 0;
  }

  const workers = [];
  for (let i = 0; i < Math.min(concurrency, tasks.length); i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}

function loadResumeState(options, outputDir, type) {
  let completedIndices = new Set();
  if (options.resume) {
    const prevState = loadBatchState(outputDir);
    if (prevState?.completed) {
      completedIndices = new Set(prevState.completed);
      console.log(`Resuming: ${completedIndices.size}/${prevState.total || '?'} already completed`);
    }
  }
  return completedIndices;
}

export function initBatch(type, options, defaultConcurrency) {
  const manifestPath = options.batchFile;
  if (!manifestPath) {
    console.error(`ERROR: --batch-file is required for ${type}`);
    console.error(`Usage: ${type} --batch-file manifest.json [--concurrency ${defaultConcurrency}] [--output dir]`);
    process.exit(1);
  }

  const { jobs, defaults } = loadBatchManifest(manifestPath);
  const concurrency = options.concurrency || defaultConcurrency;
  const outputDir = ensureDir(options.output || safeJoin(getDefaultOutputDir(options), `${type}-${Date.now()}`));
  const completedIndices = loadResumeState(options, outputDir, type);

  const batchState = {
    type, total: jobs.length, concurrency,
    completed: [...completedIndices], failed: [], results: [],
    startTime: new Date().toISOString(),
  };

  return { jobs, defaults, concurrency, outputDir, completedIndices, batchState };
}

export async function runBatchJob({ generatorFn, jobOptions, index, jobCount, batchState, outputDir, retryLabel }) {
  try {
    const result = await withRetry(
      () => generatorFn(jobOptions),
      { maxRetries: 1, baseDelay: 5000, label: retryLabel }
    );
    batchState.completed.push(index);
    saveBatchState(outputDir, batchState);
    console.log(`[${index + 1}/${jobCount}] Complete`);
    return { success: true, index, ...result };
  } catch (error) {
    batchState.failed.push({ index, error: error.message });
    saveBatchState(outputDir, batchState);
    console.error(`[${index + 1}/${jobCount}] Failed: ${error.message}`);
    return { success: false, index, error: error.message };
  }
}

export function finalizeBatch({ type, batchState, results, startTime, outputDir, jobCount }) {
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
  const succeeded = results.filter(r => r?.success).length;
  const failed = results.filter(r => r && !r.success).length;

  batchState.elapsed = `${elapsed}s`;
  batchState.results = results.map(r => ({ success: r?.success, index: r?.index }));
  saveBatchState(outputDir, batchState);

  const label = type.replace('batch-', '').charAt(0).toUpperCase() + type.replace('batch-', '').slice(1);
  console.log(`\n=== Batch ${label} Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Results: ${succeeded} succeeded, ${failed} failed, ${jobCount} total`);
  console.log(`Output: ${outputDir}`);

  if (failed > 0) {
    console.log(`\nFailed jobs:`);
    batchState.failed.forEach(f => console.log(`  [${f.index + 1}] ${f.error}`));
    console.log(`\nTo retry failed jobs: add --resume flag`);
  }

  return batchState;
}

// ---------------------------------------------------------------------------
// General generation result waiter (shared by multiple commands)
// ---------------------------------------------------------------------------

async function pollForHistoryResult(page, historyTab) {
  await page.waitForTimeout(10000);
  await historyTab.click();
  await page.waitForTimeout(3000);
}

export async function waitForGenerationResult(page, options, opts = {}) {
  const {
    selector = `${GENERATED_IMAGE_SELECTOR}, video`,
    screenshotName = 'result',
    label = 'generation',
    outputSubdir = 'output',
    defaultTimeout = 180000,
    isVideo = false,
    useHistoryPoll = false,
  } = opts;
  const timeout = options.timeout || defaultTimeout;
  console.log(`Waiting up to ${timeout / 1000}s for ${label} result...`);

  if (useHistoryPoll) {
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    if (await historyTab.count() > 0) {
      await pollForHistoryResult(page, historyTab);
    }
  }

  try {
    await page.waitForSelector(selector, { timeout, state: 'visible' });
  } catch {
    console.log(`Timeout waiting for ${label} result`);
  }

  await page.waitForTimeout(3000);
  await dismissAllModals(page);
  await debugScreenshot(page, screenshotName);

  if (options.wait !== false) {
    const baseOutput = options.output || getDefaultOutputDir(options);
    const outputDir = resolveOutputDir(baseOutput, options, outputSubdir);
    await downloadLatestResult(page, outputDir, true, options);
  }
}
