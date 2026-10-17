// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// Shared secret resolver for Node callers (GH#34892); shell twin: secret-resolver.sh.
// Lookup order: environment → credential files → gopass `aidevops/NAME`.
// Credential files are parsed as text (never executed). In tenant-loader mode
// the active tenant's credentials.sh wins, then the loader's own exports.
// Values are returned, never logged; gopass stderr is discarded.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const TENANT_RE = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
const GOPASS_TIMEOUT_MS = 10_000;

function readText(file) {
  try {
    return existsSync(file) ? readFileSync(file, 'utf-8') : '';
  } catch {
    return '';
  }
}

function activeTenant(configDir, loaderText) {
  const marker = loaderText.match(/^(?:export\s+)?AIDEVOPS_ACTIVE_TENANT="?([A-Za-z0-9][A-Za-z0-9_-]*)"?\s*$/m)?.[1];
  if (marker) return marker;
  const fromFile = readText(join(configDir, 'active-tenant')).trim();
  return TENANT_RE.test(fromFile) ? fromFile : 'default';
}

function credentialTexts(home) {
  const configDir = join(home, '.config', 'aidevops');
  const loaderText = readText(join(configDir, 'credentials.sh'));
  if (!/^(?:export\s+)?AIDEVOPS_ACTIVE_TENANT=/m.test(loaderText)) return [loaderText];
  const tenant = activeTenant(configDir, loaderText);
  return [readText(join(configDir, 'tenants', tenant, 'credentials.sh')), loaderText];
}

// Parse `[export] NAME=value` (double-quoted, single-quoted or bare word) the
// way bash assigns it; last assignment wins. Unterminated quotes are skipped.
function parseAssignment(text, name) {
  const lineRe = new RegExp(`^[ \\t]*(?:export[ \\t]+)?${name}=(.*)$`, 'gm');
  let value = '';
  for (const match of text.matchAll(lineRe)) {
    const raw = match[1];
    let parsed;
    if (raw.startsWith('"')) {
      parsed = raw.match(/^"((?:[^"\\]|\\.)*)"/)?.[1]?.replace(/\\(["\\$`])/g, '$1');
    } else if (raw.startsWith("'")) {
      parsed = raw.match(/^'([^']*)'/)?.[1];
    } else {
      // A bare word ends at unescaped whitespace or `;`; `#` mid-word is literal.
      parsed = raw.match(/^((?:[^\s;\\]|\\.)*)/)?.[1]?.replace(/\\(.)/g, '$1');
    }
    if (parsed !== undefined) value = parsed;
  }
  return value;
}

export function credentialFileSecret(name, { home = homedir() } = {}) {
  if (!NAME_RE.test(name)) return '';
  for (const text of credentialTexts(home)) {
    const value = text ? parseAssignment(text, name) : '';
    if (value) return value;
  }
  return '';
}

export function gopassSecret(name, { timeoutMs = GOPASS_TIMEOUT_MS } = {}) {
  if (!NAME_RE.test(name)) return '';
  try {
    const out = execFileSync('gopass', ['show', '-o', `aidevops/${name}`], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: timeoutMs,
    });
    return out.replace(/\r?\n$/, '');
  } catch {
    return '';
  }
}

export function resolveSecret(name, { env = process.env, home = homedir(), timeoutMs } = {}) {
  if (!NAME_RE.test(name)) return '';
  return env[name] || credentialFileSecret(name, { home }) || gopassSecret(name, { timeoutMs });
}
