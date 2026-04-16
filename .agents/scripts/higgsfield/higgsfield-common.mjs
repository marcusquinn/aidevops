// higgsfield-common.mjs — Shared constants, utilities, credit guard, CLI parsing,
// retry wrapper, and batch infrastructure for the Higgsfield automation suite.
// Imported by playwright-automator.mjs and the other focused module files.
//
// Browser helpers → higgsfield-browser.mjs
// Output/download helpers → higgsfield-output.mjs
// Discovery/login → higgsfield-discovery.mjs
// (t2127 file-complexity decomposition)

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'fs';
import { join, basename, extname } from 'path';
import { homedir } from 'os';
import { execFileSync } from 'child_process';

// ---------------------------------------------------------------------------
// Paths & Constants
// ---------------------------------------------------------------------------

export const BASE_URL = 'https://higgsfield.ai';
export const STATE_DIR = join(homedir(), '.aidevops', '.agent-workspace', 'work', 'higgsfield');
export const STATE_FILE = join(STATE_DIR, 'auth-state.json');
export const ROUTES_CACHE = join(STATE_DIR, 'routes-cache.json');
export const DISCOVERY_TIMESTAMP = join(STATE_DIR, 'last-discovery.txt');
export const USER_DOWNLOADS_DIR = join(homedir(), 'Downloads', 'higgsfield');
export const WORKSPACE_OUTPUT_DIR = join(STATE_DIR, 'output');
export const DISCOVERY_MAX_AGE_HOURS = 24;
export const CREDITS_CACHE_FILE = join(STATE_DIR, 'credits-cache.json');
export const CREDITS_CACHE_MAX_AGE_MS = 10 * 60 * 1000; // 10 minutes

// Unified CSS selector for generated images on the page.
export const GENERATED_IMAGE_SELECTOR = 'img[alt="image generation"], img[alt*="media asset by id"]';

// Credit cost estimates per operation type (approximate, varies by model/settings)
export const CREDIT_COSTS = {
  image: 2,
  video: 20,
  lipsync: 10,
  upscale: 2,
  edit: 2,
  app: 5,
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
  chain: 5,
  'seed-bracket': 10,
  pipeline: 60,
};

// Commands that don't consume credits (read-only / navigation)
export const FREE_COMMANDS = new Set([
  'login', 'discover', 'credits', 'screenshot', 'download',
  'assets', 'manage-assets', 'asset', 'test', 'self-test',
  'api-status',
]);

// Unlimited model mapping: subscription model name -> { slug, type, priority }
export const UNLIMITED_MODELS = {
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
  'Kling 2.6 Video Unlimited':          { slug: 'kling-2.6',     type: 'video',          priority: 1 },
  'Kling O1 Video Unlimited':           { slug: 'kling-o1',      type: 'video',          priority: 2 },
  'Kling 2.5 Turbo Unlimited':          { slug: 'kling-2.5',     type: 'video',          priority: 3 },
  'Kling O1 Video Edit Unlimited':      { slug: 'kling-o1',      type: 'video-edit',     priority: 1 },
  'Kling 2.6 Motion Control Unlimited': { slug: 'kling-2.6',     type: 'motion-control', priority: 1 },
  'Higgsfield Face Swap365 Unlimited':  { slug: 'face_swap',     type: 'app',            priority: 1 },
};

// Reverse lookup: CLI slug -> set of unlimited model names (for credit cost estimation)
export const UNLIMITED_SLUGS = new Map();
for (const [name, info] of Object.entries(UNLIMITED_MODELS)) {
  const key = `${info.type}:${info.slug}`;
  if (!UNLIMITED_SLUGS.has(key)) UNLIMITED_SLUGS.set(key, []);
  UNLIMITED_SLUGS.get(key).push(name);
}

// Ensure state directory exists
if (!existsSync(STATE_DIR)) {
  mkdirSync(STATE_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Unlimited model helpers
// ---------------------------------------------------------------------------

export function getUnlimitedModelForCommand(commandType) {
  const cache = getCachedCredits();
  if (!cache || !cache.unlimitedModels || cache.unlimitedModels.length === 0) return null;

  const activeNames = new Set(cache.unlimitedModels.map(m => m.model));
  const candidates = Object.entries(UNLIMITED_MODELS)
    .filter(([name, info]) => info.type === commandType && activeNames.has(name))
    .sort((a, b) => a[1].priority - b[1].priority);

  if (candidates.length === 0) return null;
  const [name, info] = candidates[0];
  return { slug: info.slug, name, type: info.type };
}

export function isUnlimitedModel(slug, commandType) {
  const key = `${commandType}:${slug}`;
  if (!UNLIMITED_SLUGS.has(key)) return false;

  const cache = getCachedCredits();
  if (!cache || !cache.unlimitedModels) return false;

  const activeNames = new Set(cache.unlimitedModels.map(m => m.model));
  return UNLIMITED_SLUGS.get(key).some(name => activeNames.has(name));
}

// ---------------------------------------------------------------------------
// Retry wrapper
// ---------------------------------------------------------------------------

const NON_RETRYABLE_ERROR_PATTERNS = [
  'unsupported content',
  'content policy',
  'No assets found',
  'not found',
  'CREDIT_GUARD',
];

function isNonRetryableError(msg) {
  return NON_RETRYABLE_ERROR_PATTERNS.some(pattern => msg.includes(pattern));
}

export async function withRetry(fn, { maxRetries = 2, baseDelay = 3000, label = 'operation' } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      const msg = error.message || String(error);
      if (isNonRetryableError(msg)) throw error;
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

// ---------------------------------------------------------------------------
// Shared filesystem utilities
// ---------------------------------------------------------------------------

export function ensureDir(dir) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

export function sanitizePathSegment(value, fallback = 'item') {
  const raw = basename(String(value ?? fallback));
  const cleaned = raw
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return cleaned || fallback;
}

export function safeJoin(basePath, ...segments) {
  const base = String(basePath || '').replace(/[\\/]+$/g, '');
  const cleanedSegments = segments
    .map(segment => String(segment ?? '').replace(/[\\]+/g, '/').replace(/^[/]+|[/]+$/g, ''))
    .filter(Boolean);
  return [base, ...cleanedSegments].join('/');
}

export function findNewestFile(dir, extensions = ['.png', '.jpg', '.webp']) {
  if (!existsSync(dir)) return null;
  const extSet = new Set(extensions.map(e => e.startsWith('.') ? e : `.${e}`));
  const files = readdirSync(dir)
    .filter(f => extSet.has(extname(f).toLowerCase()))
    .map(f => ({ name: f, time: statSync(safeJoin(dir, f)).mtimeMs }))
    .sort((a, b) => b.time - a.time);
  return files.length > 0 ? safeJoin(dir, files[0].name) : null;
}

export function findNewestFileMatching(dir, extensions, nameFilter) {
  if (!existsSync(dir)) return null;
  const extSet = new Set(extensions.map(e => e.startsWith('.') ? e : `.${e}`));
  const files = readdirSync(dir)
    .filter(f => extSet.has(extname(f).toLowerCase()) && (!nameFilter || f.includes(nameFilter)))
    .map(f => ({ name: f, time: statSync(safeJoin(dir, f)).mtimeMs }))
    .sort((a, b) => b.time - a.time);
  return files.length > 0 ? safeJoin(dir, files[0].name) : null;
}

export function curlDownload(url, savePath, { withHttpCode = false, timeout = 120000 } = {}) {
  const args = withHttpCode
    ? ['-sL', '-w', '%{http_code}', '-o', savePath, url]
    : ['-sL', '-o', savePath, url];
  const result = execFileSync('curl', args, { timeout, encoding: 'utf-8' });
  const httpCode = withHttpCode ? result.trim() : '200';
  const size = existsSync(savePath) ? statSync(savePath).size : 0;
  return { httpCode, size };
}

// ---------------------------------------------------------------------------
// CLI Argument Parsing
// ---------------------------------------------------------------------------

// Declarative flag definitions: [cliFlag, optionKey, type, alias?]
export const FLAG_DEFS = [
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
  ['--output',           'output',           'string', '-o'],
  ['--image-url',        'imageUrl',         'string', '-i'],
  ['--image-file',       'imageFile',        'string'       ],
  ['--image-file2',      'imageFile2',       'string'       ],
  ['--video-file',       'videoFile',        'string'       ],
  ['--motion-ref',       'motionRef',        'string'       ],
  ['--character-image',  'characterImage',   'string'       ],
  ['--dialogue',         'dialogue',         'string'       ],
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
  ['--count',            'count',            'int',    '-c'],
  ['--concurrency',      'concurrency',      'int',    '-C'],
  ['--batch-file',       'batchFile',        'string'       ],
  ['--headed',           'headed',           'true'         ],
  ['--headless',         'headless',         'true'         ],
  ['--wait',             'wait',             'true'         ],
  ['--unlimited',        'unlimited',        'true'         ],
  ['--force',            'force',            'true'         ],
  ['--dry-run',          'dryRun',           'true'         ],
  ['--no-retry',         'noRetry',          'true'         ],
  ['--no-sidecar',       'noSidecar',        'true'         ],
  ['--no-dedup',         'noDedup',          'true'         ],
  ['--resume',           'resume',           'true'         ],
  ['--api',              'useApi',           'true'         ],
  ['--no-enhance',       'enhance',          'false'        ],
  ['--no-sound',         'sound',            'false'        ],
  ['--no-prefer-unlimited', 'preferUnlimited', 'false'     ],
  ['--enhance',          'enhance',          'true'         ],
  ['--sound',            'sound',            'true'         ],
  ['--prefer-unlimited', 'preferUnlimited',  'true'         ],
  ['--api-only',         null,               'compound'     ],
];

export const FLAG_MAP = new Map();
for (const [flag, key, type, alias] of FLAG_DEFS) {
  FLAG_MAP.set(flag, { key, type });
  if (alias) FLAG_MAP.set(alias, { key, type });
}

function applyFlagValue(options, def, args, i) {
  if (def.type === 'string') {
    options[def.key] = args[i + 1];
    return i + 1;
  }
  if (def.type === 'int') {
    options[def.key] = parseInt(args[i + 1], 10);
    return i + 1;
  }
  if (def.type === 'true') { options[def.key] = true; return i; }
  if (def.type === 'false') { options[def.key] = false; return i; }
  if (def.type === 'compound' && args[i] === '--api-only') {
    options.useApi = true;
    options.apiOnly = true;
  }
  return i;
}

export function parseArgs() {
  const args = process.argv.slice(2);
  const command = args[0];
  const options = {};

  for (let i = 1; i < args.length; i++) {
    const def = FLAG_MAP.get(args[i]);
    if (!def) continue;
    i = applyFlagValue(options, def, args, i);
  }

  return { command, options };
}

// ---------------------------------------------------------------------------
// Credit guard
// ---------------------------------------------------------------------------

export function getCachedCredits() {
  try {
    if (existsSync(CREDITS_CACHE_FILE)) {
      const cache = JSON.parse(readFileSync(CREDITS_CACHE_FILE, 'utf-8'));
      const age = Date.now() - (cache.timestamp || 0);
      if (age < CREDITS_CACHE_MAX_AGE_MS) return cache;
    }
  } catch { /* ignore corrupt cache */ }
  return null;
}

export function saveCreditCache(creditInfo) {
  try {
    writeFileSync(CREDITS_CACHE_FILE, JSON.stringify({ ...creditInfo, timestamp: Date.now() }));
  } catch { /* ignore write errors */ }
}

function getCreditCostForCommand(command, options) {
  const typeMap = {
    image: 'image', video: 'video', lipsync: 'video',
    'video-edit': 'video-edit', 'motion-control': 'motion-control',
    'cinema-studio': 'video', cinema: 'video', app: 'app',
    'seed-bracket': 'image',
  };
  const modelType = typeMap[command] || command;
  const model = options.model;

  if (model && isUnlimitedModel(model, modelType)) return 0;
  if (!model && options.preferUnlimited !== false) {
    if (getUnlimitedModelForCommand(modelType)) return 0;
  }

  let cost = CREDIT_COSTS[command] || 5;
  if (command === 'image' && options.batch) cost *= parseInt(options.batch, 10) || 1;
  if (command === 'video' && options.duration) {
    const dur = parseInt(options.duration, 10);
    if (dur >= 15) cost = 40;
    else if (dur >= 10) cost = 30;
  }
  if (command === 'seed-bracket' && options.seedRange) {
    const parts = options.seedRange.split(/[-,]/);
    cost = Math.max(parts.length, 2) * 2;
  }
  return cost;
}

export function estimateCreditCost(command, options = {}) {
  return getCreditCostForCommand(command, options);
}

export function checkCreditGuard(command, options = {}) {
  if (FREE_COMMANDS.has(command) || options.dryRun) return;

  const cached = getCachedCredits();
  if (!cached) return;

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

// ---------------------------------------------------------------------------
// Re-exports from decomposed modules (backward compatibility)
// ---------------------------------------------------------------------------

export {
  getDefaultOutputDir,
  launchBrowser,
  withBrowser,
  navigateTo,
  debugScreenshot,
  clickHistoryTab,
  clickGenerate,
  dismissAllModals,
  forceCloseDialogs,
  dismissInterruptions,
  dismissModalsAndBanners,
  dismissOverlaysAndAgreements,
  loadKnownInterruptions,
  logNewInterruption,
} from './higgsfield-browser.mjs';

export {
  resolveOutputDir,
  inferOutputType,
  writeJsonSidecar,
  computeFileHash,
  checkDuplicate,
  finalizeDownload,
  buildDescriptiveFilename,
  downloadImageViaDialog,
  downloadImagesByCDN,
  downloadLatestResult,
  downloadSpecificImages,
  extractDialogMetadata,
} from './higgsfield-output.mjs';

export {
  loadCredentials,
  login,
  runDiscovery,
  ensureDiscovery,
  discoveryNeeded,
  categoriseRoutes,
  diffRoutesAgainstCache,
  ROUTE_PREFIXES,
  ACCOUNT_PREFIXES,
  FEATURE_PREFIXES,
  tryFillField,
  tryClickSubmit,
  isNonAuthUrl,
} from './higgsfield-discovery.mjs';

export {
  loadBatchManifest,
  saveBatchState,
  loadBatchState,
  runWithConcurrency,
  initBatch,
  runBatchJob,
  finalizeBatch,
  waitForGenerationResult,
} from './higgsfield-batch-infra.mjs';
