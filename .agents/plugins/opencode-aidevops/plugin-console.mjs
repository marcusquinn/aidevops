// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Decide whether a plugin console.error call is diagnostic text that should be
 * hidden from OpenCode's stderr-backed TUI. Payload words are deliberately not
 * interpreted as severity: commands and file paths may contain words such as
 * "failure" without representing a plugin error.
 * @param {unknown[]} args
 * @param {boolean} debug
 * @returns {boolean}
 */
export function shouldSuppressPluginConsole(args, debug) {
  if (debug || args.some((arg) => arg instanceof Error)) return false;
  return typeof args[0] === "string" && args[0].startsWith("[aidevops]");
}

/**
 * Keep tagged plugin diagnostics out of the TUI unless debug logging is
 * explicitly enabled. Returns a restore function for isolated tests.
 * @param {Console} [consoleObject]
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {() => void}
 */
export function installPluginConsoleGuard(consoleObject = console, env = process.env) {
  const originalError = consoleObject.error;
  const debug = env.AIDEVOPS_PLUGIN_DEBUG === "1";
  consoleObject.error = (...args) => {
    if (shouldSuppressPluginConsole(args, debug)) return;
    originalError.apply(consoleObject, args);
  };
  return () => {
    consoleObject.error = originalError;
  };
}
