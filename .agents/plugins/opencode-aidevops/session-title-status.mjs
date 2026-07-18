// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  resetTerminalTitleState as defaultResetTerminalTitleState,
  setTerminalTitleStatus as defaultSetTerminalTitleStatus,
} from "./terminal-title.mjs";

function getEvent(input) {
  return input?.event || input || {};
}

function sessionIDFrom(event) {
  return event.properties?.sessionID || event.properties?.info?.sessionID || event.properties?.info?.id || "";
}

function isRootSessionInfo(info) {
  return Boolean(info) && !info.parentID;
}

const ROOT_SESSION_STATUSES = new Set(["busy", "retry", "idle"]);
const TERMINAL_ASSISTANT_FINISH_REASONS = new Set(["stop", "end_turn", "completed"]);
const MAX_TRACKED_MESSAGE_IDS = 128;

function rememberMessageID(ids, messageID) {
  if (!messageID || ids.has(messageID)) return false;
  ids.add(messageID);
  while (ids.size > MAX_TRACKED_MESSAGE_IDS) ids.delete(ids.values().next().value);
  return true;
}

function isTerminalAssistantCompletion(info) {
  if (info?.role !== "assistant" || info.summary === true || info.mode === "compaction") return false;
  if (typeof info.time?.completed !== "number") return false;
  return TERMINAL_ASSISTANT_FINISH_REASONS.has(String(info.finish || "").toLowerCase());
}

function activateRootSession({ sessionID, state, resetState, setTerminalTitleStatus }) {
  state.activeRootSessionID = sessionID;
  resetState();
  setTerminalTitleStatus("idle");
}

function handleSessionCreated(context) {
  const { info } = context;
  if (!isRootSessionInfo(info)) return;
  activateRootSession(context);
}

function handleSessionUpdated(context) {
  const { info, state } = context;
  if (state.activeRootSessionID || !isRootSessionInfo(info)) return;
  activateRootSession(context);
}

function handleSessionDeleted({ sessionID, state, resetState }) {
  if (sessionID !== state.activeRootSessionID) return;
  state.activeRootSessionID = "";
  resetState();
}

function handleMessageUpdated({ info, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID) return;
  if (info?.role === "user") {
    const messageID = info.id || "";
    if (!rememberMessageID(state.seenUserMessageIDs, messageID)) return;
    const createdAt = Number.isFinite(info.time?.created) ? info.time.created : null;
    if (
      state.activeUserMessageID &&
      state.activeUserCreatedAt !== null &&
      (createdAt === null || createdAt < state.activeUserCreatedAt)
    ) {
      return;
    }
    state.activeUserMessageID = messageID;
    state.activeUserCreatedAt = createdAt;
    state.completedUserMessageID = "";
    if (state.pendingPermissionIDs.size === 0) setTerminalTitleStatus("busy");
    return;
  }
  if (!isTerminalAssistantCompletion(info) || state.pendingPermissionIDs.size > 0) return;
  if (!state.activeUserMessageID) return;
  if (state.activeUserMessageID && info.parentID && info.parentID !== state.activeUserMessageID) return;
  if (!rememberMessageID(state.completedAssistantMessageIDs, info.id)) return;
  state.completedUserMessageID = state.activeUserMessageID;
  setTerminalTitleStatus("idle");
}

function handleSessionStatus({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID || state.pendingPermissionIDs.size > 0) return;
  const status = event.properties?.status?.type;
  if (!ROOT_SESSION_STATUSES.has(status)) return;
  if (
    status === "busy" &&
    state.completedUserMessageID &&
    state.completedUserMessageID === state.activeUserMessageID
  ) return;
  if (status !== "idle") state.completedUserMessageID = "";
  setTerminalTitleStatus(status);
}

function handleSessionIdle({ sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID || state.pendingPermissionIDs.size > 0) return;
  setTerminalTitleStatus("idle");
}

function handlePermissionAsked({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID) return;
  const requestID = event.properties?.id;
  if (!requestID) return;
  state.completedUserMessageID = "";
  state.pendingPermissionIDs.add(requestID);
  setTerminalTitleStatus("permission");
}

function handlePermissionReplied({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID) return;
  const requestID = event.properties?.requestID || event.properties?.permissionID;
  const wasPending = state.pendingPermissionIDs.delete(requestID);
  if (!wasPending || state.pendingPermissionIDs.size > 0) return;
  state.completedUserMessageID = "";
  setTerminalTitleStatus("busy");
}

const EVENT_HANDLERS = new Map([
  ["session.created", handleSessionCreated],
  ["session.updated", handleSessionUpdated],
  ["session.deleted", handleSessionDeleted],
  ["message.updated", handleMessageUpdated],
  ["session.status", handleSessionStatus],
  ["session.idle", handleSessionIdle],
  ["permission.asked", handlePermissionAsked],
  ["permission.updated", handlePermissionAsked],
  ["permission.replied", handlePermissionReplied],
]);

export function createSessionTitleStatusHandler({
  isHeadless = () => false,
  isEnabled = () => process.env.AIDEVOPS_TAB_STATUS_ENABLED !== "false",
  resetTerminalTitleState = defaultResetTerminalTitleState,
  setTerminalTitleStatus = defaultSetTerminalTitleStatus,
} = {}) {
  const state = {
    activeRootSessionID: "",
    activeUserMessageID: "",
    activeUserCreatedAt: null,
    completedUserMessageID: "",
    completedAssistantMessageIDs: new Set(),
    pendingPermissionIDs: new Set(),
    seenUserMessageIDs: new Set(),
  };

  const resetState = () => {
    state.activeUserMessageID = "";
    state.activeUserCreatedAt = null;
    state.completedUserMessageID = "";
    state.completedAssistantMessageIDs.clear();
    state.pendingPermissionIDs.clear();
    state.seenUserMessageIDs.clear();
    resetTerminalTitleState();
  };

  return async function sessionTitleStatusHandler(input) {
    if (isHeadless() || !isEnabled()) return;

    const event = getEvent(input);
    const info = event.properties?.info;
    const sessionID = sessionIDFrom(event);
    if (!sessionID) return;

    EVENT_HANDLERS.get(event.type)?.({ event, info, sessionID, state, resetState, setTerminalTitleStatus });
  };
}
