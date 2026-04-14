// higgsfield-common.mjs — Shared constants, utilities, credit guard, browser helpers,
// download/output organisation for the Higgsfield automation suite.
// Imported by playwright-automator.mjs and the other focused module files.

import { chromium } from 'playwright';
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, readdirSync, statSync } from 'fs';
import { join, basename, extname } from 'path';
import { homedir } from 'os';
import { execFileSync } from 'child_process';
import { createHash } from 'crypto';

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
// Credentials
// ---------------------------------------------------------------------------

export function loadCredentials() {
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
// Browser helpers
// ---------------------------------------------------------------------------

export function getDefaultOutputDir(options = {}) {
  if (options.headless || (!process.stdout.isTTY && !options.headed)) {
    return WORKSPACE_OUTPUT_DIR;
  }
  return USER_DOWNLOADS_DIR;
}

export async function launchBrowser(options = {}) {
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

  const ctxOptions = {
    viewport: { width: 1440, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  };

  const browser = await chromium.launch(launchOptions);
  if (existsSync(STATE_FILE)) {
    ctxOptions.storageState = STATE_FILE;
  }
  const context = await browser.newContext(ctxOptions);
  const page = await context.newPage();
  return { browser, context, page };
}

export async function withBrowser(options, fn) {
  const { browser, context, page } = await launchBrowser(options);
  try {
    const result = await fn(page, context);
    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return result;
  } catch (error) {
    try { await browser.close(); } catch {}
    throw error;
  }
}

export async function navigateTo(page, path, { waitMs = 3000, timeout = 60000 } = {}) {
  const url = path.startsWith('http') ? path : `${BASE_URL}${path}`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
  await page.waitForTimeout(waitMs);
  await dismissAllModals(page);
}

export async function debugScreenshot(page, name, { fullPage = false } = {}) {
  const safeName = sanitizePathSegment(name, 'debug');
  await page.screenshot({ path: safeJoin(STATE_DIR, `${safeName}.png`), fullPage });
}

export async function clickHistoryTab(page, { waitMs = 2000 } = {}) {
  const historyTab = page.locator('[role="tab"]:has-text("History")');
  if (await historyTab.count() > 0) {
    await historyTab.click({ force: true });
    await page.waitForTimeout(waitMs);
  }
  return historyTab;
}

export async function clickGenerate(page, label = '') {
  const generateBtn = page.locator('button:has-text("Generate"), button:has-text("Create"), button:has-text("Apply")');
  if (await generateBtn.count() > 0) {
    await generateBtn.last().click({ force: true });
    console.log(`Clicked Generate${label ? ` for ${label}` : ''}`);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Modal dismissal
// ---------------------------------------------------------------------------

const KNOWN_INTERRUPTIONS_FILE = join(STATE_DIR, 'known-interruptions.json');

export function loadKnownInterruptions() {
  try {
    if (existsSync(KNOWN_INTERRUPTIONS_FILE)) {
      return JSON.parse(readFileSync(KNOWN_INTERRUPTIONS_FILE, 'utf-8'));
    }
  } catch {}
  return { types: [] };
}

export function logNewInterruption(type, selector, detail) {
  const data = loadKnownInterruptions();
  const exists = data.types.some(t => t.type === type);
  if (!exists) {
    data.types.push({ type, selector, detail, firstSeen: new Date().toISOString() });
    try {
      writeFileSync(KNOWN_INTERRUPTIONS_FILE, JSON.stringify(data, null, 2));
    } catch {}
  }
}

export async function dismissModalsAndBanners(page) {
  return page.evaluate(() => {
    const dismissed = [];

    document.querySelectorAll('.react-aria-ModalOverlay, [data-rac].react-aria-ModalOverlay')
      .forEach(o => { o.remove(); dismissed.push('react-aria-modal'); });
    document.querySelectorAll('button[aria-label="Dismiss"]')
      .forEach(b => { b.click(); dismissed.push('dismiss-button'); });

    for (const sel of ['[class*="cookie"]','[id*="cookie"]','[class*="consent"]','[id*="consent"]','[class*="gdpr"]','[id*="gdpr"]','[class*="CookieBanner"]']) {
      document.querySelectorAll(sel).forEach(el => {
        const ab = el.querySelector('button');
        if (ab) { ab.click(); dismissed.push('cookie-accept'); }
        else { el.remove(); dismissed.push('cookie-remove'); }
      });
    }

    document.querySelectorAll('[role="alert"],[class*="toast"],[class*="Toast"],[class*="notification"],[class*="Notification"],[class*="snackbar"]')
      .forEach(el => { const cb = el.querySelector('button'); if (cb) { cb.click(); dismissed.push('toast-close'); } });

    document.querySelectorAll('[class*="tooltip"][class*="onboard"],[class*="tour"],[class*="walkthrough"],[class*="Popover"][class*="guide"]')
      .forEach(el => { const sb = el.querySelector('button:last-child') || el.querySelector('button'); if (sb) { sb.click(); dismissed.push('onboarding-skip'); } else { el.remove(); dismissed.push('onboarding-remove'); } });

    return dismissed;
  });
}

export async function dismissOverlaysAndAgreements(page) {
  return page.evaluate(() => {
    const dismissed = [];

    document.querySelectorAll('[class*="upgrade"],[class*="paywall"],[class*="subscribe"]')
      .forEach(el => { if (el.style.position==='fixed'||el.style.position==='absolute'||getComputedStyle(el).position==='fixed') { el.remove(); dismissed.push('upgrade-overlay'); } });

    document.querySelectorAll('[role="dialog"]').forEach(d => { const p=d.parentElement; if(p&&(p.classList.contains('react-aria-ModalOverlay')||getComputedStyle(p).position==='fixed')){p.remove();dismissed.push('generic-dialog');} });

    document.querySelectorAll('main .size-full.flex.items-center.justify-center').forEach(el => { if(!el.querySelector('textarea,input,button[type="submit"],form')&&el.children.length<=2){el.remove();dismissed.push('loading-overlay');} });

    document.querySelectorAll('[role="dialog"],dialog').forEach(dialog => {
      const t=dialog.textContent||'';
      if(t.includes('Media upload agreement')||t.includes('I agree, continue')||t.includes('terms of service')||t.includes('Terms of Service')){
        for(const btn of dialog.querySelectorAll('button')){if(btn.textContent.includes('agree')||btn.textContent.includes('continue')||btn.textContent.includes('Accept')||btn.textContent.includes('OK')){btn.click();dismissed.push('media-upload-agreement');break;}}
      }
    });

    if(document.body.style.overflow==='hidden'||document.body.style.pointerEvents==='none'){document.body.style.overflow='';document.body.style.pointerEvents='';dismissed.push('body-unlock');}

    return dismissed;
  });
}

async function tryDismissEscapeKey(page) {
  const remaining = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (remaining === 0) return;
  await page.keyboard.press('Escape');
  await page.waitForTimeout(500);
  const afterEsc = await page.evaluate(() =>
    document.querySelectorAll('.react-aria-ModalOverlay').length
  );
  if (afterEsc < remaining) {
    console.log(`Escape dismissed ${remaining - afterEsc} more modal(s)`);
  }
}

export async function dismissInterruptions(page) {
  const part1 = await dismissModalsAndBanners(page);
  const part2 = await dismissOverlaysAndAgreements(page);
  const results = [...(Array.isArray(part1) ? part1 : []), ...(Array.isArray(part2) ? part2 : [])];

  if (results.length > 0) {
    console.log(`Cleared ${results.length} interruption(s): ${[...new Set(results)].join(', ')}`);
    for (const type of new Set(results)) {
      logNewInterruption(type, 'auto-detected', `Dismissed via comprehensive sweep`);
    }
  }

  await tryDismissEscapeKey(page);
  return results.length;
}

export async function dismissAllModals(page) {
  let totalDismissed = 0;
  for (let i = 0; i < 3; i++) {
    const count = await dismissInterruptions(page);
    totalDismissed += count;
    if (count === 0) break;
    await page.waitForTimeout(500);
  }
  return totalDismissed;
}

export async function forceCloseDialogs(page) {
  await page.keyboard.press('Escape');
  await page.waitForTimeout(500);
  const stillOpen = await page.locator('[role="dialog"]').count();
  if (stillOpen === 0) return;
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

// ---------------------------------------------------------------------------
// Output organisation (project dirs, JSON sidecars, dedup)
// ---------------------------------------------------------------------------

export function resolveOutputDir(baseOutput, options = {}, type = 'misc') {
  let dir = baseOutput;

  if (options.project) {
    const projectSlug = options.project
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '');
    dir = safeJoin(baseOutput, projectSlug, type);
  }

  return ensureDir(dir);
}

export function inferOutputType(command, options = {}) {
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

export function writeJsonSidecar(filePath, metadata, options = {}) {
  if (options.noSidecar) return;

  const sidecarPath = `${filePath}.json`;
  const sidecar = {
    source: 'higgsfield-ui-automator',
    version: '1.0',
    timestamp: new Date().toISOString(),
    file: basename(filePath),
    ...metadata,
  };

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

export function computeFileHash(filePath) {
  try {
    const data = readFileSync(filePath);
    return createHash('sha256').update(data).digest('hex');
  } catch {
    return null;
  }
}

function loadDedupIndex(indexPath) {
  if (!existsSync(indexPath)) return {};
  try {
    return JSON.parse(readFileSync(indexPath, 'utf-8'));
  } catch {
    return {};
  }
}

export function checkDuplicate(filePath, outputDir, options = {}) {
  if (options.noDedup) return null;

  const hash = computeFileHash(filePath);
  if (!hash) return null;

  const indexPath = safeJoin(outputDir, '.dedup-index.json');
  const index = loadDedupIndex(indexPath);

  if (index[hash] && index[hash] !== basename(filePath)) {
    const existingPath = safeJoin(outputDir, sanitizePathSegment(index[hash], 'unknown'));
    if (existsSync(existingPath)) return existingPath;
    delete index[hash];
  }

  index[hash] = basename(filePath);
  try {
    writeFileSync(indexPath, JSON.stringify(index, null, 2));
  } catch { /* ignore write errors */ }

  return null;
}

export function finalizeDownload(filePath, metadata, outputDir, options = {}) {
  const duplicate = checkDuplicate(filePath, outputDir, options);
  if (duplicate) {
    console.log(`[dedup] Skipping duplicate: ${basename(filePath)} matches ${basename(duplicate)}`);
    try { unlinkSync(filePath); } catch { /* ignore */ }
    return { path: duplicate, duplicate: true, skipped: true };
  }

  writeJsonSidecar(filePath, metadata, options);
  return { path: filePath, duplicate: false, skipped: false };
}

export function buildDescriptiveFilename(metadata, originalFilename, index) {
  const parts = [];

  if (metadata.model) parts.push(metadata.model.replace(/[^a-zA-Z0-9_-]/g, '_'));
  if (metadata.promptSnippet) {
    const snippet = metadata.promptSnippet
      .substring(0, 40)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_|_$/g, '');
    if (snippet) parts.push(snippet);
  }
  if (index > 0) parts.push(String(index + 1));

  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
  parts.push(timestamp);

  const ext = extname(originalFilename) || '.png';
  const prefix = parts.length > 0 ? `hf_${parts.join('_')}` : `hf_${timestamp}`;
  return `${prefix}${ext}`;
}

// ---------------------------------------------------------------------------
// Image download helpers (used by image and download modules)
// ---------------------------------------------------------------------------

async function clickDownloadButton(page) {
  const dlBtn = page.locator('[role="dialog"] button:has-text("Download"), dialog button:has-text("Download")');
  if (await dlBtn.count() === 0) return null;
  const downloadPromise = page.waitForEvent('download', { timeout: 30000 }).catch(() => null);
  await dlBtn.first().click({ force: true });
  return downloadPromise;
}

export async function downloadImageViaDialog({ page, imgLocator, index, outputDir, extraMeta, options }) {
  await imgLocator.click({ force: true });
  await page.waitForTimeout(1500);

  const dialog = page.locator('dialog, [role="dialog"]');
  if (await dialog.count() === 0) return null;

  const metadata = await extractDialogMetadata(page);
  const download = await clickDownloadButton(page);

  if (!download) {
    await page.waitForTimeout(2000);
    console.log(`Download button clicked but no download event for image ${index + 1} - trying CDN fallback`);
    await forceCloseDialogs(page);
    return null;
  }

  const origFilename = download.suggestedFilename() || `higgsfield-${Date.now()}-${index}.png`;
  const descriptiveName = buildDescriptiveFilename(metadata, origFilename, index);
  const savePath = safeJoin(outputDir, descriptiveName);
  await download.saveAs(savePath);
  const result = finalizeDownload(savePath, {
    ...extraMeta, type: 'image', ...metadata, originalFilename: origFilename,
  }, outputDir, options);

  await forceCloseDialogs(page);
  return result.skipped ? null : result.path;
}

async function extractCdnVideoUrls(page) {
  return page.evaluate(() => {
    const videos = document.querySelectorAll('video source[src], video[src]');
    return [...videos].map(v => v.src || v.getAttribute('src')).filter(Boolean);
  });
}

export async function downloadImagesByCDN(page, indices, outputDir, extraMeta, options) {
  const downloaded = [];
  const cdnUrls = await page.evaluate(({ idxList, imgSelector }) => {
    const imgs = document.querySelectorAll(imgSelector);
    const targets = idxList != null ? idxList : [...Array(imgs.length).keys()];
    return targets.map(idx => {
      const img = imgs[idx];
      if (!img) return null;
      const cfMatch = img.src.match(/(https:\/\/d8j0ntlcm91z4\.cloudfront\.net\/[^\s]+)/);
      return { url: cfMatch ? cfMatch[1] : img.src, idx };
    }).filter(Boolean);
  }, { idxList: indices, imgSelector: GENERATED_IMAGE_SELECTOR });

  if (indices == null) {
    const videoUrls = await extractCdnVideoUrls(page);
    for (const url of videoUrls) {
      cdnUrls.push({ url, idx: cdnUrls.length });
    }
  }

  for (const { url, idx } of cdnUrls) {
    const isVideo = url.includes('.mp4') || url.includes('video');
    const ext = isVideo ? '.mp4' : '.webp';
    const cdnMeta = { promptSnippet: 'cdn-fallback' };
    const filename = buildDescriptiveFilename(cdnMeta, `higgsfield-cdn-${Date.now()}${ext}`, downloaded.length);
    const savePath = safeJoin(outputDir, filename);
    try {
      execFileSync('curl', ['-sL', '-o', savePath, url], { timeout: 60000 });
      const result = finalizeDownload(savePath, {
        ...extraMeta, type: isVideo ? 'video' : 'image',
        cdnUrl: url, strategy: 'cdn-fallback', imageIndex: idx,
      }, outputDir, options);
      if (!result.skipped) {
        console.log(`Downloaded via CDN [${downloaded.length + 1}]: ${savePath}`);
      }
      downloaded.push(result.path);
    } catch (curlErr) {
      console.log(`CDN download failed for ${url}: ${curlErr.message}`);
    }
  }
  return downloaded;
}

async function downloadImagesViaDialog(page, generatedImgs, toDownload, outputDir, options) {
  const downloaded = [];
  for (let i = 0; i < toDownload; i++) {
    try {
      const path = await downloadImageViaDialog({
        page, imgLocator: generatedImgs.nth(i), index: i, outputDir,
        extraMeta: { command: 'download' }, options,
      });
      if (path) {
        console.log(`Downloaded [${i + 1}/${toDownload}]: ${path}`);
        downloaded.push(path);
      }
    } catch (imgErr) {
      console.log(`Error downloading image ${i + 1}: ${imgErr.message}`);
    }
  }
  return downloaded;
}

export async function downloadLatestResult(page, outputDir, count = 4, options = {}) {
  const downloaded = [];

  try {
    await dismissAllModals(page);

    const generatedImgs = page.locator(GENERATED_IMAGE_SELECTOR);
    const imgCount = await generatedImgs.count();
    console.log(`Found ${imgCount} generated image(s) on page`);

    if (imgCount > 0) {
      const toDownload = count === 0 ? imgCount : Math.min(count, imgCount);
      const dialogDownloads = await downloadImagesViaDialog(page, generatedImgs, toDownload, outputDir, options);
      downloaded.push(...dialogDownloads);
    }

    if (downloaded.length === 0) {
      console.log('Falling back to direct CDN URL extraction...');
      const cdnDownloads = await downloadImagesByCDN(page, null, outputDir, { command: 'download' }, options);
      downloaded.push(...(count === 0 ? cdnDownloads : cdnDownloads.slice(0, count)));
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

export async function downloadSpecificImages(page, outputDir, indices, options = {}) {
  const downloaded = [];
  const generatedImgs = page.locator(GENERATED_IMAGE_SELECTOR);

  for (const idx of indices) {
    try {
      const path = await downloadImageViaDialog({
        page, imgLocator: generatedImgs.nth(idx), index: downloaded.length, outputDir,
        extraMeta: { command: 'image', imageIndex: idx }, options,
      });
      if (path) {
        console.log(`Downloaded [${downloaded.length + 1}/${indices.length}]: ${path}`);
        downloaded.push(path);
      }
    } catch (err) {
      console.log(`Error downloading image at index ${idx}: ${err.message}`);
    }
  }

  if (downloaded.length < indices.length) {
    console.log(`Dialog download got ${downloaded.length}/${indices.length}, trying CDN fallback for remainder...`);
    const cdnDownloads = await downloadImagesByCDN(page, indices.slice(downloaded.length), outputDir, { command: 'image' }, options);
    downloaded.push(...cdnDownloads);
  }

  console.log(`Successfully downloaded ${downloaded.length} file(s)`);
  return downloaded;
}

// ---------------------------------------------------------------------------
// Dialog metadata extraction
// ---------------------------------------------------------------------------

export async function extractDialogMetadata(page) {
  return page.evaluate(() => {
    const dialog = document.querySelector('[role="dialog"], dialog');
    if (!dialog) return {};

    const metadata = {};

    const textbox = dialog.querySelector('[role="textbox"], textarea');
    if (textbox) metadata.promptSnippet = textbox.textContent?.trim()?.substring(0, 80);

    const modelText = dialog.textContent || '';
    const modelMatch = modelText.match(/Model:\s*([^\n]+)/i) || modelText.match(/via\s+([A-Z][^\n]+)/);
    if (modelMatch) metadata.model = modelMatch[1].trim().substring(0, 40);

    return metadata;
  });
}

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

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export const ROUTE_PREFIXES = [
  { prefix: '/image/',              bucket: 'image' },
  { prefix: '/create/',             bucket: 'video' },
  { prefix: '/edit',                bucket: 'edit' },
  { prefix: '/app/',                bucket: 'apps' },
  { prefix: '/motion/',             bucket: 'motions' },
  { prefix: '/mixed-media-presets/',bucket: 'mixed_media' },
];

export const ACCOUNT_PREFIXES = ['/asset/all', '/library/image', '/profile', '/pricing', '/auth/'];
export const FEATURE_PREFIXES = [
  '/cinema-studio', '/vibe-motion', '/lipsync-studio', '/character',
  '/ai-influencer-studio', '/upscale', '/fashion-factory', '/chat',
  '/ugc-factory', '/photodump-studio', '/storyboard-generator',
  '/nano-banana-pro', '/seedream-4-5', '/kling', '/sora', '/wan', '/veo', '/minimax',
];

export function categoriseRoutes(links) {
  const routes = { image: {}, video: {}, edit: {}, apps: {}, features: {}, account: {}, motions: {}, mixed_media: {}, other: {} };
  for (const [path, label] of Object.entries(links)) {
    const match = ROUTE_PREFIXES.find(r => path.startsWith(r.prefix));
    if (match) {
      routes[match.bucket][path] = label;
    } else if (ACCOUNT_PREFIXES.some(p => path.startsWith(p))) {
      routes.account[path] = label;
    } else if (FEATURE_PREFIXES.some(p => path.startsWith(p))) {
      routes.features[path] = label;
    } else {
      routes.other[path] = label;
    }
  }
  return routes;
}

const DIFF_BUCKETS = [
  { key: 'apps', label: 'APP' },
  { key: 'image', label: 'IMAGE MODEL' },
  { key: 'features', label: 'FEATURE' },
];

function collectAddedPaths(label, currentBucket, prevKeys) {
  const added = [];
  for (const path of Object.keys(currentBucket)) {
    if (!prevKeys.has(path)) added.push(`NEW ${label}: ${path} → ${currentBucket[path]}`);
  }
  return added;
}

function collectRemovedApps(currentApps, prevAppKeys) {
  const removed = [];
  for (const path of prevAppKeys) {
    if (!currentApps[path]) removed.push(`REMOVED APP: ${path}`);
  }
  return removed;
}

function diffBucket(prev, routes, { key, label }) {
  const prevKeys = new Set(Object.keys(prev[key] || {}));
  const changes = collectAddedPaths(label, routes[key], prevKeys);
  if (key === 'apps') changes.push(...collectRemovedApps(routes.apps, prevKeys));
  return changes;
}

function loadPreviousRoutes() {
  if (!existsSync(ROUTES_CACHE)) return null;
  try {
    return JSON.parse(readFileSync(ROUTES_CACHE, 'utf-8'));
  } catch {
    return null; // first run or corrupt cache
  }
}

export function diffRoutesAgainstCache(routes) {
  const prev = loadPreviousRoutes();
  if (!prev) return [];
  const changes = [];
  for (const bucket of DIFF_BUCKETS) {
    changes.push(...diffBucket(prev, routes, bucket));
  }
  return changes;
}

export function discoveryNeeded() {
  if (!existsSync(DISCOVERY_TIMESTAMP)) return true;
  try {
    const lastRun = parseInt(readFileSync(DISCOVERY_TIMESTAMP, 'utf-8').trim(), 10);
    const ageHours = (Date.now() - lastRun) / (1000 * 60 * 60);
    return ageHours > DISCOVERY_MAX_AGE_HOURS;
  } catch {
    return true;
  }
}

async function scrapeDiscoveryLinks(page) {
  return page.evaluate(() => {
    const allLinks = [...document.querySelectorAll('a[href]')];
    const map = {};
    allLinks.forEach(a => {
      const href = a.getAttribute('href');
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
}

async function scrapeImageModels(page) {
  await page.goto(`${BASE_URL}/image/soul`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(3000);
  await dismissAllModals(page);
  return page.evaluate(() => {
    const modelBtns = [...document.querySelectorAll('button')].filter(b =>
      b.textContent?.match(/soul|nano|seedream|flux|gpt|wan|kontext/i)
    );
    return modelBtns.map(b => b.textContent?.trim().substring(0, 60));
  });
}

function logDiscoverySummary(links, routes, changes) {
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
}

export async function runDiscovery(options = {}) {
  console.log('Running site discovery (checking for new/changed features)...');
  const { browser, context, page } = await launchBrowser({ ...options, headless: true });

  try {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(5000);
    await dismissAllModals(page);

    const links = await scrapeDiscoveryLinks(page);
    const routes = categoriseRoutes(links);
    const imageModels = await scrapeImageModels(page);
    const changes = diffRoutesAgainstCache(routes);

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

    logDiscoverySummary(links, routes, changes);

    await context.storageState({ path: STATE_FILE });
    await browser.close();
    return cacheData;

  } catch (error) {
    console.error('Discovery error:', error.message);
    await browser.close();
    return null;
  }
}

export async function ensureDiscovery(options = {}) {
  if (discoveryNeeded()) {
    return await runDiscovery(options);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------

async function waitForLoginRedirect(page, options) {
  try {
    await page.waitForURL(isNonAuthUrl, { timeout: 30000 });
    console.log('Login successful! Redirected to:', page.url());
  } catch {
    console.log('Still on auth page. Current URL:', page.url());
    await debugScreenshot(page, 'login-result', { fullPage: true });

    const errorText = await page.evaluate(() => {
      const errors = document.querySelectorAll('[class*="error"], [class*="alert"], [role="alert"]');
      return [...errors].map(e => e.textContent?.trim()).filter(Boolean).join('; ');
    });
    if (errorText) console.log('Error message:', errorText);

    if (options.headed) {
      console.log('Waiting 60s for manual login completion...');
      try {
        await page.waitForURL(isNonAuthUrl, { timeout: 60000 });
        console.log('Login completed manually! URL:', page.url());
      } catch {
        console.log('Timeout. Saving current state anyway...');
      }
    }
  }
}

async function performLoginSteps(page, user, pass) {
  const emailSelectors = [
    'input[type="email"]',
    'input[name="email"]',
    'input[placeholder*="email" i]',
    'input[autocomplete="email"]',
    'input[id*="email" i]',
    'input:not([type="hidden"]):not([type="password"])',
  ];

  const emailFilled = await tryFillField(page, emailSelectors, user, 'Email');

  if (!emailFilled) {
    console.log('Could not find email field automatically');
    const inputs = await page.evaluate(() => {
      return [...document.querySelectorAll('input:not([type="hidden"])')].map(el => ({
        type: el.type, name: el.name, id: el.id,
        placeholder: el.placeholder, className: el.className.substring(0, 80),
      }));
    });
    console.log('Visible inputs:', JSON.stringify(inputs, null, 2));
  }

  await page.waitForTimeout(1000);

  const passwordSelectors = [
    'input[type="password"]',
    'input[name="password"]',
    'input[placeholder*="password" i]',
    'input[autocomplete="current-password"]',
  ];

  let passFilled = await tryFillField(page, passwordSelectors, pass, 'Password');
  if (!passFilled) console.log('No password field found yet - may appear after email submission');

  await page.waitForTimeout(500);

  const submitSelectors = [
    'button[type="submit"]',
    'button:has-text("Sign in")',
    'button:has-text("Log in")',
    'button:has-text("Continue")',
    'button:has-text("Next")',
    'input[type="submit"]',
  ];

  const submitted = await tryClickSubmit(page, submitSelectors);
  if (!submitted) {
    console.log('No submit button found, trying Enter key...');
    await page.keyboard.press('Enter');
  }

  await page.waitForTimeout(3000);
  console.log('Current URL after submit:', page.url());

  if (!passFilled) {
    passFilled = await tryFillField(page, passwordSelectors, pass, 'Password (step 2)');
    if (passFilled) await tryClickSubmit(page, submitSelectors);
  }
}

export async function login(options = {}) {
  const { user, pass } = loadCredentials();
  const { browser, context, page } = await launchBrowser({ ...options, headed: true });

  const loginUrl = `${BASE_URL}/auth/email/sign-in?rp=%2F`;
  console.log(`Navigating to ${loginUrl}...`);
  await page.goto(loginUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(5000);

  const currentUrl = page.url();
  if (!currentUrl.includes('login') && !currentUrl.includes('auth')) {
    console.log('Already logged in! Saving state...');
    await context.storageState({ path: STATE_FILE });
    console.log(`Auth state saved to ${STATE_FILE}`);
    await browser.close();
    return;
  }

  await dismissAllModals(page);
  await debugScreenshot(page, 'login-page', { fullPage: true });
  console.log('Login page screenshot saved');

  const ariaSnap = await page.locator('body').ariaSnapshot();
  console.log('Page structure:', ariaSnap.substring(0, 2000));

  await performLoginSteps(page, user, pass);

  console.log('Waiting for login to complete...');
  await waitForLoginRedirect(page, options);

  await context.storageState({ path: STATE_FILE });
  console.log(`Auth state saved to ${STATE_FILE}`);
  await browser.close();
}

// Helper: try multiple selectors to fill a form field.
export async function tryFillField(page, selectors, value, fieldName) {
  for (const selector of selectors) {
    const el = page.locator(selector);
    const count = await el.count();
    if (count > 0) {
      console.log(`Found ${fieldName} field with selector: ${selector}${count > 1 ? ` (${count} matches)` : ''}`);
      await el.first().click();
      await page.waitForTimeout(300);
      await el.first().fill(value);
      console.log(`${fieldName} entered`);
      return true;
    }
  }
  return false;
}

// Helper: try multiple selectors to click a submit button.
export async function tryClickSubmit(page, selectors) {
  for (const selector of selectors) {
    const el = page.locator(selector).filter({ hasNotText: /google|apple|discord/i });
    const count = await el.count();
    if (count > 0) {
      console.log(`Clicking submit button: ${selector}`);
      await el.first().click();
      return true;
    }
  }
  return false;
}

// Helper: check if URL is not an auth/login URL.
export function isNonAuthUrl(url) {
  const u = url.toString();
  return !u.includes('/auth/') && !u.includes('/login');
}
