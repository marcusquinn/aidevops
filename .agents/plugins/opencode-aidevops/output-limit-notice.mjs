// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#39151 / GH#39556: one-shot notice for truncated or empty assistant turns.
// Split from session-turn-state.mjs to keep per-file complexity down.

const MAX_TRACKED_IDS = 32;
const TRACK_LIMIT = MAX_TRACKED_IDS * 4;

function capSet(set, limit) {
  while (set.size > limit) set.delete(set.values().next().value);
}

// OpenCode ends a response with finish "length" when it hits the request
// output cap; the in-flight tool call is aborted and nothing is saved.
export const OUTPUT_LIMIT_NOTE =
  "Your previous response hit the configured output-token limit and its tool call was discarded; " +
  "nothing was written. Write large files in sections of under ~120 lines (Write, then Edit appends).";

export const EMPTY_TURN_NOTE =
  "Your previous response ended with no visible text and no completed tool call (the output budget may have gone on reasoning). " +
  "Plan in smaller steps, state what you will do, then act; write files in sections of under ~120 lines.";
export const EMPTY_TOOL_NOTE =
  "Your previous tool call had empty arguments and was aborted; nothing was executed. " +
  "Plan in smaller steps, then retry with complete arguments; write files in sections of under ~120 lines.";

export const EMPTY_TOOL_ERROR_NOTE =
  "Your previous tool call failed with empty arguments; it may have partly run, so check state before retrying. " +
  "Plan in smaller steps, then retry with complete arguments; write files in sections of under ~120 lines.";

const EMPTY_INPUT_TOOL_STATUSES = new Set(["error", "aborted"]);

function isAbortedTool(state) {
  return state.status === "aborted" || state.error === "Tool execution aborted" || state.metadata?.interrupted === true;
}

function isEmptyInput(input) {
  return !input || (typeof input === "object" && Object.keys(input).length === 0);
}

function isUsefulPart(part) {
  if (part.type === "text") return Boolean(String(part.text || "").trim());
  return part.type === "tool" && part.state?.status === "completed";
}

function emptyToolNote(state) {
  if (!state || !EMPTY_INPUT_TOOL_STATUSES.has(state.status) || !isEmptyInput(state.input)) return "";
  return isAbortedTool(state) ? EMPTY_TOOL_NOTE : EMPTY_TOOL_ERROR_NOTE;
}

function finishNote(info, hasContent) {
  if (info.role !== "assistant" || !info.finish) return "";
  if (info.finish === "length") return OUTPUT_LIMIT_NOTE;
  return info.finish === "tool-calls" || hasContent ? "" : EMPTY_TURN_NOTE;
}

function createTracker() {
  const pending = new Map();
  const seen = new Set();
  const content = new Set();
  const textParts = new Map();
  const flag = (sessionID, key, note) => {
    if (!sessionID || seen.has(key)) return;
    seen.add(key);
    capSet(seen, TRACK_LIMIT);
    // An explicit output-limit finish outranks a pending fallback notice.
    if (!pending.has(sessionID) || note === OUTPUT_LIMIT_NOTE) pending.set(sessionID, note);
  };
  const rememberTextPart = (part, messageID) => {
    if (part.type !== "text" || !part.id) return;
    textParts.set(String(part.id), messageID);
    if (textParts.size > TRACK_LIMIT) textParts.delete(textParts.keys().next().value);
  };
  return {
    pending,
    seen,
    delta(props) {
      const messageID = textParts.get(String(props.partID || ""));
      if (messageID !== undefined && typeof props.delta === "string" && props.delta.trim()) content.add(messageID);
      capSet(content, TRACK_LIMIT);
    },
    part(part) {
      const messageID = String(part.messageID || "");
      rememberTextPart(part, messageID);
      if (isUsefulPart(part)) content.add(messageID);
      const note = part.type === "tool" ? emptyToolNote(part.state) : "";
      const sessionID = String(part.sessionID || "");
      if (note) flag(sessionID, `${sessionID}:tool:${part.id || messageID}`, note);
      capSet(content, TRACK_LIMIT);
    },
    message(info) {
      const sessionID = String(info.sessionID || "");
      const note = finishNote(info, content.has(String(info.id || "")));
      if (note) flag(sessionID, `${sessionID}:${info.id || ""}`, note);
    },
  };
}

/**
 * One-shot per-session notice. observe() flags a session when an assistant
 * message finishes with "length", ends with no usable content (GH#39556), or
 * a tool part is aborted with empty input; take() returns the note once.
 */
export function createOutputLimitNotice() {
  const tracker = createTracker();
  const { pending, seen } = tracker;
  const handlers = new Map([
    ["message.part.updated", (props) => tracker.part(props.part || {})],
    ["message.part.delta", (props) => tracker.delta(props)],
    ["message.updated", (props) => tracker.message(props.info || {})],
  ]);
  return {
    observe(event) {
      if (event?.type === "session.deleted") {
        this.forget(event.properties?.info?.id || event.properties?.sessionID);
        return;
      }
      handlers.get(event?.type)?.(event.properties || {});
    },
    forget(sessionID) {
      const id = String(sessionID || "");
      pending.delete(id);
      for (const key of seen) if (key.startsWith(`${id}:`)) seen.delete(key);
    },
    take(sessionID) {
      const id = String(sessionID || "");
      const note = pending.get(id) || "";
      pending.delete(id);
      return note;
    },
    /** Append the one-shot note to a system prompt array, if pending. */
    inject(sessionID, system) {
      const note = Array.isArray(system) ? this.take(sessionID) : "";
      if (note) system.push(note);
    },
    /** observe() that reports errors via onError instead of throwing. */
    observeSafe(event, onError) {
      try {
        this.observe(event);
      } catch (err) {
        onError(err);
      }
    },
  };
}
