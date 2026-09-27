// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Exact registered-secret redaction for tool output (GH#32362).
 *
 * Pattern scrubbing only recognises known token prefixes and sensitive
 * assignments. A credential injected by aidevops can still reach the model as a
 * bare value, for example inside a provider command line shown by `ps`. This
 * module redacts exact values known to aidevops without writing new plaintext:
 *
 * 1. Plaintext values that are already present locally: `export NAME=value`
 *    lines in aidevops credential files, and plugin-process environment values
 *    whose names are registered there or look sensitive.
 * 2. Keyed HMAC digests written by `secret-helper.sh run` for values it injects
 *    into child processes (including gopass-only values). Candidate windows are
 *    aligned to token boundaries, so the plugin never needs the plaintext.
 *    Limitation: a digest-only value glued to other token characters without a
 *    delimiter is not matched; plaintext-known values match anywhere.
 *
 * Values are matched longest-first. Nothing here logs or returns a value.
 */

import { createHmac } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const SECRET_VALUE_REDACTION_TOKEN = "[redacted-credential]";
export const MIN_SECRET_VALUE_LENGTH = 8;
const MAX_DIGEST_ENTRIES = 4096;
// Keyed-hash budget per redaction call for inner (`/`, `=`) windows. Beyond it,
// only whole token runs are checked so pathological output cannot stall every
// tool call (~50ms of HMAC work on typical hardware).
const MAX_DIGEST_EVALUATIONS = 20000;
const MAX_SECRET_VALUE_LENGTH = 4096;
const DIGEST_LINE = /^([0-9]{1,4}) ([0-9a-f]{64})$/;
const EXPORT_LINE = /^export[ \t]+([A-Z_][A-Z0-9_]*)=(.*)$/;
const SENSITIVE_ENV_NAME =
  /(?:^|_)(?:API_?KEY|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY|ACCESS_KEY_ID|ENCRYPTION_KEY|SIGNING_KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$/;
// Digest-registered values are limited to this token charset (API keys, hex,
// base64 and URL-safe tokens; see redaction-digest-registry.py). Candidate
// windows lie inside a maximal run of it, split only at `/` or `=`, which also
// delimit values in paths and `--flag=value` arguments. This bounds keyed
// hashing to a few candidates per run instead of every substring.
const TOKEN_RUN = /[A-Za-z0-9._~+/=-]+/g;
const INNER_BOUNDARY_CHARS = new Set(["/", "="]);
const PLACEHOLDERS = new Set(["", "***", "[redacted]", "[redacted-credential]", "<redacted>", "not set", "(not set)", "none", "null", "undefined", "missing", "changeme"]);

function unquoteExportValue(raw) {
  let value = raw.trim();
  if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.endsWith(value[0])) {
    value = value.slice(1, -1);
  }
  return value;
}

function usableValue(value) {
  return typeof value === "string"
    && value.length >= MIN_SECRET_VALUE_LENGTH
    && value.length <= MAX_SECRET_VALUE_LENGTH
    && !value.includes("\n")
    && !PLACEHOLDERS.has(value.toLowerCase())
    && !value.includes(SECRET_VALUE_REDACTION_TOKEN);
}

function fileSignature(path) {
  try {
    const stat = statSync(path);
    return stat.isFile() ? `${stat.mtimeMs}:${stat.size}` : "";
  } catch {
    return "";
  }
}

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

/** Mirror secret-helper.sh resolve_credential_files(). */
export function resolveCredentialFiles(configDir) {
  const primary = join(configDir, "credentials.sh");
  const primaryText = readText(primary);
  if (!primaryText.includes("AIDEVOPS_ACTIVE_TENANT=")) return primaryText ? [primary] : [];
  try {
    return readdirSync(join(configDir, "tenants"), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(configDir, "tenants", entry.name, "credentials.sh"))
      .filter((path) => fileSignature(path) !== "");
  } catch {
    return [];
  }
}

function parseCredentialFile(text) {
  const entries = [];
  for (const line of text.split(/\r?\n/)) {
    const match = EXPORT_LINE.exec(line);
    if (match) entries.push({ name: match[1], value: unquoteExportValue(match[2]) });
  }
  return entries;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseDigestRegistry(keyText, digestText) {
  const key = keyText.trim();
  if (!/^[0-9a-f]{64}$/.test(key)) return null;
  const byLength = new Map();
  let count = 0;
  for (const line of digestText.split("\n")) {
    const match = DIGEST_LINE.exec(line.trim());
    if (!match || count >= MAX_DIGEST_ENTRIES) continue;
    const length = Number(match[1]);
    if (length < MIN_SECRET_VALUE_LENGTH || length > MAX_SECRET_VALUE_LENGTH) continue;
    if (!byLength.has(length)) byLength.set(length, new Set());
    byLength.get(length).add(match[2]);
    count++;
  }
  if (count === 0) return null;
  return {
    key: Buffer.from(key, "hex"),
    // Longest-first so a longer registered value wins over its own prefix.
    lengths: [...byLength.keys()].sort((a, b) => b - a),
    byLength,
  };
}

/** Candidate [start, end) windows inside one token-charset run. */
function runBoundaries(runStart, run) {
  const starts = [runStart];
  const ends = new Set([runStart + run.length]);
  for (let i = 0; i < run.length; i++) {
    if (!INNER_BOUNDARY_CHARS.has(run[i])) continue;
    starts.push(runStart + i + 1);
    ends.add(runStart + i);
  }
  return { starts, ends };
}

function isRegisteredWindow(window, registry, scan) {
  const cached = scan.memo.get(window);
  if (cached !== undefined) return cached;
  scan.evaluations++;
  const digest = createHmac("sha256", registry.key).update(window, "utf8").digest("hex");
  const registered = registry.byLength.get(window.length)?.has(digest) === true;
  scan.memo.set(window, registered);
  return registered;
}

function matchRun(runStart, run, registry, ranges, scan) {
  // A whole run is the common argv shape (`--auth VALUE`, `user:VALUE@host`)
  // and is always checked, even after the inner-window budget is spent.
  if (registry.byLength.has(run.length) && isRegisteredWindow(run, registry, scan)) {
    ranges.push([runStart, runStart + run.length]);
    return;
  }
  const { starts, ends } = runBoundaries(runStart, run);
  let coveredUntil = runStart;
  for (const start of starts) {
    if (scan.evaluations >= MAX_DIGEST_EVALUATIONS) break;
    if (start < coveredUntil) continue;
    for (const length of registry.lengths) {
      const end = start + length;
      if (!ends.has(end)) continue;
      if (!isRegisteredWindow(run.slice(start - runStart, end - runStart), registry, scan)) continue;
      ranges.push([start, end]);
      coveredUntil = end;
      break;
    }
  }
}

function redactDigestMatches(text, registry) {
  if (!registry || text.length < MIN_SECRET_VALUE_LENGTH) return { text, count: 0 };
  const ranges = [];
  const minLength = registry.lengths.at(-1);
  const scan = { memo: new Map(), evaluations: 0 };
  for (const match of text.matchAll(TOKEN_RUN)) {
    if (match[0].length >= minLength) matchRun(match.index, match[0], registry, ranges, scan);
  }
  if (ranges.length === 0) return { text, count: 0 };
  let result = "";
  let cursor = 0;
  for (const [start, end] of ranges) {
    result += text.slice(cursor, start) + SECRET_VALUE_REDACTION_TOKEN;
    cursor = end;
  }
  return { text: result + text.slice(cursor), count: ranges.length };
}

/**
 * Create a cached redactor. Options exist for tests; production callers use the
 * defaults (HOME-based aidevops paths and the plugin process environment).
 */
export function createSecretValueRedactor(options = {}) {
  const home = options.home || homedir();
  const configDir = options.configDir || join(home, ".config", "aidevops");
  const registryDir = options.registryDir
    || process.env.AIDEVOPS_SECRET_REDACTION_DIR
    || join(home, ".aidevops", ".agent-workspace", "secret-redaction");
  const env = options.env || process.env;
  let fileCacheKey = null;
  let fileEntries = [];
  let registryCacheKey = null;
  let registry = null;
  let plaintextKey = null;
  let plaintextPattern = null;

  function loadFileEntries() {
    const files = resolveCredentialFiles(configDir);
    const key = files.map((path) => `${path}:${fileSignature(path)}`).join("|");
    if (key !== fileCacheKey) {
      fileCacheKey = key;
      fileEntries = files.flatMap((path) => parseCredentialFile(readText(path)));
    }
    return fileEntries;
  }

  function loadRegistry() {
    const keyPath = join(registryDir, "key");
    const digestPath = join(registryDir, "digests");
    const key = `${fileSignature(keyPath)}|${fileSignature(digestPath)}`;
    if (key !== registryCacheKey) {
      registryCacheKey = key;
      registry = parseDigestRegistry(readText(keyPath), readText(digestPath));
    }
    return registry;
  }

  function loadPlaintextPattern() {
    const entries = loadFileEntries();
    const registeredNames = new Set(entries.map((entry) => entry.name));
    const values = new Set(entries.map((entry) => entry.value).filter(usableValue));
    for (const [name, value] of Object.entries(env)) {
      if ((registeredNames.has(name) || SENSITIVE_ENV_NAME.test(name)) && usableValue(value)) values.add(value);
    }
    const sorted = [...values].sort((a, b) => b.length - a.length || (a < b ? -1 : 1));
    const key = sorted.join("\0");
    if (key !== plaintextKey) {
      plaintextKey = key;
      plaintextPattern = sorted.length > 0 ? new RegExp(sorted.map(escapeRegExp).join("|"), "g") : null;
    }
    return plaintextPattern;
  }

  /** Redact registered secret values from one string. */
  function redactText(text) {
    if (typeof text !== "string" || text.length < MIN_SECRET_VALUE_LENGTH) return { text, count: 0 };
    let count = 0;
    let result = text;
    const pattern = loadPlaintextPattern();
    if (pattern) {
      result = result.replace(pattern, () => {
        count++;
        return SECRET_VALUE_REDACTION_TOKEN;
      });
    }
    const digestResult = redactDigestMatches(result, loadRegistry());
    return { text: digestResult.text, count: count + digestResult.count };
  }

  /** Redact registered values from any JSON-serialisable value. */
  function redactValue(value) {
    if (typeof value === "string") {
      const { text, count } = redactText(value);
      return { value: text, count };
    }
    if (Array.isArray(value)) {
      let count = 0;
      const next = value.map((item) => {
        const scrubbed = redactValue(item);
        count += scrubbed.count;
        return scrubbed.value;
      });
      return count > 0 ? { value: next, count } : { value, count: 0 };
    }
    if (value !== null && typeof value === "object" && !Buffer.isBuffer(value)) {
      let count = 0;
      const next = {};
      for (const [key, nested] of Object.entries(value)) {
        const scrubbed = redactValue(nested);
        count += scrubbed.count;
        next[key] = scrubbed.value;
      }
      return count > 0 ? { value: next, count } : { value, count: 0 };
    }
    return { value, count: 0 };
  }

  return { redactText, redactValue };
}

let defaultRedactor = null;

/** Shared process-wide redactor using the default aidevops locations. */
export function defaultSecretValueRedactor() {
  defaultRedactor ??= createSecretValueRedactor();
  return defaultRedactor;
}
