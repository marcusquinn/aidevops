// Shared constants for chromium-debug-use modules.

import { mkdirSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';

export const TIMEOUT_MS = 15000;
export const NAVIGATION_TIMEOUT_MS = 30000;
export const IDLE_TIMEOUT_MS = 20 * 60 * 1000;
export const DAEMON_CONNECT_RETRIES = 20;
export const DAEMON_CONNECT_DELAY_MS = 300;
export const MIN_TARGET_PREFIX_LEN = 8;
export const IS_WINDOWS = process.platform === 'win32';

if (!IS_WINDOWS) process.umask(0o077);

export const RUNTIME_DIR = resolve(homedir(), '.aidevops', 'chromium-debug-use');
export const CACHE_DIR = resolve(RUNTIME_DIR, 'runtime');
export const PAGES_CACHE = resolve(CACHE_DIR, 'pages.json');

try {
  mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });
} catch {
  // ignored
}

export function socketPath(targetId) {
  if (IS_WINDOWS) {
    return `\\\\.\\pipe\\chromium-debug-use-${targetId}`;
  }
  return resolve(CACHE_DIR, `chromium-debug-use-${targetId}.sock`);
}

export function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

export function resolvePrefix(prefix, candidates, noun = 'target', missingHint = '') {
  const upperPrefix = prefix.toUpperCase();
  const matches = candidates.filter((candidate) => candidate.toUpperCase().startsWith(upperPrefix));

  if (matches.length === 0) {
    const hint = missingHint ? ` ${missingHint}` : '';
    throw new Error(`No ${noun} matching prefix "${prefix}".${hint}`);
  }

  if (matches.length > 1) {
    throw new Error(`Ambiguous prefix "${prefix}" — matches ${matches.length} ${noun}s. Use more characters.`);
  }

  return matches[0];
}

export function cleanupStaleSocket(socket) {
  if (!IS_WINDOWS) {
    try {
      unlinkSync(socket);
    } catch {
      // ignored
    }
  }
}
