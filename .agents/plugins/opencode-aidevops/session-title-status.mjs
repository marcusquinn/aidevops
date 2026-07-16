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

  return async function sessionTitleStatusHandler(input) {
    if (isHeadless() || !isEnabled()) return;

    const event = getEvent(input);
    const info = event.properties?.info;
    const sessionID = sessionIDFrom(event);

    if (event.type === "session.created" && isRootSessionInfo(info) && sessionID) {
      activeRootSessionID = sessionID;
      resetTerminalTitleState();
      return;
    }

    if (event.type === "session.updated" && !activeRootSessionID && isRootSessionInfo(info) && sessionID) {
      activeRootSessionID = sessionID;
      resetTerminalTitleState();
      return;
    }

    if (event.type === "session.deleted" && sessionID === activeRootSessionID) {
      activeRootSessionID = "";
      resetTerminalTitleState();
      return;
    }

    if (event.type !== "session.status" || sessionID !== activeRootSessionID) return;
    const status = event.properties?.status?.type;
    if (status !== "busy" && status !== "retry" && status !== "idle") return;
    setTerminalTitleStatus(status);
  };
}
