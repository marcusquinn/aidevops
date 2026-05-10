// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Terminal title helpers for OpenCode tools.
//
// The shell-side terminal-title-helper.sh updates Tabby/iTerm/etc. when a
// normal shell hook runs. OpenCode session-rename tools bypass that shell hook
// and write the session title directly to SQLite, so they must emit OSC 0
// themselves to keep the terminal/tab title in sync.

import { closeSync, openSync, writeSync } from "node:fs"

const OSC_TITLE_PREFIX = "\u001B]0;"
const OSC_TITLE_SUFFIX = "\u0007"

type TerminalTitleEnv = Record<string, string | undefined>

/**
 * Honour the same opt-out environment variables as terminal-title-helper.sh.
 */
export function isTerminalTitleEnabled(env: TerminalTitleEnv = process.env): boolean {
  return env.TERMINAL_TITLE_ENABLED !== "false" && env.AIDEVOPS_TABBY_ENABLED !== "false"
}

/**
 * Remove C0 control characters so arbitrary LLM/session titles cannot inject
 * extra terminal control sequences into the OSC payload.
 */
export function sanitizeTerminalTitle(title: string): string {
  return title.replace(/[\x00-\x1F\x7F]+/g, " ").trim()
}

/**
 * Build an OSC 0 title sequence for terminals such as Tabby.
 */
export function terminalTitleSequence(title: string): string {
  const sanitizedTitle = sanitizeTerminalTitle(title)
  if (!sanitizedTitle) {
    return ""
  }
  return `${OSC_TITLE_PREFIX}${sanitizedTitle}${OSC_TITLE_SUFFIX}`
}

/**
 * Best-effort terminal title update. Prefer /dev/tty so the sequence reaches
 * the controlling terminal even if a tool framework captures stdout; fall back
 * to stderr for runtimes where /dev/tty is unavailable so tool return payloads
 * are not polluted with terminal control sequences.
 */
export function emitTerminalTitle(title: string): boolean {
  if (!isTerminalTitleEnabled()) {
    return false
  }

  const sequence = terminalTitleSequence(title)
  if (!sequence) {
    return false
  }

  try {
    const fd = openSync("/dev/tty", "w")
    try {
      writeSync(fd, sequence)
      return true
    } finally {
      closeSync(fd)
    }
  } catch {
    try {
      return process.stderr.write(sequence)
    } catch {
      return false
    }
  }
}
