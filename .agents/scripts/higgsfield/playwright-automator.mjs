#!/usr/bin/env node
// Higgsfield UI Automator - CLI entry point
// Uses the Higgsfield web UI to generate images/videos using subscription credits
// Part of AI DevOps Framework
//
// This file is the thin CLI dispatcher. All implementation is in focused modules:
//   higgsfield-common.mjs        — constants, utilities, credit guard, CLI parsing
//   higgsfield-browser.mjs       — browser launch, navigation, modal dismissal
//   higgsfield-output.mjs        — output dirs, sidecars, dedup, image downloads
//   higgsfield-discovery.mjs     — site discovery, login
//   higgsfield-api.mjs           — Higgsfield Cloud API client
//   higgsfield-image.mjs         — image generation (Playwright)
//   higgsfield-video.mjs         — video generation, download (Playwright)
//   higgsfield-lipsync.mjs       — lipsync generation (Playwright)
//   higgsfield-commands.mjs      — misc UI commands (credits, apps, studio tools)
//   higgsfield-asset-chain.mjs   — asset chain operations
//   higgsfield-pipeline.mjs      — video production pipeline
//   higgsfield-batch-video.mjs   — batch video/lipsync, download from history
//   higgsfield-tests.mjs         — auth health check, smoke test, self-tests

import {
  parseArgs,
  checkCreditGuard,
  withRetry,
} from './higgsfield-common.mjs';

import {
  ensureDiscovery,
  login,
  runDiscovery,
} from './higgsfield-discovery.mjs';

import { generateImage, batchImage } from './higgsfield-image.mjs';
import { generateVideo } from './higgsfield-video.mjs';
import { generateLipsync } from './higgsfield-lipsync.mjs';
import {
  batchVideo,
  batchLipsync,
  downloadFromHistory,
} from './higgsfield-batch-video.mjs';
import { apiGenerateImage, apiGenerateVideo, apiStatus } from './higgsfield-api.mjs';
import { pipeline } from './higgsfield-pipeline.mjs';
import { assetChain } from './higgsfield-asset-chain.mjs';
import { authHealthCheck, smokeTest, runSelfTests } from './higgsfield-tests.mjs';
import {
  seedBracket,
  useApp,
  screenshot,
  checkCredits,
  listAssets,
  manageAssets,
  mixedMediaPreset,
  motionPreset,
  cinemaStudio,
  motionControl,
  editImage,
  upscale,
  editVideo,
  storyboard,
  vibeMotion,
  aiInfluencer,
  createCharacter,
  featurePage,
} from './higgsfield-commands.mjs';

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

// Factory: creates a command handler that sets a feature slug then delegates to featurePage.
function makeFeatureHandler(feature) {
  return (opts, r) => { opts.feature = feature; return withRetry(() => featurePage(opts), r); };
}

// Command registry: maps CLI command names to handler functions.
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
  'fashion-factory':    makeFeatureHandler('fashion-factory'),
  'ugc-factory':        makeFeatureHandler('ugc-factory'),
  'photodump':          makeFeatureHandler('photodump'),
  'camera-controls':    makeFeatureHandler('camera-controls'),
  'effects':            makeFeatureHandler('effects'),
  'batch-image':        (opts) => batchImage(opts),
  'batch-video':        (opts) => batchVideo(opts),
  'batch-lipsync':      (opts) => batchLipsync(opts),
  'test':               () => runSelfTests(),
  'self-test':          () => runSelfTests(),
};

// Print CLI usage text.
function printUsage() {
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
  download           Download latest generation (default: 4 most recent, use --count 0 for all)
  batch-image        Batch image generation from manifest JSON
  batch-video        Batch video generation from manifest JSON
  batch-lipsync      Batch lipsync generation from manifest JSON
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
  --count, -c        Number of images to download (default: 4, use 0 for all)
  --concurrency, -C  Max concurrent jobs for batch operations (default varies by command)
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
  node playwright-automator.mjs seed-bracket -p "Elegant woman, golden hour" --seed-range 1000-1010
  node playwright-automator.mjs app --effect face-swap --image-file face.jpg
  node playwright-automator.mjs credits
  node playwright-automator.mjs download --count 4
  node playwright-automator.mjs cinema-studio -p "Epic landscape" --tab image --camera "Dolly Zoom"
  node playwright-automator.mjs motion-control --video-file dance.mp4 --image-file character.jpg
  node playwright-automator.mjs edit -p "Replace background with beach" --image-file photo.jpg -m soul_inpaint
  node playwright-automator.mjs upscale --image-file low-res.jpg
  node playwright-automator.mjs manage-assets --asset-action list --filter video
  node playwright-automator.mjs chain --chain-action animate --asset-index 0
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
}

// Run site discovery unless the command does not need it.
async function runDiscoveryIfNeeded(command, options) {
  const skipDiscoveryCommands = new Set(['login', 'discover', 'health-check', 'health', 'smoke-test', 'smoke', 'api-status']);
  if (!skipDiscoveryCommands.has(command)) {
    await ensureDiscovery(options);
  }
}

// Enforce credit guard; exits process if credits are critically low.
function guardCredits(command, options) {
  if (options.force) return;
  try {
    checkCreditGuard(command, options);
  } catch (e) {
    if (e.message.includes('CREDIT_GUARD')) {
      console.error(e.message);
      process.exit(1);
    }
  }
}

// Build retry configuration objects from parsed options.
function buildRetryConfig(command, options) {
  const retryOpts = { maxRetries: options.noRetry ? 0 : 2, baseDelay: 3000, label: command };
  const retryOnce = { ...retryOpts, maxRetries: options.noRetry ? 0 : 1 };
  return { retryOpts, retryOnce };
}

async function main() {
  const { command, options } = parseArgs();

  if (!command) {
    printUsage();
    return;
  }

  await runDiscoveryIfNeeded(command, options);
  guardCredits(command, options);

  const { retryOpts, retryOnce } = buildRetryConfig(command, options);

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
