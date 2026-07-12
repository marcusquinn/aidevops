// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { closeSync, openSync, writeSync } from "node:fs";

const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/g;

export function terminalTitleSequence(title) {
  const sanitizedTitle = String(title || "").replace(CONTROL_CHAR_RE, " ").trim();
  return `\u001B]0;${sanitizedTitle}\u0007`;
}

export function emitTerminalTitle(title) {
  if (process.env.TERMINAL_TITLE_ENABLED === "false" || process.env.AIDEVOPS_TABBY_ENABLED === "false") return;

  let ttyFd;
  try {
    ttyFd = openSync("/dev/tty", "w");
    writeSync(ttyFd, terminalTitleSequence(title));
  } catch {
    // Terminal title synchronization is best-effort and must not affect sessions.
  } finally {
    if (ttyFd !== undefined) closeSync(ttyFd);
  }
}
