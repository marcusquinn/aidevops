#!/usr/bin/env node
// Higgsfield UI Automator - Playwright-based browser automation
// Uses the Higgsfield web UI to generate images/videos using subscription credits
// Part of AI DevOps Framework

import { chromium } from 'playwright';
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync, statSync, copyFileSync, symlinkSync, unlinkSync } from 'fs';
import { join, basename, extname, dirname } from 'path';
import { homedir } from 'os';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';
import { createHash } from 'crypto';

// Constants
const BASE_URL = 'https://higgsfield.ai';
const STATE_DIR = join(homedir(), '.aidevops', '.agent-workspace', 'work', 'higgsfield');
const STATE_FILE = join(STATE_DIR, 'auth-state.json');
const ROUTES_CACHE = join(STATE_DIR, 'routes-cache.json');
const DISCOVERY_TIMESTAMP = join(STATE_DIR, 'last-discovery.txt');
const DOWNLOAD_DIR = join(homedir(), 'Downloads');
const DISCOVERY_MAX_AGE_HOURS = 24;
const CREDITS_CACHE_FILE = join(STATE_DIR, 'credits-cache.json');
const CREDITS_CACHE_MAX_AGE_MS = 10 * 60 * 1000; // 10 minutes

// Credit cost estimates per operation type (approximate, varies by model/settings)
const CREDIT_COSTS = {
  image: 2,           // 1-2 credits per image
  video: 20,          // 10-40 credits depending on duration/model
  lipsync: 10,        // 5-20 credits depending on model
  upscale: 2,         // 1-4 credits depending on scale factor
  edit: 2,            // 1-3 credits for inpaint/edit
  app: 5,             // 2-10 credits for apps (varies widely)
  'cinema-studio': 20,
  'motion-control': 20,
  'mixed-media': 10,
  'motion-preset': 10,
  'video-edit': 15,
  storyboard: 10,
  'vibe-motion': 5,
  influencer: 5,
  character: 2,
  feature: 5,
  chain: 5,           // depends on target action
  'seed-bracket': 10, // multiple images
  pipeline: 60,       // multi-step: images + videos + lipsync
};

// Commands that don't consume credits (read-only / navigation)
const FREE_COMMANDS = new Set([
  'login', 'discover', 'credits', 'screenshot', 'download',
  'assets', 'manage-assets', 'asset', 'test', 'self-test',
  'api-status',
]);

// Unlimited model mapping: subscription model name -> { slug, type, priority }
// Priority determines preference order when multiple unlimited models are available.
// Lower number = higher preference. Ranked by SOTA quality for product/commercial photography:
//   - Nano Banana Pro: Gemini 3.0 reasoning engine, native 4K, best text rendering, <10s (Higgsfield flagship)
//   - GPT Image: Strong photorealism, text rendering, product shots (OpenAI GPT-4o)
//   - Seedream 4.5: Excellent photorealism and fine detail (ByteDance latest)
//   - FLUX.2 Pro: Strong photorealism, great commercial/product imagery (Black Forest Labs)
//   - Flux Kontext: Context-aware editing, product placement (Black Forest Labs)
//   - Reve: Good photorealism, newer model
//   - Soul: Higgsfield reliable all-rounder
//   - Kling O1 Image: Decent, primarily a video company's image offering
//   - Seedream 4.0: Older generation, still capable
//   - Nano Banana: Standard tier (non-Pro)
//   - Z Image: Less established
//   - Popcorn: Stylized/creative, less suited for photorealistic product shots
const UNLIMITED_MODELS = {
  // Image models (type: 'image') — sorted by SOTA quality for product/commercial use
  'Nano Banana Pro365 Unlimited':       { slug: 'nano-banana-pro', type: 'image',        priority: 1 },
  'GPT Image365 Unlimited':             { slug: 'gpt',           type: 'image',          priority: 2 },
  'Seedream 4.5365 Unlimited':          { slug: 'seedream-4-5',  type: 'image',          priority: 3 },
  'FLUX.2 Pro365 Unlimited':            { slug: 'flux',          type: 'image',          priority: 4 },
  'Flux Kontext365 Unlimited':          { slug: 'kontext',       type: 'image',          priority: 5 },
  'Reve365 Unlimited':                  { slug: 'reve',          type: 'image',          priority: 6 },
  'Higgsfield Soul365 Unlimited':       { slug: 'soul',          type: 'image',          priority: 7 },
  'Kling O1 Image365 Unlimited':        { slug: 'kling_o1',      type: 'image',          priority: 8 },
  'Seedream 4.0365 Unlimited':          { slug: 'seedream',      type: 'image',          priority: 9 },
  'Nano Banana365 Unlimited':           { slug: 'nano_banana',   type: 'image',          priority: 10 },
  'Z Image365 Unlimited':               { slug: 'z_image',       type: 'image',          priority: 11 },
  'Higgsfield Popcorn365 Unlimited':    { slug: 'popcorn',       type: 'image',          priority: 12 },

  // Video models (type: 'video') — Kling 2.6 is latest with best quality/speed balance
  'Kling 2.6 Video Unlimited':          { slug: 'kling-2.6',     type: 'video',          priority: 1 },
  'Kling O1 Video Unlimited':           { slug: 'kling-o1',      type: 'video',          priority: 2 },
  'Kling 2.5 Turbo Unlimited':          { slug: 'kling-2.5',     type: 'video',          priority: 3 },

  // Video edit models (type: 'video-edit')
  'Kling O1 Video Edit Unlimited':      { slug: 'kling-o1',      type: 'video-edit',     priority: 1 },

  // Motion control models (type: 'motion-control')
  'Kling 2.6 Motion Control Unlimited': { slug: 'kling-2.6',     type: 'motion-control', priority: 1 },

  // App models (type: 'app')
  'Higgsfield Face Swap365 Unlimited':  { slug: 'face_swap',     type: 'app',            priority: 1 },
};

// Reverse lookup: CLI slug -> set of unlimited model names (for credit cost estimation)
const UNLIMITED_SLUGS = new Map();
for (const [name, info] of Object.entries(UNLIMITED_MODELS)) {
  const key = `${info.type}:${info.slug}`;
  if (!UNLIMITED_SLUGS.has(key)) UNLIMITED_SLUGS.set(key, []);
  UNLIMITED_SLUGS.get(key).push(name);
}

// Get the best unlimited model for a given command type.
// Returns { slug, name } or null if no unlimited model is available for that type.
function getUnlimitedModelForCommand(commandType) {
  const cache = getCachedCredits();
  if (!cache || !cache.unlimitedModels || cache.unlimitedModels.length === 0) return null;

  // Build set of active unlimited model names from cache
  const activeNames = new Set(cache.unlimitedModels.map(m => m.model));

  // Find all unlimited models matching the requested type that are active
  const candidates = Object.entries(UNLIMITED_MODELS)
    .filter(([name, info]) => info.type === commandType && activeNames.has(name))
    .sort((a, b) => a[1].priority - b[1].priority);

  if (candidates.length === 0) return null;

  const [name, info] = candidates[0];
  return { slug: info.slug, name, type: info.type };
}

// Check if a specific model slug is unlimited for a given command type
function isUnlimitedModel(slug, commandType) {
  const key = `${commandType}:${slug}`;
  if (!UNLIMITED_SLUGS.has(key)) return false;

  const cache = getCachedCredits();
  if (!cache || !cache.unlimitedModels) return false;

  const activeNames = new Set(cache.unlimitedModels.map(m => m.model));
  return UNLIMITED_SLUGS.get(key).some(name => activeNames.has(name));
}

// Ensure state directory exists
if (!existsSync(STATE_DIR)) {
  mkdirSync(STATE_DIR, { recursive: true });
}

// --- Retry wrapper with exponential backoff ---
async function withRetry(fn, { maxRetries = 2, baseDelay = 3000, label = 'operation' } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      const msg = error.message || String(error);

      // Don't retry on non-transient errors
      if (msg.includes('unsupported content') || msg.includes('content policy') ||
          msg.includes('No assets found') || msg.includes('not found') ||
          msg.includes('CREDIT_GUARD')) {
        throw error;
      }

      if (attempt < maxRetries) {
        const delay = baseDelay * Math.pow(2, attempt);
        console.log(`[retry] ${label} failed (attempt ${attempt + 1}/${maxRetries + 1}): ${msg}`);
        console.log(`[retry] Waiting ${delay / 1000}s before retry...`);
        await new Promise(resolve => setTimeout(resolve, delay));
      }
    }
  }
  throw lastError;
}

// --- Credit guard: check available credits before expensive operations ---
function getCachedCredits() {
  try {
    if (existsSync(CREDITS_CACHE_FILE)) {
      const cache = JSON.parse(readFileSync(CREDITS_CACHE_FILE, 'utf-8'));
      const age = Date.now() - (cache.timestamp || 0);
      if (age < CREDITS_CACHE_MAX_AGE_MS) {
        return cache;
      }
    }
  } catch { /* ignore corrupt cache */ }
  return null;
}

function saveCreditCache(creditInfo) {
  try {
    writeFileSync(CREDITS_CACHE_FILE, JSON.stringify({
      ...creditInfo,
      timestamp: Date.now(),
    }));
  } catch { /* ignore write errors */ }
}

function estimateCreditCost(command, options = {}) {
  // Check if the selected (or auto-selected) model is unlimited (zero credit cost)
  const typeMap = {
    image: 'image', video: 'video', lipsync: 'video',
    'video-edit': 'video-edit', 'motion-control': 'motion-control',
    'cinema-studio': 'video', cinema: 'video', app: 'app',
    'seed-bracket': 'image',
  };
  const modelType = typeMap[command] || command;
  const model = options.model;
  if (model) {
    if (isUnlimitedModel(model, modelType)) return 0;
  } else if (options.preferUnlimited !== false) {
    // No explicit model — check if auto-selection would pick an unlimited model
    const unlimited = getUnlimitedModelForCommand(modelType);
    if (unlimited) return 0;
  }

  let cost = CREDIT_COSTS[command] || 5;

  // Adjust for known cost multipliers
  if (command === 'image' && options.batch) cost *= parseInt(options.batch, 10) || 1;
  if (command === 'video' && options.duration) {
    const dur = parseInt(options.duration, 10);
    if (dur >= 10) cost = 30;
    if (dur >= 15) cost = 40;
  }
  if (command === 'seed-bracket' && options.seedRange) {
    const parts = options.seedRange.split(/[-,]/);
    cost = Math.max(parts.length, 2) * 2;
  }

  return cost;
}

function checkCreditGuard(command, options = {}) {
  if (FREE_COMMANDS.has(command)) return; // no cost
  if (options.dryRun) return; // dry run doesn't generate

  const cached = getCachedCredits();
  if (!cached) return; // no cache = can't check, proceed optimistically

  // Skip guard if using an unlimited model
  const estimated = estimateCreditCost(command, options);
  if (estimated === 0) {
    console.log(`[credits] Using unlimited model — no credit cost`);
    return;
  }

  const remaining = parseInt(cached.remaining, 10);
  if (isNaN(remaining)) return;

  if (remaining < estimated) {
    throw new Error(
      `CREDIT_GUARD: Insufficient credits. Need ~${estimated}, have ${remaining}. ` +
      `Run 'credits' to refresh, or use --force to override.`
    );
  }

  if (remaining < estimated * 3) {
    console.log(`[credits] Warning: Low credits. ~${estimated} needed, ${remaining} remaining.`);
  }
}

// Load credentials from credentials.sh
function loadCredentials() {
  const credFile = join(homedir(), '.config', 'aidevops', 'credentials.sh');
  if (!existsSync(credFile)) {
    console.error('ERROR: Credentials file not found at', credFile);
    process.exit(1);
  }
  const content = readFileSync(credFile, 'utf-8');
  const user = content.match(/HIGGSFIELD_USER="([^"]+)"/)?.[1];
  const pass = content.match(/HIGGSFIELD_PASS="([^"]+)"/)?.[1];
  if (!user || !pass) {
    console.error('ERROR: HIGGSFIELD_USER or HIGGSFIELD_PASS not found in credentials.sh');
    process.exit(1);
  }
  return { user, pass };
}

// --- Higgsfield Cloud API client (https://docs.higgsfield.ai) ---
// Separate credit pool from web UI. Uses REST API with async queue pattern.
// Auth: HF_API_KEY + HF_API_SECRET from credentials.sh
const API_BASE_URL = 'https://platform.higgsfield.ai';
const API_POLL_INTERVAL_MS = 2000;
const API_POLL_MAX_WAIT_MS = 10 * 60 * 1000; // 10 minutes max wait

// Map CLI model slugs to Higgsfield API model IDs.
// Discovered from docs + cloud dashboard model gallery.
// Not all web UI models have API equivalents — only those listed here.
// Verified 2026-02-10 by probing platform.higgsfield.ai (404 = not found, else exists).
// Web-UI-only models (no API): Nano Banana Pro, GPT Image, Flux Kontext, Seedream 4.5, Wan, Sora, Veo, Minimax Hailuo, Grok Video.
const API_MODEL_MAP = {
  // Text-to-image models (verified: 403 "Not enough credits" = exists)
  'soul':           'higgsfield-ai/soul/standard',
  'soul-reference': 'higgsfield-ai/soul/reference',
  'soul-character': 'higgsfield-ai/soul/character',
  'popcorn':        'higgsfield-ai/popcorn/auto',
  'popcorn-manual': 'higgsfield-ai/popcorn/manual',
  'seedream':       'bytedance/seedream/v4/text-to-image',
  'reve':           'reve/text-to-image',
  // Image-to-video models (verified: 422/400 = exists, needs image_url)
  'dop-standard':   'higgsfield-ai/dop/standard',
  'dop-lite':       'higgsfield-ai/dop/lite',
  'dop-turbo':      'higgsfield-ai/dop/turbo',
  'dop-standard-flf': 'higgsfield-ai/dop/standard/first-last-frame',
  'dop-lite-flf':   'higgsfield-ai/dop/lite/first-last-frame',
  'dop-turbo-flf':  'higgsfield-ai/dop/turbo/first-last-frame',
  'kling-3.0':      'kling-video/v3.0/pro/image-to-video',
  'kling-2.6':      'kling-video/v2.6/pro/image-to-video',
  'kling-2.1':      'kling-video/v2.1/pro/image-to-video',
  'kling-2.1-master': 'kling-video/v2.1/master/image-to-video',
  'seedance':       'bytedance/seedance/v1/pro/image-to-video',
  'seedance-lite':  'bytedance/seedance/v1/lite/image-to-video',
  // Image edit models
  'seedream-edit':  'bytedance/seedream/v4/edit',
};

// Load API credentials from credentials.sh (HF_API_KEY + HF_API_SECRET)
function loadApiCredentials() {
  const credFile = join(homedir(), '.config', 'aidevops', 'credentials.sh');
  if (!existsSync(credFile)) return null;
  const content = readFileSync(credFile, 'utf-8');
  const apiKey = content.match(/HF_API_KEY="([^"]+)"/)?.[1];
  const apiSecret = content.match(/HF_API_SECRET="([^"]+)"/)?.[1];
  if (!apiKey || !apiSecret) return null;
  return { apiKey, apiSecret };
}

// Make an authenticated API request
async function apiRequest(method, path, { body, apiKey, apiSecret, timeout = 90000 } = {}) {
  const url = path.startsWith('http') ? path : `${API_BASE_URL}${path.startsWith('/') ? '' : '/'}${path}`;
  const headers = {
    'Authorization': `Key ${apiKey}:${apiSecret}`,
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': 'higgsfield-automator/1.0',
  };
  const fetchOpts = { method, headers };
  if (body) fetchOpts.body = JSON.stringify(body);

  // Retry on transient errors (matching Python SDK: 408, 429, 500, 502, 503, 504)
  const retryableCodes = new Set([408, 429, 500, 502, 503, 504]);
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeout);
      fetchOpts.signal = controller.signal;
      const response = await fetch(url, fetchOpts);
      clearTimeout(timer);

      if (!response.ok) {
        const text = await response.text().catch(() => '');
        if (retryableCodes.has(response.status) && attempt < 2) {
          const delay = 200 * Math.pow(2, attempt);
          console.log(`[api] Retrying ${method} ${path} (${response.status}) in ${delay}ms...`);
          await new Promise(r => setTimeout(r, delay));
          continue;
        }
        let detail = text;
        try { detail = JSON.parse(text).detail || JSON.parse(text).message || text; } catch {}
        throw new Error(`API ${response.status}: ${detail}`);
      }
      return await response.json();
    } catch (err) {
      lastError = err;
      if (err.name === 'AbortError') throw new Error(`API request timed out after ${timeout}ms`);
      if (attempt < 2 && !err.message.startsWith('API ')) {
        await new Promise(r => setTimeout(r, 200 * Math.pow(2, attempt)));
        continue;
      }
      throw err;
    }
  }
  throw lastError;
}

// Upload a local file to Higgsfield's CDN via pre-signed URL.
// Returns the public URL for use in API requests.
async function apiUploadFile(filePath, creds) {
  const { apiKey, apiSecret } = creds;
  const ext = extname(filePath).toLowerCase();
  const mimeMap = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif', '.mp4': 'video/mp4', '.mov': 'video/quicktime' };
  const contentType = mimeMap[ext] || 'application/octet-stream';

  // Get pre-signed upload URL
  const { public_url, upload_url } = await apiRequest('POST', '/files/generate-upload-url', {
    body: { content_type: contentType },
    apiKey, apiSecret,
  });

  // Upload the file data
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

// Poll for request completion. Returns the final response JSON.
async function apiPollStatus(requestId, creds, { maxWait = API_POLL_MAX_WAIT_MS } = {}) {
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
    // Gradual backoff: 2s -> 3s -> 4s -> 5s (cap)
    delay = Math.min(delay + 1000, 5000);
  }
  throw new Error(`Generation timed out after ${maxWait / 1000}s`);
}

// Download a file from URL to local path
async function apiDownloadFile(url, outputPath) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Download failed: ${response.status}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  writeFileSync(outputPath, buffer);
  return buffer.length;
}

// Resolve the API model ID from a CLI slug. Returns null if no API mapping exists.
function resolveApiModelId(slug, commandType) {
  if (!slug) return null;
  // Direct match
  if (API_MODEL_MAP[slug]) return API_MODEL_MAP[slug];
  // Try with command type prefix (e.g., 'dop' -> 'dop-standard')
  if (commandType === 'video' && API_MODEL_MAP[`${slug}-standard`]) return API_MODEL_MAP[`${slug}-standard`];
  return null;
}

// Submit an API generation request, poll for completion, return result.
// Shared by apiGenerateImage and apiGenerateVideo to reduce complexity.
async function apiSubmitAndPoll(modelId, body, creds, options = {}) {
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

// Download API result images and write sidecar metadata.
async function apiDownloadImages(result, { modelSlug, modelId, options, sidecarExtra = {} }) {
  const baseOutput = options.output || DOWNLOAD_DIR;
  const outputDir = resolveOutputDir(baseOutput, options, 'images');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
  const downloads = [];

  for (let i = 0; i < (result.images || []).length; i++) {
    const imgUrl = result.images[i].url;
    const suffix = result.images.length > 1 ? `_${i + 1}` : '';
    const filename = `hf_api_${modelSlug}_${timestamp}${suffix}.png`;
    const outputPath = join(outputDir, filename);
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

// Download API result video and write sidecar metadata.
async function apiDownloadVideo(result, { modelSlug, modelId, options, sidecarExtra = {} }) {
  if (!result.video?.url) throw new Error('API returned completed status but no video URL');
  const baseOutput = options.output || DOWNLOAD_DIR;
  const outputDir = resolveOutputDir(baseOutput, options, 'videos');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
  const filename = `hf_api_${modelSlug}_${timestamp}.mp4`;
  const outputPath = join(outputDir, filename);
  const size = await apiDownloadFile(result.video.url, outputPath);
  console.log(`[api] Downloaded: ${outputPath} (${(size / 1024 / 1024).toFixed(1)}MB)`);
  writeJsonSidecar(outputPath, {
    source: 'higgsfield-cloud-api', model: modelId, modelSlug,
    requestId: result.requestId, videoUrl: result.video.url, ...sidecarExtra,
  }, options);
  return outputPath;
}

// Validate and return API credentials, throwing if missing.
function requireApiCredentials() {
  const creds = loadApiCredentials();
  if (!creds) throw new Error('API credentials not configured (HF_API_KEY/HF_API_SECRET in credentials.sh)');
  return creds;
}

// Log a truncated prompt for API operations.
function logApiPrompt(prompt) {
  if (prompt) console.log(`[api] Prompt: "${prompt.substring(0, 80)}${prompt.length > 80 ? '...' : ''}"`);
}

// Generate an image via the Higgsfield Cloud API.
async function apiGenerateImage(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'soul';
  const modelId = resolveApiModelId(modelSlug, 'image');
  if (!modelId) throw new Error(`No API model mapping for slug '${modelSlug}'. Available: ${Object.keys(API_MODEL_MAP).filter(k => !k.includes('dop') && !k.includes('kling') && !k.includes('seedance')).join(', ')}`);
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
    sidecarExtra: { prompt: options.prompt, aspectRatio: options.aspect || 'default', resolution: options.quality || 'default', seed: options.seed },
  });
  console.log(`[api] Image generation complete: ${downloads.length} file(s)`);
  return { outputPaths: downloads, requestId: result.requestId };
}

// Generate a video via the Higgsfield Cloud API (image-to-video).
async function apiGenerateVideo(options = {}) {
  const creds = requireApiCredentials();
  const modelSlug = options.model || 'dop-standard';
  const modelId = resolveApiModelId(modelSlug, 'video');
  if (!modelId) throw new Error(`No API model mapping for video slug '${modelSlug}'. Available: ${Object.keys(API_MODEL_MAP).filter(k => k.includes('dop') || k.includes('kling') || k.includes('seedance')).join(', ')}`);

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
    sidecarExtra: { prompt: options.prompt, imageUrl, duration: options.duration, aspectRatio: options.aspect || 'default' },
  });
  console.log(`[api] Video generation complete`);
  return { outputPath, requestId: result.requestId };
}

// Check API account status (credits, connectivity)
async function apiStatus() {
  const creds = loadApiCredentials();
  if (!creds) {
    console.log('[api] No API credentials configured');
    console.log('[api] Set HF_API_KEY and HF_API_SECRET in ~/.config/aidevops/credentials.sh');
    console.log('[api] Get keys from: https://cloud.higgsfield.ai/api-keys');
    return null;
  }

  console.log('[api] Checking API connectivity...');
  try {
    // Try a lightweight request to verify auth — submit a dummy and immediately check
    // Actually, just verify we can reach the status endpoint (will 404 but auth is checked)
    const testUrl = `${API_BASE_URL}/requests/00000000-0000-0000-0000-000000000000/status`;
    const response = await fetch(testUrl, {
      headers: {
        'Authorization': `Key ${creds.apiKey}:${creds.apiSecret}`,
        'Accept': 'application/json',
      },
    });
    // 404 = auth works, endpoint reached. 401/403 = bad credentials.
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

// Parse CLI arguments
// Declarative flag definitions: [cliFlag, optionKey, type, alias?]
// Types: 'string' (takes next arg), 'int' (parseInt next arg), 'true' (boolean true),
//        'false:key' (sets key to false), 'compound' (custom multi-set logic)
const FLAG_DEFS = [
  // Generation flags
  ['--prompt',           'prompt',           'string', '-p'],
  ['--model',            'model',            'string', '-m'],
  ['--aspect',           'aspect',           'string', '-a'],
  ['--duration',         'duration',         'string', '-d'],
  ['--quality',          'quality',          'string', '-q'],
  ['--batch',            'batch',            'int',    '-b'],
  ['--seed',             'seed',             'int'          ],
  ['--seed-range',       'seedRange',        'string'       ],
  ['--brief',            'brief',            'string'       ],
  ['--scenes',           'scenes',           'int'          ],
  ['--preset',           'preset',           'string', '-s'],
  ['--effect',           'effect',           'string'       ],
  ['--camera',           'camera',           'string'       ],
  ['--lens',             'lens',             'string'       ],
  // Input/output flags
  ['--output',           'output',           'string', '-o'],
  ['--image-url',        'imageUrl',         'string', '-i'],
  ['--image-file',       'imageFile',        'string'       ],
  ['--image-file2',      'imageFile2',       'string'       ],
  ['--video-file',       'videoFile',        'string'       ],
  ['--motion-ref',       'motionRef',        'string'       ],
  ['--character-image',  'characterImage',   'string'       ],
  ['--dialogue',         'dialogue',         'string'       ],
  // Asset/chain flags
  ['--asset-action',     'assetAction',      'string'       ],
  ['--asset-type',       'assetType',        'string'       ],
  ['--asset-index',      'assetIndex',       'int'          ],
  ['--chain-action',     'chainAction',      'string'       ],
  ['--filter',           'filter',           'string'       ],
  ['--tab',              'tab',              'string'       ],
  ['--feature',          'feature',          'string'       ],
  ['--subtype',          'subtype',          'string'       ],
  ['--project',          'project',          'string'       ],
  ['--limit',            'limit',            'int'          ],
  ['--timeout',          'timeout',          'int'          ],
  // Boolean flags
  ['--headed',           'headed',           'true'         ],
  ['--headless',         'headless',         'true'         ],
  ['--wait',             'wait',             'true'         ],
  ['--unlimited',        'unlimited',        'true'         ],
  ['--force',            'force',            'true'         ],
  ['--dry-run',          'dryRun',           'true'         ],
  ['--no-retry',         'noRetry',          'true'         ],
  ['--no-sidecar',       'noSidecar',        'true'         ],
  ['--no-dedup',         'noDedup',          'true'         ],
  ['--api',              'useApi',           'true'         ],
  // Negation flags (set a key to false)
  ['--no-enhance',       'enhance',          'false'        ],
  ['--no-sound',         'sound',            'false'        ],
  ['--no-prefer-unlimited', 'preferUnlimited', 'false'     ],
  // Positive boolean flags that set true
  ['--enhance',          'enhance',          'true'         ],
  ['--sound',            'sound',            'true'         ],
  ['--prefer-unlimited', 'preferUnlimited',  'true'         ],
  // Compound flags (set multiple keys)
  ['--api-only',         null,               'compound'     ],
];

// Build lookup maps from FLAG_DEFS for O(1) flag resolution
const FLAG_MAP = new Map();
for (const [flag, key, type, alias] of FLAG_DEFS) {
  FLAG_MAP.set(flag, { key, type });
  if (alias) FLAG_MAP.set(alias, { key, type });
}

function parseArgs() {
  const args = process.argv.slice(2);
  const command = args[0];
  const options = {};

  for (let i = 1; i < args.length; i++) {
    const def = FLAG_MAP.get(args[i]);
    if (!def) continue;

    if (def.type === 'string') {
      options[def.key] = args[++i];
    } else if (def.type === 'int') {
      options[def.key] = parseInt(args[++i], 10);
    } else if (def.type === 'true') {
      options[def.key] = true;
    } else if (def.type === 'false') {
      options[def.key] = false;
    } else if (def.type === 'compound') {
      // --api-only sets both useApi and apiOnly
      if (args[i] === '--api-only') {
        options.useApi = true;
        options.apiOnly = true;
      }
    }
  }

  return { command, options };
}

// Launch browser with persistent context
async function launchBrowser(options = {}) {
  const headless = options.headless !== undefined ? options.headless :
                   options.headed ? false : true;

  const launchOptions = {
    headless,
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-sandbox',
    ],
    viewport: { width: 1440, height: 900 },
  };

  // Use persistent context if auth state exists
  if (existsSync(STATE_FILE)) {
    const browser = await chromium.launch(launchOptions);
    const context = await browser.newContext({
      storageState: STATE_FILE,
      viewport: { width: 1440, height: 900 },
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    });
    const page = await context.newPage();
    return { browser, context, page };
  }

  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  });
  const page = await context.newPage();
  return { browser, context, page };
}

// Check if site discovery is needed (stale or missing cache)
function discoveryNeeded() {
  if (!existsSync(DISCOVERY_TIMESTAMP)) return true;
  try {
    const lastRun = parseInt(readFileSync(DISCOVERY_TIMESTAMP, 'utf-8').trim(), 10);
    const ageHours = (Date.now() - lastRun) / (1000 * 60 * 60);
    return ageHours > DISCOVERY_MAX_AGE_HOURS;
  } catch {
    return true;
  }
}

// Run site discovery - crawl all nav links and cache routes + UI structure
async function runDiscovery(options = {}) {
  console.log('Running site discovery (checking for new/changed features)...');
  const { browser, context, page } = await launchBrowser({ ...options, headless: true });

  try {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    // Collect all internal links
    const links = await page.evaluate(() => {
      const allLinks = [...document.querySelectorAll('a[href]')];
      const map = {};
      allLinks.forEach(a => {
        const href = a.getAttribute('href');
        // Clean the text: strip "Your browser does not support the video." prefix
        let text = a.textContent?.trim()
          .replace(/Your browser does not support the video\.\s*/g, '')
          .replace(/\s+/g, ' ')
          .substring(0, 80) || '';
        if (href && href.startsWith('/') && !href.startsWith('//') && text) {
          if (!map[href]) map[href] = text;
        }
      });
      return map;
    });

    // Categorise routes
    const routes = { image: {}, video: {}, edit: {}, apps: {}, features: {}, account: {}, motions: {}, mixed_media: {}, other: {} };
    for (const [path, label] of Object.entries(links)) {
      if (path.startsWith('/image/'))                    routes.image[path] = label;
      else if (path.startsWith('/create/'))              routes.video[path] = label;
      else if (path.startsWith('/edit'))                 routes.edit[path] = label;
      else if (path.startsWith('/app/'))                 routes.apps[path] = label;
      else if (path.startsWith('/motion/'))              routes.motions[path] = label;
      else if (path.startsWith('/mixed-media-presets/')) routes.mixed_media[path] = label;
      else if (['/asset/all','/library/image','/profile','/pricing','/auth/'].some(p => path.startsWith(p)))
                                                         routes.account[path] = label;
      else if (['/cinema-studio','/vibe-motion','/lipsync-studio','/character',
                '/ai-influencer-studio','/upscale','/fashion-factory','/chat',
                '/ugc-factory','/photodump-studio','/storyboard-generator',
                '/nano-banana-pro','/seedream-4-5','/kling','/sora','/wan','/veo','/minimax',
               ].some(p => path.startsWith(p)))
                                                         routes.features[path] = label;
      else                                               routes.other[path] = label;
    }

    // Also snapshot the image page to capture current model options
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    const imageAria = await page.locator('body').ariaSnapshot();

    // Extract model selector options if visible
    const imageModels = await page.evaluate(() => {
      // Look for model selector buttons/dropdowns
      const modelBtns = [...document.querySelectorAll('button')].filter(b =>
        b.textContent?.match(/soul|nano|seedream|flux|gpt|wan|kontext/i)
      );
      return modelBtns.map(b => b.textContent?.trim().substring(0, 60));
    });

    // Diff against previous cache
    let changes = [];
    if (existsSync(ROUTES_CACHE)) {
      try {
        const prev = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
        const prevApps = new Set(Object.keys(prev.apps || {}));
        const prevImage = new Set(Object.keys(prev.image || {}));
        const prevFeatures = new Set(Object.keys(prev.features || {}));

        for (const path of Object.keys(routes.apps)) {
          if (!prevApps.has(path)) changes.push(`NEW APP: ${path} → ${routes.apps[path]}`);
        }
        for (const path of Object.keys(routes.image)) {
          if (!prevImage.has(path)) changes.push(`NEW IMAGE MODEL: ${path} → ${routes.image[path]}`);
        }
        for (const path of Object.keys(routes.features)) {
          if (!prevFeatures.has(path)) changes.push(`NEW FEATURE: ${path} → ${routes.features[path]}`);
        }
        // Check for removed items
        for (const path of prevApps) {
          if (!routes.apps[path]) changes.push(`REMOVED APP: ${path}`);
        }
      } catch { /* first run or corrupt cache */ }
    }

    // Save cache
    const cacheData = {
      ...routes,
      _meta: {
        timestamp: new Date().toISOString(),
        totalPaths: Object.keys(links).length,
        imageModelsOnPage: imageModels,
        changes,
      }
    };
    writeFileSync(ROUTES_CACHE, JSON.stringify(cacheData, null, 2));
    writeFileSync(DISCOVERY_TIMESTAMP, String(Date.now()));

    // Report
    console.log(`Discovery complete: ${Object.keys(links).length} paths found`);
    console.log(`  Images: ${Object.keys(routes.image).length} models`);
    console.log(`  Video: ${Object.keys(routes.video).length} tools`);
    console.log(`  Apps: ${Object.keys(routes.apps).length} apps`);
    console.log(`  Motions: ${Object.keys(routes.motions).length} presets`);
    console.log(`  Features: ${Object.keys(routes.features).length} features`);
    if (changes.length > 0) {
      console.log(`\n  CHANGES since last discovery:`);
      changes.forEach(c => console.log(`    ${c}`));
    } else if (existsSync(ROUTES_CACHE)) {
      console.log('  No changes since last discovery');
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return cacheData;

  } catch (error) {
    console.error('Discovery error:', error.message);
    await browser.close();
    return null;
  }
}

// Ensure discovery has run (call at start of each command)
async function ensureDiscovery(options = {}) {
  if (discoveryNeeded()) {
    return await runDiscovery(options);
  }
  return null;
}

// Known modal/interruption log - append new types as we encounter them
const KNOWN_INTERRUPTIONS_FILE = join(STATE_DIR, 'known-interruptions.json');

function loadKnownInterruptions() {
  if (!existsSync(KNOWN_INTERRUPTIONS_FILE)) return [];
  try { return JSON.parse(readFileSync(KNOWN_INTERRUPTIONS_FILE, 'utf-8')); }
  catch { return []; }
}

function logNewInterruption(type, selector, detail) {
  const known = loadKnownInterruptions();
  const exists = known.some(k => k.type === type && k.selector === selector);
  if (!exists) {
    known.push({ type, selector, detail, firstSeen: new Date().toISOString() });
    writeFileSync(KNOWN_INTERRUPTIONS_FILE, JSON.stringify(known, null, 2));
    console.log(`Logged new interruption type: ${type} (${detail})`);
  }
}

// Comprehensive interruption dismissal - handles all known Higgsfield UI popups
async function dismissInterruptions(page) {
  const results = await page.evaluate(() => {
    const dismissed = [];

    // --- 1. React-Aria modal overlays (promo dialogs, offers) ---
    const overlays = document.querySelectorAll(
      '.react-aria-ModalOverlay, [data-rac].react-aria-ModalOverlay'
    );
    overlays.forEach(overlay => {
      overlay.remove();
      dismissed.push('react-aria-modal');
    });

    // --- 2. Dismiss buttons (off-screen react-aria dismiss) ---
    document.querySelectorAll('button[aria-label="Dismiss"]').forEach(btn => {
      btn.click();
      dismissed.push('dismiss-button');
    });

    // --- 3. Cookie consent / GDPR banners ---
    const cookieSelectors = [
      '[class*="cookie"]', '[id*="cookie"]',
      '[class*="consent"]', '[id*="consent"]',
      '[class*="gdpr"]', '[id*="gdpr"]',
      '[class*="CookieBanner"]',
    ];
    for (const sel of cookieSelectors) {
      document.querySelectorAll(sel).forEach(el => {
        // Click accept/close button inside, or remove the banner
        const acceptBtn = el.querySelector(
          'button:has-text("Accept"), button:has-text("OK"), button:has-text("Got it"), button[class*="accept"]'
        );
        if (acceptBtn) { acceptBtn.click(); dismissed.push('cookie-accept'); }
        else { el.remove(); dismissed.push('cookie-remove'); }
      });
    }

    // --- 4. Notification toasts (credit alerts, system messages) ---
    // The ARIA snapshot showed: heading "10 daily credits added" + paragraph
    document.querySelectorAll(
      '[role="alert"], [class*="toast"], [class*="Toast"], [class*="notification"], [class*="Notification"], [class*="snackbar"]'
    ).forEach(el => {
      const closeBtn = el.querySelector('button');
      if (closeBtn) { closeBtn.click(); dismissed.push('toast-close'); }
    });

    // --- 5. Onboarding tooltips / guided tours ---
    document.querySelectorAll(
      '[class*="tooltip"][class*="onboard"], [class*="tour"], [class*="walkthrough"], [class*="Popover"][class*="guide"]'
    ).forEach(el => {
      const skipBtn = el.querySelector('button:last-child') || el.querySelector('button');
      if (skipBtn) { skipBtn.click(); dismissed.push('onboarding-skip'); }
      else { el.remove(); dismissed.push('onboarding-remove'); }
    });

    // --- 6. Upgrade/pricing nag overlays ---
    document.querySelectorAll(
      '[class*="upgrade"], [class*="paywall"], [class*="subscribe"]'
    ).forEach(el => {
      // Only remove if it's an overlay/modal, not inline content
      if (el.style.position === 'fixed' || el.style.position === 'absolute' ||
          getComputedStyle(el).position === 'fixed') {
        el.remove();
        dismissed.push('upgrade-overlay');
      }
    });

    // --- 7. Generic dialog/modal elements ---
    document.querySelectorAll('[role="dialog"]').forEach(dialog => {
      // Check if it's a blocking modal (has an overlay parent or fixed position)
      const parent = dialog.parentElement;
      if (parent && (parent.classList.contains('react-aria-ModalOverlay') ||
          getComputedStyle(parent).position === 'fixed')) {
        parent.remove();
        dismissed.push('generic-dialog');
      }
    });

    // --- 8. Full-screen loading overlays inside main ---
    document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => {
      // Only remove if it looks like a loading spinner (few/no children with content)
      const hasRealContent = el.querySelector('textarea, input, button[type="submit"], form');
      if (!hasRealContent && el.children.length <= 2) {
        el.remove();
        dismissed.push('loading-overlay');
      }
    });

    // --- 9. Media upload agreement / Terms of Service modals ---
    document.querySelectorAll('[role="dialog"], dialog').forEach(dialog => {
      const agreeBtn = dialog.querySelector('button');
      const text = dialog.textContent || '';
      if (text.includes('Media upload agreement') || text.includes('I agree, continue') ||
          text.includes('terms of service') || text.includes('Terms of Service')) {
        // Find and click the agree/continue button
        const btns = dialog.querySelectorAll('button');
        for (const btn of btns) {
          if (btn.textContent.includes('agree') || btn.textContent.includes('continue') ||
              btn.textContent.includes('Accept') || btn.textContent.includes('OK')) {
            btn.click();
            dismissed.push('media-upload-agreement');
            break;
          }
        }
      }
    });

    // --- 10. Restore body scroll/pointer if modals locked it ---
    if (document.body.style.overflow === 'hidden' ||
        document.body.style.pointerEvents === 'none') {
      document.body.style.overflow = '';
      document.body.style.pointerEvents = '';
      dismissed.push('body-unlock');
    }

    return dismissed;
  });

  if (results.length > 0) {
    console.log(`Cleared ${results.length} interruption(s): ${[...new Set(results)].join(', ')}`);
    // Log any new types we haven't seen before
    for (const type of new Set(results)) {
      logNewInterruption(type, 'auto-detected', `Dismissed via comprehensive sweep`);
    }
  }

  // Also try Escape key for any remaining react-aria modals
  const remaining = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (remaining > 0) {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
    const afterEsc = await page.evaluate(() =>
      document.querySelectorAll('.react-aria-ModalOverlay').length
    );
    if (afterEsc < remaining) {
      console.log(`Escape dismissed ${remaining - afterEsc} more modal(s)`);
    }
  }

  return results.length;
}

// Dismiss all interruptions (retry for stacked/delayed popups)
async function dismissAllModals(page) {
  let totalDismissed = 0;
  for (let i = 0; i < 3; i++) {
    const count = await dismissInterruptions(page);
    totalDismissed += count;
    if (count === 0) break;
    await page.waitForTimeout(500);
  }
  return totalDismissed;
}

// Login to Higgsfield
async function login(options = {}) {
  const { user, pass } = loadCredentials();
  const { browser, context, page } = await launchBrowser({ ...options, headed: true });

  // Go directly to the email sign-in page
  const loginUrl = `${BASE_URL}/auth/email/sign-in?rp=%2F`;
  console.log(`Navigating to ${loginUrl}...`);
  await page.goto(loginUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);

  // Check if already logged in (redirected away from auth)
  const currentUrl = page.url();
  if (!currentUrl.includes('login') && !currentUrl.includes('auth')) {
    console.log('Already logged in! Saving state...');
    await context.storageState({ path: STATE_FILE });
    console.log(`Auth state saved to ${STATE_FILE}`);
    await browser.close();
    return;
  }

  // Dismiss any promo modals/overlays that may block the form
  await dismissAllModals(page);

  // Take a screenshot to see what we're working with
  await page.screenshot({ path: join(STATE_DIR, 'login-page.png'), fullPage: true });
  console.log('Login page screenshot saved');

  // Get ARIA snapshot for understanding the page structure
  const ariaSnap = await page.locator('body').ariaSnapshot();
  console.log('Page structure:', ariaSnap.substring(0, 2000));

  // Try multiple strategies to find and fill the email field
  const emailSelectors = [
    'input[type="email"]',
    'input[name="email"]',
    'input[placeholder*="email" i]',
    'input[placeholder*="Email" i]',
    'input[autocomplete="email"]',
    'input[id*="email" i]',
    'input:not([type="hidden"]):not([type="password"])',
  ];

  let emailFilled = false;
  for (const selector of emailSelectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found email field with selector: ${selector} (${count} matches)`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(user);
      emailFilled = true;
      console.log('Email entered');
      break;
    }
  }

  if (!emailFilled) {
    console.log('Could not find email field automatically');
    // List all visible inputs for debugging
    const inputs = await page.evaluate(() => {
      return [...document.querySelectorAll('input:not([type="hidden"])')].map(el => ({
        type: el.type, name: el.name, id: el.id,
        placeholder: el.placeholder, className: el.className.substring(0, 80),
      }));
    });
    console.log('Visible inputs:', JSON.stringify(inputs, null, 2));
  }

  await page.waitForTimeout(1000);

  // Try to find and fill password field
  const passwordSelectors = [
    'input[type="password"]',
    'input[name="password"]',
    'input[placeholder*="password" i]',
    'input[autocomplete="current-password"]',
  ];

  let passFilled = false;
  for (const selector of passwordSelectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found password field with selector: ${selector}`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(pass);
      passFilled = true;
      console.log('Password entered');
      break;
    }
  }

  if (!passFilled) {
    console.log('No password field found yet - may appear after email submission');
  }

  await page.waitForTimeout(500);

  // Click submit/continue button
  const submitSelectors = [
    'button[type="submit"]',
    'button:has-text("Sign in")',
    'button:has-text("Log in")',
    'button:has-text("Continue")',
    'button:has-text("Next")',
    'input[type="submit"]',
  ];

  let submitted = false;
  for (const selector of submitSelectors) {
    const el = page.locator(selector).filter({ hasNotText: /google|apple|discord/i });
    const count = await el.count();
    if (count > 0) {
      console.log(`Clicking submit button: ${selector}`);
      await el.first().click();
      submitted = true;
      break;
    }
  }

  if (!submitted) {
    console.log('No submit button found, trying Enter key...');
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(3000);

  // Check if we need to enter password on a second page
  const currentUrl2 = page.url();
  console.log('Current URL after submit:', currentUrl2);

  if (!passFilled) {
    // Password might appear on a second step
    for (const selector of passwordSelectors) {
      const el = page.locator(selector);
      const count = await el.count();
      if (count > 0) {
        console.log(`Found password field on step 2: ${selector}`);
        await el.first().click();
        await page.waitForTimeout(300);
        await el.first().fill(pass);
        passFilled = true;
        console.log('Password entered on step 2');

        // Submit again
        for (const subSelector of submitSelectors) {
          const subEl = page.locator(subSelector).filter({ hasNotText: /google|apple|discord/i });
          if (await subEl.count() > 0) {
            await subEl.first().click();
            break;
          }
        }
        break;
      }
    }
  }

  // Wait for redirect after login
  console.log('Waiting for login to complete...');
  try {
    await page.waitForURL(url => {
      const u = url.toString();
      return !u.includes('/auth/') && !u.includes('/login');
    }, { timeout: 30000 });
    console.log('Login successful! Redirected to:', page.url());
  } catch {
    console.log('Still on auth page. Current URL:', page.url());
    await page.screenshot({ path: join(STATE_DIR, 'login-result.png'), fullPage: true });

    // Check if there's an error message
    const errorText = await page.evaluate(() => {
      const errors = document.querySelectorAll('[class*="error"], [class*="alert"], [role="alert"]');
      return [...errors].map(e => e.textContent?.trim()).filter(Boolean).join('; ');
    });
    if (errorText) {
      console.log('Error message:', errorText);
    }

    // Wait for manual intervention if headed
    if (options.headed) {
      console.log('Waiting 60s for manual login completion...');
      try {
        await page.waitForURL(url => {
          const u = url.toString();
          return !u.includes('/auth/') && !u.includes('/login');
        }, { timeout: 60000 });
        console.log('Login completed manually! URL:', page.url());
      } catch {
        console.log('Timeout. Saving current state anyway...');
      }
    }
  }

  // Save auth state regardless
  await context.storageState({ path: STATE_FILE });
  console.log(`Auth state saved to ${STATE_FILE}`);
  await browser.close();
}

// Check if logged in
async function checkAuth(page) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(2000);

  // Check for profile/avatar indicator or login button
  const profileIndicator = page.locator('[data-testid="profile"], .avatar, .user-menu, a[href="/profile"]');
  const loginBtn = page.locator('a:has-text("Log in"), button:has-text("Log in"), a:has-text("Sign in")');

  const isLoggedIn = await profileIndicator.count() > 0 || await loginBtn.count() === 0;
  return isLoggedIn;
}

// Configure image generation options on the page (aspect ratio, quality, enhance, batch, preset)
async function configureImageOptions(page, options) {
  // Select aspect ratio if specified
  if (options.aspect) {
    console.log(`Setting aspect ratio: ${options.aspect}`);
    // Aspect ratio buttons are typically in a button group
    const aspectBtn = page.locator(`button:has-text("${options.aspect}")`);
    if (await aspectBtn.count() > 0) {
      await aspectBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected aspect ratio: ${options.aspect}`);
    } else {
      // Try clicking the aspect ratio dropdown/selector first
      const aspectSelector = page.locator('button:has-text("Aspect"), [class*="aspect"]');
      if (await aspectSelector.count() > 0) {
        await aspectSelector.first().click({ force: true });
        await page.waitForTimeout(500);
        const option = page.locator(`[role="option"]:has-text("${options.aspect}"), button:has-text("${options.aspect}")`);
        if (await option.count() > 0) {
          await option.first().click({ force: true });
          await page.waitForTimeout(300);
          console.log(`Selected aspect ratio: ${options.aspect}`);
        }
      }
    }
  }

  // Select quality if specified
  if (options.quality) {
    console.log(`Setting quality: ${options.quality}`);
    const qualityBtn = page.locator(`button:has-text("${options.quality}")`);
    if (await qualityBtn.count() > 0) {
      await qualityBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected quality: ${options.quality}`);
    }
  }

  // Toggle enhance on/off
  if (options.enhance !== undefined) {
    const enhanceLabel = page.locator('label:has-text("Enhance"), button:has-text("Enhance")');
    if (await enhanceLabel.count() > 0) {
      const isChecked = await page.evaluate(() => {
        const el = document.querySelector('label:has(input) span:has-text("Enhance")');
        const input = el?.closest('label')?.querySelector('input');
        return input?.checked || false;
      });
      if (isChecked !== options.enhance) {
        await enhanceLabel.first().click({ force: true });
        await page.waitForTimeout(300);
        console.log(`${options.enhance ? 'Enabled' : 'Disabled'} enhance`);
      }
    }
  }

  // Set batch size if specified (1-4 images)
  // The UI uses a Decrement/Increment button pattern with ARIA labels:
  //   button "Decrement 4/4 Increment" containing:
  //     button "Decrement" (SVG icon, no text)
  //     text "N/4"
  //     button "Increment" (SVG icon, no text, disabled at max)
  if (options.batch && options.batch >= 1 && options.batch <= 4) {
    console.log(`Setting batch size: ${options.batch}`);

    // Read the current batch count from the "N/4" display
    const currentBatch = await page.evaluate(() => {
      const allText = document.body.innerText;
      const batchMatch = allText.match(/(\d)\/4/);
      return batchMatch ? parseInt(batchMatch[1], 10) : 4;
    });
    console.log(`Current batch size: ${currentBatch}, target: ${options.batch}`);

    if (currentBatch !== options.batch) {
      const diff = options.batch - currentBatch;

      if (diff < 0) {
        // Need to decrease: click Decrement button |diff| times
        // Use exact:true to match aria-label="Decrement" (not the outer wrapper)
        const decrementBtn = page.getByRole('button', { name: 'Decrement', exact: true });
        if (await decrementBtn.count() > 0) {
          for (let clicks = 0; clicks < Math.abs(diff); clicks++) {
            await decrementBtn.click({ force: true });
            await page.waitForTimeout(200);
          }
          console.log(`Clicked Decrement ${Math.abs(diff)} time(s) to set batch to ${options.batch}`);
        } else {
          console.log('Could not find Decrement button for batch size');
        }
      } else {
        // Need to increase: click Increment button diff times
        const incrementBtn = page.getByRole('button', { name: 'Increment', exact: true });
        if (await incrementBtn.count() > 0) {
          for (let clicks = 0; clicks < diff; clicks++) {
            await incrementBtn.click({ force: true });
            await page.waitForTimeout(200);
          }
          console.log(`Clicked Increment ${diff} time(s) to set batch to ${options.batch}`);
        } else {
          console.log('Could not find Increment button for batch size');
        }
      }

      // Verify the new batch size
      const newBatch = await page.evaluate(() => {
        const batchMatch = document.body.innerText.match(/(\d)\/4/);
        return batchMatch ? parseInt(batchMatch[1], 10) : -1;
      });
      if (newBatch === options.batch) {
        console.log(`Batch size confirmed: ${newBatch}`);
      } else {
        console.log(`WARNING: Batch size may not have changed (showing ${newBatch})`);
      }
    } else {
      console.log(`Batch size already at ${options.batch}`);
    }
  }

  // Select style preset if specified
  if (options.preset) {
    console.log(`Selecting preset: ${options.preset}`);
    // Presets are shown as a scrollable list of style cards
    const presetBtn = page.locator(`button:has-text("${options.preset}"), [class*="preset"]:has-text("${options.preset}")`);
    if (await presetBtn.count() > 0) {
      await presetBtn.first().click({ force: true });
      await page.waitForTimeout(500);
      console.log(`Selected preset: ${options.preset}`);
    } else {
      console.log(`Preset "${options.preset}" not found on page`);
    }
  }
}

// --- Image generation helpers (extracted from generateImage for clarity) ---

// Map of image model slugs to their URL paths on the Higgsfield UI.
// Models with "365" unlimited subscriptions use feature pages (e.g. /nano-banana-pro)
// which have an "Unlimited" toggle switch. Standard /image/ routes cost credits.
const IMAGE_MODEL_URL_MAP = {
  'soul': '/image/soul',
  'nano_banana': '/image/nano_banana',
  'nano-banana': '/image/nano_banana',
  'nano_banana_pro': '/nano-banana-pro',
  'nano-banana-pro': '/nano-banana-pro',
  'seedream': '/image/seedream',
  'seedream-4': '/image/seedream',
  'seedream-4.5': '/seedream-4-5',
  'seedream-4-5': '/seedream-4-5',
  'wan2': '/image/wan2',
  'wan': '/image/wan2',
  'gpt': '/image/gpt',
  'gpt-image': '/image/gpt',
  'kontext': '/image/kontext',
  'flux-kontext': '/image/kontext',
  'flux': '/image/flux',
  'flux-pro': '/image/flux',
};

// Select the best image model, preferring unlimited when available.
function selectImageModel(options) {
  let model = options.model || 'soul';
  if (!options.model && options.preferUnlimited !== false) {
    const unlimited = getUnlimitedModelForCommand('image');
    if (unlimited) {
      model = unlimited.slug;
      console.log(`[unlimited] Auto-selected unlimited image model: ${unlimited.name} (${unlimited.slug})`);
    }
  } else if (options.model && isUnlimitedModel(options.model, 'image')) {
    console.log(`[unlimited] Model "${options.model}" is unlimited (no credit cost)`);
  }
  return model;
}

// Fill the prompt textarea, with JS fallback if Playwright locator fails.
// Returns true on success, false if no input field was found.
async function fillPromptInput(page, prompt) {
  const promptInput = page.locator('textarea, [contenteditable="true"], input[placeholder*="prompt" i], input[placeholder*="describe" i], input[placeholder*="Describe" i], input[placeholder*="Upload" i]');
  const promptCount = await promptInput.count();
  console.log(`Found ${promptCount} prompt input(s)`);

  if (promptCount > 0) {
    await promptInput.first().click({ force: true });
    await page.waitForTimeout(300);
    await promptInput.first().fill('', { force: true });
    await promptInput.first().fill(prompt, { force: true });
    console.log(`Entered prompt: "${prompt}"`);
    await page.waitForTimeout(500);
    return true;
  }

  // Fallback: fill via JS
  const filled = await page.evaluate((p) => {
    const inputs = document.querySelectorAll('textarea, input[type="text"]');
    for (const input of inputs) {
      if (input.offsetParent !== null) {
        const nativeSetter = Object.getOwnPropertyDescriptor(
          window.HTMLInputElement.prototype, 'value'
        )?.set || Object.getOwnPropertyDescriptor(
          window.HTMLTextAreaElement.prototype, 'value'
        )?.set;
        if (nativeSetter) nativeSetter.call(input, p);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }
    }
    return false;
  }, prompt);

  if (filled) {
    console.log('Entered prompt via JS fallback');
    return true;
  }
  console.error('Could not find prompt input field');
  return false;
}

// Enable the "Unlimited mode" toggle on feature pages (e.g. /nano-banana-pro, /seedream-4-5).
async function enableUnlimitedMode(page) {
  const unlimitedSwitch = page.getByRole('switch');
  if (await unlimitedSwitch.count() === 0) return;

  const hasUnlimitedLabel = await page.evaluate(() => document.body.innerText.includes('Unlimited'));
  if (!hasUnlimitedLabel) return;

  const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
  if (isChecked) {
    console.log('Unlimited mode already enabled (image)');
    return;
  }

  const switchParent = page.locator('button:has(switch), *:has(> switch)').first();
  if (await switchParent.count() > 0) {
    await switchParent.click({ force: true });
  } else {
    await unlimitedSwitch.click({ force: true });
  }
  await page.waitForTimeout(500);
  const nowChecked = await unlimitedSwitch.isChecked().catch(() => false);
  console.log(nowChecked ? 'Enabled Unlimited mode (image)' : 'WARNING: Could not enable Unlimited mode');
}

// Click the Generate button and verify the click registered.
// Returns true if generation appears to have started.
async function clickAndVerifyGenerate(page, queueBefore, existingImageCount) {
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

  // Verify the click registered by checking for state changes
  await page.waitForTimeout(3000);
  const postClickState = await page.evaluate(({ prevQueue, prevImages }) => {
    const queueNow = (document.body.innerText.match(/In queue/g) || []).length;
    const imagesNow = document.querySelectorAll('img[alt="image generation"]').length;
    const hasGeneratingIndicator = document.body.innerText.includes('Generating') ||
      document.body.innerText.includes('Processing') ||
      document.querySelectorAll('[class*="spinner"], [class*="loading"], [class*="progress"]').length > 0;
    const genBtns = [...document.querySelectorAll('button')].filter(b => b.textContent?.includes('Generate'));
    const btnDisabled = genBtns.some(b => b.disabled || b.getAttribute('aria-disabled') === 'true');
    const btnTextNow = genBtns.map(b => b.textContent?.trim()).join(', ');
    return { queueNow, imagesNow, hasGeneratingIndicator, btnDisabled, btnTextNow };
  }, { prevQueue: queueBefore, prevImages: existingImageCount });

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

// Poll the page until image generation completes or times out.
// Detects completion via: queue drain, image count increase, button re-enable, or page reload.
// Returns true if generation completed within the timeout.
async function waitForImageGeneration(page, existingImageCount, queueBefore, options = {}) {
  const timeout = options.timeout || 300000;
  const startTime = Date.now();
  const pollInterval = 5000;

  // Phase 1: Wait for new "In queue" items to confirm generation started
  console.log('Waiting for generation to start...');
  let detectedQueueCount = queueBefore;
  try {
    await page.waitForFunction(
      (prevQueueCount) => (document.body.innerText.match(/In queue/g) || []).length > prevQueueCount,
      queueBefore,
      { timeout: 15000, polling: 1000 }
    );
    detectedQueueCount = await page.evaluate(() =>
      (document.body.innerText.match(/In queue/g) || []).length
    );
    console.log(`Generation started! ${detectedQueueCount} item(s) in queue`);
  } catch {
    console.log('Queue detection timed out - generation may have started differently');
  }

  // Phase 2: Poll until queue items resolve to images
  console.log(`Waiting up to ${timeout / 1000}s for generation to complete...`);
  let peakQueue = Math.max(queueBefore, detectedQueueCount);
  let retryAttempted = false;
  let reloadAttempted = false;
  let btnWasDisabled = false;

  while (Date.now() - startTime < timeout) {
    await page.waitForTimeout(pollInterval);

    const state = await page.evaluate(() => {
      const queueItems = (document.body.innerText.match(/In queue/g) || []).length;
      const images = document.querySelectorAll('img[alt="image generation"]').length;
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
    });

    if (state.queueItems > peakQueue) peakQueue = state.queueItems;
    if (state.btnDisabled || state.hasSpinner) btnWasDisabled = true;

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    console.log(`  ${elapsed}s: queue=${state.queueItems} images=${state.images} (peak=${peakQueue}) btn=${state.btnDisabled ? 'disabled' : 'enabled'}`);

    // Condition 1: queue was elevated and has now dropped back
    if (peakQueue > queueBefore && state.queueItems <= queueBefore) {
      console.log(`Generation complete! ${state.images} images on page (${elapsed}s)`);
      return true;
    }

    // Condition 2: image count increased with no queue activity
    if (state.images > existingImageCount && state.queueItems === 0 && peakQueue === queueBefore) {
      console.log(`Generation complete (fast)! ${state.images} images on page, ${state.images - existingImageCount} new (${elapsed}s)`);
      return true;
    }

    // Condition 3: Generate button was disabled/spinner and is now re-enabled
    if (btnWasDisabled && !state.btnDisabled && !state.hasSpinner) {
      console.log(`Generation complete (button re-enabled)! ${state.images} images on page (${elapsed}s)`);
      await page.waitForTimeout(3000);
      return true;
    }

    // Safety: retry Generate click after 30s of no activity
    if (!retryAttempted && parseInt(elapsed, 10) >= 30 &&
        state.queueItems === queueBefore && state.images <= existingImageCount &&
        peakQueue === queueBefore && !btnWasDisabled) {
      console.log('No activity detected after 30s - retrying Generate click...');
      await dismissAllModals(page);
      const retryBtn = page.locator('button:has-text("Generate")');
      if (await retryBtn.count() > 0) {
        await retryBtn.last().scrollIntoViewIfNeeded().catch(() => {});
        await page.waitForTimeout(300);
        await retryBtn.last().click({ force: true });
        console.log('Retried Generate click (30s safety)');
      }
      retryAttempted = true;
    }

    // Condition 4: reload after 60s of no queue/button activity
    if (!reloadAttempted && parseInt(elapsed, 10) >= 60 &&
        peakQueue === queueBefore && !btnWasDisabled) {
      console.log('No queue or button activity after 60s - reloading to check for new images...');
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
      await page.waitForTimeout(5000);
      const freshCount = await page.evaluate(() =>
        document.querySelectorAll('img[alt="image generation"]').length
      );
      if (freshCount > existingImageCount) {
        console.log(`Generation complete (post-reload)! ${freshCount} images, ${freshCount - existingImageCount} new (${elapsed}s)`);
        return true;
      }
      reloadAttempted = true;
    }
  }

  console.log('Timeout waiting for generation. Some items may still be processing.');
  return false;
}

// Download newly generated images by comparing current count to pre-generation count.
// New images appear at the TOP of the grid.
async function downloadNewImages(page, options, existingImageCount, generationComplete) {
  if (options.wait === false) return;

  const currentImageCount = await page.evaluate(() =>
    document.querySelectorAll('img[alt="image generation"]').length
  );
  const newCount = currentImageCount - existingImageCount;
  const newImageIndices = [];
  for (let i = 0; i < newCount; i++) newImageIndices.push(i);
  console.log(`New images: ${newImageIndices.length} of ${currentImageCount} total (indices: ${newImageIndices.join(', ')})`);

  const baseOutput = options.output || DOWNLOAD_DIR;
  const outputDir = resolveOutputDir(baseOutput, options, 'images');

  if (newImageIndices.length > 0) {
    await downloadSpecificImages(page, outputDir, newImageIndices, options);
  } else if (generationComplete) {
    const batchSize = options.batch || 4;
    const downloadCount = Math.min(batchSize, currentImageCount);
    console.log(`Count-based detection missed new images. Downloading top ${downloadCount} (batch=${batchSize})...`);
    const fallbackIndices = [];
    for (let i = 0; i < downloadCount; i++) fallbackIndices.push(i);
    await downloadSpecificImages(page, outputDir, fallbackIndices, options);
  } else {
    console.log('No new images detected. Generation may still be in progress.');
    console.log('Try: node playwright-automator.mjs download');
  }
}

// --- End image generation helpers ---

// Generate image via UI
async function generateImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'A serene mountain landscape at golden hour, photorealistic, 8k';
    const model = selectImageModel(options);

    // Navigate to image creation page
    const modelPath = IMAGE_MODEL_URL_MAP[model] || `/image/${model}`;
    const imageUrl = `${BASE_URL}${modelPath}`;
    console.log(`Navigating to ${imageUrl}...`);
    await page.goto(imageUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'image-page.png'), fullPage: false });

    // Wait for page content to fully load and remove loading overlays
    await page.waitForTimeout(2000);
    await page.evaluate(() => {
      document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => {
        if (el.children.length <= 1) el.remove();
      });
    });

    // Fill prompt
    const promptFilled = await fillPromptInput(page, prompt);
    if (!promptFilled) {
      await page.screenshot({ path: join(STATE_DIR, 'no-prompt-field.png'), fullPage: true });
      await browser.close();
      return null;
    }

    await configureImageOptions(page, options);
    await enableUnlimitedMode(page);

    // Capture pre-generation state
    const existingImageCount = await page.evaluate(() =>
      document.querySelectorAll('img[alt="image generation"]').length
    );
    const queueBefore = await page.evaluate(() =>
      (document.body.innerText.match(/In queue/g) || []).length
    );
    console.log(`Existing images: ${existingImageCount}, queue: ${queueBefore}`);

    // Dry-run mode: stop before clicking Generate
    if (options.dryRun) {
      console.log('[DRY-RUN] Configuration complete. Skipping Generate click.');
      await page.screenshot({ path: join(STATE_DIR, 'dry-run-configured.png'), fullPage: false });
      await context.storageState({ path: STATE_FILE });
      await browser.close();
      return { success: true, dryRun: true };
    }

    await clickAndVerifyGenerate(page, queueBefore, existingImageCount);
    const generationComplete = await waitForImageGeneration(page, existingImageCount, queueBefore, options);

    // Allow images to fully load
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'generation-result.png'), fullPage: false });

    await downloadNewImages(page, options, existingImageCount, generationComplete);

    console.log('Image generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'generation-result.png') };

  } catch (error) {
    console.error('Error during image generation:', error.message);
    try { await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}

// Download a video from the History tab on /create/video or /lipsync-studio
// The <video src> in History list items is a shared CDN motion template URL (same for all items).
// The actual full-quality video URLs are in the API response from fnf.higgsfield.ai/project.
//
// Strategy 1 (PRIMARY): Intercept the fnf.higgsfield.ai/project API response,
//   extract job_sets[0].jobs[0].results.raw.url (CloudFront URL, full 1080p).
// Strategy 2 (FALLBACK): Navigate to the page fresh to trigger the API call,
//   then extract the URL from the intercepted response.
// Strategy 3 (LAST RESORT): Extract <video src> from the list item (motion template, low quality).
async function downloadVideoFromHistory(page, outputDir, metadata = {}, options = {}) {
  const downloaded = [];

  try {
    // Switch to History tab if not already there
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(2000);
    }

    await dismissAllModals(page);

    const historyListItems = page.locator('main li');
    const listCount = await historyListItems.count();
    console.log(`Found ${listCount} item(s) in History tab`);

    if (listCount === 0) {
      console.log('No history items found to download');
      return downloaded;
    }

    // Extract model/prompt metadata from the first (newest) list item
    const videoInfo = await page.evaluate(() => {
      const firstItem = document.querySelector('main li');
      if (!firstItem) return null;

      const textbox = firstItem.querySelector('[role="textbox"], textarea');
      const promptText = textbox?.textContent?.trim() || '';

      const actionWords = /^(cancel|rerun|retry|download|delete|remove|share|copy|edit)$/i;
      const buttons = [...firstItem.querySelectorAll('button')];
      let modelText = '';
      for (const btn of buttons) {
        const text = btn.textContent?.trim();
        const hasIcon = btn.querySelector('img, svg[class*="icon"]');
        const looksLikeModel = /kling|wan|sora|minimax|veo|flux|soul|nano|seedream|gpt|higgsfield|popcorn/i.test(text);
        const isAction = actionWords.test(text) || text.length <= 2;
        if ((hasIcon || looksLikeModel) && !isAction && text.length > 0) {
          modelText = text;
          break;
        }
      }
      if (!modelText) {
        const candidates = buttons
          .map(b => b.textContent?.trim())
          .filter(t => t && t.length > 3 && !actionWords.test(t));
        if (candidates.length > 0) {
          modelText = candidates.sort((a, b) => b.length - a.length)[0];
        }
      }

      return { promptText, modelText };
    });

    const combinedMeta = {
      ...metadata,
      model: videoInfo?.modelText || metadata.model,
      promptSnippet: videoInfo?.promptText?.substring(0, 80) || metadata.promptSnippet,
    };

    // Strategy 1 (PRIMARY): Intercept the project API to get the full-quality CloudFront URL.
    // The API at fnf.higgsfield.ai/project returns job data with results.raw.url containing
    // the actual video at d8j0ntlcm91z4.cloudfront.net (1920x1080 full quality).
    // The <video src> in the DOM is just a shared motion template URL (same for all items).
    console.log('Extracting full-quality video URL from API data...');

    // Set up API interception and reload the page to trigger the API call
    let projectApiData = null;
    const apiHandler = async (response) => {
      const url = response.url();
      if (url.includes('fnf.higgsfield.ai/project')) {
        try { projectApiData = await response.json(); } catch {}
      }
    };
    page.on('response', apiHandler);

    // Reload the video page to trigger the API call
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(6000);
    page.off('response', apiHandler);

    // Fallback: Direct API fetch if interception missed the response
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

    if (projectApiData?.job_sets?.length > 0) {
      // Ensure output directory exists
      if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

      // Find the newest completed job with a video result
      for (const jobSet of projectApiData.job_sets) {
        for (const job of (jobSet.jobs || [])) {
          if (job.status === 'completed' && job.results?.raw?.url) {
            const videoUrl = job.results.raw.url;
            // Only use CloudFront URLs (the actual generated videos)
            if (videoUrl.includes('cloudfront.net')) {
              const filename = buildDescriptiveFilename(combinedMeta, `higgsfield-video-${Date.now()}.mp4`, 0);
              const savePath = join(outputDir, filename);
              try {
                const curlResult = execFileSync('curl', ['-sL', '-w', '%{http_code}', '-o', savePath, videoUrl], { timeout: 120000, encoding: 'utf-8' });
                const httpCode = curlResult.trim();
                if (httpCode === '200' && existsSync(savePath)) {
                    const fileSize = statSync(savePath).size;
                    if (fileSize > 10000) { // Sanity check: real videos are >10KB
                      const result = finalizeDownload(savePath, {
                        command: 'video', type: 'video', ...combinedMeta,
                        strategy: 'api-interception', cloudFrontUrl: videoUrl,
                      }, outputDir, options);
                      if (!result.skipped) {
                        console.log(`Downloaded full-quality video (${(fileSize / 1024 / 1024).toFixed(1)}MB, HTTP ${httpCode}): ${savePath}`);
                      }
                      downloaded.push(result.path);
                    } else {
                    console.log(`CloudFront returned ${httpCode} but file too small (${fileSize}B), skipping: ${videoUrl.substring(videoUrl.lastIndexOf('/') + 1)}`);
                  }
                } else {
                  console.log(`CloudFront HTTP ${httpCode} for: ${videoUrl.substring(videoUrl.lastIndexOf('/') + 1)}`);
                }
              } catch (curlErr) {
                console.log(`CloudFront download error: ${curlErr.stderr || curlErr.message}`);
              }
              break; // Only download the newest video
            }
          }
        }
        if (downloaded.length > 0) break;
      }
    }

    if (downloaded.length === 0) {
      console.log('API interception did not yield a video URL');
    }

    // Strategy 2 (FALLBACK): Extract <video src> from the list item directly.
    // This gives the motion template URL (shared across all items, lower quality).
    if (downloaded.length === 0) {
      console.log('Falling back to CDN video src (motion template quality)...');

      // Re-click History tab after reload
      if (await historyTab.count() > 0) {
        await historyTab.click({ force: true });
        await page.waitForTimeout(2000);
      }

      const videoSrc = await page.evaluate(() => {
        const firstItem = document.querySelector('main li');
        const video = firstItem?.querySelector('video');
        return video?.src || video?.querySelector('source')?.src || null;
      });

      if (videoSrc) {
        const filename = buildDescriptiveFilename(combinedMeta, `higgsfield-video-${Date.now()}.mp4`, 0);
        const savePath = join(outputDir, filename);
        try {
          execFileSync('curl', ['-sL', '-o', savePath, videoSrc], { timeout: 120000 });
          const result = finalizeDownload(savePath, {
            command: 'video', type: 'video', ...combinedMeta,
            strategy: 'cdn-fallback', cdnUrl: videoSrc,
          }, outputDir, options);
          if (!result.skipped) {
            console.log(`Downloaded video (CDN fallback): ${savePath}`);
          }
          downloaded.push(result.path);
        } catch (curlErr) {
          console.log(`CDN video download failed: ${curlErr.message}`);
        }
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'video-download-result.png'), fullPage: false });
  } catch (error) {
    console.log(`Video download error: ${error.message}`);
  }

  return downloaded;
}

// Generate video via UI
// Supports two flows:
//   1. Upload start frame image (--image-file) + prompt
//   2. Direct navigation to /create/video with prompt only (some models support text-to-video)
// Results appear in the History tab, not as inline <video> elements.
async function generateVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Camera slowly pans across a beautiful landscape as clouds drift overhead';

    // Auto-select unlimited video model if no explicit model specified
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

    // Navigate to video creation page
    console.log('Navigating to video creation page...');
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-page.png'), fullPage: false });

    // Upload start frame image if provided
    if (options.imageFile) {
      console.log(`Uploading start frame: ${options.imageFile}`);

      // Step 1: If there's an existing start frame, remove it first
      // The existing frame shows as button "Uploaded image" with a small X button nearby
      const existingFrame = page.getByRole('button', { name: 'Uploaded image' });
      if (await existingFrame.count() > 0) {
        // The X/remove button is a small 20x20 button below the start frame area
        // Find it by looking for a small button near the uploaded image
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

      // Step 2: Upload the start frame image via file chooser.
      // The page has a button "Upload image or generate it" that triggers a file chooser.
      // Also try clicking the "Start frame" area directly as a fallback.
      let uploaded = false;

      // Strategy A: Click the "Upload image" button
      const uploadBtn = page.getByRole('button', { name: /Upload image/ });
      if (!uploaded && await uploadBtn.count() > 0) {
        try {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 10000 }),
            uploadBtn.click({ force: true }),
          ]);
          await fileChooser.setFiles(options.imageFile);
          await page.waitForTimeout(3000);
          uploaded = true;
          console.log('Start frame uploaded via Upload button');
        } catch (uploadErr) {
          console.log(`Upload button approach failed: ${uploadErr.message}`);
        }
      }

      // Strategy B: Click the "Start frame" text/area directly
      if (!uploaded) {
        const startFrameBtn = page.locator('text=Start frame').first();
        if (await startFrameBtn.count() > 0) {
          try {
            const [fileChooser] = await Promise.all([
              page.waitForEvent('filechooser', { timeout: 10000 }),
              startFrameBtn.click({ force: true }),
            ]);
            await fileChooser.setFiles(options.imageFile);
            await page.waitForTimeout(3000);
            uploaded = true;
            console.log('Start frame uploaded via Start frame area');
          } catch (err) {
            console.log(`Start frame area click failed: ${err.message}`);
          }
        }
      }

      // Strategy C: Use drag-and-drop via page.setInputFiles on any hidden file input
      if (!uploaded) {
        const fileInput = page.locator('input[type="file"]');
        if (await fileInput.count() > 0) {
          try {
            await fileInput.first().setInputFiles(options.imageFile);
            await page.waitForTimeout(3000);
            uploaded = true;
            console.log('Start frame uploaded via hidden file input');
          } catch (err) {
            console.log(`Hidden file input failed: ${err.message}`);
          }
        }
      }

      // Strategy D: Click coordinates of the Start frame box (from screenshot: ~97, 310)
      if (!uploaded) {
        try {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 5000 }),
            page.mouse.click(97, 310),
          ]);
          await fileChooser.setFiles(options.imageFile);
          await page.waitForTimeout(3000);
          uploaded = true;
          console.log('Start frame uploaded via coordinate click');
        } catch {
          console.log('WARNING: Could not upload start frame image (all strategies failed)');
        }
      }
    } else {
      console.log('No start frame image provided. Some models support text-to-video.');
      console.log('For best results, provide --image-file with a start frame.');
    }

    // Wait for page to stabilize after upload and dismiss any new modals
    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-after-upload.png'), fullPage: false });

    // Select model (click model selector, find matching option)
    // Model name mapping: CLI names (lowercase, hyphenated) -> UI dropdown button text patterns
    // The Model dropdown shows options like "Kling 2.6 1080p 5s-10s" as button text.
    // We match by the model name prefix to handle varying resolution/duration suffixes.
    {
      const modelNameMap = {
        'kling-3.0': 'Kling 3.0',
        'kling-2.6': 'Kling 2.6',
        'kling-2.5': 'Kling 2.5',
        'kling-2.1': 'Kling 2.1',
        'kling-motion': 'Kling Motion Control',
        'seedance': 'Seedance',
        'grok': 'Grok Imagine',
        'minimax': 'Minimax Hailuo',
        'wan-2.1': 'Wan 2.1',
        'sora': 'Sora',
        'veo': 'Veo',
        'veo-3': 'Veo 3',
      };
      const uiModelName = modelNameMap[model] || model;
      console.log(`Selecting model: ${model} (UI: "${uiModelName}")`);

      // ARIA: button "Model" with paragraph showing current model name
      const modelSelector = page.getByRole('button', { name: 'Model' });
      if (await modelSelector.count() > 0) {
        // Check if the desired model is already selected
        const currentModel = await modelSelector.textContent().catch(() => '');
        if (currentModel.includes(uiModelName)) {
          console.log(`Model already set to ${uiModelName}`);
        } else {
          await modelSelector.click({ force: true });
          await page.waitForTimeout(1500);

          // The dropdown is a popover with "Featured models" and "All models" sections.
          // Each option is a button with text like "Kling 2.61080p5s-10s" (no spaces).
          // CRITICAL: button:has-text("Kling 2.6") also matches History items on the right.
          // We must find the dropdown option by position (x < 800) to avoid History matches.
          let selected = false;

          // Strategy: find all buttons matching the model name, pick the one in the
          // dropdown area (x < 800, center of page) not the History sidebar (x > 1000).
          const matchingBtns = await page.evaluate((modelName) => {
            return [...document.querySelectorAll('button')]
              .filter(b => b.textContent?.includes(modelName) && b.offsetParent !== null)
              .map(b => {
                const r = b.getBoundingClientRect();
                return { x: r.x, y: r.y, w: r.width, h: r.height, text: b.textContent?.trim()?.substring(0, 60) };
              })
              .filter(b => b.x < 800 && b.x > 100); // Dropdown area only
          }, uiModelName);

          if (matchingBtns.length > 0) {
            const btn = matchingBtns[0];
            await page.mouse.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
            await page.waitForTimeout(1500);
            selected = true;
            console.log(`Selected model from dropdown: ${btn.text}`);
          }

          if (!selected) {
            // Fallback: use the search box in the dropdown to filter, then click by position
            const searchBox = page.locator('input[placeholder*="Search"]');
            if (await searchBox.count() > 0) {
              await searchBox.fill(uiModelName);
              await page.waitForTimeout(1000);
              const filtered = await page.evaluate((modelName) => {
                return [...document.querySelectorAll('button')]
                  .filter(b => b.textContent?.includes(modelName) && b.offsetParent !== null)
                  .map(b => {
                    const r = b.getBoundingClientRect();
                    return { x: r.x, y: r.y, w: r.width, h: r.height };
                  })
                  .filter(b => b.x < 800 && b.x > 100);
              }, uiModelName);
              if (filtered.length > 0) {
                await page.mouse.click(filtered[0].x + filtered[0].w / 2, filtered[0].y + filtered[0].h / 2);
                await page.waitForTimeout(1500);
                selected = true;
                console.log(`Selected model via search: ${uiModelName}`);
              }
            }
          }

          if (!selected) {
            await page.keyboard.press('Escape');
            console.log(`Model "${uiModelName}" not found in dropdown, using default`);
          }
        }
      }

      // Verify the model was actually selected
      const verifyModel = page.getByRole('button', { name: 'Model' });
      if (await verifyModel.count() > 0) {
        const finalModel = await verifyModel.textContent().catch(() => '');
        console.log(`Model now set to: ${finalModel?.replace('Model', '').trim()}`);
      }
    }

    // Enable "Unlimited mode" switch if available (saves credits on supported models)
    // ARIA: switch "Unlimited mode" — use getByRole for reliable matching
    const unlimitedSwitch = page.getByRole('switch', { name: 'Unlimited mode' });
    if (await unlimitedSwitch.count() > 0) {
      const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
      if (!isChecked) {
        await unlimitedSwitch.click({ force: true });
        await page.waitForTimeout(500);
        const nowChecked = await unlimitedSwitch.isChecked().catch(() => false);
        console.log(nowChecked ? 'Enabled Unlimited mode' : 'WARNING: Could not enable Unlimited mode');
      } else {
        console.log('Unlimited mode already enabled');
      }
    } else {
      console.log('No Unlimited mode switch found on this page');
    }

    // Fill the prompt - try multiple selectors
    let promptFilled = false;
    // Strategy 1: ARIA textbox named "Prompt"
    const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
    if (await promptByRole.count() > 0) {
      await promptByRole.click({ force: true });
      await page.waitForTimeout(300);
      await promptByRole.fill(prompt, { force: true });
      promptFilled = true;
      console.log(`Entered prompt via ARIA textbox: "${prompt.substring(0, 60)}..."`);
    }
    // Strategy 2: textarea or input with placeholder
    if (!promptFilled) {
      const promptInput = page.locator('textarea, input[placeholder*="Describe" i], input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().click({ force: true });
        await page.waitForTimeout(300);
        await promptInput.first().fill(prompt, { force: true });
        promptFilled = true;
        console.log(`Entered prompt via textarea: "${prompt.substring(0, 60)}..."`);
      }
    }
    // Strategy 3: contenteditable div
    if (!promptFilled) {
      const editable = page.locator('[contenteditable="true"], [role="textbox"]');
      if (await editable.count() > 0) {
        await editable.first().click({ force: true });
        await page.waitForTimeout(300);
        await page.keyboard.press('Meta+a');
        await page.keyboard.type(prompt);
        promptFilled = true;
        console.log(`Entered prompt via contenteditable: "${prompt.substring(0, 60)}..."`);
      }
    }
    if (!promptFilled) {
      console.log('WARNING: Could not find prompt input field');
    }

    // Count existing History items BEFORE generating (to detect new ones)
    // Also snapshot the newest item's prompt text for dedup (CDN URLs can be reused)
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    let existingHistoryCount = 0;
    let existingNewestPrompt = '';
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1500);
      existingHistoryCount = await page.locator('main li').count();
      // Record the newest item's prompt text for dedup comparison
      existingNewestPrompt = await page.evaluate(() => {
        const firstItem = document.querySelector('main li');
        const textbox = firstItem?.querySelector('[role="textbox"], textarea');
        return textbox?.textContent?.trim()?.substring(0, 100) || '';
      });
      console.log(`Existing History items: ${existingHistoryCount}`);
      if (existingNewestPrompt) {
        console.log(`Existing newest prompt: "${existingNewestPrompt.substring(0, 60)}..."`);
      }

      // Switch back to the generation tab to click Generate
      const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:has-text("Generate")');
      if (await createTab.count() > 0) {
        await createTab.first().click({ force: true });
        await page.waitForTimeout(1000);
      }
    }

    // Dry-run mode: stop before clicking Generate
    if (options.dryRun) {
      console.log('[DRY-RUN] Configuration complete. Skipping Generate click.');
      await page.screenshot({ path: join(STATE_DIR, 'dry-run-configured.png'), fullPage: false });
      await context.storageState({ path: STATE_FILE });
      await browser.close();
      return { success: true, dryRun: true };
    }

    // Click generate button
    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      console.log('Clicked Generate button');
    } else {
      console.log('WARNING: Generate button not found');
      await page.screenshot({ path: join(STATE_DIR, 'video-no-generate-btn.png'), fullPage: false });
    }

    await page.waitForTimeout(3000);
    await page.screenshot({ path: join(STATE_DIR, 'video-generate-clicked.png'), fullPage: false });

    // Wait for video generation by polling the History tab for new list items
    const timeout = options.timeout || 600000; // 10 minutes default (videos can take 5-10 min)
    console.log(`Waiting up to ${timeout / 1000}s for video generation...`);
    const startTime = Date.now();

    // Switch to History tab to monitor progress
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1000);
    }

    let generationComplete = false;
    const pollInterval = 10000; // Check every 10 seconds
    let lastRefreshTime = Date.now();
    let wasProcessing = false; // Track if we ever saw a processing state

    // The submitted prompt (first 60 chars) for matching against History items
    const submittedPromptPrefix = prompt.substring(0, 60);

    while (Date.now() - startTime < timeout) {
      await page.waitForTimeout(pollInterval);
      await dismissAllModals(page);

      // Detection strategy for video completion:
      // The History tab has a FIXED display limit (~12 items). New items push old ones
      // out, so item count may NOT increase. Instead we detect completion by:
      // 1. The newest item's prompt matches our submitted prompt
      // 2. The newest item is NOT processing (no "In queue"/"Processing"/"Cancel" text)
      // 3. OR: item count increased (works when History wasn't full)
      const state = await page.evaluate(({ prevCount, prevPrompt, ourPrompt }) => {
        const items = document.querySelectorAll('main li');
        const currentCount = items.length;
        const firstItem = items[0];
        if (!firstItem) return { currentCount, isComplete: false, isProcessing: false };

        const itemText = firstItem.textContent || '';
        const isProcessing = itemText.includes('In queue') || itemText.includes('Processing') || itemText.includes('Cancel');

        // Get prompt text from the newest item
        const textbox = firstItem.querySelector('[role="textbox"], textarea');
        const promptText = textbox?.textContent?.trim() || '';
        const promptPrefix = promptText.substring(0, 60);

        // Check if newest item matches our submitted prompt
        const matchesOurPrompt = ourPrompt && promptPrefix.includes(ourPrompt.substring(0, 40));
        // Check if newest item is different from what was there before
        const isNewItem = prevPrompt && promptPrefix !== prevPrompt.substring(0, 60);
        // Count-based detection (works when History wasn't full)
        const countIncreased = currentCount > prevCount;

        // Complete if: (prompt matches OR new item appeared OR count increased) AND not processing
        const isComplete = !isProcessing && (matchesOurPrompt || isNewItem || countIncreased);

        return { currentCount, isProcessing, promptText: promptPrefix, matchesOurPrompt, isNewItem, countIncreased, isComplete };
      }, { prevCount: existingHistoryCount, prevPrompt: existingNewestPrompt, ourPrompt: submittedPromptPrefix });

      const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);

      if (state.isComplete) {
        const reason = state.matchesOurPrompt ? 'prompt match' : state.isNewItem ? 'new item' : 'count increase';
        console.log(`Video generation complete! (${elapsedSec}s, ${state.currentCount} items, ${reason}, prompt: "${state.promptText}...")`);
        generationComplete = true;
        break;
      }

      // Log progress
      if (state.isProcessing) {
        wasProcessing = true;
        console.log(`  ${elapsedSec}s: processing (${state.currentCount} items)...`);
      } else if (wasProcessing && !state.matchesOurPrompt && !state.isNewItem) {
        // Was processing but now stopped, and no matching item found yet
        // Try refreshing the History tab — the completed item may need a refresh to appear
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
          lastRefreshTime = Date.now();
        } else {
          console.log(`  ${elapsedSec}s: waiting for result (${state.currentCount} items)...`);
        }
      } else {
        console.log(`  ${elapsedSec}s: waiting (${state.currentCount} items, prompt: "${state.promptText?.substring(0, 40)}...")...`);
      }
    }

    if (!generationComplete) {
      console.log('Timeout waiting for video generation. The video may still be processing.');
      console.log('Check back later with: node playwright-automator.mjs download --model video');
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-result.png'), fullPage: false });

    // Download the video from History
    if (generationComplete && options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'videos');
      const videoMeta = { model, promptSnippet: prompt.substring(0, 80) };
      const downloads = await downloadVideoFromHistory(page, outputDir, videoMeta, options);
      if (downloads.length > 0) {
        console.log(`Video downloaded successfully: ${downloads.join(', ')}`);
      } else {
        console.log('Video appeared in History but download failed. Try manually or re-run download command.');
      }
    }

    console.log('Video generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'video-result.png') };

  } catch (error) {
    console.error('Error during video generation:', error.message);
    try { await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}

// Generate lipsync video via UI
// Requires an image (--image-file) and text prompt or audio file
async function generateLipsync(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const prompt = options.prompt || 'Hello! Welcome to our channel. Today we have something amazing to show you.';

    console.log('Navigating to Lipsync Studio...');
    await page.goto(`${BASE_URL}/lipsync-studio`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-page.png'), fullPage: false });

    // Upload character image
    if (options.imageFile) {
      console.log(`Uploading character image: ${options.imageFile}`);
      const fileInput = page.locator('input[type="file"]');
      if (await fileInput.count() > 0) {
        await fileInput.first().setInputFiles(options.imageFile);
        await page.waitForTimeout(3000);
        console.log('Character image uploaded');
      } else {
        // Try clicking an upload button first
        const uploadBtn = page.locator('button:has-text("Upload"), [class*="upload"]');
        if (await uploadBtn.count() > 0) {
          await uploadBtn.first().click({ force: true });
          await page.waitForTimeout(1000);
          const fileInput2 = page.locator('input[type="file"]');
          if (await fileInput2.count() > 0) {
            await fileInput2.first().setInputFiles(options.imageFile);
            await page.waitForTimeout(3000);
            console.log('Character image uploaded (after clicking upload button)');
          }
        }
      }
    } else {
      console.log('WARNING: Lipsync requires a character image (--image-file)');
      await browser.close();
      return { success: false, error: 'Character image required. Use --image-file to provide one.' };
    }

    // Select model if specified
    if (options.model) {
      console.log(`Selecting lipsync model: ${options.model}`);
      const modelSelector = page.locator('button:has-text("Model"), [class*="model"]');
      if (await modelSelector.count() > 0) {
        await modelSelector.first().click({ force: true });
        await page.waitForTimeout(1000);
        const modelOption = page.locator(`[role="option"]:has-text("${options.model}"), button:has-text("${options.model}")`);
        if (await modelOption.count() > 0) {
          await modelOption.first().click({ force: true });
          await page.waitForTimeout(500);
          console.log(`Selected model: ${options.model}`);
        }
      }
    }

    // Fill the text prompt (for text-to-speech lipsync)
    const textInput = page.locator('textarea, input[placeholder*="text" i], input[placeholder*="speak" i], input[placeholder*="say" i]');
    if (await textInput.count() > 0) {
      await textInput.first().click({ force: true });
      await page.waitForTimeout(300);
      await textInput.first().fill(prompt, { force: true });
      console.log(`Entered text: "${prompt}"`);
    }

    // Count existing History items before generating
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    let existingHistoryCount = 0;
    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1500);
      existingHistoryCount = await page.locator('main li').count();
      console.log(`Existing History items: ${existingHistoryCount}`);
      // Switch back
      const createTab = page.locator('[role="tab"]:has-text("Create"), [role="tab"]:first-child');
      if (await createTab.count() > 0) {
        await createTab.first().click({ force: true });
        await page.waitForTimeout(1000);
      }
    }

    // Click generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      console.log('Clicked Generate button');
    }

    await page.waitForTimeout(3000);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-generate-clicked.png'), fullPage: false });

    // Wait for result in History tab
    const timeout = options.timeout || 600000; // 10 min default
    console.log(`Waiting up to ${timeout / 1000}s for lipsync generation...`);
    const startTime = Date.now();

    if (await historyTab.count() > 0) {
      await historyTab.click({ force: true });
      await page.waitForTimeout(1000);
    }

    let generationComplete = false;
    const pollInterval = 10000;

    while (Date.now() - startTime < timeout) {
      await page.waitForTimeout(pollInterval);
      await dismissAllModals(page);

      const currentCount = await page.locator('main li').count();
      if (currentCount > existingHistoryCount) {
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
        console.log(`Lipsync result detected! (${elapsed}s)`);
        generationComplete = true;
        break;
      }

      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      console.log(`  ${elapsed}s: waiting for lipsync result...`);
    }

    if (!generationComplete) {
      console.log('Timeout waiting for lipsync generation.');
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'lipsync-result.png'), fullPage: false });

    // Download from History
    if (generationComplete && options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'lipsync');
      const meta = { model: options.model || 'lipsync', promptSnippet: prompt.substring(0, 80) };
      const downloads = await downloadVideoFromHistory(page, outputDir, meta, options);
      if (downloads.length > 0) {
        console.log(`Lipsync video downloaded: ${downloads.join(', ')}`);
      }
    }

    console.log('Lipsync generation complete');
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, screenshot: join(STATE_DIR, 'lipsync-result.png') };

  } catch (error) {
    console.error('Error during lipsync generation:', error.message);
    try { await page.screenshot({ path: join(STATE_DIR, 'error.png'), fullPage: true }); } catch {}
    try { await browser.close(); } catch {}
    return { success: false, error: error.message };
  }
}

// Navigate to assets page and list recent generations
async function listAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to assets page...');
    await page.goto(`${BASE_URL}/asset/all`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    await page.screenshot({ path: join(STATE_DIR, 'assets-page.png'), fullPage: false });

    // Extract asset information
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

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return assets;

  } catch (error) {
    console.error('Error listing assets:', error.message);
    await browser.close();
    return [];
  }
}

// Extract metadata from the open Asset showcase dialog
// Returns { model, preset, quality, promptSnippet } or null
async function extractDialogMetadata(page) {
  try {
    return await page.evaluate(() => {
      const dialog = document.querySelector('[role="dialog"]');
      if (!dialog) return null;

      const paragraphs = [...dialog.querySelectorAll('p, span, paragraph')];
      const getText = (label) => {
        for (let i = 0; i < paragraphs.length; i++) {
          if (paragraphs[i].textContent?.trim() === label && paragraphs[i + 1]) {
            return paragraphs[i + 1].textContent?.trim();
          }
        }
        return null;
      };

      // The dialog structure: "Model" paragraph followed by model name paragraph,
      // "Preset" followed by preset name, "Quality" followed by quality value
      const model = getText('Model');
      const preset = getText('Preset');
      const quality = getText('Quality');

      // Get prompt text from the tabpanel
      // Structure: p"Prompt", p"{actual prompt text}", p"See all", ...
      const tabpanel = dialog.querySelector('[role="tabpanel"]');
      let promptText = '';
      if (tabpanel) {
        const allP = [...tabpanel.querySelectorAll('p')];
        for (let i = 0; i < allP.length; i++) {
          if (allP[i].textContent?.trim() === 'Prompt' && allP[i + 1]) {
            promptText = allP[i + 1].textContent?.trim() || '';
            break;
          }
        }
        if (!promptText) {
          // Fallback: longest paragraph (likely the prompt)
          promptText = allP
            .map(p => p.textContent?.trim())
            .filter(t => t && t.length > 30)
            .sort((a, b) => b.length - a.length)[0] || '';
        }
      }

      return { model, preset, quality, promptSnippet: promptText.substring(0, 80) };
    });
  } catch {
    return null;
  }
}

// Build a descriptive filename from metadata
// Format: hf_{model}_{quality}_{aspect}_{promptSlug}_{index}.{ext}
function buildDescriptiveFilename(metadata, originalFilename, index) {
  const ext = extname(originalFilename) || '.png';
  const parts = ['hf'];

  if (metadata?.model) {
    parts.push(metadata.model.toLowerCase().replace(/[\s.]+/g, '-').replace(/[^a-z0-9-]/g, ''));
  }
  if (metadata?.quality) {
    parts.push(metadata.quality.toLowerCase());
  }
  if (metadata?.preset && metadata.preset !== 'General') {
    parts.push(metadata.preset.toLowerCase().replace(/[\s.]+/g, '-').replace(/[^a-z0-9-]/g, ''));
  }
  if (metadata?.promptSnippet) {
    const slug = metadata.promptSnippet
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .trim()
      .split(/\s+/)
      .slice(0, 6)
      .join('-');
    if (slug) parts.push(slug);
  }

  // Add timestamp and index for uniqueness
  const ts = new Date().toISOString().replace(/[-:T]/g, '').substring(0, 14);
  parts.push(ts);
  if (index !== undefined) parts.push(String(index + 1));

  return parts.join('_') + ext;
}

// --- Output Organization: project dirs, JSON sidecars, dedup ---

// Resolve the output directory with optional project organization.
// When --project is set, creates: {baseOutput}/{project}/{type}/
// Types: images, videos, lipsync, edits, pipeline, misc
function resolveOutputDir(baseOutput, options = {}, type = 'misc') {
  let dir = baseOutput;

  if (options.project) {
    // Sanitize project name for filesystem
    const projectSlug = options.project
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
    dir = join(baseOutput, projectSlug, type);
  }

  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

// Infer the output type from the command/context
function inferOutputType(command, options = {}) {
  const typeMap = {
    image: 'images',
    video: 'videos',
    lipsync: 'lipsync',
    pipeline: 'pipeline',
    'seed-bracket': 'seed-brackets',
    edit: 'edits',
    inpaint: 'edits',
    upscale: 'upscaled',
    'cinema-studio': 'cinema',
    'motion-control': 'videos',
    'video-edit': 'videos',
    storyboard: 'storyboards',
    'vibe-motion': 'videos',
    influencer: 'characters',
    character: 'characters',
    app: 'apps',
    chain: 'chained',
    'mixed-media': 'mixed-media',
    'motion-preset': 'motion-presets',
    feature: 'features',
    download: options.model === 'video' ? 'videos' : 'images',
  };
  return typeMap[command] || 'misc';
}

// Write a JSON sidecar metadata file alongside a downloaded file.
// Sidecar path: {filePath}.json (e.g., hf_soul_2k_sunset_20260210.png.json)
function writeJsonSidecar(filePath, metadata, options = {}) {
  if (options.noSidecar) return;

  const sidecarPath = `${filePath}.json`;
  const sidecar = {
    source: 'higgsfield-ui-automator',
    version: '1.0',
    timestamp: new Date().toISOString(),
    file: basename(filePath),
    ...metadata,
  };

  // Add file stats if the file exists
  if (existsSync(filePath)) {
    const stats = statSync(filePath);
    sidecar.fileSize = stats.size;
    sidecar.fileSizeHuman = stats.size > 1024 * 1024
      ? `${(stats.size / 1024 / 1024).toFixed(1)}MB`
      : `${(stats.size / 1024).toFixed(1)}KB`;
  }

  try {
    writeFileSync(sidecarPath, JSON.stringify(sidecar, null, 2));
  } catch (err) {
    console.log(`[sidecar] Warning: could not write ${sidecarPath}: ${err.message}`);
  }
}

// Compute SHA-256 hash of a file for deduplication
function computeFileHash(filePath) {
  try {
    const data = readFileSync(filePath);
    return createHash('sha256').update(data).digest('hex');
  } catch {
    return null;
  }
}

// Check if a file is a duplicate of any existing file in the output directory.
// Uses SHA-256 hash comparison. Returns the path of the duplicate if found, null otherwise.
// Maintains a hash index file (.dedup-index.json) in the output directory for fast lookups.
function checkDuplicate(filePath, outputDir, options = {}) {
  if (options.noDedup) return null;

  const hash = computeFileHash(filePath);
  if (!hash) return null;

  const indexPath = join(outputDir, '.dedup-index.json');
  let index = {};

  // Load existing index
  if (existsSync(indexPath)) {
    try {
      index = JSON.parse(readFileSync(indexPath, 'utf-8'));
    } catch { index = {}; }
  }

  // Check for duplicate
  if (index[hash] && index[hash] !== basename(filePath)) {
    const existingPath = join(outputDir, index[hash]);
    if (existsSync(existingPath)) {
      return existingPath;
    }
    // Stale entry — remove it
    delete index[hash];
  }

  // Register this file in the index
  index[hash] = basename(filePath);
  try {
    writeFileSync(indexPath, JSON.stringify(index, null, 2));
  } catch { /* ignore write errors */ }

  return null;
}

// Wrapper: save a downloaded file with sidecar + dedup.
// Returns { path, duplicate, skipped } where duplicate is the existing file path if skipped.
function finalizeDownload(filePath, metadata, outputDir, options = {}) {
  // Check for duplicates
  const duplicate = checkDuplicate(filePath, outputDir, options);
  if (duplicate) {
    console.log(`[dedup] Skipping duplicate: ${basename(filePath)} matches ${basename(duplicate)}`);
    // Remove the duplicate file we just downloaded
    try { unlinkSync(filePath); } catch { /* ignore */ }
    return { path: duplicate, duplicate: true, skipped: true };
  }

  // Write JSON sidecar
  writeJsonSidecar(filePath, metadata, options);

  return { path: filePath, duplicate: false, skipped: false };
}

// Download generated results from the current page
// Strategy: click each generated image to open the "Asset showcase" dialog,
// then click the Download button in the dialog. Falls back to extracting
// CloudFront CDN URLs directly from img[alt="image generation"] elements.
async function downloadLatestResult(page, outputDir, downloadAll = true, options = {}) {
  const downloaded = [];

  try {
    // Dismiss any lingering modals first
    await dismissAllModals(page);

    // Strategy 1: Click generated images to open detail dialog with Download button
    // On image generation pages: img[alt="image generation"]
    // On assets page: img[alt*="media asset by id"]
    const generatedImgs = page.locator('img[alt="image generation"], img[alt*="media asset by id"]');
    const imgCount = await generatedImgs.count();
    console.log(`Found ${imgCount} generated image(s) on page`);

    if (imgCount > 0) {
      const toDownload = downloadAll ? imgCount : 1;

      for (let i = 0; i < toDownload; i++) {
        try {
          // Click the image to open the Asset showcase dialog
          await generatedImgs.nth(i).click({ force: true });
          await page.waitForTimeout(1500);

          // Wait for the dialog to appear
          const dialog = page.locator('dialog, [role="dialog"]');
          const dialogVisible = await dialog.count() > 0;

          if (dialogVisible) {
            // Extract metadata from dialog before downloading
            const metadata = await extractDialogMetadata(page);

            // Look for Download button inside the dialog
            const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
            const dlBtnCount = await dlBtn.count();

            if (dlBtnCount > 0) {
              // Set up download event handler before clicking
              const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
              await dlBtn.first().click({ force: true });

              const download = await downloadPromise;
              if (download) {
                const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${i}.png`;
                const descriptiveName = buildDescriptiveFilename(metadata, origFilename, i);
                const savePath = join(outputDir, descriptiveName);
                await download.saveAs(savePath);
                const result = finalizeDownload(savePath, {
                  command: 'download', type: 'image', ...metadata,
                  originalFilename: origFilename,
                }, outputDir, options);
                if (!result.skipped) {
                  console.log(`Downloaded [${i + 1}/${toDownload}]: ${savePath}`);
                }
                downloaded.push(result.path);
              } else {
                // Download event didn't fire - the button may trigger a blob/fetch download
                // Wait a moment and check if a file appeared
                await page.waitForTimeout(2000);
                console.log(`Download button clicked but no download event for image ${i + 1} - trying CDN fallback`);
              }
            }

            // Close the dialog (press Escape or click outside)
            await page.keyboard.press('Escape');
            await page.waitForTimeout(500);

            // Verify dialog closed, force-remove if not
            const stillOpen = await page.locator('[role="dialog"]').count();
            if (stillOpen > 0) {
              await page.evaluate(() => {
                document.querySelectorAll('[role="dialog"]').forEach(d => {
                  const overlay = d.closest('.react-aria-ModalOverlay') || d.parentElement;
                  if (overlay) overlay.remove();
                  else d.remove();
                });
                document.body.style.overflow = '';
                document.body.style.pointerEvents = '';
              });
            }
          }
        } catch (imgErr) {
          console.log(`Error downloading image ${i + 1}: ${imgErr.message}`);
        }
      }
    }

    // Strategy 2: If dialog-based download didn't work, extract CDN URLs directly
    if (downloaded.length === 0) {
      console.log('Falling back to direct CDN URL extraction...');

      const cdnUrls = await page.evaluate(() => {
        const imgs = document.querySelectorAll('img[alt="image generation"], img[alt*="media asset by id"]');
        return [...imgs].map(img => {
          const src = img.src;
          // Extract the raw CloudFront URL from the cdn-cgi wrapper
          // Format: https://higgsfield.ai/cdn-cgi/image/.../https://d8j0ntlcm91z4.cloudfront.net/...
          const cfMatch = src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
          return cfMatch ? cfMatch[1] : src;
        });
      });

      // Also check for video elements
      const videoUrls = await page.evaluate(() => {
        const videos = document.querySelectorAll('video source[src], video[src]');
        return [...videos].map(v => v.src || v.getAttribute('src')).filter(Boolean);
      });

      const allUrls = [...cdnUrls, ...videoUrls];
      const toDownload = downloadAll ? allUrls : allUrls.slice(0, 1);

      for (let i = 0; i < toDownload.length; i++) {
        const url = toDownload[i];
        const isVideo = url.includes('.mp4') || url.includes('video');
        const ext = isVideo ? '.mp4' : '.webp';
        const cdnMeta = { promptSnippet: 'cdn-fallback' };
        const filename = buildDescriptiveFilename(cdnMeta, `higgsfield-cdn-${Date.now()}${ext}`, i);
        const savePath = join(outputDir, filename);

        try {
          execFileSync('curl', ['-sL', '-o', savePath, url], { timeout: 60000 });
          const result = finalizeDownload(savePath, {
            command: 'download', type: isVideo ? 'video' : 'image',
            cdnUrl: url, strategy: 'cdn-fallback',
          }, outputDir, options);
          if (!result.skipped) {
            console.log(`Downloaded via CDN [${i + 1}/${toDownload.length}]: ${savePath}`);
          }
          downloaded.push(result.path);
        } catch (curlErr) {
          console.log(`CDN download failed for ${url}: ${curlErr.message}`);
        }
      }
    }

    if (downloaded.length === 0) {
      console.log('No downloadable content found');
    } else {
      console.log(`Successfully downloaded ${downloaded.length} file(s)`);
    }

    return downloaded.length === 1 ? downloaded[0] : downloaded;

  } catch (error) {
    console.log('Download attempt failed:', error.message);
    return downloaded.length > 0 ? downloaded : null;
  }
}

// Download specific images by their index on the page
// Uses the same dialog-based approach as downloadLatestResult but only for specified indices
async function downloadSpecificImages(page, outputDir, indices, options = {}) {
  const downloaded = [];
  const generatedImgs = page.locator('img[alt="image generation"], img[alt*="media asset by id"]');

  for (const idx of indices) {
    try {
      // Click the image to open the Asset showcase dialog
      await generatedImgs.nth(idx).click({ force: true });
      await page.waitForTimeout(1500);

      // Wait for dialog
      const dialog = page.locator('[role="dialog"]');
      if (await dialog.count() > 0) {
        // Extract metadata for descriptive filename
        const metadata = await extractDialogMetadata(page);

        const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
        if (await dlBtn.count() > 0) {
          const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
          await dlBtn.first().click({ force: true });

          const download = await downloadPromise;
          if (download) {
            const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${idx}.png`;
            const descriptiveName = buildDescriptiveFilename(metadata, origFilename, downloaded.length);
            const savePath = join(outputDir, descriptiveName);
            await download.saveAs(savePath);
            const result = finalizeDownload(savePath, {
              command: 'image', type: 'image', ...metadata,
              originalFilename: origFilename, imageIndex: idx,
            }, outputDir, options);
            if (!result.skipped) {
              console.log(`Downloaded [${downloaded.length + 1}/${indices.length}]: ${savePath}`);
            }
            downloaded.push(result.path);
          }
        }

        // Close dialog
        await page.keyboard.press('Escape');
        await page.waitForTimeout(500);
        const stillOpen = await page.locator('[role="dialog"]').count();
        if (stillOpen > 0) {
          await page.evaluate(() => {
            document.querySelectorAll('[role="dialog"]').forEach(d => {
              const overlay = d.closest('.react-aria-ModalOverlay') || d.parentElement;
              if (overlay) overlay.remove();
              else d.remove();
            });
            document.body.style.overflow = '';
            document.body.style.pointerEvents = '';
          });
        }
      }
    } catch (err) {
      console.log(`Error downloading image at index ${idx}: ${err.message}`);
    }
  }

  // CDN fallback for any that failed
  if (downloaded.length < indices.length) {
    console.log(`Dialog download got ${downloaded.length}/${indices.length}, trying CDN fallback for remainder...`);
    const cdnUrls = await page.evaluate((idxList) => {
      const imgs = document.querySelectorAll('img[alt="image generation"], img[alt*="media asset by id"]');
      return idxList.map(idx => {
        const img = imgs[idx];
        if (!img) return null;
        const cfMatch = img.src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
        return cfMatch ? cfMatch[1] : img.src;
      }).filter(Boolean);
    }, indices.slice(downloaded.length));

    for (let i = 0; i < cdnUrls.length; i++) {
      const ext = cdnUrls[i].includes('.mp4') ? '.mp4' : '.webp';
      const cdnMeta = { promptSnippet: 'cdn-fallback' };
      const filename = buildDescriptiveFilename(cdnMeta, `higgsfield-cdn-${Date.now()}${ext}`, downloaded.length);
      const savePath = join(outputDir, filename);
      try {
        execFileSync('curl', ['-sL', '-o', savePath, cdnUrls[i]], { timeout: 60000 });
        const result = finalizeDownload(savePath, {
          command: 'image', type: 'image', cdnUrl: cdnUrls[i],
          strategy: 'cdn-fallback', imageIndex: indices[downloaded.length],
        }, outputDir, options);
        if (!result.skipped) {
          console.log(`Downloaded via CDN [${downloaded.length + 1}]: ${savePath}`);
        }
        downloaded.push(result.path);
      } catch (curlErr) {
        console.log(`CDN download failed: ${curlErr.message}`);
      }
    }
  }

  console.log(`Successfully downloaded ${downloaded.length} file(s)`);
  return downloaded;
}

// Use a specific app/effect
async function useApp(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const appSlug = options.effect || 'face-swap';
    console.log(`Navigating to app: ${appSlug}...`);
    await page.goto(`${BASE_URL}/app/${appSlug}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    // Dismiss any promo modals
    await dismissAllModals(page);

    await page.screenshot({ path: join(STATE_DIR, `app-${appSlug}.png`), fullPage: false });

    // Upload image if provided
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]');
      if (await fileInput.count() > 0) {
        await fileInput.first().setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Image uploaded to app');
      }
    }

    // Fill prompt if available
    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    // Click generate/create
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply"), button[type="submit"]:visible');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked generate/apply button');
    }

    // Wait for result
    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], video', {
        timeout,
        state: 'visible'
      });
    } catch {
      console.log('Timeout waiting for app result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `app-${appSlug}-result.png`), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'apps');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };

  } catch (error) {
    console.error('Error using app:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Take a screenshot of any Higgsfield page
async function screenshot(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const url = options.prompt || `${BASE_URL}/asset/all`;
    console.log(`Navigating to ${url}...`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);

    const outputPath = options.output || join(STATE_DIR, 'screenshot.png');
    await page.screenshot({ path: outputPath, fullPage: false });
    console.log(`Screenshot saved to: ${outputPath}`);

    // Also get ARIA snapshot for AI understanding
    const ariaSnapshot = await page.locator('body').ariaSnapshot();
    console.log('\n--- ARIA Snapshot ---');
    console.log(ariaSnapshot.substring(0, 3000));

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, path: outputPath };

  } catch (error) {
    console.error('Screenshot error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Check account credits/status via the subscription settings page
async function checkCredits(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Checking account credits...');
    await page.goto(`${BASE_URL}/me/settings/subscription`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    // Scroll down to load the unlimited models table
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await page.waitForTimeout(2000);

    // Change rows-per-page to 50 so all models are visible on one page
    const rowsPerPageSelect = page.locator('select');
    if (await rowsPerPageSelect.count() > 0) {
      await rowsPerPageSelect.selectOption('50');
      await page.waitForTimeout(2000);
      console.log('Set rows per page to 50 to show all models');
    }

    // Extract credit info
    const creditInfo = await page.evaluate(() => {
      const text = document.body.innerText;

      // Parse "6 004/ 6 000" or "6,004/ 6,000" format
      const creditMatch = text.match(/([\d\s,]+)\/([\d\s,]+)/);
      const remaining = creditMatch ? creditMatch[1].trim().replace(/[\s,]/g, '') : 'unknown';
      const total = creditMatch ? creditMatch[2].trim().replace(/[\s,]/g, '') : 'unknown';

      // Parse plan name
      const planMatch = text.match(/(Creator|Team|Enterprise|Free)\s*Plan/i);
      const plan = planMatch ? planMatch[1] : 'unknown';

      // Parse unlimited models from the table (all rows now visible)
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

      // Parse pagination info for verification
      const pageInfo = text.match(/Page (\d+) of (\d+)/);
      const currentPage = pageInfo ? parseInt(pageInfo[1], 10) : 1;
      const totalPages = pageInfo ? parseInt(pageInfo[2], 10) : 1;

      return { remaining, total, plan, unlimitedModels, currentPage, totalPages };
    });

    console.log(`Plan: ${creditInfo.plan}`);
    console.log(`Credits: ${creditInfo.remaining} / ${creditInfo.total}`);
    console.log(`\nUnlimited models (${creditInfo.unlimitedModels.length}):`);
    creditInfo.unlimitedModels.forEach(m => {
      console.log(`  ${m.model} (expires: ${m.expires})`);
    });

    if (creditInfo.totalPages > 1) {
      console.log(`\nWARNING: Still showing page ${creditInfo.currentPage} of ${creditInfo.totalPages} - some models may be missing`);
    }

    // Cache credit info for credit guard checks
    saveCreditCache(creditInfo);

    await page.screenshot({ path: join(STATE_DIR, 'subscription.png'), fullPage: true });
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return creditInfo;

  } catch (error) {
    console.error('Error checking credits:', error.message);
    await browser.close();
    return null;
  }
}

// Seed bracketing: test a range of seeds with the same prompt to find winners
// Based on the technique from "How I Cut AI Video Costs By 60%"
// Recommended ranges: people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999
async function seedBracket(options = {}) {
  const prompt = options.prompt;
  if (!prompt) {
    console.error('ERROR: --prompt is required for seed bracketing');
    process.exit(1);
  }

  // Parse seed range: "1000-1010" or "1000,1005,1010"
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
  const outputDir = options.output || join(DOWNLOAD_DIR, `seed-bracket-${Date.now()}`);
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  const results = [];

  for (const seed of seeds) {
    console.log(`\n--- Testing seed ${seed} ---`);
    // Generate with this specific seed
    // Note: Higgsfield UI may not expose seed control directly.
    // For image models, we append the seed to the prompt as a hint.
    // For video models with explicit seed fields, we'd fill that instead.
    const seedPrompt = `${prompt} --seed ${seed}`;
    const result = await generateImage({
      ...options,
      prompt: seedPrompt,
      output: outputDir,
      batch: 1, // Single image per seed for efficiency
    });
    results.push({ seed, ...result });
    console.log(`Seed ${seed}: ${result?.success ? 'OK' : 'FAILED'}`);
  }

  // Summary
  console.log(`\n=== Seed Bracket Results ===`);
  console.log(`Prompt: "${prompt}"`);
  console.log(`Model: ${model}`);
  console.log(`Output: ${outputDir}`);
  console.log(`Results: ${results.filter(r => r.success).length}/${results.length} successful`);
  console.log(`\nReview the images in ${outputDir} and note the best seeds.`);
  console.log(`Then use --seed <number> with your chosen seed for consistent results.`);

  // Save results manifest
  const manifest = {
    prompt,
    model,
    seeds: results.map(r => ({ seed: r.seed, success: r.success })),
    timestamp: new Date().toISOString(),
  };
  writeFileSync(join(outputDir, 'bracket-results.json'), JSON.stringify(manifest, null, 2));
  console.log(`Results saved to ${join(outputDir, 'bracket-results.json')}`);

  return results;
}

// Video production pipeline: chains image -> video -> lipsync -> assembly
// Reads a brief JSON file or uses CLI options to define the production
//
// Brief format (JSON):
// {
//   "title": "Product Demo Short",
//   "character": { "description": "Young woman, brown hair...", "image": "/path/to/face.png" },
//   "scenes": [
//     { "prompt": "Close-up of character holding product...", "duration": 5, "dialogue": "Check this out!" },
//     { "prompt": "Wide shot of character in kitchen...", "duration": 5, "dialogue": "It changed my life." }
//   ],
//   "imageModel": "soul",
//   "videoModel": "kling-2.6",
//   "aspect": "9:16",
//   "music": "/path/to/background.mp3"
// }

// Submit a video generation job on an already-open page (no browser open/close).
// Used by the parallel pipeline to submit multiple jobs before waiting.
// Returns the submitted prompt prefix for tracking, or null on failure.
async function submitVideoJobOnPage(page, sceneOptions) {
  const prompt = sceneOptions.prompt || '';
  const model = sceneOptions.model || 'kling-2.6';

  try {
    // Navigate to video creation page
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);

    // Upload start frame if provided
    if (sceneOptions.imageFile) {
      // Remove existing start frame if present
      const existingFrame = page.getByRole('button', { name: 'Uploaded image' });
      if (await existingFrame.count() > 0) {
        const smallButtons = await page.evaluate(() => {
          const btns = [...document.querySelectorAll('main button')];
          return btns
            .filter(b => { const r = b.getBoundingClientRect(); return r.width <= 24 && r.height <= 24 && r.y > 200 && r.y < 300; })
            .map(b => ({ x: b.getBoundingClientRect().x + 10, y: b.getBoundingClientRect().y + 10 }));
        });
        if (smallButtons.length > 0) {
          await page.mouse.click(smallButtons[0].x, smallButtons[0].y);
          await page.waitForTimeout(1500);
        }
      }

      // Upload via file chooser
      let uploaded = false;
      const uploadBtn = page.getByRole('button', { name: /Upload image/ });
      if (!uploaded && await uploadBtn.count() > 0) {
        try {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 10000 }),
            uploadBtn.click({ force: true }),
          ]);
          await fileChooser.setFiles(sceneOptions.imageFile);
          await page.waitForTimeout(3000);
          uploaded = true;
        } catch {}
      }
      if (!uploaded) {
        const startFrameBtn = page.locator('text=Start frame').first();
        if (await startFrameBtn.count() > 0) {
          try {
            const [fileChooser] = await Promise.all([
              page.waitForEvent('filechooser', { timeout: 10000 }),
              startFrameBtn.click({ force: true }),
            ]);
            await fileChooser.setFiles(sceneOptions.imageFile);
            await page.waitForTimeout(3000);
            uploaded = true;
          } catch {}
        }
      }
      if (!uploaded) {
        console.log(`  WARNING: Could not upload start frame for: "${prompt.substring(0, 40)}..."`);
      }
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);

    // Select model
    const modelNameMap = {
      'kling-3.0': 'Kling 3.0', 'kling-2.6': 'Kling 2.6', 'kling-2.5': 'Kling 2.5',
      'kling-2.1': 'Kling 2.1', 'kling-motion': 'Kling Motion Control',
      'seedance': 'Seedance', 'grok': 'Grok Imagine', 'minimax': 'Minimax Hailuo',
      'wan-2.1': 'Wan 2.1', 'sora': 'Sora', 'veo': 'Veo', 'veo-3': 'Veo 3',
    };
    const uiModelName = modelNameMap[model] || model;
    const modelSelector = page.getByRole('button', { name: 'Model' });
    if (await modelSelector.count() > 0) {
      const currentModel = await modelSelector.textContent().catch(() => '');
      if (!currentModel.includes(uiModelName)) {
        await modelSelector.click({ force: true });
        await page.waitForTimeout(1500);
        const matchingBtns = await page.evaluate((mn) => {
          return [...document.querySelectorAll('button')]
            .filter(b => b.textContent?.includes(mn) && b.offsetParent !== null)
            .map(b => { const r = b.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; })
            .filter(b => b.x < 800 && b.x > 100);
        }, uiModelName);
        if (matchingBtns.length > 0) {
          await page.mouse.click(matchingBtns[0].x + matchingBtns[0].w / 2, matchingBtns[0].y + matchingBtns[0].h / 2);
          await page.waitForTimeout(1500);
        } else {
          await page.keyboard.press('Escape');
        }
      }
    }

    // Enable unlimited mode
    const unlimitedSwitch = page.getByRole('switch', { name: 'Unlimited mode' });
    if (await unlimitedSwitch.count() > 0) {
      const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
      if (!isChecked) {
        await unlimitedSwitch.click({ force: true });
        await page.waitForTimeout(500);
      }
    }

    // Fill prompt
    const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
    if (await promptByRole.count() > 0) {
      await promptByRole.click({ force: true });
      await page.waitForTimeout(300);
      await promptByRole.fill(prompt, { force: true });
    }

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      await page.waitForTimeout(3000);
      console.log(`  Submitted: "${prompt.substring(0, 60)}..."`);
      return prompt.substring(0, 60);
    }

    console.log(`  Failed to submit: "${prompt.substring(0, 40)}..." (no Generate button)`);
    return null;
  } catch (err) {
    console.log(`  Submit error: ${err.message}`);
    return null;
  }
}

// Poll History tab for multiple submitted video prompts and download all via API.
// Returns an array of { sceneIndex, path } for successfully downloaded videos.
async function pollAndDownloadVideos(page, submittedJobs, outputDir, timeout = 600000) {
  const results = new Map(); // sceneIndex -> path
  const startTime = Date.now();
  const pollInterval = 15000;

  console.log(`Polling for ${submittedJobs.length} video(s) (timeout: ${timeout / 1000}s)...`);

  // Switch to History tab
  const historyTab = page.locator('[role="tab"]:has-text("History")');
  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(2000);
  }

  while (Date.now() - startTime < timeout && results.size < submittedJobs.length) {
    await page.waitForTimeout(pollInterval);
    await dismissAllModals(page);

    // Get all History items with their prompt text and processing status
    const historyItems = await page.evaluate(() => {
      const items = document.querySelectorAll('main li');
      return [...items].map((item, i) => {
        const textbox = item.querySelector('[role="textbox"], textarea');
        const promptText = textbox?.textContent?.trim()?.substring(0, 80) || '';
        const itemText = item.textContent || '';
        const isProcessing = itemText.includes('In queue') || itemText.includes('Processing') || itemText.includes('Cancel');
        return { index: i, promptText, isProcessing };
      });
    });

    const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(0);
    let completedThisPoll = 0;
    let processingCount = 0;

    for (const job of submittedJobs) {
      if (results.has(job.sceneIndex)) continue; // Already downloaded

      // Find matching History item by prompt prefix
      const match = historyItems.find(h =>
        h.promptText.substring(0, 40).includes(job.promptPrefix.substring(0, 40)) ||
        job.promptPrefix.substring(0, 40).includes(h.promptText.substring(0, 40))
      );

      if (match && !match.isProcessing) {
        completedThisPoll++;
      } else if (match && match.isProcessing) {
        processingCount++;
      }
    }

    const pendingCount = submittedJobs.length - results.size;
    console.log(`  ${elapsedSec}s: ${results.size} done, ${processingCount} processing, ${pendingCount - processingCount - completedThisPoll} waiting`);

    // If any new completions detected, download them via API
    if (completedThisPoll > 0) {
      console.log(`  ${completedThisPoll} new completion(s) detected, downloading via API...`);

      // Intercept API to get all video URLs — try multiple approaches
      let projectApiData = null;
      const apiHandler = async (response) => {
        const url = response.url();
        // Catch project API, job_sets API, or any Higgsfield API with video data
        if (url.includes('fnf.higgsfield.ai/project') ||
            url.includes('fnf.higgsfield.ai/job') ||
            url.includes('higgsfield.ai/api/')) {
          try {
            const data = await response.json();
            // Accept any response that has job_sets with video URLs
            if (data?.job_sets?.length > 0) {
              projectApiData = data;
            }
          } catch {}
        }
      };
      page.on('response', apiHandler);

      // Navigate to video creation page to trigger API call (reload may not fire it)
      await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await page.waitForTimeout(4000);

      // Click History tab to load job data
      const histTab = page.locator('[role="tab"]:has-text("History")');
      if (await histTab.count() > 0) {
        await histTab.click({ force: true });
        await page.waitForTimeout(4000);
      }

      // If no API data yet, try a page reload as fallback
      if (!projectApiData) {
        await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
        await page.waitForTimeout(6000);
      }

      page.off('response', apiHandler);

      // Fallback: Direct API fetch using the page's auth context.
      // The API interception can miss responses if they arrive before the listener
      // is attached or if the page caches the data. Fetching directly is more reliable.
      if (!projectApiData) {
        console.log(`  API interception missed. Trying direct fetch...`);
        try {
          projectApiData = await page.evaluate(async () => {
            // The Higgsfield API endpoint for video history
            const resp = await fetch('https://fnf.higgsfield.ai/project?job_set_type=image2video&limit=20&offset=0', {
              credentials: 'include',
              headers: { 'Accept': 'application/json' },
            });
            if (resp.ok) return await resp.json();
            return null;
          });
          if (projectApiData?.job_sets?.length > 0) {
            console.log(`  Direct fetch got ${projectApiData.job_sets.length} job set(s)`);
          }
        } catch (fetchErr) {
          console.log(`  Direct fetch failed: ${fetchErr.message}`);
        }
      }

      if (!projectApiData) {
        console.log(`  WARNING: No API data captured. API interception may need updating.`);
      }

      if (projectApiData?.job_sets?.length > 0) {
        if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

        // Match API job_sets to our submitted jobs by prompt text.
        // CRITICAL: Track matched jobSets to prevent the same video being
        // downloaded for multiple scenes (each jobSet matches exactly one scene).
        const matchedJobSetIds = new Set();

        // Pre-filter to only completed jobSets with downloadable videos
        const completedJobSets = projectApiData.job_sets.filter(js =>
          (js.jobs || []).some(j => j.status === 'completed' && j.results?.raw?.url?.includes('cloudfront.net'))
        );

        // Strategy 1: Prompt-based matching (works for most models)
        for (const job of submittedJobs) {
          if (results.has(job.sceneIndex)) continue;

          let bestMatch = null;
          let bestScore = 0;

          for (const jobSet of completedJobSets) {
            const jobSetId = jobSet.id || jobSet.prompt;
            if (matchedJobSetIds.has(jobSetId)) continue;

            const jobPrompt = jobSet.prompt || '';
            const submittedPrompt = job.promptPrefix || '';

            // Score the match: longer matching prefix = better match
            let score = 0;
            const minLen = Math.min(jobPrompt.length, submittedPrompt.length, 60);
            for (let c = 0; c < minLen; c++) {
              if (jobPrompt[c] === submittedPrompt[c]) score++;
              else break;
            }

            if (score >= 20 && score > bestScore) {
              bestMatch = jobSet;
              bestScore = score;
            }
          }

          if (bestMatch) {
            const bestId = bestMatch.id || bestMatch.prompt;
            matchedJobSetIds.add(bestId);
            job._matchedJobSet = bestMatch;
            job._matchMethod = 'prompt';
          }
        }

        // Strategy 2: Order-based fallback for models with empty prompts (e.g. Seedance).
        // The API returns job_sets newest-first. Our submittedJobs are in scene order
        // (oldest submission first). So we reverse-match: the Nth unmatched submitted
        // job corresponds to the Nth-from-last unmatched completed jobSet.
        const unmatchedJobs = submittedJobs.filter(j => !results.has(j.sceneIndex) && !j._matchedJobSet);
        if (unmatchedJobs.length > 0) {
          const unmatchedJobSets = completedJobSets.filter(js => {
            const jsId = js.id || js.prompt;
            return !matchedJobSetIds.has(jsId);
          });

          // API returns newest first; submitted jobs are in chronological order.
          // Reverse the unmatched jobSets so index 0 = oldest = first submitted.
          const reversedJobSets = [...unmatchedJobSets].reverse();

          for (let i = 0; i < unmatchedJobs.length && i < reversedJobSets.length; i++) {
            const job = unmatchedJobs[i];
            const jobSet = reversedJobSets[i];
            const jsId = jobSet.id || jobSet.prompt;
            matchedJobSetIds.add(jsId);
            job._matchedJobSet = jobSet;
            job._matchMethod = 'order';
            console.log(`  Scene ${job.sceneIndex + 1}: order-based match (empty prompt fallback)`);
          }
        }

        for (const job of submittedJobs) {
          if (results.has(job.sceneIndex)) continue;
          const bestMatch = job._matchedJobSet;
          if (!bestMatch) continue;
          delete job._matchedJobSet;

          // Download the completed video (jobSet already claimed above)
          for (const j of (bestMatch.jobs || [])) {
            if (j.status === 'completed' && j.results?.raw?.url?.includes('cloudfront.net')) {
              const videoUrl = j.results.raw.url;
              const meta = { model: job.model, promptSnippet: job.promptPrefix };
              const filename = buildDescriptiveFilename(meta, `scene-${job.sceneIndex + 1}-${Date.now()}.mp4`, job.sceneIndex);
              const savePath = join(outputDir, filename);
              try {
                const curlResult = execFileSync('curl', ['-sL', '-w', '%{http_code}', '-o', savePath, videoUrl], { timeout: 120000, encoding: 'utf-8' });
                const httpCode = curlResult.trim();
                if (httpCode === '200' && existsSync(savePath) && statSync(savePath).size > 10000) {
                  const fileSize = statSync(savePath).size;
                  // Write JSON sidecar for pipeline scene video
                  writeJsonSidecar(savePath, {
                    command: 'pipeline', type: 'video', ...meta,
                    sceneIndex: job.sceneIndex, strategy: 'api-interception',
                    cloudFrontUrl: videoUrl, matchScore: bestScore,
                  });
                  const matchMethod = job._matchMethod || 'prompt';
                  console.log(`  Scene ${job.sceneIndex + 1}: downloaded (${(fileSize / 1024 / 1024).toFixed(1)}MB) ${filename}`);
                  console.log(`    Match method: ${matchMethod}, prompt: "${(bestMatch.prompt || '(empty)').substring(0, 60)}"`);
                  results.set(job.sceneIndex, savePath);
                }
              } catch {}
              break;
            }
          }
        }
      }

      // Re-click History tab after reload for continued polling
      if (await historyTab.count() > 0) {
        await historyTab.click({ force: true });
        await page.waitForTimeout(2000);
      }
    }
  }

  if (results.size < submittedJobs.length) {
    const missing = submittedJobs.filter(j => !results.has(j.sceneIndex)).map(j => j.sceneIndex + 1);
    console.log(`Timeout: ${results.size}/${submittedJobs.length} videos downloaded. Missing scenes: ${missing.join(', ')}`);
  } else {
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    console.log(`All ${results.size} videos downloaded in ${elapsed}s`);
  }

  return results;
}

// ffmpeg fallback for video assembly (no captions/transitions)
function assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState) {
  if (validVideos.length === 1) {
    copyFileSync(validVideos[0], finalPath);
    console.log(`Final video (single scene, ffmpeg copy): ${finalPath}`);
  } else {
    const concatList = join(outputDir, 'concat-list.txt');
    const concatContent = validVideos.map(v => `file '${v}'`).join('\n');
    writeFileSync(concatList, concatContent);

    try {
      execFileSync('ffmpeg', ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c', 'copy', finalPath], {
        timeout: 120000,
        stdio: 'pipe',
      });
      console.log(`Final video (ffmpeg concat, ${validVideos.length} scenes): ${finalPath}`);
    } catch (ffmpegErr) {
      try {
        execFileSync('ffmpeg', ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c:v', 'libx264', '-c:a', 'aac', '-movflags', '+faststart', finalPath], {
          timeout: 300000,
          stdio: 'pipe',
        });
        console.log(`Final video (ffmpeg re-encoded, ${validVideos.length} scenes): ${finalPath}`);
      } catch (reencodeErr) {
        console.log(`ffmpeg assembly failed: ${reencodeErr.message}`);
        console.log(`Individual scene videos are in: ${outputDir}`);
        pipelineState.steps.push({ step: 'assembly', success: false, method: 'ffmpeg', reason: reencodeErr.message });
        return;
      }
    }
  }

  // Add background music if specified
  if (brief.music && existsSync(brief.music) && existsSync(finalPath)) {
    const withMusicPath = finalPath.replace('-final.mp4', '-final-music.mp4');
    try {
      execFileSync('ffmpeg', ['-y', '-i', finalPath, '-i', brief.music, '-c:v', 'copy', '-c:a', 'aac', '-map', '0:v:0', '-map', '1:a:0', '-shortest', withMusicPath], {
        timeout: 120000,
        stdio: 'pipe',
      });
      console.log(`Final video with music: ${withMusicPath}`);
    } catch (musicErr) {
      console.log(`Adding music failed: ${musicErr.message}`);
    }
  }

  pipelineState.steps.push({ step: 'assembly', success: true, method: 'ffmpeg', path: finalPath });
}

async function pipeline(options = {}) {
  // Load brief from file or construct from CLI options
  let brief;
  if (options.brief) {
    if (!existsSync(options.brief)) {
      console.error(`ERROR: Brief file not found: ${options.brief}`);
      process.exit(1);
    }
    brief = JSON.parse(readFileSync(options.brief, 'utf-8'));
  } else {
    // Construct minimal brief from CLI options
    brief = {
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

  const outputDir = options.output || join(DOWNLOAD_DIR, `pipeline-${Date.now()}`);
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  console.log(`\n=== Video Production Pipeline ===`);
  console.log(`Title: ${brief.title}`);
  console.log(`Scenes: ${brief.scenes.length}`);
  console.log(`Image model: ${brief.imageModel}`);
  console.log(`Video model: ${brief.videoModel}`);
  console.log(`Aspect: ${brief.aspect}`);
  console.log(`Output: ${outputDir}`);

  const pipelineState = {
    brief,
    outputDir,
    steps: [],
    startTime: Date.now(),
  };

  // Step 1: Generate character image if not provided
  let characterImagePath = brief.character?.image;
  if (!characterImagePath) {
    console.log(`\n--- Step 1: Generate character image ---`);
    const charPrompt = brief.character?.description || 'A photorealistic portrait of a friendly young person, neutral expression, studio lighting, high quality';
    console.log(`Prompt: "${charPrompt.substring(0, 80)}..."`);

    const charResult = await generateImage({
      ...options,
      prompt: charPrompt,
      model: brief.imageModel,
      aspect: '1:1', // Square for character portraits
      batch: 1,
      output: outputDir,
    });

    if (charResult?.success) {
      // Find the most recently created file in outputDir
      const files = existsSync(outputDir) ? readdirSync(outputDir)
        .filter(f => f.endsWith('.png') || f.endsWith('.jpg') || f.endsWith('.webp'))
        .map(f => ({ name: f, time: statSync(join(outputDir, f)).mtimeMs }))
        .sort((a, b) => b.time - a.time) : [];
      characterImagePath = files.length > 0 ? join(outputDir, files[0].name) : null;
      console.log(`Character image: ${characterImagePath || 'NOT FOUND'}`);
      pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath });
    } else {
      console.log('WARNING: Character image generation failed, continuing without it');
      pipelineState.steps.push({ step: 'character-image', success: false });
    }
  } else {
    console.log(`\n--- Step 1: Using provided character image: ${characterImagePath} ---`);
    pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath, provided: true });
  }

  // Step 2: Generate scene images (one per scene)
  // If brief.imagePrompts[] exists, use those for image generation (separate from video prompts)
  console.log(`\n--- Step 2: Generate scene images (${brief.scenes.length} scenes) ---`);
  if (brief.imagePrompts?.length > 0) {
    console.log(`Using separate imagePrompts for start frame generation`);
  }
  const sceneImages = [];

  for (let i = 0; i < brief.scenes.length; i++) {
    const scene = brief.scenes[i];
    const imagePrompt = brief.imagePrompts?.[i] || scene.prompt;
    console.log(`\nScene ${i + 1}/${brief.scenes.length}: "${imagePrompt?.substring(0, 60)}..."`);

    const sceneResult = await generateImage({
      ...options,
      prompt: imagePrompt,
      model: brief.imageModel,
      aspect: brief.aspect,
      batch: 1,
      output: outputDir,
    });

    if (sceneResult?.success) {
      // Find the newest image file
      const files = readdirSync(outputDir)
        .filter(f => (f.endsWith('.png') || f.endsWith('.jpg') || f.endsWith('.webp')) && f.includes('hf_'))
        .map(f => ({ name: f, time: statSync(join(outputDir, f)).mtimeMs }))
        .sort((a, b) => b.time - a.time);
      const scenePath = files.length > 0 ? join(outputDir, files[0].name) : null;
      sceneImages.push(scenePath);
      console.log(`Scene ${i + 1} image: ${scenePath || 'NOT FOUND'}`);
    } else {
      sceneImages.push(null);
      console.log(`Scene ${i + 1} image generation failed`);
    }
  }
  pipelineState.steps.push({ step: 'scene-images', count: sceneImages.filter(Boolean).length, total: brief.scenes.length });

  // Step 3: Animate scene images into video clips (PARALLEL submission)
  // Instead of sequential generate-wait-generate-wait, we:
  //   3a. Submit ALL video jobs in one browser session (fast, ~30s each)
  //   3b. Poll History tab for ALL prompts simultaneously
  //   3c. Download all completed videos via API interception
  // This cuts N*4min to ~4min for N scenes.
  const validScenes = brief.scenes
    .map((scene, i) => ({ scene, index: i, image: sceneImages[i] }))
    .filter(s => s.image);
  const skippedScenes = brief.scenes.length - validScenes.length;
  if (skippedScenes > 0) console.log(`Skipping ${skippedScenes} scene(s) with no image`);

  console.log(`\n--- Step 3a: Submit ${validScenes.length} video job(s) in parallel ---`);
  const sceneVideos = new Array(brief.scenes.length).fill(null);

  if (validScenes.length > 0) {
    const { browser: videoBrowser, context: videoCtx, page: videoPage } = await launchBrowser(options);

    try {
      const submittedJobs = [];

      for (const { scene, index, image } of validScenes) {
        console.log(`\n  Submitting scene ${index + 1}/${brief.scenes.length}...`);
        const promptPrefix = await submitVideoJobOnPage(videoPage, {
          prompt: scene.prompt,
          imageFile: image,
          model: brief.videoModel,
          duration: String(scene.duration || 5),
        });

        if (promptPrefix) {
          submittedJobs.push({
            sceneIndex: index,
            promptPrefix,
            model: brief.videoModel,
          });
        }
      }

      if (submittedJobs.length > 0) {
        console.log(`\n--- Step 3b: Polling for ${submittedJobs.length} video(s) ---`);
        const videoResults = await pollAndDownloadVideos(
          videoPage, submittedJobs, outputDir, options.timeout || 600000
        );

        // Map results back to scene order
        for (const [sceneIndex, path] of videoResults) {
          sceneVideos[sceneIndex] = path;
        }
      }

      await videoCtx.storageState({ path: STATE_FILE });
    } catch (err) {
      console.error('Error during parallel video generation:', err.message);
    }
    try { await videoBrowser.close(); } catch {}
  }

  const videoCount = sceneVideos.filter(Boolean).length;
  console.log(`\nVideo generation: ${videoCount}/${brief.scenes.length} scenes completed`);
  pipelineState.steps.push({ step: 'scene-videos', count: videoCount, total: brief.scenes.length });

  // Step 4: Add lipsync dialogue to scenes that have it
  console.log(`\n--- Step 4: Add lipsync dialogue ---`);
  const scenesWithDialogue = brief.scenes.filter(s => s.dialogue);
  const lipsyncVideos = [];

  if (scenesWithDialogue.length > 0 && characterImagePath) {
    for (let i = 0; i < brief.scenes.length; i++) {
      const scene = brief.scenes[i];
      if (!scene.dialogue) {
        lipsyncVideos.push(sceneVideos[i]); // Keep original video
        continue;
      }

      console.log(`\nLipsync scene ${i + 1}: "${scene.dialogue.substring(0, 60)}..."`);
      const lipsyncResult = await generateLipsync({
        ...options,
        prompt: scene.dialogue,
        imageFile: characterImagePath,
        output: outputDir,
      });

      if (lipsyncResult?.success) {
        const files = readdirSync(outputDir)
          .filter(f => f.endsWith('.mp4'))
          .map(f => ({ name: f, time: statSync(join(outputDir, f)).mtimeMs }))
          .sort((a, b) => b.time - a.time);
        const lipsyncPath = files.length > 0 ? join(outputDir, files[0].name) : null;
        lipsyncVideos.push(lipsyncPath);
        console.log(`Lipsync video: ${lipsyncPath || 'NOT FOUND'}`);
      } else {
        lipsyncVideos.push(sceneVideos[i]); // Fall back to non-lipsync video
        console.log(`Lipsync failed, using original video for scene ${i + 1}`);
      }
    }
  } else {
    console.log('No dialogue scenes or no character image - skipping lipsync');
    lipsyncVideos.push(...sceneVideos);
  }
  pipelineState.steps.push({ step: 'lipsync', count: lipsyncVideos.filter(Boolean).length });

  // Step 5: Assemble final video with Remotion (captions + transitions)
  // Falls back to ffmpeg concat if Remotion is not installed
  console.log(`\n--- Step 5: Assemble final video ---`);
  const validVideos = lipsyncVideos.filter(Boolean);

  if (validVideos.length > 0) {
    const finalPath = join(outputDir, `${brief.title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-final.mp4`);
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const remotionDir = join(__dirname, 'remotion');
    const remotionInstalled = existsSync(join(remotionDir, 'node_modules', 'remotion'));
    const hasCaptions = brief.captions && brief.captions.length > 0;

    if (remotionInstalled && (hasCaptions || validVideos.length > 1)) {
      // Remotion render: captions + transitions + assembly in one pass
      console.log(`Using Remotion for assembly (${validVideos.length} scenes, ${brief.captions?.length || 0} captions)`);

      // Copy scene videos into Remotion public/ dir so staticFile() can find them
      // Note: symlinks don't survive Remotion's webpack bundling (copies public/ to temp dir)
      const publicDir = join(remotionDir, 'public');
      if (!existsSync(publicDir)) mkdirSync(publicDir, { recursive: true });
      const staticVideoNames = [];
      for (let i = 0; i < validVideos.length; i++) {
        const staticName = `scene-${i}.mp4`;
        const destPath = join(publicDir, staticName);
        try { if (existsSync(destPath)) unlinkSync(destPath); } catch (e) { /* ignore */ }
        copyFileSync(validVideos[i], destPath);
        staticVideoNames.push(staticName);
      }

      const remotionProps = {
        title: brief.title || 'Untitled',
        scenes: brief.scenes || [],
        aspect: brief.aspect || '9:16',
        captions: brief.captions || [],
        sceneVideos: staticVideoNames, // staticFile() names, not absolute paths
        transitionStyle: brief.transitionStyle || 'fade',
        transitionDuration: brief.transitionDuration || 15,
        musicPath: brief.music && existsSync(brief.music) ? brief.music : undefined,
      };

      const propsJson = JSON.stringify(remotionProps);
      // Write props to file to avoid shell escaping issues
      const propsFile = join(outputDir, 'remotion-props.json');
      writeFileSync(propsFile, propsJson);

      // calculateMetadata in Root.tsx dynamically computes duration/dimensions from props
      const remotionArgs = [
        'remotion', 'render',
        'src/index.ts',
        'FullVideo',
        finalPath,
        `--props=${propsFile}`,
        '--codec=h264',
        '--log=warn',
      ];

      try {
        execFileSync('npx', remotionArgs, {
          cwd: remotionDir,
          stdio: 'inherit',
          timeout: 600000, // 10 min
        });
        console.log(`Final video (Remotion, ${validVideos.length} scenes + captions): ${finalPath}`);
        pipelineState.steps.push({ step: 'assembly', success: true, method: 'remotion', path: finalPath });
      } catch (remotionErr) {
        console.log(`Remotion render failed: ${remotionErr.message}`);
        console.log('Falling back to ffmpeg concat...');
        // Fall through to ffmpeg fallback below
        assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
      }
    } else if (validVideos.length === 1 && !hasCaptions) {
      // Single video, no captions - just copy
      copyFileSync(validVideos[0], finalPath);
      console.log(`Final video (single scene): ${finalPath}`);
      pipelineState.steps.push({ step: 'assembly', success: true, method: 'copy', path: finalPath });
    } else {
      // ffmpeg fallback (no Remotion installed)
      if (!remotionInstalled) {
        console.log('Remotion not installed - using ffmpeg concat (no captions/transitions)');
        console.log(`Install with: cd ${remotionDir} && npm install`);
      }
      assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
    }
  } else {
    console.log('No valid video clips to assemble');
    pipelineState.steps.push({ step: 'assembly', success: false, reason: 'no valid clips' });
  }

  // Save pipeline state
  const elapsed = ((Date.now() - pipelineState.startTime) / 1000).toFixed(0);
  pipelineState.elapsed = `${elapsed}s`;
  writeFileSync(join(outputDir, 'pipeline-state.json'), JSON.stringify(pipelineState, null, 2));

  console.log(`\n=== Pipeline Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Output: ${outputDir}`);
  console.log(`Steps: ${pipelineState.steps.map(s => `${s.step}:${s.success !== false ? 'OK' : 'FAIL'}`).join(' -> ')}`);

  return pipelineState;
}

// Cinema Studio — professional cinematic image/video with camera/lens simulation
async function cinemaStudio(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Cinema Studio...');
    await page.goto(`${BASE_URL}/cinema-studio`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Select Image or Video tab (default: Image)
    const tabName = options.duration ? 'Video' : 'Image';
    const tab = page.locator(`[role="tab"]:has-text("${tabName}")`);
    if (await tab.count() > 0) {
      await tab.click();
      await page.waitForTimeout(1000);
      console.log(`Selected ${tabName} tab`);
    }

    // Upload image if provided (as prompt reference)
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Image uploaded to Cinema Studio');
      }
    }

    // Fill prompt
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    // Set quality (1K, 2K, 4K)
    if (options.quality) {
      const qualityBtn = page.locator(`button:has-text("${options.quality}")`);
      if (await qualityBtn.count() > 0) {
        await qualityBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Quality set to ${options.quality}`);
      }
    }

    // Set aspect ratio
    if (options.aspect) {
      const aspectBtn = page.locator(`button:has-text("${options.aspect}")`);
      if (await aspectBtn.count() > 0) {
        await aspectBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Aspect set to ${options.aspect}`);
      }
    }

    // Set batch count
    if (options.batch) {
      const batchBtn = page.locator(`button:has-text("${options.batch}/4"), button:has-text("1/${options.batch}")`);
      if (await batchBtn.count() > 0) {
        await batchBtn.first().click();
        await page.waitForTimeout(500);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'cinema-studio-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate in Cinema Studio');
    }

    // Wait for result
    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for Cinema Studio result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], video', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for Cinema Studio result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'cinema-studio-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'cinema');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Cinema Studio error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Motion Control — upload motion reference video + character image
async function motionControl(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Motion Control...');
    await page.goto(`${BASE_URL}/create/motion-control`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload motion reference video (first file input)
    if (options.videoFile || options.motionRef) {
      const videoPath = options.videoFile || options.motionRef;
      const fileInputs = page.locator('input[type="file"]');
      if (await fileInputs.count() > 0) {
        await fileInputs.first().setInputFiles(videoPath);
        await page.waitForTimeout(3000);
        console.log(`Motion reference uploaded: ${basename(videoPath)}`);
      }
    }

    // Upload character/subject image (second file input)
    if (options.imageFile) {
      const fileInputs = page.locator('input[type="file"]');
      const count = await fileInputs.count();
      if (count > 1) {
        await fileInputs.nth(1).setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log(`Character image uploaded: ${basename(options.imageFile)}`);
      }
    }

    // Fill prompt if provided
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    // Enable unlimited mode if requested
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

    await page.screenshot({ path: join(STATE_DIR, 'motion-control-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate in Motion Control');
    }

    // Wait for result — motion control videos take longer
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for Motion Control result...`);

    // Poll History tab for completion
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    if (await historyTab.count() > 0) {
      await page.waitForTimeout(10000);
      await historyTab.click();
      await page.waitForTimeout(3000);
    }

    try {
      await page.waitForSelector('video', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for Motion Control result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'motion-control-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'videos');
      await downloadVideoFromHistory(page, outputDir, {}, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Motion Control error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Edit/Inpaint — upload image, apply mask region, generate with prompt
async function editImage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    // 5 edit models: soul_inpaint, nano_banana_pro_inpaint, banana_placement, canvas, multi
    const model = options.model || 'soul_inpaint';
    const editUrl = `${BASE_URL}/edit?model=${model}`;
    console.log(`Navigating to Edit (${model})...`);
    await page.goto(editUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload image
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(3000);
        console.log(`Image uploaded for editing: ${basename(options.imageFile)}`);
      }
    }

    // Upload second image for multi-reference or product placement
    if (options.imageFile2) {
      const fileInputs = page.locator('input[type="file"]');
      const count = await fileInputs.count();
      if (count > 1) {
        await fileInputs.nth(1).setInputFiles(options.imageFile2);
        await page.waitForTimeout(2000);
        console.log(`Second image uploaded: ${basename(options.imageFile2)}`);
      }
    }

    // Fill prompt (describes what to generate in the masked area)
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Edit prompt entered');
      }
    }

    await page.screenshot({ path: join(STATE_DIR, `edit-${model}-configured.png`), fullPage: false });

    // Click Generate/Apply
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Apply"), button:has-text("Edit")').first();
    if (await generateBtn.count() > 0) {
      await generateBtn.click();
      console.log('Clicked Generate/Apply for edit');
    }

    // Wait for result
    const timeout = options.timeout || 120000;
    console.log(`Waiting up to ${timeout / 1000}s for edit result...`);

    try {
      await page.waitForSelector('img[alt="image generation"]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for edit result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `edit-${model}-result.png`), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'edits');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Upscale — upload media for AI upscaling
async function upscale(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Upscale...');
    await page.goto(`${BASE_URL}/upscale`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload media file
    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(mediaFile);
        await page.waitForTimeout(3000);
        console.log(`Media uploaded for upscaling: ${basename(mediaFile)}`);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'upscale-configured.png'), fullPage: false });

    // Click Upscale/Generate
    const upscaleBtn = page.locator('button:has-text("Upscale"), button:has-text("Generate"), button:has-text("Enhance")');
    if (await upscaleBtn.count() > 0) {
      await upscaleBtn.first().click();
      console.log('Clicked Upscale');
    }

    // Wait for result
    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for upscale result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], a[download]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for upscale result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'upscale-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'upscaled');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Upscale error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Asset Library — browse, filter, download, delete assets
async function manageAssets(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const action = options.assetAction || 'list';
    console.log(`Asset Library: ${action}...`);
    await page.goto(`${BASE_URL}/asset/all`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Apply filter if specified
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

    // Scroll to load assets
    for (let i = 0; i < 3; i++) {
      await page.evaluate(() => window.scrollBy(0, 800));
      await page.waitForTimeout(1000);
    }

    // Count assets
    const assetCount = await page.evaluate(() => document.querySelectorAll('main img').length);
    console.log(`Assets loaded: ${assetCount}`);

    if (action === 'list') {
      await page.screenshot({ path: join(STATE_DIR, 'asset-library.png'), fullPage: false });
      console.log(`Asset library screenshot saved. ${assetCount} assets visible.`);
      await context.storageState({ path: STATE_FILE });
      await browser.close();
      return { success: true, count: assetCount };
    }

    if (action === 'download' || action === 'download-latest') {
      // Click on the first/latest asset
      const targetIndex = options.assetIndex || 0;
      const assetImg = page.locator('main img').nth(targetIndex);
      if (await assetImg.isVisible({ timeout: 3000 }).catch(() => false)) {
        await assetImg.click();
        await page.waitForTimeout(2500);
        await page.screenshot({ path: join(STATE_DIR, 'asset-detail.png'), fullPage: false });

        // Try to download via the asset detail view
        const baseOutput = options.output || DOWNLOAD_DIR;
        const dlDir = resolveOutputDir(baseOutput, options, 'misc');
        await downloadLatestResult(page, dlDir, false, options);
        console.log('Asset downloaded');
      }
    }

    if (action === 'download-all') {
      // Download multiple assets
      const maxDownloads = options.limit || 10;
      const baseOutput = options.output || DOWNLOAD_DIR;
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

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true, count: assetCount };
  } catch (error) {
    console.error('Asset Library error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Asset Chaining — "Open in" menu from asset detail dialog
// Allows chaining operations without download/re-upload round-trip
// Actions: animate, inpaint, upscale, relight, angles, shots, ai-stylist, skin-enhancer, multishot
async function assetChain(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const action = options.chainAction || 'animate';
    const actionMap = {
      animate: 'Animate',
      inpaint: 'Inpaint',
      upscale: 'Upscale',
      relight: 'Relight',
      angles: 'Angles',
      shots: 'Shots',
      'ai-stylist': 'AI Stylist',
      'skin-enhancer': 'Skin Enhancer',
      multishot: 'Multishot',
    };
    const actionLabel = actionMap[action] || action;
    console.log(`Asset Chain: ${actionLabel}...`);

    // Navigate to asset source — either a specific page or the asset library
    const sourceUrl = options.prompt || `${BASE_URL}/asset/all`;
    await page.goto(sourceUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // If an image file is provided, navigate to the image model page and generate first
    if (options.imageFile) {
      // Upload to the current page if there is a file input
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(3000);
        console.log('Source image uploaded');
      }
    }

    // Wait for asset images to appear (SPA may load them asynchronously)
    try {
      await page.waitForSelector('main img', { timeout: 15000, state: 'visible' });
    } catch {
      console.log('No images appeared after 15s, scrolling to trigger lazy load...');
    }

    // Scroll to trigger lazy loading, then scroll back to top
    for (let i = 0; i < 3; i++) {
      await page.evaluate(() => window.scrollBy(0, 800));
      await page.waitForTimeout(1000);
    }
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(1000);

    // Click on the target asset (first/latest or by index)
    const targetIndex = options.assetIndex || 0;
    // Use broad 'main img' selector (matches manageAssets which works reliably)
    let assetImg = page.locator('main img');
    let assetCount = await assetImg.count();
    // Fallback to alt-based selector if main img finds nothing
    if (assetCount === 0) {
      assetImg = page.locator('img[alt="image generation"], img[alt*="media asset by id"]');
      assetCount = await assetImg.count();
    }
    // Final fallback: wait longer for lazy-loaded content
    if (assetCount === 0) {
      console.log('No assets found yet, waiting for lazy load...');
      await page.waitForTimeout(5000);
      assetImg = page.locator('main img');
      assetCount = await assetImg.count();
    }

    if (assetCount === 0) {
      console.error('No assets found on page');
      await page.screenshot({ path: join(STATE_DIR, 'asset-chain-no-assets.png'), fullPage: false });
      await browser.close();
      return { success: false, error: 'No assets found' };
    }

    console.log(`Found ${assetCount} assets, clicking index ${targetIndex}...`);
    const targetAsset = assetImg.nth(targetIndex);

    // Try multiple click strategies — overlays (play buttons, checkboxes) can intercept
    let dialogOpen = false;
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
      if (dialogOpen) break;
      try {
        await strategy.fn();
        await page.waitForTimeout(2500);
        await dismissInterruptions(page);
        dialogOpen = await page.locator('[role="dialog"], dialog').count() > 0;
        if (dialogOpen) {
          console.log(`Dialog opened via ${strategy.name}`);
        }
      } catch {
        console.log(`${strategy.name} failed, trying next...`);
      }
    }

    // Screenshot the dialog state for debugging
    await page.screenshot({ path: join(STATE_DIR, 'asset-chain-dialog.png'), fullPage: false });

    // Remove any overlays that intercept pointer events inside the dialog
    if (dialogOpen) {
      await page.evaluate(() => {
        document.querySelectorAll('.absolute.top-0.left-0.w-full').forEach(el => {
          if (el.style) el.style.pointerEvents = 'none';
        });
      });
    }

    // Strategy 1: Look for "Open in" button strictly inside the dialog
    let actionClicked = false;
    const dialog = page.locator('[role="dialog"], dialog');
    const openInBtn = dialog.locator('button:has-text("Open in")');
    if (await openInBtn.count() > 0) {
      await openInBtn.first().click({ force: true });
      await page.waitForTimeout(1000);
      console.log('Opened "Open in" menu');
      await page.screenshot({ path: join(STATE_DIR, 'asset-chain-openin-menu.png'), fullPage: false });

      // The menu items may appear as a popover outside the dialog
      const actionBtn = page.locator(`[role="menuitem"]:has-text("${actionLabel}"), [role="option"]:has-text("${actionLabel}"), [data-radix-popper-content-wrapper] button:has-text("${actionLabel}"), [data-radix-popper-content-wrapper] a:has-text("${actionLabel}")`);
      if (await actionBtn.count() > 0) {
        await actionBtn.first().click({ force: true });
        await page.waitForTimeout(3000);
        console.log(`Clicked "${actionLabel}" from Open in menu`);
        actionClicked = true;
      }
    }

    // Strategy 2: Look for action buttons/links strictly inside the dialog
    if (!actionClicked) {
      const directBtn = dialog.locator(`button:has-text("${actionLabel}"), a:has-text("${actionLabel}")`);
      if (await directBtn.count() > 0) {
        await directBtn.first().click({ force: true });
        await page.waitForTimeout(3000);
        console.log(`Clicked "${actionLabel}" inside dialog`);
        actionClicked = true;
      }
    }

    // Strategy 3: Look for overflow/more menu inside the dialog
    if (!actionClicked) {
      const moreBtn = dialog.locator('button[aria-label*="more" i], button[aria-label*="menu" i], button:has(svg[class*="dots"]), button:has(svg[class*="ellipsis"])');
      for (let m = 0; m < await moreBtn.count() && !actionClicked; m++) {
        await moreBtn.nth(m).click({ force: true });
        await page.waitForTimeout(1000);
        const menuAction = page.locator(`[role="menuitem"]:has-text("${actionLabel}"), [role="option"]:has-text("${actionLabel}")`);
        if (await menuAction.count() > 0) {
          await menuAction.first().click({ force: true });
          await page.waitForTimeout(3000);
          console.log(`Clicked "${actionLabel}" from overflow menu`);
          actionClicked = true;
        }
      }
    }

    // Strategy 4: Fallback — download the asset, close dialog, navigate to tool, upload
    if (!actionClicked) {
      console.log(`"${actionLabel}" not found in dialog. Downloading asset and navigating to tool...`);
      await page.screenshot({ path: join(STATE_DIR, 'asset-chain-fallback.png'), fullPage: false });

      // Download the asset from the dialog first
      const outputDir = options.output || DOWNLOAD_DIR;
      const downloadedFiles = await downloadLatestResult(page, outputDir, false, options);
      const downloadedFile = Array.isArray(downloadedFiles) ? downloadedFiles[0] : downloadedFiles;

      // Close dialog
      await page.keyboard.press('Escape');
      await page.waitForTimeout(1000);
      await page.evaluate(() => {
        document.querySelectorAll('[role="dialog"]').forEach(d => {
          const overlay = d.closest('.react-aria-ModalOverlay') || d.parentElement;
          if (overlay) overlay.remove();
          else d.remove();
        });
        document.body.style.overflow = '';
        document.body.style.pointerEvents = '';
      });

      // Navigate to the target tool directly
      const toolUrlMap = {
        animate: '/create/video',
        inpaint: '/edit?model=soul_inpaint',
        upscale: '/upscale',
        relight: '/app/relight',
        angles: '/app/angles',
        shots: '/app/shots',
        'ai-stylist': '/app/ai-stylist',
        'skin-enhancer': '/app/skin-enhancer',
        multishot: '/app/shots',
      };
      const toolUrl = toolUrlMap[action] || `/app/${action}`;
      console.log(`Navigating to ${toolUrl}...`);
      await page.goto(`${BASE_URL}${toolUrl}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await page.waitForTimeout(3000);
      await dismissAllModals(page);

      // Upload the downloaded asset to the tool
      if (downloadedFile) {
        const fileInput = page.locator('input[type="file"]').first();
        if (await fileInput.count() > 0) {
          await fileInput.setInputFiles(downloadedFile);
          await page.waitForTimeout(3000);
          console.log(`Uploaded asset to ${action} tool: ${basename(downloadedFile)}`);
        }
      }
      actionClicked = true;
    }

    await page.screenshot({ path: join(STATE_DIR, `asset-chain-${action}.png`), fullPage: false });

    // Now we should be on the target tool page with the asset pre-loaded
    // Fill additional prompt if provided
    if (options.prompt && !options.prompt.startsWith('http')) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Additional prompt entered');
      }
    }

    // Helper: dismiss "Media upload agreement" modal via Playwright click (React needs synthetic events)
    async function dismissMediaUploadAgreement() {
      const agreeBtn = page.locator('button:has-text("I agree, continue")');
      if (await agreeBtn.count() > 0) {
        await agreeBtn.first().click({ force: true });
        await page.waitForTimeout(2000);
        console.log('Dismissed "Media upload agreement" modal');
        return true;
      }
      return false;
    }

    // Check for media upload agreement before clicking Generate (may appear after upload)
    await page.waitForTimeout(2000);
    await dismissMediaUploadAgreement();

    // Click the action button on the target tool page
    // Different tools use different button labels: Generate, Apply, Create, Upscale, Enhance, etc.
    await page.waitForTimeout(1000);
    const actionLabels = ['Generate', 'Apply', 'Create', 'Upscale', 'Enhance', 'Start', 'Submit'];
    const actionSelector = actionLabels.map(l => `button:has-text("${l}")`).join(', ');
    const generateBtn = page.locator(actionSelector);
    if (await generateBtn.count() > 0) {
      // Click the last matching button (usually the primary CTA at the bottom)
      await generateBtn.last().click({ force: true });
      console.log(`Clicked action button on target tool`);
    }

    // Check for media upload agreement after clicking action button (appears as confirmation)
    await page.waitForTimeout(3000);
    const dismissed = await dismissMediaUploadAgreement();

    // If we dismissed the agreement, the generation should now start — wait a moment
    if (dismissed) {
      await page.waitForTimeout(2000);
    }

    // Wait for result — poll for completion indicators
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for chained result...`);

    const startTime = Date.now();
    let resultReady = false;
    while (Date.now() - startTime < timeout && !resultReady) {
      await page.waitForTimeout(5000);

      // Check for progress indicators (still processing)
      const hasProgress = await page.locator('progress, [role="progressbar"], .animate-spin, [class*="loading"], [class*="spinner"]').count() > 0;
      if (hasProgress) {
        const elapsed = Math.round((Date.now() - startTime) / 1000);
        console.log(`Still processing... (${elapsed}s)`);
        continue;
      }

      // Check for completion: download button appears, or result image changes
      const hasDownload = await page.locator('button:has-text("Download"), a:has-text("Download")').count() > 0;
      const hasCompare = await page.locator('button:has-text("Compare"), [class*="compare"]').count() > 0;
      const hasNewResult = await page.locator('img[alt*="upscal"], img[alt*="result"], [data-testid*="result"]').count() > 0;

      if (hasDownload || hasCompare || hasNewResult) {
        resultReady = true;
        console.log('Result ready');
      }

      // If no progress and no result after 30s, check if the page changed at all
      if (!hasProgress && !resultReady && (Date.now() - startTime > 30000)) {
        // Take a screenshot to see current state
        await page.screenshot({ path: join(STATE_DIR, `asset-chain-${action}-waiting.png`), fullPage: false });
        // Check if maybe the media upload agreement is still blocking
        const dismissed2 = await dismissMediaUploadAgreement();
        if (dismissed2) {
          console.log('Late media upload agreement dismissed, continuing...');
          continue;
        }
        // If nothing is happening after 60s, break
        if (Date.now() - startTime > 60000) {
          console.log('No progress detected after 60s, checking result...');
          break;
        }
      }
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `asset-chain-${action}-result.png`), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'chained');
      const isVideoAction = ['animate'].includes(action);
      if (isVideoAction) {
        await downloadVideoFromHistory(page, outputDir, {}, options);
      } else {
        // Try standard download first
        const downloaded = await downloadLatestResult(page, outputDir, true, options);
        const hasDownloaded = Array.isArray(downloaded) ? downloaded.length > 0 : !!downloaded;

        // If standard download failed, try the download icon button (upscale/edit pages use icon buttons)
        if (!hasDownloaded) {
          console.log('Standard download failed, trying download icon...');
          // Look for download icon buttons (SVG icons without text labels)
          const dlIcon = page.locator('button:has(svg), a[download]').filter({ has: page.locator('svg') });
          let iconDownloaded = false;

          // Try each potential download icon
          for (let di = 0; di < Math.min(await dlIcon.count(), 5) && !iconDownloaded; di++) {
            const btn = dlIcon.nth(di);
            const ariaLabel = await btn.getAttribute('aria-label').catch(() => '');
            const title = await btn.getAttribute('title').catch(() => '');
            if (ariaLabel?.toLowerCase().includes('download') || title?.toLowerCase().includes('download')) {
              const [dl] = await Promise.all([
                page.waitForEvent('download', { timeout: 10000 }).catch(() => null),
                btn.click({ force: true }),
              ]);
              if (dl) {
                const savePath = join(outputDir, dl.suggestedFilename() || `chained-${action}-${Date.now()}.png`);
                await dl.saveAs(savePath);
                console.log(`Downloaded via icon: ${savePath}`);
                iconDownloaded = true;
              }
            }
          }

          // Final fallback: extract the largest image src from the page and download via curl
          if (!iconDownloaded) {
            console.log('Icon download failed, trying CDN extraction...');
            const imgSrc = await page.evaluate(() => {
              // Find the largest visible image on the page (likely the result)
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
              // Extract raw CloudFront URL if wrapped in cdn-cgi
              if (best) {
                const cfMatch = best.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
                return cfMatch ? cfMatch[1] : best;
              }
              return null;
            });
            if (imgSrc) {
              const ext = imgSrc.includes('.png') ? 'png' : 'webp';
              const savePath = join(outputDir, `chained-${action}-${Date.now()}.${ext}`);
              try {
                execFileSync('curl', ['-sL', '-o', savePath, imgSrc], { timeout: 60000 });
                console.log(`Downloaded via CDN: ${savePath}`);
              } catch (curlErr) {
                console.log(`CDN download failed: ${curlErr.message}`);
              }
            }
          }
        }
      }
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Asset Chain error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Mixed Media Presets — apply visual transformation presets (32+ presets)
// Each preset has a UUID-based URL: /mixed-media-presets/preset/{uuid}
async function mixedMediaPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset || 'sketch';

    // Load preset lookup from routes.json
    const routesPath = join(dirname(fileURLToPath(import.meta.url)), 'routes.json');
    const routes = JSON.parse(readFileSync(routesPath, 'utf-8'));
    const presets = routes.mixed_media_presets || {};

    // Find the preset URL
    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
    let presetUrl = presets[presetKey];

    if (!presetUrl) {
      // Try fuzzy match
      const match = Object.keys(presets).find(k => k.includes(presetKey) || presetKey.includes(k));
      if (match) {
        presetUrl = presets[match];
        console.log(`Fuzzy matched preset: ${presetName} → ${match}`);
      } else {
        console.log(`Available presets: ${Object.keys(presets).join(', ')}`);
        await browser.close();
        return { success: false, error: `Unknown preset: ${presetName}` };
      }
    }

    console.log(`Navigating to Mixed Media preset: ${presetName}...`);
    await page.goto(`${BASE_URL}${presetUrl}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload media file
    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(mediaFile);
        await page.waitForTimeout(3000);
        console.log(`Media uploaded: ${basename(mediaFile)}`);
      }
    }

    // Fill prompt if provided
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    await page.screenshot({ path: join(STATE_DIR, `mixed-media-${presetKey}-configured.png`), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Apply"), button:has-text("Create")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for mixed media preset');
    }

    // Wait for result
    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for mixed media result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], video', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for mixed media result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `mixed-media-${presetKey}-result.png`), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'mixed-media');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Mixed Media Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Motion/VFX Presets — apply motion or VFX effects (150+ presets)
// Presets discovered dynamically and stored in routes-cache.json
async function motionPreset(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const presetName = options.preset;

    if (!presetName) {
      // List available presets from discovery cache
      if (existsSync(ROUTES_CACHE)) {
        const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
        const motions = cache.motions || {};
        const names = Object.keys(motions);
        console.log(`Available motion presets (${names.length}):`);
        names.slice(0, 50).forEach(n => console.log(`  ${n} → ${motions[n]}`));
        if (names.length > 50) console.log(`  ... and ${names.length - 50} more`);
      } else {
        console.log('No discovery cache found. Run "discover" first.');
      }
      await browser.close();
      return { success: true, action: 'list' };
    }

    // Resolve preset to URL from discovery cache
    let presetUrl = null;
    if (existsSync(ROUTES_CACHE)) {
      const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
      const motions = cache.motions || {};
      const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');

      // Exact match
      presetUrl = motions[presetKey];

      // Fuzzy match
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

    // If preset is a UUID or URL path, use directly
    if (!presetUrl && presetName.includes('/')) {
      presetUrl = presetName.startsWith('/') ? presetName : `/motion/${presetName}`;
    }
    if (!presetUrl && presetName.match(/^[0-9a-f-]{36}$/i)) {
      presetUrl = `/motion/${presetName}`;
    }

    if (!presetUrl) {
      console.error(`Motion preset not found: ${presetName}. Run "discover" to refresh cache.`);
      await browser.close();
      return { success: false, error: `Unknown preset: ${presetName}` };
    }

    console.log(`Navigating to motion preset: ${presetName}...`);
    await page.goto(`${BASE_URL}${presetUrl}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload media file
    const mediaFile = options.imageFile || options.videoFile;
    if (mediaFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(mediaFile);
        await page.waitForTimeout(3000);
        console.log(`Media uploaded: ${basename(mediaFile)}`);
      }
    }

    // Fill prompt if provided
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'motion-preset-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Apply"), button:has-text("Create")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for motion preset');
    }

    // Wait for result (motion presets produce videos, which take longer)
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for motion preset result...`);

    try {
      await page.waitForSelector('video, img[alt="image generation"]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for motion preset result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'motion-preset-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'motion-presets');
      await downloadVideoFromHistory(page, outputDir, {}, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Motion Preset error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Video Edit — upload video + character image for video editing
async function editVideo(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Video Edit...');
    await page.goto(`${BASE_URL}/create/edit`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload video file (first file input)
    if (options.videoFile) {
      const fileInputs = page.locator('input[type="file"]');
      if (await fileInputs.count() > 0) {
        await fileInputs.first().setInputFiles(options.videoFile);
        await page.waitForTimeout(3000);
        console.log(`Video uploaded: ${basename(options.videoFile)}`);
      }
    }

    // Upload character/subject image (second file input)
    if (options.imageFile) {
      const fileInputs = page.locator('input[type="file"]');
      const count = await fileInputs.count();
      if (count > 1) {
        await fileInputs.nth(1).setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log(`Character image uploaded: ${basename(options.imageFile)}`);
      } else if (count === 1 && !options.videoFile) {
        // Only one input and no video — use it for the image
        await fileInputs.first().setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log(`Image uploaded: ${basename(options.imageFile)}`);
      }
    }

    // Fill prompt
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Edit prompt entered');
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'video-edit-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Apply"), button:has-text("Edit")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for video edit');
    }

    // Wait for result
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for video edit result...`);

    // Poll History tab
    const historyTab = page.locator('[role="tab"]:has-text("History")');
    if (await historyTab.count() > 0) {
      await page.waitForTimeout(10000);
      await historyTab.click();
      await page.waitForTimeout(3000);
    }

    try {
      await page.waitForSelector('video', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for video edit result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'video-edit-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'videos');
      await downloadVideoFromHistory(page, outputDir, {}, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Video Edit error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Storyboard Generator — create multi-panel storyboards from a script/prompt
async function storyboard(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Storyboard Generator...');
    await page.goto(`${BASE_URL}/storyboard-generator`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload reference image if provided
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Reference image uploaded');
      }
    }

    // Fill script/prompt
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Storyboard script entered');
      }
    }

    // Set number of panels/scenes if supported
    if (options.scenes) {
      const scenesInput = page.locator('input[type="number"], input[placeholder*="scene" i], input[placeholder*="panel" i]');
      if (await scenesInput.count() > 0) {
        await scenesInput.first().fill(String(options.scenes));
        console.log(`Panels set to ${options.scenes}`);
      }
    }

    // Select style if provided
    if (options.preset) {
      const styleBtn = page.locator(`button:has-text("${options.preset}")`);
      if (await styleBtn.count() > 0) {
        await styleBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Style selected: ${options.preset}`);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'storyboard-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Build")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for storyboard');
    }

    // Wait for result — storyboards may take longer due to multiple panels
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for storyboard result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], .storyboard-panel, [class*="storyboard"]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for storyboard result');
    }

    await page.waitForTimeout(5000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'storyboard-result.png'), fullPage: true });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'storyboards');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Storyboard error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Vibe Motion — animated content with sub-types (Infographics, Text Animation, Posters, Presentation, From Scratch)
async function vibeMotion(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Vibe Motion...');
    await page.goto(`${BASE_URL}/vibe-motion`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Select sub-type tab (default: From Scratch)
    const subtype = options.tab || 'From Scratch';
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
    const subtypeLabel = subtypeMap[subtype.toLowerCase()] || subtype;
    const subtypeTab = page.locator(`[role="tab"]:has-text("${subtypeLabel}"), button:has-text("${subtypeLabel}")`);
    if (await subtypeTab.count() > 0) {
      await subtypeTab.first().click();
      await page.waitForTimeout(1000);
      console.log(`Selected sub-type: ${subtypeLabel}`);
    }

    // Upload image/logo if provided
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Image/logo uploaded');
      }
    }

    // Fill content/prompt
    if (options.prompt) {
      const promptInput = page.locator('textarea').first();
      if (await promptInput.count() > 0) {
        await promptInput.fill(options.prompt);
        console.log('Content entered');
      }
    }

    // Select style if provided (Minimal, Corporate, Fashion, Marketing)
    if (options.preset) {
      const styleBtn = page.locator(`button:has-text("${options.preset}")`);
      if (await styleBtn.count() > 0) {
        await styleBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Style selected: ${options.preset}`);
      }
    }

    // Set duration if provided (Auto, 5, 10, 15, 30)
    if (options.duration) {
      const durBtn = page.locator(`button:has-text("${options.duration}s"), button:has-text("${options.duration}")`);
      if (await durBtn.count() > 0) {
        await durBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Duration set to ${options.duration}s`);
      }
    }

    // Set aspect ratio
    if (options.aspect) {
      const aspectBtn = page.locator(`button:has-text("${options.aspect}")`);
      if (await aspectBtn.count() > 0) {
        await aspectBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Aspect set to ${options.aspect}`);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'vibe-motion-configured.png'), fullPage: false });

    // Click Generate
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Build")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for Vibe Motion');
    }

    // Wait for result — Vibe Motion produces videos
    const timeout = options.timeout || 300000;
    console.log(`Waiting up to ${timeout / 1000}s for Vibe Motion result...`);

    try {
      await page.waitForSelector('video', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for Vibe Motion result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'vibe-motion-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'videos');
      await downloadVideoFromHistory(page, outputDir, {}, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Vibe Motion error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// AI Influencer Studio — create AI-generated influencer characters
async function aiInfluencer(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to AI Influencer Studio...');
    await page.goto(`${BASE_URL}/ai-influencer-studio`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Select character type if provided (Human, Ant, Bee, Octopus, Alien, Elf, etc.)
    if (options.preset) {
      const typeBtn = page.locator(`button:has-text("${options.preset}"), [role="option"]:has-text("${options.preset}")`);
      if (await typeBtn.count() > 0) {
        await typeBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Character type: ${options.preset}`);
      }
    }

    // Upload reference image if provided
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Reference image uploaded');
      }
    }

    // Fill prompt/description
    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i], input[placeholder*="describe" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Description entered');
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'ai-influencer-configured.png'), fullPage: false });

    // Click Generate/Create
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Build")');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate for AI Influencer');
    }

    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for AI Influencer result...`);

    try {
      await page.waitForSelector('img[alt="image generation"]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for AI Influencer result');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'ai-influencer-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'characters');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('AI Influencer error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Character — create persistent character profiles for consistent generation
async function createCharacter(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    console.log('Navigating to Character...');
    await page.goto(`${BASE_URL}/character`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload character photos (may accept multiple)
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        // Check if multiple files can be uploaded
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

    // Fill character name/label
    if (options.prompt) {
      const nameInput = page.locator('input[placeholder*="name" i], input[placeholder*="label" i], textarea').first();
      if (await nameInput.count() > 0) {
        await nameInput.fill(options.prompt);
        console.log(`Character name/description: ${options.prompt}`);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, 'character-configured.png'), fullPage: false });

    // Click Create/Save
    const createBtn = page.locator('button:has-text("Create"), button:has-text("Save"), button:has-text("Generate")');
    if (await createBtn.count() > 0) {
      await createBtn.first().click();
      console.log('Clicked Create for character');
    }

    const timeout = options.timeout || 120000;
    console.log(`Waiting up to ${timeout / 1000}s for character creation...`);

    try {
      await page.waitForSelector('img[alt="image generation"], [class*="character"]', { timeout, state: 'visible' });
    } catch {
      console.log('Timeout waiting for character creation');
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, 'character-result.png'), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'characters');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error('Character error:', error.message);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Feature Page — generic handler for simple feature pages
// Covers: Fashion Factory, UGC Factory, Photodump Studio, Camera Controls, Effects
async function featurePage(options = {}) {
  const { browser, context, page } = await launchBrowser(options);

  try {
    const featureMap = {
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

    const featureKey = options.effect || options.feature || 'fashion-factory';
    const feature = featureMap[featureKey.toLowerCase()] || { url: `/${featureKey}`, name: featureKey };

    console.log(`Navigating to ${feature.name}...`);
    await page.goto(`${BASE_URL}${feature.url}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(3000);
    await dismissAllModals(page);

    // Upload image(s)
    if (options.imageFile) {
      const fileInput = page.locator('input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.imageFile);
        await page.waitForTimeout(2000);
        console.log('Image uploaded');
      }
    }

    // Upload additional images for multi-upload features (e.g., Photodump)
    if (options.imageFile2) {
      const fileInputs = page.locator('input[type="file"]');
      const count = await fileInputs.count();
      if (count > 1) {
        await fileInputs.nth(1).setInputFiles(options.imageFile2);
        await page.waitForTimeout(2000);
        console.log('Additional image uploaded');
      }
    }

    // Upload video if provided (Camera Controls may accept video)
    if (options.videoFile) {
      const fileInput = page.locator('input[type="file"][accept*="video"], input[type="file"]').first();
      if (await fileInput.count() > 0) {
        await fileInput.setInputFiles(options.videoFile);
        await page.waitForTimeout(2000);
        console.log('Video uploaded');
      }
    }

    // Fill prompt
    if (options.prompt) {
      const promptInput = page.locator('textarea, input[placeholder*="prompt" i]');
      if (await promptInput.count() > 0) {
        await promptInput.first().fill(options.prompt);
        console.log('Prompt entered');
      }
    }

    // Select style/preset if provided
    if (options.preset) {
      const styleBtn = page.locator(`button:has-text("${options.preset}")`);
      if (await styleBtn.count() > 0) {
        await styleBtn.first().click();
        await page.waitForTimeout(500);
        console.log(`Style/preset selected: ${options.preset}`);
      }
    }

    await page.screenshot({ path: join(STATE_DIR, `feature-${featureKey}-configured.png`), fullPage: false });

    // Click Generate/Create/Apply
    const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply"), button[type="submit"]:visible');
    if (await generateBtn.count() > 0) {
      await generateBtn.first().click({ force: true });
      console.log('Clicked Generate');
    }

    const timeout = options.timeout || 180000;
    console.log(`Waiting up to ${timeout / 1000}s for ${feature.name} result...`);

    try {
      await page.waitForSelector('img[alt="image generation"], video', { timeout, state: 'visible' });
    } catch {
      console.log(`Timeout waiting for ${feature.name} result`);
    }

    await page.waitForTimeout(3000);
    await dismissAllModals(page);
    await page.screenshot({ path: join(STATE_DIR, `feature-${featureKey}-result.png`), fullPage: false });

    if (options.wait !== false) {
      const baseOutput = options.output || DOWNLOAD_DIR;
      const outputDir = resolveOutputDir(baseOutput, options, 'features');
      await downloadLatestResult(page, outputDir, true, options);
    }

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return { success: true };
  } catch (error) {
    console.error(`Feature page error: ${error.message}`);
    await browser.close();
    return { success: false, error: error.message };
  }
}

// Auth health check - verify auth state is valid
async function authHealthCheck(options = {}) {
  console.log('[health-check] Verifying authentication state...');
  
  // Check if state file exists
  if (!existsSync(STATE_FILE)) {
    console.log('[health-check] ❌ No auth state found');
    console.log('[health-check] Run: higgsfield-helper.sh login');
    return { success: false, error: 'No auth state' };
  }

  // Check state file age
  const stats = statSync(STATE_FILE);
  const ageMs = Date.now() - stats.mtimeMs;
  const ageHours = Math.floor(ageMs / (1000 * 60 * 60));
  const ageDays = Math.floor(ageHours / 24);
  
  console.log(`[health-check] Auth state file: ${STATE_FILE}`);
  console.log(`[health-check] Age: ${ageDays}d ${ageHours % 24}h`);

  // Try to load and verify the state
  try {
    const { browser, context, page } = await launchBrowser({ ...options, headless: true });
    
    // Navigate to a protected page to verify auth
    console.log('[health-check] Testing auth by navigating to /image/soul...');
    await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(3000);
    
    const currentUrl = page.url();
    
    // If redirected to login/auth, session is invalid
    if (currentUrl.includes('login') || currentUrl.includes('auth') || currentUrl.includes('sign-in')) {
      console.log('[health-check] ❌ Auth state is invalid (redirected to login)');
      console.log('[health-check] Run: higgsfield-helper.sh login');
      await browser.close();
      return { success: false, error: 'Auth expired or invalid' };
    }
    
    // Check for user menu or account indicator
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
      console.log('[health-check] ✅ Auth state is valid');
      console.log('[health-check] Session age: OK');
      return { success: true, age: { hours: ageHours, days: ageDays } };
    } else {
      console.log('[health-check] ⚠️  Auth state uncertain (no user indicator found)');
      console.log('[health-check] Page loaded but could not verify login status');
      return { success: true, warning: 'Could not verify user indicator' };
    }
    
  } catch (error) {
    console.error(`[health-check] ❌ Error during health check: ${error.message}`);
    return { success: false, error: error.message };
  }
}

// Smoke test - quick end-to-end test without consuming credits
async function smokeTest(options = {}) {
  console.log('[smoke-test] Running smoke test...');
  console.log('[smoke-test] This will verify: auth, navigation, UI elements (no generation)');
  
  const results = {
    auth: false,
    navigation: false,
    credits: false,
    discovery: false,
    overall: false,
  };
  
  try {
    // 1. Check auth health
    console.log('\n[smoke-test] Step 1/4: Auth health check...');
    const authResult = await authHealthCheck({ ...options, headless: true });
    results.auth = authResult.success;
    
    if (!results.auth) {
      console.log('[smoke-test] ❌ Auth check failed, aborting smoke test');
      return results;
    }
    
    // 2. Test navigation to key pages
    console.log('\n[smoke-test] Step 2/4: Testing navigation...');
    const { browser, context, page } = await launchBrowser({ ...options, headless: true });
    
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
          console.log(`[smoke-test]   ❌ ${testPage.name}: Redirected to login`);
          navSuccess = false;
        } else {
          console.log(`[smoke-test]   ✅ ${testPage.name}: OK`);
        }
      } catch (error) {
        console.log(`[smoke-test]   ❌ ${testPage.name}: ${error.message}`);
        navSuccess = false;
      }
    }
    results.navigation = navSuccess;
    
    // 3. Check credits
    console.log('\n[smoke-test] Step 3/4: Checking credits...');
    try {
      await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForTimeout(2000);
      
      const creditSelectors = [
        'text=/\\d+\\s*(credits?|cr)/i',
        '[data-testid*="credit"]',
        'div:has-text("credits")',
      ];
      
      let foundCredits = false;
      for (const selector of creditSelectors) {
        const el = page.locator(selector);
        if (await el.count() > 0) {
          const text = await el.first().textContent();
          console.log(`[smoke-test]   ✅ Credits visible: ${text?.trim()}`);
          foundCredits = true;
          break;
        }
      }
      
      if (!foundCredits) {
        console.log('[smoke-test]   ⚠️  Could not find credit indicator (may still work)');
      }
      results.credits = foundCredits;
    } catch (error) {
      console.log(`[smoke-test]   ❌ Credits check failed: ${error.message}`);
      results.credits = false;
    }
    
    // 4. Verify discovery cache
    console.log('\n[smoke-test] Step 4/4: Checking discovery cache...');
    if (existsSync(ROUTES_CACHE)) {
      const cache = JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
      const modelCount = Object.keys(cache.models || {}).length;
      const appCount = Object.keys(cache.apps || {}).length;
      console.log(`[smoke-test]   ✅ Discovery cache: ${modelCount} models, ${appCount} apps`);
      results.discovery = true;
    } else {
      console.log('[smoke-test]   ⚠️  No discovery cache (run: higgsfield-helper.sh image "test")');
      results.discovery = false;
    }
    
    await browser.close();
    
    // Overall result
    results.overall = results.auth && results.navigation;
    
    console.log('\n[smoke-test] ========== RESULTS ==========');
    console.log(`[smoke-test] Auth:       ${results.auth ? '✅' : '❌'}`);
    console.log(`[smoke-test] Navigation: ${results.navigation ? '✅' : '❌'}`);
    console.log(`[smoke-test] Credits:    ${results.credits ? '✅' : '⚠️ '}`);
    console.log(`[smoke-test] Discovery:  ${results.discovery ? '✅' : '⚠️ '}`);
    console.log(`[smoke-test] Overall:    ${results.overall ? '✅ PASS' : '❌ FAIL'}`);
    console.log('[smoke-test] ============================');
    
    return results;
    
  } catch (error) {
    console.error(`[smoke-test] ❌ Smoke test error: ${error.message}`);
    results.overall = false;
    return results;
  }
}

// --- Self-tests for unlimited model selection logic ---
// Run with: node playwright-automator.mjs test
async function runSelfTests() {
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

  // Save original cache and create a mock
  const originalCache = existsSync(CREDITS_CACHE_FILE)
    ? readFileSync(CREDITS_CACHE_FILE, 'utf-8')
    : null;

  console.log('\n=== Unlimited Model Selection Tests ===\n');

  // Test 1: UNLIMITED_MODELS structure
  console.log('--- UNLIMITED_MODELS mapping ---');
  const imageModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'image');
  const videoModels = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === 'video');
  assert(imageModels.length === 12, `12 image models mapped (got ${imageModels.length})`);
  assert(videoModels.length === 3, `3 video models mapped (got ${videoModels.length})`);

  // Test 2: Priority ordering — SOTA quality ranking
  console.log('\n--- SOTA quality priority ordering ---');
  const imagePriorities = imageModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(imagePriorities[0][1].slug === 'nano-banana-pro', 'Nano Banana Pro is priority 1 (Gemini 3.0, native 4K, fastest)');
  assert(imagePriorities[1][1].slug === 'gpt', 'GPT Image is priority 2 (strong photorealism)');
  assert(imagePriorities[2][1].slug === 'seedream-4-5', 'Seedream 4.5 is priority 3');
  assert(imagePriorities[3][1].slug === 'flux', 'FLUX.2 Pro is priority 4');
  assert(imagePriorities[11][1].slug === 'popcorn', 'Popcorn is last (stylized, not photorealistic)');

  const videoPriorities = videoModels.sort((a, b) => a[1].priority - b[1].priority);
  assert(videoPriorities[0][1].slug === 'kling-2.6', 'Kling 2.6 is top video model');
  assert(videoPriorities[1][1].slug === 'kling-o1', 'Kling O1 is second (higher quality than Turbo)');
  assert(videoPriorities[2][1].slug === 'kling-2.5', 'Kling 2.5 Turbo is third (fast but lower quality)');

  // Test 3: No duplicate priorities within a type
  console.log('\n--- No duplicate priorities ---');
  const types = ['image', 'video', 'video-edit', 'motion-control', 'app'];
  for (const type of types) {
    const models = Object.entries(UNLIMITED_MODELS).filter(([, v]) => v.type === type);
    const priorities = models.map(([, v]) => v.priority);
    const uniquePriorities = new Set(priorities);
    assert(priorities.length === uniquePriorities.size, `No duplicate priorities in type '${type}'`);
  }

  // Test 4: Mock credit cache and test getUnlimitedModelForCommand
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

  // Test 5: getUnlimitedModelForCommand with partial cache (only some models active)
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
  assert(partialBest.slug === 'soul', `With only Soul+Nano active, Soul wins (priority 7 < 10) (got: ${partialBest?.slug})`);

  const noVideo = getUnlimitedModelForCommand('video');
  assert(noVideo === null, 'No video model when none are in cache');

  // Test 6: getUnlimitedModelForCommand with empty cache
  console.log('\n--- Empty/missing cache ---');
  const emptyCache = { remaining: '0', total: '0', plan: 'Free', unlimitedModels: [], timestamp: Date.now() };
  saveCreditCache(emptyCache);

  const emptyResult = getUnlimitedModelForCommand('image');
  assert(emptyResult === null, 'Returns null when no unlimited models in cache');

  // Test 7: isUnlimitedModel
  console.log('\n--- isUnlimitedModel ---');
  saveCreditCache(mockCache); // Restore full mock
  assert(isUnlimitedModel('gpt', 'image') === true, 'GPT is unlimited for image');
  assert(isUnlimitedModel('kling-2.6', 'video') === true, 'Kling 2.6 is unlimited for video');
  assert(isUnlimitedModel('soul', 'image') === true, 'Soul is unlimited for image');
  assert(isUnlimitedModel('sora', 'video') === false, 'Sora is NOT unlimited');
  assert(isUnlimitedModel('gpt', 'video') === false, 'GPT is NOT unlimited for video type');
  assert(isUnlimitedModel('kling-2.6', 'image') === false, 'Kling 2.6 is NOT unlimited for image type');

  // Test 8: estimateCreditCost with unlimited models
  console.log('\n--- estimateCreditCost with unlimited models ---');
  assert(estimateCreditCost('image', { model: 'gpt' }) === 0, 'GPT image costs 0 credits');
  assert(estimateCreditCost('video', { model: 'kling-2.6' }) === 0, 'Kling 2.6 video costs 0 credits');
  assert(estimateCreditCost('image', { model: 'sora' }) > 0, 'Non-unlimited model has credit cost');
  assert(estimateCreditCost('image', {}) === 0, 'No model + prefer-unlimited default = 0 (auto-selects unlimited)');
  assert(estimateCreditCost('image', { preferUnlimited: false }) > 0, 'prefer-unlimited=false has credit cost');
  assert(estimateCreditCost('video', {}) === 0, 'Video with auto-select = 0 credits');

  // Test 9: checkCreditGuard with unlimited models (should not throw)
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

  // Test 10: UNLIMITED_SLUGS reverse lookup
  console.log('\n--- UNLIMITED_SLUGS reverse lookup ---');
  assert(UNLIMITED_SLUGS.has('image:gpt'), 'Reverse lookup has image:gpt');
  assert(UNLIMITED_SLUGS.has('video:kling-2.6'), 'Reverse lookup has video:kling-2.6');
  assert(!UNLIMITED_SLUGS.has('video:gpt'), 'No reverse lookup for video:gpt');
  assert(UNLIMITED_SLUGS.get('image:gpt').includes('GPT Image365 Unlimited'), 'Reverse lookup maps to correct name');

  // Test 11: CLI flag parsing
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
  assert(parsed.options.preferUnlimited === undefined, 'No flag leaves undefined (default behavior)');

  // Test 12: --api and --api-only flag parsing
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

  // Test 13: API model ID mapping (verified against platform.higgsfield.ai 2026-02-10)
  console.log('\n--- API model ID mapping ---');
  assert(resolveApiModelId('soul', 'image') === 'higgsfield-ai/soul/standard', 'soul -> higgsfield-ai/soul/standard');
  assert(resolveApiModelId('seedream', 'image') === 'bytedance/seedream/v4/text-to-image', 'seedream maps to v4');
  assert(resolveApiModelId('reve', 'image') === 'reve/text-to-image', 'reve maps correctly');
  assert(resolveApiModelId('popcorn-manual', 'image') === 'higgsfield-ai/popcorn/manual', 'popcorn-manual maps correctly');
  assert(resolveApiModelId('dop-standard', 'video') === 'higgsfield-ai/dop/standard', 'dop-standard maps correctly');
  assert(resolveApiModelId('dop-standard-flf', 'video') === 'higgsfield-ai/dop/standard/first-last-frame', 'dop-standard-flf maps correctly');
  assert(resolveApiModelId('kling-3.0', 'video') === 'kling-video/v3.0/pro/image-to-video', 'kling-3.0 maps correctly');
  assert(resolveApiModelId('kling-2.6', 'video') === 'kling-video/v2.6/pro/image-to-video', 'kling-2.6 maps correctly');
  assert(resolveApiModelId('kling-2.1', 'video') === 'kling-video/v2.1/pro/image-to-video', 'kling-2.1 maps correctly');
  assert(resolveApiModelId('kling-2.1-master', 'video') === 'kling-video/v2.1/master/image-to-video', 'kling-2.1-master maps correctly');
  assert(resolveApiModelId('seedance', 'video') === 'bytedance/seedance/v1/pro/image-to-video', 'seedance maps correctly');
  assert(resolveApiModelId('seedance-lite', 'video') === 'bytedance/seedance/v1/lite/image-to-video', 'seedance-lite maps correctly');
  assert(resolveApiModelId('nonexistent', 'image') === null, 'Unknown slug returns null');
  assert(resolveApiModelId('dop', 'video') === 'higgsfield-ai/dop/standard', 'dop shorthand resolves to dop-standard for video');
  assert(resolveApiModelId(null, 'image') === null, 'null slug returns null');

  // Test 14: API credential loading
  console.log('\n--- API credential loading ---');
  const apiCreds = loadApiCredentials();
  // May or may not have creds — just verify the function doesn't crash
  if (apiCreds) {
    assert(typeof apiCreds.apiKey === 'string' && apiCreds.apiKey.length > 0, 'API key is non-empty string');
    assert(typeof apiCreds.apiSecret === 'string' && apiCreds.apiSecret.length > 0, 'API secret is non-empty string');
  } else {
    console.log('  (No API credentials configured — skipping value checks)');
    passed++; // Count as pass — absence is valid
  }

  // Test 15: API_MODEL_MAP completeness (verified model counts 2026-02-10)
  console.log('\n--- API_MODEL_MAP structure ---');
  const apiImageModels = Object.entries(API_MODEL_MAP).filter(([k]) => !k.includes('dop') && !k.includes('kling') && !k.includes('seedance') && !k.includes('edit'));
  const apiVideoModels = Object.entries(API_MODEL_MAP).filter(([k]) => k.includes('dop') || k.includes('kling') || k.includes('seedance'));
  assert(apiImageModels.length >= 7, `At least 7 image models in API map (got ${apiImageModels.length})`);
  assert(apiVideoModels.length >= 11, `At least 11 video models in API map (got ${apiVideoModels.length})`);
  // All values should be non-empty strings containing '/'
  for (const [slug, modelId] of Object.entries(API_MODEL_MAP)) {
    assert(typeof modelId === 'string' && modelId.includes('/'), `API model ID for '${slug}' is valid path: ${modelId}`);
  }

  // Restore original cache
  if (originalCache) {
    writeFileSync(CREDITS_CACHE_FILE, originalCache);
  }

  // Summary
  console.log(`\n=== Test Results: ${passed} passed, ${failed} failed ===\n`);
  if (failed > 0) {
    process.exit(1);
  }
}


// --- Batch Operations with Concurrency Control ---

// Load a batch manifest from a JSON file.
// Manifest format:
// {
//   "jobs": [
//     { "prompt": "...", "model": "soul", "aspect": "16:9", ... },
//     { "prompt": "...", "imageFile": "/path/to/img.jpg", ... }
//   ],
//   "defaults": { "model": "soul", "aspect": "9:16" }
// }
// Or a simple array of prompts: ["prompt 1", "prompt 2", ...]
function loadBatchManifest(filePath) {
  if (!existsSync(filePath)) {
    throw new Error(`Batch manifest not found: ${filePath}`);
  }
  const raw = JSON.parse(readFileSync(filePath, 'utf-8'));

  // Simple array of strings → convert to job objects
  if (Array.isArray(raw)) {
    return { jobs: raw.map(item => typeof item === 'string' ? { prompt: item } : item), defaults: {} };
  }

  // Object with jobs array
  if (raw.jobs && Array.isArray(raw.jobs)) {
    return { jobs: raw.jobs, defaults: raw.defaults || {} };
  }

  throw new Error('Invalid manifest format. Expected { "jobs": [...] } or ["prompt1", "prompt2", ...]');
}

// Save batch progress state for resume capability
function saveBatchState(outputDir, state) {
  writeFileSync(join(outputDir, 'batch-state.json'), JSON.stringify(state, null, 2));
}

function loadBatchState(outputDir) {
  const stateFile = join(outputDir, 'batch-state.json');
  if (existsSync(stateFile)) {
    return JSON.parse(readFileSync(stateFile, 'utf-8'));
  }
  return null;
}

// Generic concurrency limiter — runs async tasks with a max concurrency limit.
// Each task is a function returning a Promise.
// Returns results in the same order as the input tasks.
async function runWithConcurrency(tasks, concurrency) {
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
  }

  const workers = [];
  for (let i = 0; i < Math.min(concurrency, tasks.length); i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}

// Batch Image Generation
// Processes multiple image prompts with concurrency control.
// Concurrency for images means running N sequential browser sessions in parallel.
// Default concurrency: 2 (Higgsfield can handle 2-3 concurrent image generations).
async function batchImage(options = {}) {
  const manifestPath = options.batchFile;
  if (!manifestPath) {
    console.error('ERROR: --batch-file is required for batch-image');
    console.error('Usage: batch-image --batch-file manifest.json [--concurrency 2] [--output dir]');
    process.exit(1);
  }

  const { jobs, defaults } = loadBatchManifest(manifestPath);
  const concurrency = options.concurrency || 2;
  const outputDir = options.output || join(DOWNLOAD_DIR, `batch-image-${Date.now()}`);
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  console.log(`\n=== Batch Image Generation ===`);
  console.log(`Jobs: ${jobs.length}`);
  console.log(`Concurrency: ${concurrency}`);
  console.log(`Output: ${outputDir}`);
  console.log(`Defaults: ${JSON.stringify(defaults)}`);

  // Check for resume state
  let completedIndices = new Set();
  if (options.resume) {
    const prevState = loadBatchState(outputDir);
    if (prevState?.completed) {
      completedIndices = new Set(prevState.completed);
      console.log(`Resuming: ${completedIndices.size}/${jobs.length} already completed`);
    }
  }

  const startTime = Date.now();
  const batchState = {
    type: 'batch-image',
    total: jobs.length,
    concurrency,
    completed: [...completedIndices],
    failed: [],
    results: [],
    startTime: new Date().toISOString(),
  };

  // Create tasks for each job
  const tasks = jobs.map((job, index) => async () => {
    if (completedIndices.has(index)) {
      console.log(`[${index + 1}/${jobs.length}] Skipping (already completed)`);
      return { success: true, skipped: true, index };
    }

    const jobOptions = {
      ...options,
      ...defaults,
      ...job,
      output: outputDir,
      // Don't pass batch-file to individual jobs
      batchFile: undefined,
    };

    console.log(`[${index + 1}/${jobs.length}] Generating: "${(job.prompt || '').substring(0, 60)}..." (model: ${jobOptions.model || 'soul'})`);

    try {
      const result = await withRetry(
        () => generateImage(jobOptions),
        { maxRetries: 1, baseDelay: 5000, label: `batch-image[${index}]` }
      );

      batchState.completed.push(index);
      saveBatchState(outputDir, batchState);
      console.log(`[${index + 1}/${jobs.length}] Complete`);
      return { success: true, index, ...result };
    } catch (error) {
      batchState.failed.push({ index, error: error.message });
      saveBatchState(outputDir, batchState);
      console.error(`[${index + 1}/${jobs.length}] Failed: ${error.message}`);
      return { success: false, index, error: error.message };
    }
  });

  // Run with concurrency control
  const results = await runWithConcurrency(tasks, concurrency);

  // Summary
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
  const succeeded = results.filter(r => r?.success).length;
  const failed = results.filter(r => r && !r.success).length;

  batchState.elapsed = `${elapsed}s`;
  batchState.results = results.map(r => ({ success: r?.success, index: r?.index }));
  saveBatchState(outputDir, batchState);

  console.log(`\n=== Batch Image Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Results: ${succeeded} succeeded, ${failed} failed, ${jobs.length} total`);
  console.log(`Output: ${outputDir}`);

  if (failed > 0) {
    console.log(`\nFailed jobs:`);
    batchState.failed.forEach(f => console.log(`  [${f.index + 1}] ${f.error}`));
    console.log(`\nTo retry failed jobs: add --resume flag`);
  }

  return batchState;
}

// Batch Video Generation
// Uses the parallel submission pattern from pipeline():
// 1. Submit all video jobs sequentially in one browser session (fast, ~30s each)
// 2. Poll History tab for all prompts simultaneously
// 3. Download all completed videos via API interception
// Concurrency here controls how many browser sessions run in parallel for submission.
// For video, the bottleneck is generation time (4-10 min), not submission.
// So we submit all jobs first, then poll for all results together.
async function batchVideo(options = {}) {
  const manifestPath = options.batchFile;
  if (!manifestPath) {
    console.error('ERROR: --batch-file is required for batch-video');
    console.error('Usage: batch-video --batch-file manifest.json [--concurrency 3] [--output dir]');
    process.exit(1);
  }

  const { jobs, defaults } = loadBatchManifest(manifestPath);
  const concurrency = options.concurrency || 3; // How many to submit before polling
  const outputDir = options.output || join(DOWNLOAD_DIR, `batch-video-${Date.now()}`);
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  console.log(`\n=== Batch Video Generation ===`);
  console.log(`Jobs: ${jobs.length}`);
  console.log(`Concurrency (submit batch size): ${concurrency}`);
  console.log(`Output: ${outputDir}`);

  // Check for resume state
  let completedIndices = new Set();
  if (options.resume) {
    const prevState = loadBatchState(outputDir);
    if (prevState?.completed) {
      completedIndices = new Set(prevState.completed);
      console.log(`Resuming: ${completedIndices.size}/${jobs.length} already completed`);
    }
  }

  const startTime = Date.now();
  const batchState = {
    type: 'batch-video',
    total: jobs.length,
    concurrency,
    completed: [...completedIndices],
    failed: [],
    results: [],
    startTime: new Date().toISOString(),
  };

  // Filter out already-completed jobs
  const pendingJobs = jobs
    .map((job, index) => ({ job, index }))
    .filter(({ index }) => !completedIndices.has(index));

  if (pendingJobs.length === 0) {
    console.log('All jobs already completed!');
    return batchState;
  }

  // Process in batches of `concurrency` — submit a batch, poll for results, repeat
  for (let batchStart = 0; batchStart < pendingJobs.length; batchStart += concurrency) {
    const batch = pendingJobs.slice(batchStart, batchStart + concurrency);
    const batchNum = Math.floor(batchStart / concurrency) + 1;
    const totalBatches = Math.ceil(pendingJobs.length / concurrency);

    console.log(`\n--- Batch ${batchNum}/${totalBatches}: submitting ${batch.length} video job(s) ---`);

    const { browser, context, page } = await launchBrowser(options);

    try {
      // Phase 1: Submit all jobs in this batch
      const submittedJobs = [];
      for (const { job, index } of batch) {
        const jobOptions = { ...defaults, ...job };
        const model = jobOptions.model || 'kling-2.6';

        console.log(`  Submitting [${index + 1}/${jobs.length}]: "${(job.prompt || '').substring(0, 50)}..." (model: ${model})`);

        const promptPrefix = await submitVideoJobOnPage(page, {
          prompt: jobOptions.prompt || '',
          imageFile: jobOptions.imageFile,
          model,
          duration: String(jobOptions.duration || 5),
        });

        if (promptPrefix) {
          submittedJobs.push({
            sceneIndex: index,
            promptPrefix,
            model,
          });
        } else {
          batchState.failed.push({ index, error: 'Failed to submit job' });
        }
      }

      // Phase 2: Poll for all submitted jobs
      if (submittedJobs.length > 0) {
        console.log(`\n  Polling for ${submittedJobs.length} video(s)...`);
        const timeout = options.timeout || 600000;
        const videoResults = await pollAndDownloadVideos(page, submittedJobs, outputDir, timeout);

        for (const { index } of batch) {
          if (videoResults.has(index)) {
            batchState.completed.push(index);
            console.log(`  [${index + 1}/${jobs.length}] Downloaded: ${videoResults.get(index)}`);
          } else if (!batchState.failed.some(f => f.index === index)) {
            batchState.failed.push({ index, error: 'Generation timed out or download failed' });
          }
        }
      }

      saveBatchState(outputDir, batchState);
      await context.storageState({ path: STATE_FILE });
    } catch (error) {
      console.error(`Batch ${batchNum} error: ${error.message}`);
      for (const { index } of batch) {
        if (!batchState.completed.includes(index) && !batchState.failed.some(f => f.index === index)) {
          batchState.failed.push({ index, error: error.message });
        }
      }
      saveBatchState(outputDir, batchState);
    }

    try { await browser.close(); } catch {}
  }

  // Summary
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
  batchState.elapsed = `${elapsed}s`;
  batchState.results = jobs.map((_, i) => ({
    index: i,
    success: batchState.completed.includes(i),
  }));
  saveBatchState(outputDir, batchState);

  const succeeded = batchState.completed.length;
  const failed = batchState.failed.length;

  console.log(`\n=== Batch Video Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Results: ${succeeded} succeeded, ${failed} failed, ${jobs.length} total`);
  console.log(`Output: ${outputDir}`);

  if (failed > 0) {
    console.log(`\nFailed jobs:`);
    batchState.failed.forEach(f => console.log(`  [${f.index + 1}] ${f.error}`));
    console.log(`\nTo retry failed jobs: add --resume flag`);
  }

  return batchState;
}

// Batch Lipsync Generation
// Processes multiple lipsync jobs with concurrency control.
// Each job needs: text (prompt), imageFile (character face).
// Concurrency: sequential browser sessions (lipsync is slower, default 1).
async function batchLipsync(options = {}) {
  const manifestPath = options.batchFile;
  if (!manifestPath) {
    console.error('ERROR: --batch-file is required for batch-lipsync');
    console.error('Usage: batch-lipsync --batch-file manifest.json [--concurrency 1] [--output dir]');
    process.exit(1);
  }

  const { jobs, defaults } = loadBatchManifest(manifestPath);
  const concurrency = options.concurrency || 1; // Lipsync is slow, default sequential
  const outputDir = options.output || join(DOWNLOAD_DIR, `batch-lipsync-${Date.now()}`);
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

  console.log(`\n=== Batch Lipsync Generation ===`);
  console.log(`Jobs: ${jobs.length}`);
  console.log(`Concurrency: ${concurrency}`);
  console.log(`Output: ${outputDir}`);

  // Check for resume state
  let completedIndices = new Set();
  if (options.resume) {
    const prevState = loadBatchState(outputDir);
    if (prevState?.completed) {
      completedIndices = new Set(prevState.completed);
      console.log(`Resuming: ${completedIndices.size}/${jobs.length} already completed`);
    }
  }

  const startTime = Date.now();
  const batchState = {
    type: 'batch-lipsync',
    total: jobs.length,
    concurrency,
    completed: [...completedIndices],
    failed: [],
    results: [],
    startTime: new Date().toISOString(),
  };

  // Create tasks for each job
  const tasks = jobs.map((job, index) => async () => {
    if (completedIndices.has(index)) {
      console.log(`[${index + 1}/${jobs.length}] Skipping (already completed)`);
      return { success: true, skipped: true, index };
    }

    const jobOptions = {
      ...options,
      ...defaults,
      ...job,
      output: outputDir,
      batchFile: undefined,
    };

    if (!jobOptions.imageFile) {
      const msg = `Job ${index + 1} missing imageFile (character face required for lipsync)`;
      console.error(`[${index + 1}/${jobs.length}] ${msg}`);
      batchState.failed.push({ index, error: msg });
      saveBatchState(outputDir, batchState);
      return { success: false, index, error: msg };
    }

    console.log(`[${index + 1}/${jobs.length}] Generating lipsync: "${(job.prompt || '').substring(0, 60)}..."`);

    try {
      const result = await withRetry(
        () => generateLipsync(jobOptions),
        { maxRetries: 1, baseDelay: 5000, label: `batch-lipsync[${index}]` }
      );

      batchState.completed.push(index);
      saveBatchState(outputDir, batchState);
      console.log(`[${index + 1}/${jobs.length}] Complete`);
      return { success: true, index, ...result };
    } catch (error) {
      batchState.failed.push({ index, error: error.message });
      saveBatchState(outputDir, batchState);
      console.error(`[${index + 1}/${jobs.length}] Failed: ${error.message}`);
      return { success: false, index, error: error.message };
    }
  });

  // Run with concurrency control
  const results = await runWithConcurrency(tasks, concurrency);

  // Summary
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
  const succeeded = results.filter(r => r?.success).length;
  const failed = results.filter(r => r && !r.success).length;

  batchState.elapsed = `${elapsed}s`;
  batchState.results = results.map(r => ({ success: r?.success, index: r?.index }));
  saveBatchState(outputDir, batchState);

  console.log(`\n=== Batch Lipsync Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Results: ${succeeded} succeeded, ${failed} failed, ${jobs.length} total`);
  console.log(`Output: ${outputDir}`);

  if (failed > 0) {
    console.log(`\nFailed jobs:`);
    batchState.failed.forEach(f => console.log(`  [${f.index + 1}] ${f.error}`));
    console.log(`\nTo retry failed jobs: add --resume flag`);
  }

  return batchState;
}

// Run a command with API-first fallback to Playwright browser automation.
async function runWithApiFallback(apiFn, browserFn, options, retryOpts) {
  if (!options.useApi) return withRetry(() => browserFn(options), retryOpts);
  try {
    return await withRetry(() => apiFn(options), retryOpts);
  } catch (err) {
    if (options.apiOnly) throw err;
    console.log(`[api] API failed: ${err.message}`);
    console.log('[api] Falling back to Playwright browser automation...');
    return withRetry(() => browserFn(options), retryOpts);
  }
}

// Download latest generation results from the web UI.
async function downloadFromHistory(options) {
  const dlModel = options.model || 'soul';
  const isVideoDownload = dlModel === 'video' || options.duration;
  const { browser: dlBrowser, context: dlCtx, page: dlPage } = await launchBrowser(options);

  if (isVideoDownload) {
    console.log('Navigating to video page to download from History...');
    await dlPage.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await dlPage.waitForTimeout(5000);
    await dismissAllModals(dlPage);
    const dlDir = resolveOutputDir(options.output || DOWNLOAD_DIR, options, 'videos');
    await downloadVideoFromHistory(dlPage, dlDir, {}, options);
  } else {
    const dlUrl = `${BASE_URL}/image/${dlModel}`;
    console.log(`Navigating to ${dlUrl} to download latest generations...`);
    await dlPage.goto(dlUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await dlPage.waitForTimeout(5000);
    await dismissAllModals(dlPage);
    const dlDir = resolveOutputDir(options.output || DOWNLOAD_DIR, options, 'images');
    await downloadLatestResult(dlPage, dlDir, true, options);
  }

  await dlCtx.storageState({ path: STATE_FILE });
  await dlBrowser.close();
}

// Command registry: maps CLI command names to handler functions.
// Each entry is (options, retryOpts, retryOnce) => Promise<void>.
// Aliases (e.g., 'cinema' -> cinemaStudio) share the same handler reference.
const COMMAND_REGISTRY = {
  'login':              (opts) => login(opts),
  'discover':           (opts) => runDiscovery(opts),
  'image':              (opts, r) => runWithApiFallback(apiGenerateImage, generateImage, opts, r),
  'video':              (opts, _r, r1) => runWithApiFallback(apiGenerateVideo, generateVideo, opts, r1),
  'lipsync':            (opts, _r, r1) => withRetry(() => generateLipsync(opts), r1),
  'pipeline':           (opts) => pipeline(opts),
  'seed-bracket':       (opts) => seedBracket(opts),
  'app':                (opts, r) => withRetry(() => useApp(opts), r),
  'assets':             (opts) => listAssets(opts),
  'credits':            (opts) => checkCredits(opts),
  'api-status':         () => apiStatus(),
  'health-check':       (opts) => authHealthCheck(opts),
  'health':             (opts) => authHealthCheck(opts),
  'smoke-test':         (opts) => smokeTest(opts),
  'smoke':              (opts) => smokeTest(opts),
  'screenshot':         (opts) => screenshot(opts),
  'download':           (opts) => downloadFromHistory(opts),
  'cinema':             (opts, _r, r1) => withRetry(() => cinemaStudio(opts), r1),
  'cinema-studio':      (opts, _r, r1) => withRetry(() => cinemaStudio(opts), r1),
  'motion-control':     (opts, _r, r1) => withRetry(() => motionControl(opts), r1),
  'edit':               (opts, r) => withRetry(() => editImage(opts), r),
  'inpaint':            (opts, r) => withRetry(() => editImage(opts), r),
  'upscale':            (opts, r) => withRetry(() => upscale(opts), r),
  'asset':              (opts) => manageAssets(opts),
  'manage-assets':      (opts) => manageAssets(opts),
  'chain':              (opts, r) => withRetry(() => assetChain(opts), r),
  'asset-chain':        (opts, r) => withRetry(() => assetChain(opts), r),
  'open-in':            (opts, r) => withRetry(() => assetChain(opts), r),
  'mixed-media':        (opts, r) => withRetry(() => mixedMediaPreset(opts), r),
  'mixed-media-preset': (opts, r) => withRetry(() => mixedMediaPreset(opts), r),
  'motion-preset':      (opts, r) => withRetry(() => motionPreset(opts), r),
  'vfx-preset':         (opts, r) => withRetry(() => motionPreset(opts), r),
  'video-edit':         (opts, _r, r1) => withRetry(() => editVideo(opts), r1),
  'edit-video':         (opts, _r, r1) => withRetry(() => editVideo(opts), r1),
  'storyboard':         (opts, r) => withRetry(() => storyboard(opts), r),
  'vibe-motion':        (opts, r) => withRetry(() => vibeMotion(opts), r),
  'vibe':               (opts, r) => withRetry(() => vibeMotion(opts), r),
  'influencer':         (opts, r) => withRetry(() => aiInfluencer(opts), r),
  'ai-influencer':      (opts, r) => withRetry(() => aiInfluencer(opts), r),
  'character':          (opts, r) => withRetry(() => createCharacter(opts), r),
  'feature':            (opts, r) => withRetry(() => featurePage(opts), r),
  'fashion-factory':    (opts, r) => { opts.feature = 'fashion-factory'; return withRetry(() => featurePage(opts), r); },
  'ugc-factory':        (opts, r) => { opts.feature = 'ugc-factory'; return withRetry(() => featurePage(opts), r); },
  'photodump':          (opts, r) => { opts.feature = 'photodump'; return withRetry(() => featurePage(opts), r); },
  'camera-controls':    (opts, r) => { opts.feature = 'camera-controls'; return withRetry(() => featurePage(opts), r); },
  'effects':            (opts, r) => { opts.feature = 'effects'; return withRetry(() => featurePage(opts), r); },
  'test':               () => runSelfTests(),
  'self-test':          () => runSelfTests(),
};

// Main CLI handler
async function main() {
  const { command, options } = parseArgs();

  if (!command) {
    console.log(`
Higgsfield UI Automator - Browser-based generation using subscription credits

Usage: node playwright-automator.mjs <command> [options]

Commands:
  login              Login and save auth state
  discover           Force re-scan site for new features/models/apps
  health-check       Verify auth state is valid (no credits used)
  smoke-test         Run quick end-to-end test (no credits used)
  image              Generate an image from text prompt
  video              Generate a video (text-to-video or image-to-video)
  lipsync            Generate a lipsync video (image + text/audio)
  pipeline           Full production: image -> video -> lipsync -> assembly
  seed-bracket       Test seed range to find best seeds for a prompt
  app                Use a Higgsfield app/effect
  cinema-studio      Cinema Studio - cinematic image/video with camera+lens presets
  motion-control     Motion Control - animate character with motion reference video
  edit               Edit/Inpaint an image (soul_inpaint, banana_placement, canvas, etc.)
  upscale            AI upscale an image or video
  manage-assets      Browse, filter, and download from Asset Library
  chain              Chain asset to another tool (animate, inpaint, upscale, relight, etc.)
  mixed-media        Apply a mixed media preset (sketch, noir, particles, etc.)
  motion-preset      Apply a motion/VFX preset (150+ presets from discovery)
  video-edit         Edit a video with character image overlay
  storyboard         Generate multi-panel storyboard from script
  vibe-motion        Animated content (Infographics, Text Animation, Posters, etc.)
  influencer         AI Influencer Studio - create AI characters
  character          Create persistent character profile from photos
  feature            Generic feature page (fashion-factory, ugc-factory, photodump, etc.)
  assets             List recent generations
  credits            Check account credits/plan
  screenshot         Take screenshot of any page
  download           Download latest generation (use --model video for videos)
  api-status         Check API credentials and connectivity
  test               Run self-tests for unlimited model selection logic

Options:
  --prompt, -p       Text prompt for generation
  --model, -m        Model to use (soul, nano_banana, seedream, kling-2.6, etc.)
  --aspect, -a       Aspect ratio (16:9, 9:16, 1:1, 3:4, 4:3, 2:3, 3:2)
  --quality, -q      Quality setting (1K, 1.5K, 2K, 4K)
  --output, -o       Output directory or file path
  --headed           Run browser in headed mode (visible)
  --headless         Run browser in headless mode (default)
  --duration, -d     Video duration in seconds (5, 10, 15)
  --image-file       Path to image file for upload
  --image-url, -i    URL of image for image-to-video
  --wait             Wait for generation to complete
  --timeout          Timeout in milliseconds
  --effect           App/effect slug (e.g., face-swap, 3d-render)
  --enhance          Enable prompt enhancement
  --no-enhance       Disable prompt enhancement
  --sound            Enable sound/audio for video
  --no-sound         Disable sound/audio
  --batch, -b        Number of images to generate (1-4)
  --unlimited        Prefer unlimited models only
  --preset, -s       Style preset name (e.g., "Sunset beach", "CCTV")
  --seed             Seed number for reproducible generation
  --seed-range       Seed range for bracketing (e.g., "1000-1010" or "1000,1005,1010")
  --brief            Path to pipeline brief JSON file
  --character-image  Path to character face image for pipeline
  --dialogue         Dialogue text for lipsync in pipeline
  --scenes           Number of scenes to generate in pipeline
  --video-file       Path to video file (motion reference for motion-control)
  --motion-ref       Alias for --video-file (motion reference video)
  --image-file2      Second image file (multi-reference edit, product placement)
  --camera           Camera preset for cinema-studio (e.g., "Dolly Zoom")
  --lens             Lens preset for cinema-studio (e.g., "Anamorphic")
  --tab              Tab selection: "image" or "video" (cinema-studio)
  --filter           Asset filter: image, video, lipsync, upscaled, liked
  --asset-action     Asset action: list, download, download-latest, download-all
  --asset-type       Asset type filter for manage-assets
  --asset-index      Index of specific asset to download (0-based)
  --limit            Max number of assets to download
  --chain-action     Asset chain action: animate, inpaint, upscale, relight, angles, shots, ai-stylist, skin-enhancer, multishot
  --feature          Feature page slug: fashion-factory, ugc-factory, photodump-studio, camera-controls, effects
  --subtype          Vibe Motion sub-type: infographics, text-animation, posters, presentation, from-scratch
  --project          Project name for organized output dirs (creates {output}/{project}/{type}/)
  --no-sidecar       Disable JSON sidecar metadata files
  --no-dedup         Disable SHA-256 duplicate detection
  --force            Override credit guard (proceed even with low credits)
  --dry-run          Navigate and configure but don't click Generate
  --no-retry         Disable automatic retry on failure
  --prefer-unlimited Auto-select unlimited models when available (default: on)
  --no-prefer-unlimited  Use default models even if unlimited alternatives exist
  --api              Use Higgsfield Cloud API instead of browser (separate credit pool)
  --api-only         Use API only, fail if API unavailable (no Playwright fallback)

Examples:
  node playwright-automator.mjs login --headed
  node playwright-automator.mjs image -p "A cyberpunk city at night, neon lights"
  node playwright-automator.mjs video -p "Camera pans across landscape" --image-file photo.jpg
  node playwright-automator.mjs lipsync -p "Hello world!" --image-file face.jpg
  node playwright-automator.mjs pipeline --brief brief.json
  node playwright-automator.mjs pipeline -p "Person reviews product" --character-image face.png --dialogue "This is amazing!"
  node playwright-automator.mjs seed-bracket -p "Elegant woman, golden hour" --seed-range 1000-1010
  node playwright-automator.mjs app --effect face-swap --image-file face.jpg
  node playwright-automator.mjs credits
  node playwright-automator.mjs download --model video
  node playwright-automator.mjs screenshot -p "https://higgsfield.ai/image/soul"
  node playwright-automator.mjs cinema-studio -p "Epic landscape" --tab image --camera "Dolly Zoom"
  node playwright-automator.mjs motion-control --video-file dance.mp4 --image-file character.jpg
  node playwright-automator.mjs edit -p "Replace background with beach" --image-file photo.jpg -m soul_inpaint
  node playwright-automator.mjs upscale --image-file low-res.jpg
  node playwright-automator.mjs manage-assets --asset-action list --filter video
  node playwright-automator.mjs manage-assets --asset-action download-latest --filter image
  node playwright-automator.mjs chain --chain-action animate --asset-index 0
  node playwright-automator.mjs chain --chain-action inpaint -p "Replace background" --asset-index 0
  node playwright-automator.mjs mixed-media --preset sketch --image-file photo.jpg
  node playwright-automator.mjs motion-preset --preset "dolly_zoom" --image-file photo.jpg
  node playwright-automator.mjs video-edit --video-file clip.mp4 --image-file character.jpg
  node playwright-automator.mjs storyboard -p "A hero's journey through a cyberpunk city" --scenes 6
  node playwright-automator.mjs vibe-motion -p "Product launch announcement" --tab posters --preset Corporate
  node playwright-automator.mjs influencer --preset Human -p "Fashion influencer, warm smile"
  node playwright-automator.mjs character --image-file face1.jpg -p "Sarah"
  node playwright-automator.mjs feature --feature fashion-factory --image-file outfit.jpg

API mode (uses cloud.higgsfield.ai — separate credit pool from web UI):
  node playwright-automator.mjs api-status
  node playwright-automator.mjs image -p "A sunset over mountains" --api
  node playwright-automator.mjs image -p "Product shot" -m soul --api-only
  node playwright-automator.mjs video --image-file photo.jpg -p "Camera pans" --api -m dop-standard
`);
    return;
  }

  // Run site discovery if cache is stale (skips login, discovery, and diagnostic commands)
  const skipDiscoveryCommands = new Set(['login', 'discover', 'health-check', 'health', 'smoke-test', 'smoke', 'api-status']);
  if (!skipDiscoveryCommands.has(command)) {
    await ensureDiscovery(options);
  }

  // Credit guard: check available credits before expensive operations
  if (!options.force) {
    try {
      checkCreditGuard(command, options);
    } catch (e) {
      if (e.message.includes('CREDIT_GUARD')) {
        console.error(e.message);
        process.exit(1);
      }
    }
  }

  // Retry configuration: generation commands get retry, read-only commands don't
  const retryOpts = { maxRetries: options.noRetry ? 0 : 2, baseDelay: 3000, label: command };
  const retryOnce = { ...retryOpts, maxRetries: options.noRetry ? 0 : 1 };

  const entry = COMMAND_REGISTRY[command];
  if (!entry) {
    console.error(`Unknown command: ${command}`);
    process.exit(1);
  }
  await entry(options, retryOpts, retryOnce);
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
