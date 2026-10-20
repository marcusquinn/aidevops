// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Compaction replay — locate the compaction anchor and collect the user turns
// it hides (GH#35186). Pure functions over OpenCode 1 `{ info, parts }` data.
// ---------------------------------------------------------------------------

/**
 * Same media rule as OpenCode util/media.ts isMedia().
 * @param {string} mime
 * @returns {boolean}
 */
export function isMedia(mime) {
  const value = String(mime || "");
  return value.startsWith("image/") || value === "application/pdf";
}

function isCompletedSummary(msg) {
  const info = msg?.info;
  return Boolean(info?.role === "assistant" && info.summary === true && info.finish && !info.error);
}

/**
 * Locate the active compaction anchor: the user message whose compaction part
 * a completed summary answers. filterCompacted() puts it first in the list.
 * @param {Array<object>} messages
 * @returns {{ anchorIndex: number, anchorID: string, summaryID: string, overflow: boolean } | null}
 */
export function findCompactionAnchor(messages) {
  const summary = Array.isArray(messages) ? messages.find(isCompletedSummary) : undefined;
  if (!summary) return null;
  const anchorIndex = messages.findIndex(
    (msg) => msg?.info?.role === "user" && msg.info.id === summary.info.parentID,
  );
  const compactionPart = anchorIndex < 0
    ? undefined
    : (messages[anchorIndex].parts || []).find((part) => part?.type === "compaction");
  if (!compactionPart) return null;
  return {
    anchorIndex,
    anchorID: messages[anchorIndex].info.id,
    summaryID: summary.info.id,
    overflow: compactionPart.overflow === true,
  };
}

/**
 * Describe a file part that is not replayed inline so the model can still find it.
 * @param {object} part
 * @param {string} reason
 * @returns {string}
 */
export function attachmentLabel(part, reason) {
  const name = part.filename || "file";
  const url = String(part.url || "");
  const path = url.startsWith("file://") ? ` (${decodeURIComponent(url.slice("file://".length))})` : "";
  return `[Attached ${part.mime || "unknown"}: ${name}${path}${reason ? ` — ${reason}` : ""}]`;
}

/**
 * Classify one stored part as user-authored text, media, a file note, or nothing.
 * @param {object} part
 * @returns {{ kind: string, text?: string, part?: object } | null}
 */
function partItem(part) {
  if (part?.type === "text") {
    const text = part.synthetic || part.ignored ? "" : String(part.text || "").trim();
    return text ? { kind: "text", text } : null;
  }
  if (part?.type !== "file" || part.mime === "application/x-directory") return null;
  return isMedia(part.mime) ? { kind: "media", part } : { kind: "note", text: attachmentLabel(part, "") };
}

/**
 * Extract user-authored content from one stored message. Messages carrying a
 * compaction or subtask part are host-generated and contribute nothing.
 * @param {object} message - { info, parts }
 * @returns {Array<{ kind: string, text?: string, part?: object }>}
 */
export function userAuthoredItems(message) {
  if (message?.info?.role !== "user") return [];
  const parts = Array.isArray(message.parts) ? message.parts : [];
  if (parts.some((part) => part?.type === "compaction" || part?.type === "subtask")) return [];
  return parts.map(partItem).filter(Boolean);
}

const itemsOfKind = (items, kind) => items.filter((item) => item.kind === kind);

/**
 * Collect user turns that the compacted request no longer shows, in full.
 * Consecutive duplicates (OpenCode overflow replays) are dropped.
 * @param {Array<object>} history - full stored session messages, oldest first
 * @param {Set<string>} visibleIDs
 * @returns {Array<{ id: string, created: number, text: string, media: object[], notes: string[] }>}
 */
export function collectHiddenUserInput(history, visibleIDs) {
  const entries = [];
  for (const message of Array.isArray(history) ? history : []) {
    const id = message?.info?.id;
    const items = id && !visibleIDs.has(id) ? userAuthoredItems(message) : [];
    if (items.length === 0) continue;
    const text = itemsOfKind(items, "text").map((item) => item.text).join("\n\n");
    if (text && entries.at(-1)?.text === text) continue;
    entries.push({
      id,
      created: Number(message.info.time?.created) || 0,
      text,
      media: itemsOfKind(items, "media").map((item) => item.part),
      notes: itemsOfKind(items, "note").map((item) => item.text),
    });
  }
  return entries;
}
