// Output organisation, naming, sidecars and deduplication, separate from downloads.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { ensureDir, safeJoin, sanitizePathSegment } from './higgsfield-common.mjs';

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
