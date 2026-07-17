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

function handleSessionIdle({ sessionID, state, setTerminalTitleStatus }) {
  if (sessionID !== state.activeRootSessionID || state.pendingPermissionIDs.size > 0) return;
  setTerminalTitleStatus("idle");
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
  const requestID = event.properties?.requestID || event.properties?.permissionID;
  const wasPending = state.pendingPermissionIDs.delete(requestID);
  if (!wasPending || state.pendingPermissionIDs.size > 0) return;
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
