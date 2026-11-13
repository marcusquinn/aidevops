// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ---------------------------------------------------------------------------
// GH#37997: pure helpers for compaction summaries that loop on repeated text.
//
// A summarizer copying a long verbatim quote can fall into a copy loop
// (observed: one 91-char span of a quoted user aim repeated 437 times until
// the user aborted). Nothing bounded it but the 32K output cap. These helpers
// detect a back-to-back periodic run, collapse it, and repair the model input
// the loop leaves behind (OpenCode 1.19 data shapes, `{ info, parts }`).
// ---------------------------------------------------------------------------

// A legitimate summary never repeats one span back-to-back for 2,000+ chars
// at least 4 times; the observed loop crossed this ~2.5KB into the loop.
export const LOOP_DEFAULTS = Object.freeze({
  maxPeriod: 2000,
  minRunChars: 2000,
  minRepeats: 4,
  window: 24000,
});

const LOOP_MARKER = (removed) => ` [aidevops: removed ${removed} chars of repeated summarizer text]`;
const KEY_CHARS = 16;

function settings(options) {
  return { ...LOOP_DEFAULTS, ...(options || {}) };
}

function qualifies(runChars, period, limits) {
  return runChars >= limits.minRunChars && runChars / period >= limits.minRepeats;
}

/**
 * Detect a periodic run that ends at the end of `text` (a stream still looping).
 * The smallest qualifying period wins, so the result is the repeated unit.
 * @param {string} text
 * @param {object} [options] - LOOP_DEFAULTS overrides
 * @returns {{ period: number, runChars: number, repeats: number } | null}
 */
export function repetitionAtTail(text, options) {
  const limits = settings(options);
  const value = String(text || "");
  const end = value.length;
  const floor = Math.max(0, end - limits.window);
  for (let period = 1; period <= limits.maxPeriod && end - floor >= period * 2; period += 1) {
    let matched = 0;
    for (let index = end - 1; index - period >= floor; index -= 1) {
      if (value.charCodeAt(index) !== value.charCodeAt(index - period)) break;
      matched += 1;
    }
    const runChars = matched + period;
    if (qualifies(runChars, period, limits)) {
      return { period, runChars, repeats: Math.floor(runChars / period) };
    }
  }
  return null;
}

// Periods at which a 16-char key recurs often enough to hide a long run.
function candidatePeriods(value, limits) {
  const seen = new Map();
  const counts = new Map();
  for (let index = 0; index + KEY_CHARS <= value.length; index += 1) {
    const key = value.slice(index, index + KEY_CHARS);
    const previous = seen.get(key);
    if (previous !== undefined && index - previous <= limits.maxPeriod) {
      const period = index - previous;
      counts.set(period, (counts.get(period) || 0) + 1);
    }
    seen.set(key, index);
  }
  const needed = Math.floor(limits.minRunChars / 2);
  return [...counts].filter(([, count]) => count >= needed).map(([period]) => period).sort((a, b) => a - b);
}

function runsForPeriod(value, period, limits) {
  const runs = [];
  let start = -1;
  for (let index = period; index <= value.length; index += 1) {
    const same = index < value.length && value.charCodeAt(index) === value.charCodeAt(index - period);
    if (same) {
      if (start < 0) start = index;
    } else if (start >= 0) {
      const runStart = start - period;
      if (qualifies(index - runStart, period, limits)) runs.push({ start: runStart, end: index, period });
      start = -1;
    }
  }
  return runs;
}

/**
 * Find non-overlapping back-to-back repeated runs anywhere in `text`.
 * Smaller (fundamental) periods claim a region before their multiples.
 * @param {string} text
 * @param {object} [options] - LOOP_DEFAULTS overrides
 * @returns {Array<{ start: number, end: number, period: number }>} sorted by start
 */
export function findRepetitionRuns(text, options) {
  const limits = settings(options);
  const value = String(text || "");
  if (value.length < limits.minRunChars) return [];
  const chosen = [];
  for (const period of candidatePeriods(value, limits)) {
    for (const run of runsForPeriod(value, period, limits)) {
      if (!chosen.some((other) => run.start < other.end && other.start < run.end)) chosen.push(run);
    }
  }
  return chosen.sort((a, b) => a.start - b.start);
}

/**
 * Keep one copy of each repeated unit and mark what was removed.
 * @param {string} text
 * @param {object} [options] - LOOP_DEFAULTS overrides
 * @returns {{ text: string, removed: number, runs: number }}
 */
export function collapseRepetitions(text, options) {
  const value = String(text ?? "");
  const runs = findRepetitionRuns(value, options);
  if (runs.length === 0) return { text: value, removed: 0, runs: 0 };
  let result = "";
  let cursor = 0;
  let removed = 0;
  for (const run of runs) {
    const keepUntil = run.start + run.period;
    result += value.slice(cursor, keepUntil) + LOOP_MARKER(run.end - keepUntil);
    removed += run.end - keepUntil;
    cursor = run.end;
  }
  return { text: result + value.slice(cursor), removed, runs: runs.length };
}

/** Assistant message written by OpenCode's compaction agent. */
export function isCompactionSummary(info) {
  return Boolean(info?.role === "assistant" && (info.summary === true || info.mode === "compaction"));
}

function isCompletedSummary(info) {
  return isCompactionSummary(info) && Boolean(info.finish) && !info.error;
}

function isAfter(info, other) {
  const created = Number(info?.time?.created) || 0;
  const otherCreated = Number(other?.time?.created) || 0;
  if (created !== otherCreated) return created > otherCreated;
  return String(info?.id || "") > String(other?.id || "");
}

function hasCompactionPart(message) {
  return (Array.isArray(message?.parts) ? message.parts : []).some((part) => part?.type === "compaction");
}

// OpenCode 1.19 prompt.ts runs a pending compaction task with
// `parentID: lastUser.id`. After an aborted compaction that is the user's next
// typed message, which has no compaction part, so filterCompacted() skips the
// boundary and resends the whole history. Treat that summary as the boundary.
function trimMisanchoredBoundary(messages) {
  let latest = -1;
  messages.forEach((message, index) => {
    if (!isCompletedSummary(message?.info)) return;
    if (latest < 0 || isAfter(message.info, messages[latest].info)) latest = index;
  });
  if (latest < 0) return 0;
  const parentID = messages[latest].info.parentID;
  const anchor = messages.findIndex((message) => message?.info?.role === "user" && message.info.id === parentID);
  if (anchor <= 0 || anchor > latest || hasCompactionPart(messages[anchor])) return 0;
  messages.splice(0, anchor);
  return anchor;
}

/**
 * Repair model input in place: drop failed or unfinished compaction summaries
 * (OpenCode replays aborted assistant text, so a looping partial would prime
 * the next request), then apply a misanchored summary's boundary.
 * @param {Array<object>} messages - `output.messages` of messages.transform
 * @returns {{ dropped: number, trimmed: number }}
 */
export function repairCompactedHistory(messages) {
  if (!Array.isArray(messages)) return { dropped: 0, trimmed: 0 };
  let dropped = 0;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const info = messages[index]?.info;
    if (isCompactionSummary(info) && (info.error || !info.finish)) {
      messages.splice(index, 1);
      dropped += 1;
    }
  }
  return { dropped, trimmed: trimMisanchoredBoundary(messages) };
}
