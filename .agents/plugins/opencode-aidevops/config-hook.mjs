// ---------------------------------------------------------------------------
// Config Hook — agent registration, MCP setup, provider cleanup
// Extracted from index.mjs (t1914).
// ---------------------------------------------------------------------------

import { existsSync, readFileSync, appendFileSync } from "fs";
import { join } from "path";
import { loadAgentIndex, applyAgentMcpTools } from "./agent-loader.mjs";
import { registerMcpServers } from "./mcp-registry.mjs";
import { registerPoolProvider, getAccounts, ensureValidToken } from "./oauth-pool.mjs";
import { getCursorProxyPort, registerCursorProvider } from "./cursor-proxy.mjs";
import { getGoogleProxyPort, registerGoogleProvider } from "./google-proxy.mjs";
import { checkOpenCodeVersionDrift } from "./version-tracking.mjs";

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
 * Discover models for a proxy provider and register them in config.
 * Deduplicates the cursor/google model discovery pattern.
 * @param {object} opts
 * @param {string} opts.provider - Pool provider name ("cursor" | "google")
 * @param {number} opts.port - Proxy port
 * @param {Function} opts.discoverModels - async (token) => models[]
 * @param {Function} opts.registerProvider - (config, port, models) => boolean
 * @param {object} opts.config - OpenCode Config object (mutable)
 * @returns {Promise<number>} Number of models registered
 */
async function discoverAndRegisterModels(opts) {
  const { provider, port, discoverModels, registerProvider, config } = opts;
  if (!port) return 0;

  try {
    const accounts = getAccounts(provider);
    const account = accounts.find((a) => a.status === "active");
    const token = account ? await ensureValidToken(provider, account) : null;
    const models = token ? await discoverModels(token) : [];

    if (models.length > 0 && registerProvider(config, port, models)) {
      return models.length;
    }
  } catch (err) {
    console.error(`[aidevops] Config hook: ${provider} model registration failed: ${err.message}`);
  }
  return 0;
}

/**
 * Register agents from the pre-built index into config.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {string} agentsDir
 * @returns {number} Number of agents injected
 */
function registerAgents(config, agentsDir) {
  const indexAgents = loadAgentIndex(agentsDir, readIfExists);
  let injected = 0;

  for (const agent of indexAgents) {
    if (config.agent[agent.name]) continue;
    config.agent[agent.name] = {
      description: agent.description,
      mode: "subagent",
    };
    injected++;
  }
  return injected;
}

/**
 * Ensure at least one agent is enabled (prevents OpenCode crash).
 * @param {object} config - OpenCode Config object (mutable)
 * @param {string} workspaceDir
 */
function ensureAgentGuard(config, workspaceDir) {
  const enabledAgents = Object.entries(config.agent).filter(
    ([, v]) => !v.disable,
  );
  if (enabledAgents.length > 0) return;

  if (config.agent.build) {
    delete config.agent.build.disable;
  } else {
    config.agent.build = { description: "Default coding agent" };
  }
  const logPath = join(workspaceDir, "tmp", "plugin-warnings.log");
  try {
    appendFileSync(
      logPath,
      `[${new Date().toISOString()}] WARN: All agents disabled — re-enabled 'build' as fallback to prevent crash\n`,
    );
  } catch {
    // best-effort logging
  }
}

/**
 * Create the config hook function.
 * @param {object} deps - { agentsDir, workspaceDir, pluginDir }
 * @returns {Function} Config hook
 */
export function createConfigHook(deps) {
  const { agentsDir, workspaceDir, pluginDir } = deps;

  /**
   * Modify OpenCode config to register aidevops subagents, MCP servers,
   * and per-agent tool permissions.
   * @param {object} config - OpenCode Config object (mutable)
   */
  return async function configHook(config) {
    if (!config.agent) config.agent = {};

    const agentsInjected = registerAgents(config, agentsDir);
    ensureAgentGuard(config, workspaceDir);

    const mcpsRegistered = registerMcpServers(config);
    const agentToolsUpdated = applyAgentMcpTools(config);
    const poolCleaned = registerPoolProvider(config);

    // Discover and register proxy provider models
    const { getCursorModels } = await import("./cursor/models.js");
    const { discoverGoogleModels } = await import("./google-proxy.mjs");

    const cursorModelsRegistered = await discoverAndRegisterModels({
      provider: "cursor",
      port: getCursorProxyPort(),
      discoverModels: getCursorModels,
      registerProvider: registerCursorProvider,
      config,
    });

    const googleModelsRegistered = await discoverAndRegisterModels({
      provider: "google",
      port: getGoogleProxyPort(),
      discoverModels: discoverGoogleModels,
      registerProvider: registerGoogleProvider,
      config,
    });

    const versionDrift = checkOpenCodeVersionDrift(pluginDir);

    // Silent unless something was actually changed
    const parts = [];
    if (agentsInjected > 0) parts.push(`${agentsInjected} agents`);
    if (mcpsRegistered > 0) parts.push(`${mcpsRegistered} MCPs`);
    if (agentToolsUpdated > 0) parts.push(`${agentToolsUpdated} agent tool perms`);
    if (poolCleaned > 0) parts.push(`cleaned ${poolCleaned} stale pool provider${poolCleaned === 1 ? "" : "s"}`);
    if (cursorModelsRegistered > 0) parts.push(`${cursorModelsRegistered} Cursor models`);
    if (googleModelsRegistered > 0) parts.push(`${googleModelsRegistered} Google models`);

    if (parts.length > 0) {
      console.error(`[aidevops] Config hook: ${parts.join(", ")}`);
    }

    if (versionDrift) {
      console.error(`[aidevops] Version drift: ${versionDrift}`);
    }
  };
}
