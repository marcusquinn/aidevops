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

/**
 * Create the shell environment hook.
 * @param {object} deps - { agentsDir, scriptsDir, workspaceDir, version? }
 * @returns {Function} Shell env hook function
 */
export function createShellEnvHook(deps) {
  const { agentsDir = "", scriptsDir = "", workspaceDir = "", version } = deps || {};
  const precomputedVersion = typeof version === "string" ? version.trim() : "";

  /**
   * Inject aidevops environment variables into shell sessions.
   * @param {object} input - { cwd, session/sessionID, model }
   * @param {object} output - { env } (mutable)
   */
  return async function shellEnvHook(input, output) {
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
    output.env.AIDEVOPS_SESSION_ORIGIN = shellSessionOrigin(output.env);

    // Set aidevops version if available. Prefer the deployed framework version
    // source; ~/.aidevops/version is a legacy/stale compatibility fallback.
    const version =
      precomputedVersion ||
      readIfExists(join(agentsDir, "VERSION")) ||
      readIfExists(join(agentsDir, "..", "VERSION")) ||
      readIfExists(join(agentsDir, "..", "version"));
    if (version) {
      output.env.AIDEVOPS_VERSION = version;
    }

    // Signature helpers need the current OpenCode session, not a session guessed
    // from the long-lived app process start time (GH#22003). OpenCode hook input
    // has changed shape across releases, so accept the known variants and keep
    // this best-effort: absence should not block shell startup.
    const sessionId = getSessionId(input);
    if (sessionId && !output.env.OPENCODE_SESSION_ID) {
      output.env.OPENCODE_SESSION_ID = sessionId;
    }

    const modelId = getModelId(input);
    if (modelId && !output.env.AIDEVOPS_SIG_MODEL) {
      output.env.AIDEVOPS_SIG_MODEL = modelId;
    }

    // OTEL env passthrough (t2177) — propagate OpenTelemetry config so
    // subprocesses spawned by opencode (headless workers, helper scripts,
    // nested shells) inherit the same trace endpoint. opencode itself reads
    // these from its own process.env; we forward them to shell subprocesses
    // which otherwise wouldn't see them across the Bun→Node→bash boundary.
    // No-op when the user hasn't configured OTEL.
    const OTEL_VARS = [
      "OTEL_EXPORTER_OTLP_ENDPOINT",
      "OTEL_EXPORTER_OTLP_HEADERS",
      "OTEL_EXPORTER_OTLP_PROTOCOL",
      "OTEL_SERVICE_NAME",
      "OTEL_RESOURCE_ATTRIBUTES",
    ];
    for (const key of OTEL_VARS) {
      const value = process.env[key];
      if (value && !output.env[key]) {
        output.env[key] = value;
      }
    }
  };
}
