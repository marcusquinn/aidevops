// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Exact registered-secret redaction for tool output (GH#32362).
 *
 * Pattern scrubbing only recognises known token prefixes and sensitive
 * assignments. A credential injected by aidevops can still reach the model as a
 * bare value, for example inside a provider command line shown by `ps`. This
 * module redacts exact values known to aidevops (see registered-value-sources)
 * without writing new plaintext:
 *
 * - Plaintext-known values match anywhere, longest-first.
 * - Digest-only values (injected by `secret-helper.sh run`, including gopass
 *   values) match as keyed-HMAC windows aligned to token boundaries, so the
 *   plugin never needs the plaintext. Limitation: a digest-only value glued to
 *   other token characters without a delimiter is not matched.
 *
 * Nothing here logs or returns a value.
 */

import { createHmac } from "node:crypto";

import {
  MIN_VALUE_LENGTH,
  REDACTION_TOKEN,
  RegisteredValueSources,
} from "./registered-value-sources.mjs";

export const SECRET_VALUE_REDACTION_TOKEN = REDACTION_TOKEN;
export const MIN_SECRET_VALUE_LENGTH = MIN_VALUE_LENGTH;

// Digest-registered values are limited to this token charset (API keys, hex,
// base64 and URL-safe tokens; mirrored by redaction-digest-registry.py).
// Candidate windows lie inside a maximal run of it, split only at `/` or `=`,
// which also delimit values in paths and `--flag=value` arguments. This bounds
// keyed hashing to a few candidates per run instead of every substring.
const TOKEN_RUN = /[A-Za-z0-9._~+/=-]+/g;
const INNER_BOUNDARY_CHARS = new Set(["/", "="]);
// Keyed-hash budget per redaction call for inner windows. Beyond it, only whole
// token runs are checked so pathological output cannot stall every tool call.
const MAX_DIGEST_EVALUATIONS = 20000;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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

/** Longest registered window starting at `start`, or 0. */
function registeredLengthAt(start, runStart, run, ends, context) {
  const { registry, scan } = context;
  for (const length of registry.lengths) {
    if (!ends.has(start + length)) continue;
    const window = run.slice(start - runStart, start - runStart + length);
    if (isRegisteredWindow(window, registry, scan)) return length;
  }
  return 0;
}

function matchRun(runStart, run, context) {
  const { registry, scan, ranges } = context;
  // A whole run is the common argv shape (`--auth VALUE`, `user:VALUE@host`)
  // and is always checked, even after the inner-window budget is spent.
  if (registry.byLength.has(run.length) && isRegisteredWindow(run, registry, scan)) {
    ranges.push([runStart, runStart + run.length]);
    return;
  }
  const { starts, ends } = runBoundaries(runStart, run);
  let coveredUntil = runStart;
  for (const start of starts) {
    if (scan.evaluations >= MAX_DIGEST_EVALUATIONS) return;
    if (start < coveredUntil) continue;
    const length = registeredLengthAt(start, runStart, run, ends, context);
    if (length === 0) continue;
    ranges.push([start, start + length]);
    coveredUntil = start + length;
  }
}

function replaceRanges(text, ranges) {
  let result = "";
  let cursor = 0;
  for (const [start, end] of ranges) {
    result += text.slice(cursor, start) + REDACTION_TOKEN;
    cursor = end;
  }
  return result + text.slice(cursor);
}

function redactDigestMatches(text, registry) {
  if (!registry) return { text, count: 0 };
  const context = { registry, scan: { memo: new Map(), evaluations: 0 }, ranges: [] };
  const minLength = registry.lengths.at(-1);
  for (const match of text.matchAll(TOKEN_RUN)) {
    if (match[0].length >= minLength) matchRun(match.index, match[0], context);
  }
  return { text: replaceRanges(text, context.ranges), count: context.ranges.length };
}

function redactPlaintext(text, pattern) {
  if (!pattern) return { text, count: 0 };
  let count = 0;
  const redacted = text.replace(pattern, () => {
    count++;
    return REDACTION_TOKEN;
  });
  return { text: redacted, count };
}

function redactEntries(entries, redactValue) {
  let count = 0;
  const next = entries.map(([key, nested]) => {
    const scrubbed = redactValue(nested);
    count += scrubbed.count;
    return [key, scrubbed.value];
  });
  return { next, count };
}

/** Redact registered values from any JSON-serialisable value. */
function redactStructured(value, redactText) {
  const recurse = (nested) => redactStructured(nested, redactText);
  if (typeof value === "string") {
    const { text, count } = redactText(value);
    return { value: text, count };
  }
  if (value === null || typeof value !== "object" || Buffer.isBuffer(value)) return { value, count: 0 };
  const isArray = Array.isArray(value);
  const { next, count } = redactEntries(isArray ? value.map((item, index) => [index, item]) : Object.entries(value), recurse);
  if (count === 0) return { value, count: 0 };
  return { value: isArray ? next.map(([, item]) => item) : Object.fromEntries(next), count };
}

/**
 * Create a cached redactor. Options exist for tests; production callers use the
 * defaults (HOME-based aidevops paths and the plugin process environment).
 */
export function createSecretValueRedactor(options = {}) {
  const sources = new RegisteredValueSources(options);
  const plaintext = { key: null, pattern: null };

  function plaintextPattern() {
    const values = sources.plaintextValues();
    const key = values.join("\0");
    if (key !== plaintext.key) {
      plaintext.key = key;
      plaintext.pattern = values.length > 0 ? new RegExp(values.map(escapeRegExp).join("|"), "g") : null;
    }
    return plaintext.pattern;
  }

  function redactText(text) {
    if (typeof text !== "string" || text.length < MIN_VALUE_LENGTH) return { text, count: 0 };
    const known = redactPlaintext(text, plaintextPattern());
    const digest = redactDigestMatches(known.text, sources.digestRegistry());
    return { text: digest.text, count: known.count + digest.count };
  }

  return { redactText, redactValue: (value) => redactStructured(value, redactText) };
}

let defaultRedactor = null;

/** Shared process-wide redactor using the default aidevops locations. */
export function defaultSecretValueRedactor() {
  defaultRedactor ??= createSecretValueRedactor();
  return defaultRedactor;
}
