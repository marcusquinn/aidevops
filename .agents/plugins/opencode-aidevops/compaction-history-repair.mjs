// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ---------------------------------------------------------------------------
// GH#37997: repair the model input a looping compaction leaves behind
// (OpenCode 1.19 data shapes, `{ info, parts }` from messages.transform).
// ---------------------------------------------------------------------------

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
