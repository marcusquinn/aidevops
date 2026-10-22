// higgsfield-batch-video-matching.mjs — Match completed job sets to submitted video jobs
// and download the matched videos. Extracted from higgsfield-batch-video.mjs.

import {
  curlDownload,
  safeJoin,
  sanitizePathSegment,
} from './higgsfield-common.mjs';
import { buildDescriptiveFilename } from './higgsfield-output.mjs';

function scorePromptMatch(promptA, promptB) {
  let score = 0;
  const minLen = Math.min(promptA.length, promptB.length, 60);
  for (let c = 0; c < minLen; c++) {
    if (promptA[c] === promptB[c]) score++;
    else break;
  }
  return score;
}

function jobSetKey(jobSet) {
  return jobSet.id || jobSet.prompt;
}

function findBestPromptMatch(job, completedJobSets, matchedJobSetIds) {
  let bestMatch = null;
  let bestScore = 0;
  for (const jobSet of completedJobSets) {
    if (matchedJobSetIds.has(jobSetKey(jobSet))) continue;
    const score = scorePromptMatch(jobSet.prompt || '', job.promptPrefix || '');
    if (score >= 20 && score > bestScore) {
      bestMatch = jobSet;
      bestScore = score;
    }
  }
  return bestMatch;
}

function assignPromptMatches(submittedJobs, completedJobSets, results, matchedJobSetIds) {
  for (const job of submittedJobs) {
    if (results.has(job.sceneIndex)) continue;
    const bestMatch = findBestPromptMatch(job, completedJobSets, matchedJobSetIds);
    if (bestMatch) {
      matchedJobSetIds.add(jobSetKey(bestMatch));
      job._matchedJobSet = bestMatch;
      job._matchMethod = 'prompt';
    }
  }
}

function assignOrderFallbackMatches(submittedJobs, completedJobSets, results, matchedJobSetIds) {
  const unmatchedJobs = submittedJobs.filter(j => !results.has(j.sceneIndex) && !j._matchedJobSet);
  if (unmatchedJobs.length === 0) return;

  const unmatchedJobSets = completedJobSets.filter(js => !matchedJobSetIds.has(jobSetKey(js)));
  const reversedJobSets = [...unmatchedJobSets].reverse();

  const pairCount = Math.min(unmatchedJobs.length, reversedJobSets.length);
  for (let i = 0; i < pairCount; i++) {
    const job = unmatchedJobs[i];
    const jobSet = reversedJobSets[i];
    matchedJobSetIds.add(jobSetKey(jobSet));
    job._matchedJobSet = jobSet;
    job._matchMethod = 'order';
    console.log(`  Scene ${job.sceneIndex + 1}: order-based match (empty prompt fallback)`);
  }
}

export function matchJobSetsToSubmittedJobs(submittedJobs, completedJobSets, results) {
  const matchedJobSetIds = new Set();
  assignPromptMatches(submittedJobs, completedJobSets, results, matchedJobSetIds);
  assignOrderFallbackMatches(submittedJobs, completedJobSets, results, matchedJobSetIds);
}

function findCompletedJobWithUrl(jobSet) {
  for (const j of (jobSet.jobs || [])) {
    if (j.status === 'completed' && j.results?.raw?.url?.includes('cloudfront.net')) {
      return j;
    }
  }
  return null;
}

function downloadSingleMatchedVideo(job, bestMatch, matchMethod, outputDir, results) {
  const completedJob = findCompletedJobWithUrl(bestMatch);
  if (!completedJob) return;

  const videoUrl = completedJob.results.raw.url;
  const meta = { model: job.model, promptSnippet: job.promptPrefix };
  const filename = buildDescriptiveFilename(meta, `scene-${job.sceneIndex + 1}.mp4`, job.sceneIndex);
  const savePath = safeJoin(outputDir, sanitizePathSegment(filename, `scene-${job.sceneIndex + 1}.mp4`));

  try {
    const { httpCode, size } = curlDownload(videoUrl, savePath, { withHttpCode: true });
    if (httpCode === '200' && size > 10000) {
      console.log(`  Scene ${job.sceneIndex + 1}: downloaded (${(size / 1024 / 1024).toFixed(1)}MB) ${filename}`);
      console.log(`    Match method: ${matchMethod}, prompt: "${(bestMatch.prompt || '(empty)').substring(0, 60)}"`);
      results.set(job.sceneIndex, savePath);
    }
  } catch {
    /* download failures are reported by the poller's missing-scenes log */
  }
}

export function downloadMatchedVideos(submittedJobs, outputDir, results) {
  for (const job of submittedJobs) {
    if (results.has(job.sceneIndex)) continue;
    const bestMatch = job._matchedJobSet;
    if (!bestMatch) continue;
    const matchMethod = job._matchMethod || 'prompt';
    delete job._matchedJobSet;
    delete job._matchMethod;
    downloadSingleMatchedVideo(job, bestMatch, matchMethod, outputDir, results);
  }
}
