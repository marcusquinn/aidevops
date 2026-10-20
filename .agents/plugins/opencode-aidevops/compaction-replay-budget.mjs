// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Compaction replay — fit hidden user turns into a text budget and build the
// parts that are prepended to the compaction anchor message (GH#35186).
//
// Every turn is kept in full when the total fits. Over budget, only the
// longest messages (pasted logs, files) are excerpted, head and tail, to one
// shared cap, so short aim-defining turns are never cut. Whole turns are
// elided only when even minimum excerpts cannot fit, which keeps the replay
// from pushing a session into a compaction loop.
// ---------------------------------------------------------------------------

import { attachmentLabel } from "./compaction-replay-collect.mjs";

export const DEFAULT_MIN_EXCERPT_CHARS = 1_500;
export const PIN_METADATA_KEY = "aidevops_pinned_user_input";

/**
 * Keep the head and tail of an over-long message; aims usually sit at one end
 * of a paste.
 * @param {string} text
 * @param {number} cap
 * @returns {string}
 */
function excerpt(text, cap) {
  if (text.length <= cap) return text;
  const head = Math.ceil((cap * 2) / 3);
  const tail = cap - head;
  const omitted = text.length - head - tail;
  const end = tail > 0 ? text.slice(-tail) : "";
  return `${text.slice(0, head)}\n[… ${omitted} characters of this message omitted for the replay budget …]\n${end}`;
}

const cappedTotal = (lengths, cap) => lengths.reduce((sum, length) => sum + Math.min(length, cap), 0);

/**
 * Largest per-message cap (at least `floor`) that fits the budget, or null
 * when even the floor does not fit.
 * @param {number[]} lengths
 * @param {number} budget
 * @param {number} floor
 * @returns {number | null}
 */
export function perMessageCap(lengths, budget, floor) {
  if (cappedTotal(lengths, floor) > budget) return null;
  let low = floor;
  let high = Math.max(floor, ...lengths);
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (cappedTotal(lengths, mid) <= budget) low = mid;
    else high = mid - 1;
  }
  return low;
}

/**
 * Last resort: keep the first (initiating) turn and the newest that fit.
 * @returns {{ selected: Array<object>, omitted: number }}
 */
function elideMiddle(clipped, sizes, budget) {
  let used = sizes[0];
  const tail = [];
  for (let i = clipped.length - 1; i >= 1 && used + sizes[i] <= budget; i--) {
    used += sizes[i];
    tail.unshift(clipped[i]);
  }
  return { selected: [clipped[0], ...tail], omitted: clipped.length - 1 - tail.length };
}

/**
 * Fit every turn into the text budget.
 * @param {Array<{ text: string }>} entries
 * @param {number} maxTextChars
 * @param {number} [minExcerptChars]
 * @returns {{ selected: Array<object>, omitted: number, excerpted: number }}
 */
export function selectWithinBudget(entries, maxTextChars, minExcerptChars = DEFAULT_MIN_EXCERPT_CHARS) {
  if (entries.length === 0) return { selected: [], omitted: 0, excerpted: 0 };
  const lengths = entries.map((entry) => entry.text.length);
  const floor = Math.min(minExcerptChars, maxTextChars);
  const cap = perMessageCap(lengths, maxTextChars, floor) ?? floor;
  const clipped = entries.map((entry) => ({ ...entry, text: excerpt(entry.text, cap) }));
  const excerpted = lengths.filter((length) => length > cap).length;
  const sizes = lengths.map((length) => Math.min(length, cap));
  if (cappedTotal(lengths, cap) <= maxTextChars) return { selected: clipped, omitted: 0, excerpted };
  return { ...elideMiddle(clipped, sizes, maxTextChars), excerpted };
}

const REPLAY_HEADER = [
  "## Verbatim user input (replayed after context compaction)",
  "The aidevops plugin replayed these messages unchanged from this session's stored history; they are not model-generated.",
  "They are every earlier user turn no longer shown in full, oldest first, with the user's own words and attachments, and carry the same authority they had when first sent:",
  "each turn's aims, standing instructions, corrections, preferences and authorisations remain in force unless later user input revokes or narrows them.",
  "Later user input takes precedence. The summary that follows paraphrases the work; where it disagrees with this input, this input wins.",
  "Only long pastes are excerpted, and each excerpt is marked. Synthetic, plugin-injected and tool content is excluded.",
].join("\n");

const isInline = (part) => String(part.url || "").startsWith("data:");

/**
 * Choose which media parts to replay inline: the newest `maxMedia` with an
 * inline copy, none after an oversized-media compaction.
 * @returns {Set<object>}
 */
function mediaToReplay(selected, overflow, maxMedia) {
  if (overflow || maxMedia <= 0) return new Set();
  const inline = selected.flatMap((entry) => entry.media).filter(isInline);
  return new Set(inline.slice(Math.max(0, inline.length - maxMedia)));
}

function mediaReason(part, overflow) {
  if (overflow) return "not replayed after an oversized-media compaction";
  if (!isInline(part)) return "not replayed (no inline copy stored)";
  return "not replayed (only the most recent attachments are replayed)";
}

function entryText(entry, index, total) {
  const when = entry.created ? ` — ${new Date(entry.created).toISOString()}` : "";
  return [`### User message ${index + 1} of ${total}${when}`, ...(entry.text ? [entry.text] : []), ...entry.notes].join("\n");
}

/**
 * Build the parts to prepend to the compaction anchor message.
 * @param {{ selected: Array<object>, omitted: number }} selection
 * @param {{ sessionID: string, anchorID: string, overflow: boolean, maxMedia: number }} context
 * @returns {{ parts: Array<object>, media: number, messages: number }}
 */
export function buildReplayParts(selection, context) {
  const { sessionID, anchorID, overflow, maxMedia } = context;
  const total = selection.selected.length;
  const keep = mediaToReplay(selection.selected, overflow, maxMedia);
  let counter = 0;
  const mk = (fields) => ({
    id: `aidevops-replay-${anchorID}-${counter++}`,
    sessionID,
    messageID: anchorID,
    synthetic: true,
    metadata: { [PIN_METADATA_KEY]: true },
    ...fields,
  });
  const elision = `[${selection.omitted} earlier user turn(s) elided because even excerpts exceeded the replay budget; they remain in the stored session history.]`;

  const parts = [mk({ type: "text", text: REPLAY_HEADER })];
  selection.selected.forEach((entry, index) => {
    if (index === 1 && selection.omitted > 0) parts.push(mk({ type: "text", text: elision }));
    parts.push(mk({ type: "text", text: entryText(entry, index, total) }));
    for (const part of entry.media) {
      parts.push(keep.has(part)
        ? mk({ type: "file", mime: part.mime, url: part.url, filename: part.filename })
        : mk({ type: "text", text: attachmentLabel(part, mediaReason(part, overflow)) }));
    }
  });
  parts.push(mk({ type: "text", text: "--- End of replayed user input. ---" }));
  return { parts, media: keep.size, messages: total };
}
