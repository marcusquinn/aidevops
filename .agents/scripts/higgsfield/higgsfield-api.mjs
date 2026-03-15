// higgsfield-api.mjs — Higgsfield Cloud API client (https://docs.higgsfield.ai)
// Separate credit pool from web UI. Uses REST API with async queue pattern.
// Auth: HF_API_KEY + HF_API_SECRET from credentials.sh
// Imported by playwright-automator.mjs.

import { readFileSync, existsSync } from 'fs';
import { join, extname, basename } from 'path';
import { homedir } from 'os';
import { writeFileSync } from 'fs';
import {
  getDefaultOutputDir,
  resolveOutputDir,
  safeJoin,
  sanitizePathSegment,
  writeJsonSidecar,
} from './higgsfield-common.mjs';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const API_BASE_URL = 'https://platform.higgsfield.ai';
const API_POLL_INTERVAL_MS = 2000;
const API_POLL_MAX_WAIT_MS = 10 * 60 * 1000; // 10 minutes max wait

// Map CLI model slugs to Higgsfield API model IDs.
// Verified 2026-02-10 by probing platform.higgsfield.ai.
// Web-UI-only models (no API): Nano Banana Pro, GPT Image, Flux Kontext, Seedream 4.5, Wan, Sora, Veo, Minimax Hailuo, Grok Imagine.
const API_MODEL_MAP = {
  // Text-to-image models (verified: 403 "Not enough credits" = exists)
  'soul':               'higgsfield-ai/soul/standard',
  'soul-reference':     'higgsfield-ai/soul/reference',
  'soul-character':     'higgsfield-ai/soul/character',
  'popcorn':            'higgsfield-ai/popcorn/auto',
  'popcorn-manual':     'higgsfield-ai/popcorn/manual',
  'seedream':           'bytedance/seedream/v4/text-to-image',
  'reve':               'reve/text-to-image',
  // Image-to-video models (verified: 422/400 = exists, needs image_url)
  'dop-standard':       'higgsfield-ai/dop/standard',
  'dop-lite':           'higgsfield-ai/dop/lite',
  'dop-turbo':          'higgsfield-ai/dop/turbo',
  'dop-standard-flf':   'higgsfield-ai/dop/standard/first-last-frame',
  'dop-lite-flf':       'higgsfield-ai/dop/lite/first-last-frame',
  'dop-turbo-flf':      'higgsfield-ai/dop/turbo/first-last-frame',
  'kling-3.0':          'kling-video/v3.0/pro/image-to-video',
  'kling-2.6':          'kling-video/v2.6/pro/image-to-video',
  'kling-2.1':          'kling-video/v2.1/pro/image-to-video',
  'kling-2.1-master':   'kling-video/v2.1/master/image-to-video',
  'seedance':           'bytedance/seedance/v1/pro/image-to-video',
  'seedance-lite':      'bytedance/seedance/v1/lite/image-to-video',
  // Image edit models
  'seedream-edit':      'bytedance/seedream/v4/edit',
};

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

export function loadApiCredentials() {
  const credFile = join(homedir(), '.config', 'aidevops', 'credentials.sh');
  if (!existsSync(credFile)) return null;
  const content = readFileSync(credFile, 'utf-8');
  const apiKey = content.match(/HF_API_KEY="([^"]+)"/)?.[1];
  const apiSecret = content.match(/HF_API_SECRET="([^"]+)"/)?.[1];
  if (!apiKey || !apiSecret) return null;
  return { apiKey, apiSecret };
}

export function requireApiCredentials() {
  const creds = loadApiCredentials();
  if (!creds) throw new Error('API credentials not configured (HF_API_KEY/HF_API_SECRET in credentials.sh)');
  return creds;
}

// ---------------------------------------------------------------------------
// Core HTTP helpers
// ---------------------------------------------------------------------------

export async function apiExecuteFetch(url, fetchOpts, timeout) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  fetchOpts.signal = controller.signal;
  try {
    const response = await fetch(url, fetchOpts);
    clearTimeout(timer);
    return response;
  } catch (err) {
    clearTimeout(timer);
    if (err.name === 'AbortError') throw new Error(`API request timed out after ${timeout}ms`);
    throw err;
  }
}

export function parseApiErrorDetail(text) {
  try { return JSON.parse(text).detail || JSON.parse(text).message || text; } catch {}
  return text;
}

export async function apiRequest(method, path, { body, apiKey, apiSecret, timeout = 90000 } = {}) {
  const url = path.startsWith('http') ? path : `${API_BASE_URL}${path.startsWith('/') ? '' : '/'}${path}`;
  const headers = {
    'Authorization': `Key ${apiKey}:${apiSecret}`,
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': 'higgsfield-automator/1.0',
  };
  const fetchOpts = { method, headers };
  if (body) fetchOpts.body = JSON.stringify(body);

  const retryableCodes = new Set([408, 429, 500, 502, 503, 504]);
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await apiExecuteFetch(url, fetchOpts, timeout);

      if (!response.ok) {
        const text = await response.text().catch(() => '');
        if (retryableCodes.has(response.status) && attempt < 2) {
          const delay = 200 * Math.pow(2, attempt);
          console.log(`[api] Retrying ${method} ${path} (${response.status}) in ${delay}ms...`);
          await new Promise(r => setTimeout(r, delay));
          continue;
        }
        throw new Error(`API ${response.status}: ${parseApiErrorDetail(text)}`);
      }
      return await response.json();
    } catch (err) {
      lastError = err;
      if (err.message.startsWith('API request timed out') || err.message.startsWith('API ')) throw err;
      if (attempt < 2) {
        await new Promise(r => setTimeout(r, 200 * Math.pow(2, attempt)));
        continue;
      }
      throw err;
    }
  }
  throw lastError;
}

// ---------------------------------------------------------------------------
// File upload / download
// ---------------------------------------------------------------------------

export async function apiUploadFile(filePath, creds) {
  const { apiKey, apiSecret } = creds;
  const ext = extname(filePath).toLowerCase();
  const mimeMap = {
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.webp': 'image/webp', '.gif': 'image/gif', '.mp4': 'video/mp4', '.mov': 'video/quicktime',
  };
  const contentType = mimeMap[ext] || 'application/octet-stream';

  const { public_url, upload_url } = await apiRequest('POST', '/files/generate-upload-url', {
    body: { content_type: contentType },
    apiKey, apiSecret,
  });

  const fileData = readFileSync(filePath);
  const uploadResp = await fetch(upload_url, {
    method: 'PUT',
    body: fileData,
    headers: { 'Content-Type': contentType },
  });
  if (!uploadResp.ok) {
    throw new Error(`File upload failed: ${uploadResp.status} ${await uploadResp.text().catch(() => '')}`);
  }

  console.log(`[api] Uploaded ${basename(filePath)} (${(fileData.length / 1024).toFixed(0)}KB) -> ${public_url}`);
  return public_url;
}

export async function apiDownloadFile(url, outputPath) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Download failed: ${response.status}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  writeFileSync(outputPath, buffer);
  return buffer.length;
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

export async function apiPollStatus(requestId, creds, { maxWait = API_POLL_MAX_WAIT_MS } = {}) {
  const { apiKey, apiSecret } = creds;
  const startTime = Date.now();
  let delay = API_POLL_INTERVAL_MS;

  while (Date.now() - startTime < maxWait) {
    const data = await apiRequest('GET', `/requests/${requestId}/status`, { apiKey, apiSecret });
    const status = data.status;

    if (status === 'completed') return data;
    if (status === 'failed') throw new Error(`Generation failed: ${data.error || 'unknown error'}`);
    if (status === 'nsfw') throw new Error('Content flagged as NSFW (credits refunded)');

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    process.stdout.write(`\r[api] Status: ${status} (${elapsed}s elapsed)...`);

    await new Promise(r => setTimeout(r, delay));
    delay = Math.min(delay + 1000, 5000);
  }
  throw new Error(`Generation timed out after ${maxWait / 1000}s`);
}

// ---------------------------------------------------------------------------
// Shared submit+poll helper
// ---------------------------------------------------------------------------

export function resolveApiModelId(slug, commandType) {
  if (!slug) return null;
  if (API_MODEL_MAP[slug]) return API_MODEL_MAP[slug];
  if (commandType === 'video' && API_MODEL_MAP[`${slug}-standard`]) return API_MODEL_MAP[`${slug}-standard`];
  return null;
}

export function logApiPrompt(prompt) {
  if (prompt) console.log(`[api] Prompt: "${prompt.substring(0, 80)}${prompt.length > 80 ? '...' : ''}"`);
}

export async function apiSubmitAndPoll(modelId, body, creds, options = {}) {
  if (options.dryRun) {
    console.log('[api] DRY RUN — would submit:', JSON.stringify(body, null, 2));
    return { dryRun: true };
  }
  const submitResp = await apiRequest('POST', `/${modelId}`, {
    body, apiKey: creds.apiKey, apiSecret: creds.apiSecret,
  });
  console.log(`[api] Request queued: ${submitResp.request_id}`);
  const result = await apiPollStatus(submitResp.request_id, creds);
  console.log(''); // Clear the status line
  return { ...result, requestId: submitResp.request_id };
}

// ---------------------------------------------------------------------------
// Result download helpers
// ---------------------------------------------------------------------------

export async function apiDownloadImages(result, { modelSlug, modelId, options, sidecarExtra = {} }) {
  const baseOutput = options.output || getDefaultOutputDir(options);
  const outputDir = resolveOutputDir(baseOutput, options, 'images');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
  const downloads = [];

  for (let i = 0; i < (result.images || []).length; i++) {
    const imgUrl = result.images[i].url;
    const suffix = result.images.length > 1 ? `_${i + 1}` : '';
    const filename = `hf_api_${modelSlug}_${timestamp}${suffix}.png`;
    const outputPath = safeJoin(outputDir, sanitizePathSegment(filename, 'api-image.png'));
    const size = await apiDownloadFile(imgUrl, outputPath);
    console.log(`[api] Downloaded: ${outputPath} (${(size / 1024).toFixed(0)}KB)`);
    writeJsonSidecar(outputPath, {
      source: 'higgsfield-cloud-api', model: modelId, modelSlug,
      requestId: result.requestId, imageUrl: imgUrl, ...sidecarExtra,
    }, options);
    downloads.push(outputPath);
  }
  return downloads;
}

export async function apiDownloadVideo(result, { modelSlug, modelId, options, sidecarExtra = {} }) {
  if (!result.video?.url) throw new Error('API returned completed status but no video URL');
  const baseOutput = options.output || getDefaultOutputDir(options);
  const outputDir = resolveOutputDir(baseOutput, options, 'videos');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
  const filename = `hf_api_${modelSlug}_${timestamp}.mp4`;
  const outputPath = safeJoin(outputDir, sanitizePathSegment(filename, 'api-video.mp4'));
  const size = await apiDownloadFile(result.video.url, outputPath);
  console.log(`[api] Downloaded: ${outputPath} (${(size / 1024 / 1024).toFixed(1)}MB)`);
  writeJsonSidecar(outputPath, {
    source: 'higgsfield-cloud-api', model: modelId, modelSlug,
    requestId: result.requestId, videoUrl: result.video.url, ...sidecarExtra,
  }, options);
  return outputPath;
}

// ---------------------------------------------------------------------------
// High-level API commands
// ---------------------------------------------------------------------------

export async function apiGenerateImage(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'soul';
  const modelId = resolveApiModelId(modelSlug, 'image');
  if (!modelId) {
    const imageModels = Object.keys(API_MODEL_MAP).filter(k =>
      !k.includes('dop') && !k.includes('kling') && !k.includes('seedance')
    );
    throw new Error(`No API model mapping for slug '${modelSlug}'. Available: ${imageModels.join(', ')}`);
  }
  if (!options.prompt) throw new Error('--prompt is required for image generation');

  const body = { prompt: options.prompt };
  if (options.aspect) body.aspect_ratio = options.aspect;
  if (options.quality) body.resolution = options.quality;
  if (options.seed !== undefined) body.seed = options.seed;

  console.log(`[api] Generating image via API: model=${modelId}`);
  logApiPrompt(options.prompt);

  const result = await apiSubmitAndPoll(modelId, body, creds, options);
  if (result.dryRun) return result;

  const downloads = await apiDownloadImages(result, {
    modelSlug, modelId, options,
    sidecarExtra: {
      prompt: options.prompt,
      aspectRatio: options.aspect || 'default',
      resolution: options.quality || 'default',
      seed: options.seed,
    },
  });
  console.log(`[api] Image generation complete: ${downloads.length} file(s)`);
  return { outputPaths: downloads, requestId: result.requestId };
}

export async function apiGenerateVideo(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'dop-standard';
  const modelId = resolveApiModelId(modelSlug, 'video');
  if (!modelId) {
    const videoModels = Object.keys(API_MODEL_MAP).filter(k =>
      k.includes('dop') || k.includes('kling') || k.includes('seedance')
    );
    throw new Error(`No API model mapping for video slug '${modelSlug}'. Available: ${videoModels.join(', ')}`);
  }

  let imageUrl = options.imageUrl;
  if (!imageUrl && options.imageFile) {
    console.log(`[api] Uploading source image: ${options.imageFile}`);
    imageUrl = await apiUploadFile(options.imageFile, creds);
  }
  if (!imageUrl) throw new Error('--image-file or --image-url is required for API video generation');

  const body = { image_url: imageUrl };
  if (options.prompt) body.prompt = options.prompt;
  if (options.duration) body.duration = parseInt(options.duration, 10);
  if (options.aspect) body.aspect_ratio = options.aspect;

  console.log(`[api] Generating video via API: model=${modelId}`);
  logApiPrompt(options.prompt);

  const result = await apiSubmitAndPoll(modelId, body, creds, options);
  if (result.dryRun) return result;

  const outputPath = await apiDownloadVideo(result, {
    modelSlug, modelId, options,
    sidecarExtra: {
      prompt: options.prompt, imageUrl,
      duration: options.duration, aspectRatio: options.aspect || 'default',
    },
  });
  console.log(`[api] Video generation complete`);
  return { outputPath, requestId: result.requestId };
}

export async function apiStatus() {
  const creds = loadApiCredentials();
  if (!creds) {
    console.log('[api] No API credentials configured');
    console.log('[api] Set HF_API_KEY and HF_API_SECRET in ~/.config/aidevops/credentials.sh');
    console.log('[api] Get keys from: https://cloud.higgsfield.ai/api-keys');
    return null;
  }

  console.log('[api] Checking API connectivity...');
  try {
    const testUrl = `${API_BASE_URL}/requests/00000000-0000-0000-0000-000000000000/status`;
    const response = await fetch(testUrl, {
      headers: {
        'Authorization': `Key ${creds.apiKey}:${creds.apiSecret}`,
        'Accept': 'application/json',
      },
    });
    if (response.status === 401 || response.status === 403) {
      console.log('[api] ERROR: Invalid API credentials (401/403)');
      return { authenticated: false };
    }
    console.log('[api] API credentials valid (authenticated)');
    console.log('[api] Note: API uses separate credit pool from web UI subscription');
    console.log('[api] Top up credits at: https://cloud.higgsfield.ai/credits');
    return { authenticated: true };
  } catch (err) {
    console.log(`[api] Connection error: ${err.message}`);
    return { authenticated: false, error: err.message };
  }
}
