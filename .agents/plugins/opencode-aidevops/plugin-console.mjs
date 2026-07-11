// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  renameSync,
  statSync,
} from "node:fs";
import { dirname } from "node:path";

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const MAX_ENTRY_LENGTH = 4000;
const CREDENTIAL_PATTERN =
  /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;

function formatArgument(arg) {
  if (arg instanceof Error) return arg.stack || arg.message;
  if (typeof arg === "string") return arg;
  try {
    return JSON.stringify(arg);
  } catch {
    return String(arg);
  }
}

function sanitizeEntry(args) {
  return args
    .map(formatArgument)
    .join(" ")
    .replace(CREDENTIAL_PATTERN, "$1[redacted-credential]")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ")
    .slice(0, MAX_ENTRY_LENGTH);
}

function appendDiagnostic(logPath, args) {
  mkdirSync(dirname(logPath), { recursive: true });
  if (existsSync(logPath) && statSync(logPath).size > MAX_LOG_BYTES) {
    renameSync(logPath, `${logPath}.1`);
  }
  appendFileSync(logPath, `[${new Date().toISOString()}] ${sanitizeEntry(args)}\n`);
}

/**
 * Route tagged aidevops diagnostics to a persistent log instead of OpenCode's
 * stderr-backed TUI. Untagged host errors retain their normal console path.
 * @param {{ consoleObject?: Console, logPath: string, debug?: boolean }} options
 * @returns {() => void}
 */
export function installPluginConsoleRouter(options) {
  const {
    consoleObject = console,
    logPath,
    debug = false,
  } = options;
  const originalError = consoleObject.error;

  consoleObject.error = (...args) => {
    const tagged = typeof args[0] === "string" && args[0].startsWith("[aidevops]");
    if (!tagged) {
      originalError.apply(consoleObject, args);
      return;
    }
    try {
      appendDiagnostic(logPath, args);
    } catch (error) {
      originalError.call(consoleObject, "aidevops diagnostic logging failed", error);
    }
    if (debug) originalError.apply(consoleObject, args);
  };

  return () => {
    consoleObject.error = originalError;
  };
}
