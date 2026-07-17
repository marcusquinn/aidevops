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

export function createSessionTitleStatusHandler({
  isHeadless = () => false,
  isEnabled = () => process.env.AIDEVOPS_TAB_STATUS_ENABLED !== "false",
  resetTerminalTitleState = defaultResetTerminalTitleState,
  setTerminalTitleStatus = defaultSetTerminalTitleStatus,
} = {}) {
  let activeRootSessionID = "";
  const pendingPermissionIDs = new Set();

  const resetState = () => {
    pendingPermissionIDs.clear();
    resetTerminalTitleState();
  };

  return async function sessionTitleStatusHandler(input) {
    if (isHeadless() || !isEnabled()) return;

    const event = getEvent(input);
    const info = event.properties?.info;
    const sessionID = sessionIDFrom(event);

    if (event.type === "session.created" && isRootSessionInfo(info) && sessionID) {
      activeRootSessionID = sessionID;
      resetState();
    } else if (event.type === "session.updated" && !activeRootSessionID && isRootSessionInfo(info) && sessionID) {
      activeRootSessionID = sessionID;
      resetState();
    } else if (event.type === "session.deleted" && sessionID === activeRootSessionID) {
      activeRootSessionID = "";
      resetState();
    } else if (
      event.type === "message.updated" &&
      sessionID === activeRootSessionID &&
      info?.role === "user" &&
      pendingPermissionIDs.size === 0
    ) {
      setTerminalTitleStatus("busy");
    } else if (event.type === "session.status" && sessionID === activeRootSessionID) {
      const status = event.properties?.status?.type;
      if (pendingPermissionIDs.size === 0 && (status === "busy" || status === "retry" || status === "idle")) {
        setTerminalTitleStatus(status);
      }
    } else if (event.type === "permission.asked" && sessionID === activeRootSessionID) {
      const requestID = event.properties?.id;
      if (requestID) {
        pendingPermissionIDs.add(requestID);
        setTerminalTitleStatus("permission");
      }
    } else if (event.type === "permission.replied" && sessionID === activeRootSessionID) {
      const wasPending = pendingPermissionIDs.delete(event.properties?.requestID);
      if (wasPending && pendingPermissionIDs.size === 0) setTerminalTitleStatus("busy");
    }
  };
}
