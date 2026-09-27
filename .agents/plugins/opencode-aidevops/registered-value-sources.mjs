// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Sources of registered credential values for exact redaction (GH#32362).
 *
 * - Plaintext values that already exist locally: `export NAME=value` lines in
 *   aidevops credential files, plus plugin-process environment values whose
 *   names are registered there or look sensitive.
 * - Keyed HMAC digests written by `redaction-digest-registry.py` when
 *   `secret-helper.sh run` injects values into a child process.
 *
 * Reads are cached by file mtime/size. Nothing here logs or returns a value to
 * callers other than the redactor.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const REDACTION_TOKEN = "[redacted-credential]";
export const MIN_VALUE_LENGTH = 8;
const MAX_VALUE_LENGTH = 4096;
const MAX_DIGEST_ENTRIES = 4096;
const DIGEST_LINE = /^([0-9]{1,4}) ([0-9a-f]{64})$/;
const DIGEST_KEY = /^[0-9a-f]{64}$/;
const EXPORT_LINE = /^export[ \t]+([A-Z_][A-Z0-9_]*)=(.*)$/;
const SENSITIVE_ENV_NAME =
  /(?:^|_)(?:API_?KEY|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY|ACCESS_KEY_ID|ENCRYPTION_KEY|SIGNING_KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$/;
const PLACEHOLDERS = new Set(["", "***", "[redacted]", REDACTION_TOKEN, "<redacted>", "not set", "(not set)", "none", "null", "undefined", "missing", "changeme"]);

const hasUsableLength = (value) => value.length >= MIN_VALUE_LENGTH && value.length <= MAX_VALUE_LENGTH;
const isPlaceholder = (value) => PLACEHOLDERS.has(value.toLowerCase()) || value.includes(REDACTION_TOKEN);

export function usableValue(value) {
  if (typeof value !== "string" || !hasUsableLength(value)) return false;
  return !value.includes("\n") && !isPlaceholder(value);
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

function unquoteExportValue(raw) {
  const value = raw.trim();
  const quote = value[0];
  const quoted = value.length >= 2 && (quote === '"' || quote === "'") && value.endsWith(quote);
  return quoted ? value.slice(1, -1) : value;
}

function tenantCredentialFiles(configDir) {
  try {
    return readdirSync(join(configDir, "tenants"), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(configDir, "tenants", entry.name, "credentials.sh"))
      .filter((path) => fileSignature(path) !== "");
  } catch {
    return [];
  }
}

/** Mirror secret-helper.sh resolve_credential_files(). */
export function resolveCredentialFiles(configDir) {
  const primary = join(configDir, "credentials.sh");
  const primaryText = readText(primary);
  if (primaryText.includes("AIDEVOPS_ACTIVE_TENANT=")) return tenantCredentialFiles(configDir);
  return primaryText ? [primary] : [];
}

function parseCredentialFile(text) {
  const entries = [];
  for (const line of text.split(/\r?\n/)) {
    const match = EXPORT_LINE.exec(line);
    if (match) entries.push({ name: match[1], value: unquoteExportValue(match[2]) });
  }
  return entries;
}

function parseDigestLines(digestText) {
  const byLength = new Map();
  let count = 0;
  for (const line of digestText.split("\n")) {
    const match = DIGEST_LINE.exec(line.trim());
    const length = match ? Number(match[1]) : 0;
    if (count >= MAX_DIGEST_ENTRIES || length < MIN_VALUE_LENGTH || length > MAX_VALUE_LENGTH) continue;
    if (!byLength.has(length)) byLength.set(length, new Set());
    byLength.get(length).add(match[2]);
    count++;
  }
  return byLength;
}

export function parseDigestRegistry(keyText, digestText) {
  const key = keyText.trim();
  if (!DIGEST_KEY.test(key)) return null;
  const byLength = parseDigestLines(digestText);
  if (byLength.size === 0) return null;
  return {
    key: Buffer.from(key, "hex"),
    // Longest-first so a longer registered value wins over its own prefix.
    lengths: [...byLength.keys()].sort((a, b) => b - a),
    byLength,
  };
}

/** Cached access to registered plaintext values and the digest registry. */
export class RegisteredValueSources {
  constructor(options = {}) {
    const home = options.home || homedir();
    this.configDir = options.configDir || join(home, ".config", "aidevops");
    this.registryDir = options.registryDir
      || process.env.AIDEVOPS_SECRET_REDACTION_DIR
      || join(home, ".aidevops", ".agent-workspace", "secret-redaction");
    this.env = options.env || process.env;
    this.fileCache = { key: null, entries: [] };
    this.registryCache = { key: null, registry: null };
  }

  credentialEntries() {
    const files = resolveCredentialFiles(this.configDir);
    const key = files.map((path) => `${path}:${fileSignature(path)}`).join("|");
    if (key !== this.fileCache.key) {
      this.fileCache = { key, entries: files.flatMap((path) => parseCredentialFile(readText(path))) };
    }
    return this.fileCache.entries;
  }

  /** Usable plaintext values, longest first. */
  plaintextValues() {
    const entries = this.credentialEntries();
    const registeredNames = new Set(entries.map((entry) => entry.name));
    const values = new Set(entries.map((entry) => entry.value).filter(usableValue));
    for (const [name, value] of Object.entries(this.env)) {
      const namedSecret = registeredNames.has(name) || SENSITIVE_ENV_NAME.test(name);
      if (namedSecret && usableValue(value)) values.add(value);
    }
    return [...values].sort((a, b) => b.length - a.length || (a < b ? -1 : 1));
  }

  digestRegistry() {
    const keyPath = join(this.registryDir, "key");
    const digestPath = join(this.registryDir, "digests");
    const key = `${fileSignature(keyPath)}|${fileSignature(digestPath)}`;
    if (key !== this.registryCache.key) {
      this.registryCache = { key, registry: parseDigestRegistry(readText(keyPath), readText(digestPath)) };
    }
    return this.registryCache.registry;
  }
}
