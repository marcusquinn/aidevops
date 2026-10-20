// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * True when `moduleUrl` is the script Node was asked to run.
 *
 * Deployed scripts are reached through `~/.aidevops/agents`, a symlink into a
 * runtime bundle. Node resolves `import.meta.url` to the real bundle path while
 * `process.argv[1]` keeps the symlinked path, so both sides must be resolved
 * before comparison. Unresolvable paths are never treated as the entrypoint.
 */
export function isDirectEntrypoint(moduleUrl, argvPath = process.argv[1]) {
  if (!argvPath) return false;
  try {
    return realpathSync(argvPath) === realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}
