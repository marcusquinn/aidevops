// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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
 * Return true when the agents directory is usable for deterministic framework
 * file lookups.
 * @param {string} value
 * @returns {boolean}
 */
function hasAgentsDir(value) {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * Extract the current OpenCode session ID from hook input variants.
 * @param {object} input
 * @returns {string}
 */
function getSessionId(input) {
  const candidates = [input?.session?.id, input?.sessionID, input?.session_id, input?.id];
  return candidates.find((value) => value) || "";
}

/**
 * Extract the current model ID from hook input variants.
 * @param {object} input
 * @returns {string}
 */
function getModelId(input) {
  const provider = input?.model?.providerID || "";
  const model = input?.model?.modelID || input?.modelID || input?.model || "";

  if (provider && model && typeof model === "string" && !model.includes("/")) {
    return `${provider}/${model}`;
  }
  return typeof model === "string" ? model : "";
}

/**
 * Env vars that mark a shell as headless worker context. Shell commands run by
 * an interactive OpenCode TUI may inherit stale worker-origin env from a parent
 * process; the plugin must stamp the intended session origin explicitly so
 * issue/PR creation helpers do not mislabel maintainer-directed work.
 */
const HEADLESS_ENV_VARS = [
  "FULL_LOOP_HEADLESS",
  "AIDEVOPS_HEADLESS",
  "OPENCODE_HEADLESS",
  "GITHUB_ACTIONS",
];

const WORKER_LINEAGE_ENV_VARS = [
  "AIDEVOPS_WORKER_ID",
  "AIDEVOPS_PARENT_WORKER_ID",
  "AIDEVOPS_ROOT_WORKER_ID",
  "AIDEVOPS_CORRELATION_ID",
  "AIDEVOPS_CAUSATION_ID",
  "AIDEVOPS_PARENT_EVENT_ID",
  "AIDEVOPS_ROOT_EVENT_ID",
];

const OTEL_ENV_VARS = [
  "OTEL_EXPORTER_OTLP_ENDPOINT",
  "OTEL_EXPORTER_OTLP_HEADERS",
  "OTEL_EXPORTER_OTLP_PROTOCOL",
  "OTEL_SERVICE_NAME",
  "OTEL_RESOURCE_ATTRIBUTES",
];

/**
 * @param {string | undefined} value
 * @returns {boolean}
 */
function isTruthyEnv(value) {
  return !!value && value !== "0" && value !== "false";
}

/**
 * Determine the origin label intent for shell subprocesses.
 * @param {object} env
 * @returns {"worker" | "interactive"}
 */
function shellSessionOrigin(env) {
  const headless = HEADLESS_ENV_VARS.some((key) =>
    isTruthyEnv(env?.[key] || process.env[key]),
  );
  return headless ? "worker" : "interactive";
}

function prependScriptsPath(env, scriptsDir) {
  if (!existsSync(scriptsDir)) return;
  const currentPath = env.PATH || process.env.PATH || "";
  const pathParts = currentPath.split(":").filter((part) => part && part !== scriptsDir);
  env.PATH = [scriptsDir, ...pathParts].join(":");
}

function projectWorkerLineage(env) {
  const sessionOrigin = shellSessionOrigin(env);
  env.AIDEVOPS_SESSION_ORIGIN = sessionOrigin;
  for (const key of WORKER_LINEAGE_ENV_VARS) {
    if (sessionOrigin !== "worker") {
      delete env[key];
    } else if (!env[key] && process.env[key]) {
      env[key] = process.env[key];
    }
  }
}

function resolveVersion({ activeAgentsDir, agentsDir, precomputedVersion }) {
  if (precomputedVersion) return precomputedVersion;
  const activeVersion = hasAgentsDir(activeAgentsDir)
    ? readIfExists(join(activeAgentsDir, "VERSION"))
    : "";
  if (activeVersion || !hasAgentsDir(agentsDir)) return activeVersion;
  return readIfExists(join(agentsDir, "VERSION")) ||
    readIfExists(join(agentsDir, "..", "VERSION")) ||
    readIfExists(join(agentsDir, "..", "version"));
}

function projectFrameworkEnvironment(env, config) {
  env.AIDEVOPS_AGENTS_DIR = config.agentsDir;
  if (hasAgentsDir(config.activeAgentsDir)) {
    env.AIDEVOPS_ACTIVE_AGENTS_DIR = config.activeAgentsDir;
  }
  env.AIDEVOPS_WORKSPACE_DIR = config.workspaceDir;
  projectWorkerLineage(env);

  const version = resolveVersion(config);
  if (version) env.AIDEVOPS_VERSION = version;
}

function projectSessionIdentity(input, env) {
  const sessionId = getSessionId(input);
  if (sessionId) {
    env.OPENCODE_SESSION_ID = sessionId;
    env.AIDEVOPS_OPENCODE_SESSION_ID = sessionId;
  }

  const modelId = getModelId(input);
  if (modelId && !env.AIDEVOPS_SIG_MODEL) env.AIDEVOPS_SIG_MODEL = modelId;
}

function projectOtelEnvironment(env) {
  for (const key of OTEL_ENV_VARS) {
    const value = process.env[key];
    if (value && !env[key]) env[key] = value;
  }
}

function normalizeDependencies(deps) {
  const {
    activeAgentsDir = "",
    agentsDir = "",
    scriptsDir = "",
    workspaceDir = "",
    version,
  } = deps || {};
  return {
    activeAgentsDir,
    agentsDir,
    scriptsDir,
    workspaceDir,
    precomputedVersion: typeof version === "string" ? version.trim() : "",
  };
}

async function shellEnvHook(config, input, output) {
  prependScriptsPath(output.env, config.scriptsDir);
  projectFrameworkEnvironment(output.env, config);
  projectSessionIdentity(input, output.env);
  projectOtelEnvironment(output.env);
}

/**
 * Create the shell environment hook.
 * @param {object} deps - { activeAgentsDir?, agentsDir, scriptsDir, workspaceDir, version? }
 * @returns {Function} Shell env hook function
 */
export function createShellEnvHook(deps) {
  return shellEnvHook.bind(null, normalizeDependencies(deps));
}
