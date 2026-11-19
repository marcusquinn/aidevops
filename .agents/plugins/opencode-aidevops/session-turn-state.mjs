// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#34138: per-session turn state for session-turn-diagnostics.mjs.
// Reducers record only metadata: status, error class, tool name, part and
// permission IDs, and whether visible text exists. Text itself is never kept.

import { classifyError } from "./session-turn-outcomes.mjs";

const MAX_TRACKED_IDS = 32;
const ACTIVE_TOOL_STATES = new Set(["pending", "running"]);
export const ACTIVE_SESSION_STATES = new Set(["busy", "retry"]);

function capMap(map, limit) {
  while (map.size > limit) map.delete(map.keys().next().value);
}

function capSet(set, limit) {
  while (set.size > limit) set.delete(set.values().next().value);
}

function safeToolName(tool) {
  const name = String(tool || "").replace(/[^\w.-]/g, "").slice(0, 64);
  return name || "unknown";
}

export function sessionIDFrom(event) {
  const properties = event.properties || {};
  const candidates = [
    properties.sessionID,
    properties.part?.sessionID,
    properties.info?.sessionID,
    properties.info?.id,
  ];
  return String(candidates.find(Boolean) || "");
}

export function initialState() {
  return {
    activeTools: new Map(),
    error: null,
    lastActivityAt: 0,
    notified: new Set(),
    parentID: null,
    pendingPermissionIDs: new Set(),
    status: "",
    stepSeen: false,
    textPartIDs: new Set(),
    textSeen: false,
    toolSeen: false,
    turnActive: false,
    turnID: 0,
    turnStartedAt: 0,
    userMessageIDs: new Set(),
  };
}

function newTurn(state, now) {
  state.turnID += 1;
  state.turnActive = true;
  state.turnStartedAt = now;
  state.lastActivityAt = now;
  state.textSeen = false;
  state.stepSeen = false;
  state.toolSeen = false;
  state.error = null;
  state.activeTools.clear();
  state.textPartIDs.clear();
  state.notified.clear();
}

function updateSession(state, event) {
  const info = event.properties?.info || {};
  if (Object.hasOwn(info, "parentID") || state.parentID === null) {
    state.parentID = String(info.parentID || "");
  }
  return false;
}

function updateStatus(state, event, now) {
  const status = String(event.properties?.status?.type || "").toLowerCase();
  if (!status) return false;
  if (ACTIVE_SESSION_STATES.has(status) && !state.turnActive) newTurn(state, now);
  state.status = status;
  return status === "idle";
}

function markIdle(state) {
  state.status = "idle";
  return true;
}

function recordSessionError(state, event) {
  const classified = classifyError(event.properties?.error);
  if (classified) state.error = classified;
  return false;
}

function rememberUserMessage(state, messageID, now) {
  if (!messageID || state.userMessageIDs.has(messageID)) return;
  state.userMessageIDs.add(messageID);
  capSet(state.userMessageIDs, MAX_TRACKED_IDS);
  // A queued follow-up during an active turn must not erase evidence that
  // the running turn already answered.
  if (!state.turnActive) newTurn(state, now);
}

function updateMessage(state, event, now) {
  const info = event.properties?.info || {};
  if (info.role === "user") {
    rememberUserMessage(state, String(info.id || ""), now);
  } else if (info.role === "assistant") {
    const classified = classifyError(info.error);
    if (classified) state.error = classified;
  }
  return false;
}

function updateToolPart(state, part) {
  state.toolSeen = true;
  const callID = String(part.callID || part.id || "");
  if (!callID) return;
  const status = String(part.state?.status || "").toLowerCase();
  if (ACTIVE_TOOL_STATES.has(status)) {
    state.activeTools.set(callID, safeToolName(part.tool));
    capMap(state.activeTools, MAX_TRACKED_IDS);
  } else {
    state.activeTools.delete(callID);
  }
}

function isAssistantText(state, part) {
  if (part.type !== "text" || part.synthetic === true || part.ignored === true) return false;
  return !state.userMessageIDs.has(String(part.messageID || ""));
}

function updateTextPart(state, part) {
  if (!isAssistantText(state, part)) return;
  if (part.id) {
    state.textPartIDs.add(String(part.id));
    capSet(state.textPartIDs, MAX_TRACKED_IDS);
  }
  if (typeof part.text === "string" && part.text.trim()) state.textSeen = true;
}

const PART_HANDLERS = new Map([
  ["step-start", (state) => { state.stepSeen = true; }],
  ["step-finish", (state) => { state.stepSeen = true; }],
  ["tool", updateToolPart],
  ["text", updateTextPart],
]);

function updatePart(state, event) {
  const part = event.properties?.part || {};
  PART_HANDLERS.get(part.type)?.(state, part);
  return false;
}

// Streaming runtimes may send visible text only as deltas to a text part
// announced earlier with empty text. Only known assistant text parts count.
function updateDelta(state, event) {
  const { partID, delta } = event.properties || {};
  if (!state.textPartIDs.has(String(partID || ""))) return false;
  if (typeof delta === "string" && delta.trim()) state.textSeen = true;
  return false;
}

function askPermission(state, event) {
  const requestID = String(event.properties?.id || "");
  if (requestID) state.pendingPermissionIDs.add(requestID);
  capSet(state.pendingPermissionIDs, MAX_TRACKED_IDS);
  return false;
}

function replyPermission(state, event) {
  const properties = event.properties || {};
  state.pendingPermissionIDs.delete(String(properties.requestID || properties.permissionID || ""));
  return false;
}

const EVENT_REDUCERS = new Map([
  ["session.created", updateSession],
  ["session.updated", updateSession],
  ["session.status", updateStatus],
  ["session.idle", markIdle],
  ["session.error", recordSessionError],
  ["message.updated", updateMessage],
  ["message.part.updated", updatePart],
  ["message.part.delta", updateDelta],
  ["permission.asked", askPermission],
  ["permission.updated", askPermission],
  ["permission.replied", replyPermission],
]);

// GH#39151: OpenCode ends a response with finish "length" when it hits the
// request output cap; the in-flight tool call is aborted and nothing is saved.
export const OUTPUT_LIMIT_NOTE =
  "Your previous response hit the configured output-token limit and its tool call was discarded; " +
  "nothing was written. Write large files in sections of under ~120 lines (Write, then Edit appends).";

/**
 * One-shot per-session notice. observe() flags a session when an assistant
 * message finishes with "length"; take() returns the note once and clears it.
 */
export function createOutputLimitNotice() {
  const pending = new Set();
  const seen = new Set();
  return {
    observe(event) {
      if (event?.type === "session.deleted") {
        this.forget(event.properties?.info?.id || event.properties?.sessionID);
        return;
      }
      if (event?.type !== "message.updated") return;
      const info = event.properties?.info || {};
      if (info.role !== "assistant" || info.finish !== "length") return;
      const sessionID = String(info.sessionID || "");
      const key = `${sessionID}:${info.id || ""}`;
      if (!sessionID || seen.has(key)) return;
      seen.add(key);
      capSet(seen, MAX_TRACKED_IDS * 4);
      pending.add(sessionID);
    },
    forget(sessionID) {
      const id = String(sessionID || "");
      pending.delete(id);
      for (const key of seen) if (key.startsWith(`${id}:`)) seen.delete(key);
    },
    take(sessionID) {
      const id = String(sessionID || "");
      if (!id || !pending.delete(id)) return "";
      return OUTPUT_LIMIT_NOTE;
    },
  };
}

// Session metadata changes are not model or tool activity.
const NON_ACTIVITY_EVENTS = new Set(["session.created", "session.updated", "session.idle"]);

/**
 * Apply one event to a session's state. Returns null for unhandled events,
 * otherwise whether the event marks an idle (turn-ending) boundary.
 */
export function applyEvent(state, event, now) {
  const reducer = EVENT_REDUCERS.get(event.type);
  if (!reducer) return null;
  const idle = reducer(state, event, now);
  if (!NON_ACTIVITY_EVENTS.has(event.type)) state.lastActivityAt = now;
  return idle;
}
