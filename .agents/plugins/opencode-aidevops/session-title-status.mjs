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
  return event.properties?.sessionID || event.properties?.info?.id || "";
}

function isRootSessionInfo(info) {
  return Boolean(info) && !info.parentID;
}

const ROOT_SESSION_STATUSES = new Set(["busy", "retry", "idle"]);

function handleSessionCreated({ info, sessionID, state, resetState }) {
  if (!isRootSessionInfo(info)) return;
  state.activeRootSessionID = sessionID;
  resetState();
}

function handleSessionUpdated({ info, sessionID, state, resetState }) {
  if (state.activeRootSessionID || !isRootSessionInfo(info)) return;
  state.activeRootSessionID = sessionID;
  resetState();
}

function handleSessionDeleted({ sessionID, state, resetState }) {
  if (sessionID !== state.activeRootSessionID) return;
  state.activeRootSessionID = "";
  resetState();
}

function handleMessageUpdated({ info, sessionID, state, setTerminalTitleStatus }) {
  if (
    sessionID !== state.activeRootSessionID ||
    info?.role !== "user" ||
    state.pendingPermissionIDs.size > 0
  ) {
    return;
  }
  setTerminalTitleStatus("busy");
}

function handleSessionStatus({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID || state.pendingPermissionIDs.size > 0) return;
  const status = event.properties?.status?.type;
  if (!ROOT_SESSION_STATUSES.has(status)) return;
  setTerminalTitleStatus(status);
}

function handlePermissionAsked({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID) return;
  const requestID = event.properties?.id;
  if (!requestID) return;
  state.pendingPermissionIDs.add(requestID);
  setTerminalTitleStatus("permission");
}

function handlePermissionReplied({ event, sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID) return;
  const wasPending = state.pendingPermissionIDs.delete(event.properties?.requestID);
  if (!wasPending || state.pendingPermissionIDs.size > 0) return;
  setTerminalTitleStatus("busy");
}

const EVENT_HANDLERS = new Map([
  ["session.created", handleSessionCreated],
  ["session.updated", handleSessionUpdated],
  ["session.deleted", handleSessionDeleted],
  ["message.updated", handleMessageUpdated],
  ["session.status", handleSessionStatus],
  ["permission.asked", handlePermissionAsked],
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
    pendingPermissionIDs: new Set(),
  };

  const resetState = () => {
    state.pendingPermissionIDs.clear();
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
