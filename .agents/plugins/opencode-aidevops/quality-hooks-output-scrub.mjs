// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Credential transcript scrubbing shared by OpenCode post-tool hooks. */

import { parseStructuredText } from "./structured-text-parser.mjs";

const CREDENTIAL_PATTERN =
  /(^|[^A-Za-z0-9_-])(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const NAMED_CREDENTIAL_ASSIGNMENT_PATTERN =
  /(^|[^A-Za-z0-9_])((?:"[A-Za-z_][A-Za-z0-9_. -]*"|'[A-Za-z_][A-Za-z0-9_. -]*'|(?:API[ \t]+KEY|PRIVATE[ \t]+KEY|SECRET[ \t]+KEY|ACCESS[ \t]+TOKEN|AUTH[ \t]+TOKEN|CLIENT[ \t]+SECRET|USER[ \t]+PASSWORD)|[A-Za-z_][A-Za-z0-9_.-]*))(\s*(?:=|:)\s*)(\$\{[A-Za-z_][A-Za-z0-9_]*(?::?[-?=+])?\}|"(?:\\.|[^"\\])*"[^\r\n\s,}\])&;|<>]*|'(?:\\.|[^'\\])*'[^\r\n\s,}\])&;|<>]*|\[[^\r\n\s,};&|<>]*\][^\r\n\s,}\])&;|<>]*|<[^>\r\n]*>[^\r\n\s,}\])&;|<>]*|\([^()\r\n]*\)[^\r\n\s,}\])&;|<>]*|not[ \t]+set(?=$|[\s,}\])&;|<>])|[^\s,}\])&;|<>]+)/gim;
// scheme://user:password@host (any scheme); captures through the ":" before the password.
const URL_USERINFO_PATTERN = /\b([A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s:@/"'<>\\]+:)([^\s@/"'<>\\]+)(?=@)/g;
// {"name":"X_PASSWORD","value":"secret"} where the secret name is a sibling field.
const NAME_VALUE_PAIR_PATTERN =
  /(\\?"(?:name|key|variable)\\?"\s*:\s*\\?"([^"\\]*)\\?"\s*,\s*\\?"value\\?"\s*:\s*\\?")([^"\\]+)(?=\\?")/gi;
// JSON records embedded in plain text with escaped quotes (not standalone JSON).
const ESCAPED_CREDENTIAL_ASSIGNMENT_PATTERN =
  /(\\"([A-Za-z_][A-Za-z0-9_. -]*)\\"\s*[:=]\s*\\")((?:[^"\\]|\\\\(?:\\.|[^\\])|\\[^"\\])*)(?=\\")/gi;
const ESCAPED_NON_STRING_ASSIGNMENT_PATTERN =
  /\\"([A-Za-z_][A-Za-z0-9_. -]*)\\"\s*[:=]\s*(?=[\[{\d-]|true\b|false\b|null\b)/gi;
const ESCAPED_STRING_PATTERN = /\\"(?:[^"\\]|\\\\(?:\\.|[^\\])|\\[^"\\])*\\"/y;
const PEM_BEGIN_MARKER = "-----BEGIN ";
const PEM_KEY_SUFFIX = "PRIVATE KEY-----";
const PEM_LABEL_PATTERN = /^[A-Z0-9 ]*$/;
const PLACEHOLDER_VALUES = new Set([
  "",
  "***",
  "[redacted]",
  "[redacted-credential]",
  "[redacted-private-key]",
  "(not set)",
  "<redacted>",
  "missing",
  "none",
  "not set",
  "null",
  "undefined",
]);

export const REDACTION_TOKEN = "[redacted-credential]";
export const PEM_REDACTION_TOKEN = "[redacted-private-key]";
const IDENTIFIER_FIELD_NAMES = new Set(["KEY", "NAME", "VARIABLE"]);
const VALUE_FIELD_NAMES = new Set(["VALUE"]);

function scrubPrivateKeys(text) {
  const chunks = [];
  let cursor = 0;
  let count = 0;
  while (cursor < text.length) {
    const start = text.indexOf(PEM_BEGIN_MARKER, cursor);
    if (start < 0) break;
    const labelStart = start + PEM_BEGIN_MARKER.length;
    const suffixStart = text.indexOf(PEM_KEY_SUFFIX, labelStart);
    if (suffixStart < 0) break;
    const label = text.slice(labelStart, suffixStart);
    const headerEnd = suffixStart + PEM_KEY_SUFFIX.length;
    if (!PEM_LABEL_PATTERN.test(label)) {
      chunks.push(text.slice(cursor, labelStart));
      cursor = labelStart;
      continue;
    }
    const endMarker = `-----END ${label}${PEM_KEY_SUFFIX}`;
    const nextStart = text.indexOf(PEM_BEGIN_MARKER, headerEnd);
    const segmentEnd = nextStart < 0 ? text.length : nextStart;
    const relativeEnd = text.slice(headerEnd, segmentEnd).indexOf(endMarker);
    if (relativeEnd < 0) {
      chunks.push(text.slice(cursor, headerEnd));
      cursor = headerEnd;
      continue;
    }
    const end = headerEnd + relativeEnd;
    chunks.push(text.slice(cursor, start), PEM_REDACTION_TOKEN);
    cursor = end + endMarker.length;
    count++;
  }
  chunks.push(text.slice(cursor));
  return { scrubbed: chunks.join(""), count };
}

function unquote(value) {
  const trimmed = String(value).trim();
  const quote = trimmed.at(0);
  if ((quote === '"' || quote === "'") && trimmed.endsWith(quote)) return trimmed.slice(1, -1);
  return trimmed;
}

function normalizeFieldName(name) {
  return unquote(name)
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[-.\s]+/g, "_")
    .toUpperCase();
}

function isSensitiveFieldName(name) {
  return /(?:^|_)(?:API_?KEY|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY|ACCESS_KEY_ID|ENCRYPTION_KEY|SIGNING_KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$/.test(
    normalizeFieldName(name),
  );
}

// Shell references with no literal default (`$VAR`, `${VAR}`, `${VAR:-}`) carry no secret.
const SHELL_REFERENCE_PATTERN = /^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*(?::?[-?=+])?\})$/;

function isPlaceholderValue(value) {
  const bare = unquote(value);
  return PLACEHOLDER_VALUES.has(bare.toLowerCase()) || SHELL_REFERENCE_PATTERN.test(bare);
}

function preservesSensitiveValue(value) {
  return value == null || (typeof value === "string" && isPlaceholderValue(value));
}

function isIdentifierFieldName(name) {
  return IDENTIFIER_FIELD_NAMES.has(normalizeFieldName(name));
}

function isValueFieldName(name) {
  return VALUE_FIELD_NAMES.has(normalizeFieldName(name));
}

function redactAssignedValue(value) {
  if (isPlaceholderValue(value)) return value;
  const quote = value.at(0);
  if ((quote === '"' || quote === "'") && value.endsWith(quote)) {
    return `${quote}${REDACTION_TOKEN}${quote}`;
  }
  if (quote === "(" && value.endsWith(")")) return `(${REDACTION_TOKEN})`;
  return REDACTION_TOKEN;
}

/** Redact the last capture group per match; `named` also gates on a sensitive field name (group 2). */
function redactGroupValues(pattern, text, named) {
  let count = 0;
  const replaced = text.replace(pattern, (match, ...groups) => {
    const skip = isPlaceholderValue(groups[named ? 2 : 1]) || (named && !isSensitiveFieldName(groups[1]));
    count += skip ? 0 : 1;
    return skip ? match : `${groups[0]}${REDACTION_TOKEN}`;
  });
  return { text: replaced, count };
}

// Locate a complete escaped JSON container without stopping at commas or brackets inside strings.
function escapedNonStringValueEnd(text, start, cache) {
  if (cache.has(start)) return cache.get(start);
  const scalar = /^(?:-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)(?=$|[\s,}\]])/.exec(text.slice(start));
  if (scalar) return start + scalar[0].length;
  const stack = [];
  for (let cursor = start; cursor < text.length; cursor++) {
    ESCAPED_STRING_PATTERN.lastIndex = cursor;
    const quoted = ESCAPED_STRING_PATTERN.exec(text);
    if (quoted) {
      cursor += quoted[0].length - 1;
      continue;
    }
    const char = text[cursor];
    if (char === "[" || char === "{") stack.push(cursor);
    else if (char === "]" || char === "}") {
      const opening = stack.at(-1);
      if (opening === undefined || (text[opening] === "[" ? "]" : "}") !== char) break;
      stack.pop();
      cache.set(opening, cursor + 1);
      if (stack.length === 0) return cursor + 1;
    }
  }
  // Only unfinished containers failed; completed nested values remain usable.
  for (const opening of stack) cache.set(opening, opening);
  cache.set(start, start);
  return start;
}

function scrubEscapedNonStringCredentials(text) {
  const chunks = [];
  let cursor = 0;
  let count = 0;
  const valueEndCache = new Map();
  for (const match of text.matchAll(ESCAPED_NON_STRING_ASSIGNMENT_PATTERN)) {
    if (match.index < cursor || !isSensitiveFieldName(match[1])) continue;
    const start = match.index + match[0].length;
    const end = escapedNonStringValueEnd(text, start, valueEndCache);
    if (end === start || text.slice(start, end) === "null") continue;
    chunks.push(text.slice(cursor, start), `\\"${REDACTION_TOKEN}\\"`);
    cursor = end;
    count++;
  }
  chunks.push(text.slice(cursor));
  return { text: chunks.join(""), count };
}

/** Scrub known token prefixes and unknown-format values under sensitive names. */
function scrubPlainCredentials(text) {
  const { scrubbed: pemScrubbed, count: pemCount } = scrubPrivateKeys(text);
  let count = pemCount;
  const nonStringScrubbed = scrubEscapedNonStringCredentials(pemScrubbed);
  count += nonStringScrubbed.count;
  const escapedScrubbed = redactGroupValues(ESCAPED_CREDENTIAL_ASSIGNMENT_PATTERN, nonStringScrubbed.text, true);
  const pairScrubbed = redactGroupValues(NAME_VALUE_PAIR_PATTERN, escapedScrubbed.text, true);
  const urlScrubbed = redactGroupValues(URL_USERINFO_PATTERN, pairScrubbed.text, false);
  count += escapedScrubbed.count + pairScrubbed.count + urlScrubbed.count;
  const namedScrubbed = urlScrubbed.text.replace(
    NAMED_CREDENTIAL_ASSIGNMENT_PATTERN,
    (match, boundary, name, separator, value) => {
      if (!isSensitiveFieldName(name)) return match;
      const redacted = redactAssignedValue(value);
      if (redacted === value) return match;
      count++;
      return `${boundary}${name}${separator}${redacted}`;
    },
  );
  const scrubbed = namedScrubbed.replace(CREDENTIAL_PATTERN, (_match, boundary) => {
    count++;
    return `${boundary}${REDACTION_TOKEN}`;
  });
  return { scrubbed, count };
}

export function scrubCredentials(text) {
  const parsed = parseStructuredText(text);
  const scrubbed = parsed && scrubValue(parsed.value);
  return scrubbed?.count > 0
    ? { scrubbed: parsed.stringify(scrubbed.value), count: scrubbed.count }
    : scrubPlainCredentials(text);
}

function scrubValue(value) {
  if (typeof value === "string") return scrubTextValue(value);
  if (Array.isArray(value)) return scrubSequence(value);
  if (value !== null && typeof value === "object") return scrubMapping(value);
  return { value, count: 0 };
}

function scrubTextValue(value) {
  const parsed = parseStructuredText(value);
  const scrubbed = parsed && scrubValue(parsed.value);
  return scrubbed?.count > 0
    ? { value: parsed.stringify(scrubbed.value), count: scrubbed.count }
    : renameScrubbedText(value);
}

function renameScrubbedText(value) {
  const { scrubbed, count } = scrubCredentials(value);
  return { value: scrubbed, count };
}

function scrubSequence(value) {
  return value.reduce(
    (result, item) => {
      const scrubbed = scrubValue(item);
      result.value.push(scrubbed.value);
      result.count += scrubbed.count;
      return result;
    },
    { value: [], count: 0 },
  );
}

function scrubMapping(value) {
  const hasSensitiveIdentifier = Object.entries(value).some(
    ([key, nestedValue]) =>
      isIdentifierFieldName(key) && typeof nestedValue === "string" && isSensitiveFieldName(nestedValue),
  );
  return Object.entries(value).reduce((result, [key, nestedValue]) => {
    const scrubbed = shouldRedactField(key, nestedValue, hasSensitiveIdentifier)
      ? { value: REDACTION_TOKEN, count: 1 }
      : scrubValue(nestedValue);
    result.value[key] = scrubbed.value;
    result.count += scrubbed.count;
    return result;
  }, { value: {}, count: 0 });
}

function shouldRedactField(key, value, hasSensitiveIdentifier) {
  return !preservesSensitiveValue(value) && (
    isSensitiveFieldName(key) || (hasSensitiveIdentifier && isValueFieldName(key))
  );
}

/** Scrub credentials from any JSON-serialisable tool output. */
export function scrubToolOutput(output) {
  const { value, count } = scrubValue(output);
  return { output: value, redacted: count > 0 };
}
