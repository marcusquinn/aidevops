// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { closeSync, openSync, writeSync } from "node:fs";

const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/g;
const STATUS_PREFIX_RE = /^(?:\[(?:RUN|WAIT)\]|⚪|🔴|🟡|🟢)\s+/u;

export function sanitizeTerminalTitle(title) {
  return String(title || "").replace(CONTROL_CHAR_RE, " ").trim();
}

export function terminalTitleStatusLabel(status) {
  if (status === "busy") return "⚪";
  if (status === "retry") return "🔴";
  if (status === "permission") return "🟡";
  if (status === "idle") return "🟢";
  return "";
}

export function withTerminalTitleStatus(title, status) {
  const baseTitle = sanitizeTerminalTitle(title).replace(STATUS_PREFIX_RE, "").trim();
  const label = terminalTitleStatusLabel(status);
  if (!baseTitle || !label) return baseTitle;
  return `${label} ${baseTitle}`;
}

export function terminalTitleSequence(title) {
  const sanitizedTitle = sanitizeTerminalTitle(title);
  if (!sanitizedTitle) return "";
  return `\u001B]0;${sanitizedTitle}\u0007`;
}

function writeTerminalTitle(title) {
  const sequence = terminalTitleSequence(title);
  if (!sequence) return false;
  let ttyFd;
  try {
    ttyFd = openSync("/dev/tty", "w");
    writeSync(ttyFd, sequence);
    return true;
  } catch {
    // Terminal title synchronization is best-effort and must not affect sessions.
    return false;
  } finally {
    if (ttyFd !== undefined) {
      try {
        closeSync(ttyFd);
      } catch {
        // Terminal title synchronization is best-effort and must not affect sessions.
      }
    }
  }
}

export function createTerminalTitleController({
  writeTitle = writeTerminalTitle,
  isEnabled = () =>
    process.env.TERMINAL_TITLE_ENABLED !== "false" && process.env.AIDEVOPS_TABBY_ENABLED !== "false",
} = {}) {
  let baseTitle = "";
  let status = "";

  const render = () => {
    if (!baseTitle || !isEnabled()) return false;
    return writeTitle(withTerminalTitleStatus(baseTitle, status)) !== false;
  };

  return {
    emit(title) {
      baseTitle = sanitizeTerminalTitle(title).replace(STATUS_PREFIX_RE, "").trim();
      return render();
    },
    setStatus(nextStatus) {
      const nextLabel = terminalTitleStatusLabel(nextStatus);
      if (nextLabel === terminalTitleStatusLabel(status)) return false;
      status = nextStatus;
      return render();
    },
    reset() {
      baseTitle = "";
      status = "";
    },
  };
}

const terminalTitleController = createTerminalTitleController();

export function emitTerminalTitle(title) {
  return terminalTitleController.emit(title);
}

export function setTerminalTitleStatus(status) {
  return terminalTitleController.setStatus(status);
}

export function resetTerminalTitleState() {
  terminalTitleController.reset();
}
