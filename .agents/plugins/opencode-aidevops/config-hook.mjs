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
import { getClaudeProxyPort, registerClaudeProvider } from "./claude-proxy.mjs";
import { checkOpenCodeVersionDrift } from "./version-tracking.mjs";

/**
 * Shared model definition template for Claude models managed by aidevops.
 * @param {object} overrides
 * @returns {object}
 */
function claudeModelDef(overrides) {
  return {
    attachment: true,
    tool_call: false,
    temperature: true,
    reasoning: true,
    modalities: { input: ["text", "image"], output: ["text"] },
    cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
    ...overrides,
  };
}

// Context window and output token limits. 1M context requires the
// `context-1m-2025-08-07` beta header — injected automatically by
// provider-auth.mjs REQUIRED_BETAS. Sonnet/Opus cap output at 64K;
// Haiku caps output at 32K.
const CONTEXT_1M = 1000000;
const OUTPUT_64K = 64000;
const OUTPUT_32K = 32000;

/** Models registered under the built-in anthropic provider (via aidevops OAuth pool). */
const ANTHROPIC_MODELS = {
  "claude-haiku-4-5": claudeModelDef({
    name: "Claude Haiku 4.5 (via aidevops)",
    limit: { context: CONTEXT_1M, output: OUTPUT_32K },
  }),
  "claude-sonnet-4-6": claudeModelDef({
    name: "Claude Sonnet 4.6 (via aidevops)",
    limit: { context: CONTEXT_1M, output: OUTPUT_64K },
  }),
  "claude-opus-4-6": claudeModelDef({
    name: "Claude Opus 4.6 (via aidevops)",
    limit: { context: CONTEXT_1M, output: OUTPUT_64K },
  }),
};

/** Models registered under the claudecli provider (via Claude CLI proxy). */
const CLAUDECLI_MODELS = {
  "claude-haiku-4-5": claudeModelDef({
    name: "Claude Haiku 4.5 (via CLI)",
    limit: { context: CONTEXT_1M, output: OUTPUT_32K },
  }),
  "claude-sonnet-4-6": claudeModelDef({
    name: "Claude Sonnet 4.6 (via CLI)",
    limit: { context: CONTEXT_1M, output: OUTPUT_64K },
  }),
  "claude-opus-4-6": claudeModelDef({
    name: "Claude Opus 4.6 (via CLI)",
    limit: { context: CONTEXT_1M, output: OUTPUT_64K },
  }),
};

/**
 * Upsert aidevops-managed models into the anthropic and claudecli providers.
 * Preserves any user options already set on the providers.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} number of model entries upserted
 */
function registerAnthropicModels(config) {
  if (!config.provider) config.provider = {};
  let count = 0;

  // anthropic provider — via aidevops OAuth pool
  if (!config.provider.anthropic) config.provider.anthropic = {};
  if (!config.provider.anthropic.models) config.provider.anthropic.models = {};
  for (const [id, def] of Object.entries(ANTHROPIC_MODELS)) {
    const existing = config.provider.anthropic.models[id];
    // Always merge — ensures stale fields (modalities, attachment) get updated
    config.provider.anthropic.models[id] = { ...existing, ...def };
    if (!existing) count++;
  }

  // claudecli provider — via Claude CLI proxy
  if (!config.provider.claudecli) {
    config.provider.claudecli = {
      name: "Claude CLI",
      npm: "@ai-sdk/openai-compatible",
      api: "http://127.0.0.1:32125/v1",
    };
  } else if (config.provider.claudecli.name === "Claude CLI (coming soon)") {
    // Migrate legacy provider name
    config.provider.claudecli.name = "Claude CLI";
  }
  if (!config.provider.claudecli.models) config.provider.claudecli.models = {};
  for (const [id, def] of Object.entries(CLAUDECLI_MODELS)) {
    const existing = config.provider.claudecli.models[id];
    // Always merge — ensures stale fields (modalities, attachment) get updated
    config.provider.claudecli.models[id] = { ...existing, ...def };
    if (!existing) count++;
  }

  return count;
}

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
    const anthropicModelsRegistered = registerAnthropicModels(config);

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

    // Claude CLI transport proxy — registers the `claudecli` provider with the
    // local proxy base URL. Derives models from CLAUDECLI_MODELS to avoid drift.
    // When proxy is not running, removes placeholder entries to avoid dead models.
    const claudeProxyPort = getClaudeProxyPort();
    let claudeModelsRegistered = 0;
    if (claudeProxyPort) {
      const claudeModels = Object.entries(CLAUDECLI_MODELS).map(([id, def]) => ({
        id,
        name: def.name,
        reasoning: def.reasoning !== false,
        contextWindow: def.limit?.context || 200000,
        maxTokens: def.limit?.output || 32000,
      }));
      claudeModelsRegistered = registerClaudeProvider(config, claudeProxyPort, claudeModels)
        ? claudeModels.length
        : 0;
    } else if (config.provider?.claudecli) {
      // Proxy not running — remove placeholder entries so dead models don't show
      delete config.provider.claudecli;
    }

    const versionDrift = checkOpenCodeVersionDrift(pluginDir);

    // Silent unless something was actually changed
    const parts = [];
    if (agentsInjected > 0) parts.push(`${agentsInjected} agents`);
    if (mcpsRegistered > 0) parts.push(`${mcpsRegistered} MCPs`);
    if (agentToolsUpdated > 0) parts.push(`${agentToolsUpdated} agent tool perms`);
    if (poolCleaned > 0) parts.push(`cleaned ${poolCleaned} stale pool provider${poolCleaned === 1 ? "" : "s"}`);
    if (anthropicModelsRegistered > 0) parts.push(`${anthropicModelsRegistered} anthropic models`);
    if (cursorModelsRegistered > 0) parts.push(`${cursorModelsRegistered} Cursor models`);
    if (googleModelsRegistered > 0) parts.push(`${googleModelsRegistered} Google models`);
    if (claudeModelsRegistered > 0) parts.push(`${claudeModelsRegistered} Claude CLI models`);

    if (parts.length > 0) {
      console.error(`[aidevops] Config hook: ${parts.join(", ")}`);
    }

    if (versionDrift) {
      console.error(`[aidevops] Version drift: ${versionDrift}`);
    }
  };
}
