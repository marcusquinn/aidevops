// Route classification and cached route comparison, independent of browser actions.

import { existsSync, readFileSync } from 'node:fs';
import { ROUTES_CACHE } from './higgsfield-common.mjs';

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
