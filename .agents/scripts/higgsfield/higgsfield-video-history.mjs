// Video history observation: project API retrieval, status and polling progress.
// Download finalization and generation submission stay in their command modules.

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

export async function logVideoPollingProgress(page, state, { elapsedSec, wasProcessing, lastRefreshTime, historyTab }) {
  if (state.isProcessing) {
    console.log(`  ${elapsedSec}s: processing (${state.currentCount} items)...`);
    return { wasProcessing: true, lastRefreshTime };
  }
  if (wasProcessing && !state.matchesOurPrompt && !state.isNewItem) {
    if (Date.now() - lastRefreshTime > 30000) {
      console.log(`  ${elapsedSec}s: processing ended, refreshing History...`);
      const settingsTab = page.locator('[role="tab"]:has-text("Settings")');
      if (await settingsTab.count() > 0) {
        await settingsTab.click({ force: true });
        await page.waitForTimeout(1000);
      }
      if (await historyTab.count() > 0) {
        await historyTab.click({ force: true });
        await page.waitForTimeout(2000);
      }
      return { wasProcessing, lastRefreshTime: Date.now() };
    }
    console.log(`  ${elapsedSec}s: waiting for result (${state.currentCount} items)...`);
    return { wasProcessing, lastRefreshTime };
  }
  console.log(`  ${elapsedSec}s: waiting (${state.currentCount} items, prompt: "${state.promptText?.substring(0, 40)}...")...`);
  return { wasProcessing, lastRefreshTime };
}
