// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/** Scan escaped JSON values embedded in plain-text credential assignments. */
const ASSIGNMENT_PATTERN =
  /\\"([A-Za-z_][A-Za-z0-9_. -]*)\\"\s*[:=]\s*(?=[\[{\d-]|true\b|false\b|null\b)/gi;
const STRING_PATTERN = /\\"(?:[^"\\]|\\\\(?:\\.|[^\\])|\\[^"\\])*\\"/y;

function cacheContainerEnd(text, cursor, stack, cache) {
  const opening = stack.at(-1);
  if (opening === undefined || (text[opening] === "[" ? "]" : "}") !== text[cursor]) return false;
  stack.pop();
  cache.set(opening, cursor + 1);
  return true;
}

// Locate a complete container without stopping at commas or brackets inside strings.
function escapedNonStringValueEnd(text, start, cache) {
  if (cache.has(start)) return cache.get(start);
  const scalar = /^(?:-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)(?=$|[\s,}\]])/.exec(text.slice(start));
  if (scalar) return start + scalar[0].length;
  return scanEscapedContainer(text, start, cache);
}

// Yield only characters outside escaped strings; their contents are not delimiters.
function* containerCharacters(text, start) {
  for (let cursor = start; cursor < text.length; cursor++) {
    STRING_PATTERN.lastIndex = cursor;
    const quoted = STRING_PATTERN.exec(text);
    if (quoted) cursor += quoted[0].length - 1;
    else yield [cursor, text[cursor]];
  }
}

function scanEscapedContainer(text, start, cache) {
  const stack = [];
  for (const [cursor, char] of containerCharacters(text, start)) {
    if (char === "[" || char === "{") stack.push(cursor);
    else if (char === "]" || char === "}") {
      if (!cacheContainerEnd(text, cursor, stack, cache)) break;
      if (stack.length === 0) return cursor + 1;
    }
  }
  // Only unfinished containers failed; completed nested values remain usable.
  for (const opening of stack) cache.set(opening, opening);
  cache.set(start, start);
  return start;
}

export function scrubEscapedNonStringCredentials(text, isSensitiveFieldName, redactionToken) {
  const chunks = [];
  let cursor = 0;
  let count = 0;
  const valueEndCache = new Map();
  for (const match of text.matchAll(ASSIGNMENT_PATTERN)) {
    if (match.index < cursor || !isSensitiveFieldName(match[1])) continue;
    const start = match.index + match[0].length;
    const end = escapedNonStringValueEnd(text, start, valueEndCache);
    if (end === start || text.slice(start, end) === "null") continue;
    chunks.push(text.slice(cursor, start), `\\"${redactionToken}\\"`);
    cursor = end;
    count++;
  }
  chunks.push(text.slice(cursor));
  return { text: chunks.join(""), count };
}
