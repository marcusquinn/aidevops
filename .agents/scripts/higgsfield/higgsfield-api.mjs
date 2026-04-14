// higgsfield-api.mjs — High-level Higgsfield Cloud API commands.
// Wraps the low-level transport in higgsfield-api-client.mjs.
// Auth: HF_API_KEY + HF_API_SECRET from credentials.sh
// Imported by playwright-automator.mjs.

import {
  getDefaultOutputDir,
  resolveOutputDir,
  safeJoin,
  sanitizePathSegment,
  writeJsonSidecar,
} from './higgsfield-common.mjs';

import {
  API_BASE_URL,
  loadApiCredentials,
  requireApiCredentials,
  apiRequest,
  apiUploadFile,
  apiDownloadFile,
  apiPollStatus,
} from './higgsfield-api-client.mjs';

// Re-export low-level surface so existing callers (and tests) keep working.
export {
  API_BASE_URL,
  loadApiCredentials,
  requireApiCredentials,
  apiRequest,
  apiUploadFile,
  apiDownloadFile,
  apiPollStatus,
};
export {
  apiExecuteFetch,
  parseApiErrorDetail,
  API_POLL_INTERVAL_MS,
  API_POLL_MAX_WAIT_MS,
} from './higgsfield-api-client.mjs';

// ---------------------------------------------------------------------------
// Model mapping
// ---------------------------------------------------------------------------

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

const IMAGE_MODEL_KEYS = Object.keys(API_MODEL_MAP).filter(k =>
  !k.includes('dop') && !k.includes('kling') && !k.includes('seedance')
);
const VIDEO_MODEL_KEYS = Object.keys(API_MODEL_MAP).filter(k =>
  k.includes('dop') || k.includes('kling') || k.includes('seedance')
);

export function resolveApiModelId(slug, commandType) {
  if (!slug) return null;
  if (API_MODEL_MAP[slug]) return API_MODEL_MAP[slug];
  if (commandType === 'video' && API_MODEL_MAP[`${slug}-standard`]) return API_MODEL_MAP[`${slug}-standard`];
  return null;
}

export function logApiPrompt(prompt) {
  if (prompt) console.log(`[api] Prompt: "${prompt.substring(0, 80)}${prompt.length > 80 ? '...' : ''}"`);
}

// ---------------------------------------------------------------------------
// Shared submit+poll helper
// ---------------------------------------------------------------------------

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

function buildApiTimestamp() {
  return new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
}

export async function apiDownloadImages(result, { modelSlug, modelId, options, sidecarExtra = {} }) {
  const baseOutput = options.output || getDefaultOutputDir(options);
  const outputDir = resolveOutputDir(baseOutput, options, 'images');
  const timestamp = buildApiTimestamp();
  const downloads = [];
  const images = result.images || [];

  for (let i = 0; i < images.length; i++) {
    const imgUrl = images[i].url;
    const suffix = images.length > 1 ? `_${i + 1}` : '';
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
  const timestamp = buildApiTimestamp();
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

function buildImageApiBody(options) {
  const body = { prompt: options.prompt };
  if (options.aspect) body.aspect_ratio = options.aspect;
  if (options.quality) body.resolution = options.quality;
  if (options.seed !== undefined) body.seed = options.seed;
  return body;
}

export async function apiGenerateImage(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'soul';
  const modelId = resolveApiModelId(modelSlug, 'image');
  if (!modelId) {
    throw new Error(`No API model mapping for slug '${modelSlug}'. Available: ${IMAGE_MODEL_KEYS.join(', ')}`);
  }
  if (!options.prompt) throw new Error('--prompt is required for image generation');

  const body = buildImageApiBody(options);

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

async function resolveVideoSourceImage(options, creds) {
  if (options.imageUrl) return options.imageUrl;
  if (options.imageFile) {
    console.log(`[api] Uploading source image: ${options.imageFile}`);
    return apiUploadFile(options.imageFile, creds);
  }
  return null;
}

function buildVideoApiBody(options, imageUrl) {
  const body = { image_url: imageUrl };
  if (options.prompt) body.prompt = options.prompt;
  if (options.duration) body.duration = parseInt(options.duration, 10);
  if (options.aspect) body.aspect_ratio = options.aspect;
  return body;
}

export async function apiGenerateVideo(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'dop-standard';
  const modelId = resolveApiModelId(modelSlug, 'video');
  if (!modelId) {
    throw new Error(`No API model mapping for video slug '${modelSlug}'. Available: ${VIDEO_MODEL_KEYS.join(', ')}`);
  }

  const imageUrl = await resolveVideoSourceImage(options, creds);
  if (!imageUrl) throw new Error('--image-file or --image-url is required for API video generation');

  const body = buildVideoApiBody(options, imageUrl);

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

function logApiStatusUnauthenticated() {
  console.log('[api] No API credentials configured');
  console.log('[api] Set HF_API_KEY and HF_API_SECRET in ~/.config/aidevops/credentials.sh');
  console.log('[api] Get keys from: https://cloud.higgsfield.ai/api-keys');
}

function logApiStatusAuthenticated() {
  console.log('[api] API credentials valid (authenticated)');
  console.log('[api] Note: API uses separate credit pool from web UI subscription');
  console.log('[api] Top up credits at: https://cloud.higgsfield.ai/credits');
}

export async function apiStatus() {
  const creds = loadApiCredentials();
  if (!creds) {
    logApiStatusUnauthenticated();
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
    logApiStatusAuthenticated();
    return { authenticated: true };
  } catch (err) {
    console.log(`[api] Connection error: ${err.message}`);
    return { authenticated: false, error: err.message };
  }
}
