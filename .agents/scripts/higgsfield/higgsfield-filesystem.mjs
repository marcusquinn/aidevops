// Filesystem paths, file selection and curl downloads for Higgsfield assets.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { basename, extname } from 'node:path';

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
