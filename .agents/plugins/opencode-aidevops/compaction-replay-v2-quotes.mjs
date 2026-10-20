// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Checkpoint tail quote matching for the OpenCode 2 replay (GH#35189)
//
// OpenCode 2.0.3 serializes the checkpoint's recent tail as `[User]: …` and
// `[Assistant…]: …` lines joined by "\n" inside <recent-context>. A recorded
// prompt counts as already quoted only when it appears there as a whole turn,
// so a hidden "approve" is never suppressed by a visible
// "approved only for staging".
// ---------------------------------------------------------------------------

const QUOTE_END = /^(?:\n\[(?:User|Assistant)[^\]\n]*\]: |\n<\/recent-context>|$)/;

/**
 * Number of whole-turn `[User]: <text>` quotes in the checkpoint text.
 * @param {string} haystack
 * @param {string} text
 * @returns {number}
 */
export function wholeTurnQuotes(haystack, text) {
  const needle = `[User]: ${text}`;
  let count = 0;
  for (let at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + 1)) {
    const starts = at === 0 || haystack[at - 1] === "\n";
    if (starts && QUOTE_END.test(haystack.slice(at + needle.length))) count++;
  }
  return count;
}

/**
 * Ids of text-only entries quoted as whole turns. Each quote covers one
 * entry, newest first, so repeated identical prompts beyond the quoted
 * count are still replayed.
 * @param {Array<{id: string, text: string, media: Array}>} entries
 * @param {string} checkpointText
 * @returns {Set<string>}
 */
export function quotedIDs(entries, checkpointText) {
  const remaining = new Map();
  const quoted = new Set();
  const textOnly = entries.filter((entry) => entry.media.length === 0 && entry.text);
  for (const entry of textOnly.reverse()) {
    if (!remaining.has(entry.text)) remaining.set(entry.text, wholeTurnQuotes(checkpointText, entry.text));
    const left = remaining.get(entry.text);
    if (left > 0) {
      remaining.set(entry.text, left - 1);
      quoted.add(entry.id);
    }
  }
  return quoted;
}
