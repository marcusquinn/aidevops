// ---------------------------------------------------------------------------
// Phase 4: Shell Environment
// Extracted from index.mjs (t1914) — shell env variable injection.
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { join } from "path";

/**
 * Read a file if it exists, or return empty string.
 * @param {string} filepath
 * @returns {string}
 */
function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

/**
 * Create the shell environment hook.
 * @param {object} deps - { agentsDir, scriptsDir, workspaceDir }
 * @returns {Function} Shell env hook function
 */
export function createShellEnvHook(deps) {
  const { agentsDir, scriptsDir, workspaceDir } = deps;

  /**
   * Inject aidevops environment variables into shell sessions.
   * @param {object} _input - { cwd }
   * @param {object} output - { env } (mutable)
   */
  return async function shellEnvHook(_input, output) {
    // Ensure aidevops scripts are on PATH
    if (existsSync(scriptsDir)) {
      const currentPath = output.env.PATH || process.env.PATH || "";
      if (!currentPath.includes(scriptsDir)) {
        output.env.PATH = `${scriptsDir}:${currentPath}`;
      }
    }

    // Set aidevops workspace directory
    output.env.AIDEVOPS_AGENTS_DIR = agentsDir;
    output.env.AIDEVOPS_WORKSPACE_DIR = workspaceDir;

    // Set aidevops version if available
    const version = readIfExists(join(agentsDir, "..", "version"));
    if (version) {
      output.env.AIDEVOPS_VERSION = version;
    }
  };
}
