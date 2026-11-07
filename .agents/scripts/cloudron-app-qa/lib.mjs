// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Shared helpers for cloudron-app-qa-helper.sh browser/OAuth modules:
// output redaction, PASS/FAIL reporting and Playwright profile launch.

import { chmodSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { loadPlaywright, resolvePlaywrightBrowserExecutable } from '../playwright-runtime.mjs';

let failures = 0;

/** Redact one-time tokens, setup links and long opaque strings from text. */
export function redact(input) {
  return String(input ?? '')
    .replace(/([?&#](?:token|code|state|access_token|refresh_token)=)[^&\s"'<>]+/gi, '$1[redacted]')
    .replace(/(\/(?:setup|recovery|invite|join|reset)[^\s"'<>?]*)/gi, (m) => m.split('/').slice(0, 2).join('/') + '/[redacted]')
    .replace(/[A-Za-z0-9_\-.~+/=]{32,}/g, '[redacted]');
}

export function pass(message) {
  console.log(`PASS: ${redact(message)}`);
}

export function fail(message) {
  failures += 1;
  console.log(`FAIL: ${redact(message)}`);
}

export function info(message) {
  console.log(`INFO: ${redact(message)}`);
}

export function failureCount() {
  return failures;
}

/** Print only redacted messages for uncaught errors, then exit non-zero. */
export function installErrorHandlers() {
  const handler = (error) => {
    console.log(`FAIL: uncaught error: ${redact(error && error.message ? error.message : error)}`);
    process.exit(1);
  };
  process.on('uncaughtException', handler);
  process.on('unhandledRejection', handler);
}

/** Parse `--key value` / `--flag` argv into an object. */
export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const eq = arg.indexOf('=');
    if (eq > 2) {
      out[arg.slice(2, eq)] = arg.slice(eq + 1);
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

/** Launch a persistent Chromium profile (mode 0700) with optional host pinning. */
export async function launchProfile(profileDir, { resolve, headless = true } = {}) {
  const runtime = await loadPlaywright();
  mkdirSync(profileDir, { recursive: true, mode: 0o700 });
  chmodSync(profileDir, 0o700);
  const args = [];
  if (resolve) {
    // resolve: "host=ip" -> --host-resolver-rules for subdomains local DNS lacks.
    const text = String(resolve);
    const eq = text.indexOf('=');
    const host = eq > 0 ? text.slice(0, eq) : '';
    const ip = eq > 0 ? text.slice(eq + 1) : '';
    if (/^[A-Za-z0-9.*-]+$/.test(host) && /^[0-9A-Fa-f:.]+$/.test(ip)) args.push(`--host-resolver-rules=MAP ${host} ${ip}`);
  }
  const executablePath = resolvePlaywrightBrowserExecutable(runtime) || undefined;
  return runtime.chromium.launchPersistentContext(profileDir, { headless, executablePath, args });
}

export function profilePath(scratch, name) {
  return join(scratch, `profile-${name}`);
}

export async function loadAdapter(path) {
  if (!path) return null;
  const { pathToFileURL } = await import('node:url');
  const { resolve } = await import('node:path');
  return import(pathToFileURL(resolve(path)).href);
}
