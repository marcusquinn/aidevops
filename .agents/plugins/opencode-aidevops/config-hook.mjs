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

/**
 * Single source of truth for Claude model limits (GH#18621 Finding 5).
 * Both ANTHROPIC_MODELS and CLAUDECLI_MODELS derive their `limit` from here so
 * the transport metadata stays consistent no matter which provider
 * registration path runs first.
 */
const CLAUDE_MODEL_LIMITS = {
  "claude-haiku-4-5":  { context: 1000000, output: 32000 },
  "claude-sonnet-4-5": { context:  200000, output: 64000 },
  "claude-sonnet-4-6": { context: 1000000, output: 64000 },
  "claude-opus-4-5":   { context:  200000, output: 64000 },
  "claude-opus-4-6":   { context: 1000000, output: 64000 },
  // Opus 4.7 context intentionally capped at 200K (not the 1M API ceiling).
  // Anthropic's own MRCR v2 8-needle data shows long-context retrieval collapse:
  // 256K drops 91.9% -> 59.2%, 1M drops 78.3% -> 32.2%. Users opting into 4.7
  // should stay inside the still-functional window. See models-opus.md "Opus 4.7 (opt-in)".
  "claude-opus-4-7":   { context:  200000, output: 64000 },
};

/**
 * Build a provider model map from CLAUDE_MODEL_LIMITS with provider-specific
 * display names. Preserves backward compatibility with the previous
 * ANTHROPIC_MODELS / CLAUDECLI_MODELS shapes.
 * @param {Record<string,string>} names - model id → display name
 * @returns {Record<string,object>}
 */
function buildClaudeModelMap(names) {
  const out = {};
  for (const [id, limit] of Object.entries(CLAUDE_MODEL_LIMITS)) {
    out[id] = claudeModelDef({ name: names[id] || id, limit });
  }
  return out;
}

/** Models registered under the built-in anthropic provider (via aidevops OAuth pool). */
const ANTHROPIC_MODELS = buildClaudeModelMap({
  "claude-haiku-4-5":  "Claude Haiku 4.5 (via aidevops)",
  "claude-sonnet-4-5": "Claude Sonnet 4.5 (via aidevops)",
  "claude-sonnet-4-6": "Claude Sonnet 4.6 (via aidevops)",
  "claude-opus-4-5":   "Claude Opus 4.5 (via aidevops)",
  "claude-opus-4-6":   "Claude Opus 4.6 (via aidevops)",
  "claude-opus-4-7":   "Claude Opus 4.7 (via aidevops)",
});

/** Models registered under the claudecli provider (via Claude CLI proxy). */
const CLAUDECLI_MODELS = buildClaudeModelMap({
  "claude-haiku-4-5":  "Claude Haiku 4.5 (via CLI)",
  "claude-sonnet-4-5": "Claude Sonnet 4.5 (via CLI)",
  "claude-sonnet-4-6": "Claude Sonnet 4.6 (via CLI)",
  "claude-opus-4-5":   "Claude Opus 4.5 (via CLI)",
  "claude-opus-4-6":   "Claude Opus 4.6 (via CLI)",
  "claude-opus-4-7":   "Claude Opus 4.7 (via CLI)",
});

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
  } else if (
    config.provider.claudecli.name === "Claude CLI (coming soon)" ||
    config.provider.claudecli.name === "Claude CLI (via aidevops proxy)"
  ) {
    // Migrate legacy provider names
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
 * Register Claude CLI proxy models or clean up stale placeholder entries.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of models registered
 */
function registerClaudeCliModels(config) {
  const claudeProxyPort = getClaudeProxyPort();
  if (claudeProxyPort) {
    const claudeModels = Object.entries(CLAUDECLI_MODELS).map(([id, def]) => ({
      id,
      name: def.name,
      reasoning: def.reasoning !== false,
      contextWindow: def.limit?.context || 200000,
      maxTokens: def.limit?.output || 32000,
    }));
    return registerClaudeProvider(config, claudeProxyPort, claudeModels)
      ? claudeModels.length
      : 0;
  }
  // Proxy not running — remove placeholder entries so dead models don't show
  if (config.provider?.claudecli) {
    delete config.provider.claudecli;
  }
  return 0;
}

/**
 * Log a summary of config hook changes (silent when nothing changed).
 * @param {object} counts - { agents, mcps, agentTools, poolCleaned, anthropic, cursor, google, claude }
 * @param {string|null} versionDrift
 */
function logConfigSummary(counts, versionDrift) {
  const labels = [
    [counts.agents, "agents"],
    [counts.mcps, "MCPs"],
    [counts.agentTools, "agent tool perms"],
    [counts.poolCleaned, `cleaned ${counts.poolCleaned} stale pool provider${counts.poolCleaned === 1 ? "" : "s"}`],
    [counts.anthropic, "anthropic models"],
    [counts.cursor, "Cursor models"],
    [counts.google, "Google models"],
    [counts.claude, "Claude CLI models"],
  ];
  const parts = labels
    .filter(([n]) => n > 0)
    .map(([n, label]) => (typeof label === "string" && label.startsWith("cleaned")) ? label : `${n} ${label}`);

  if (parts.length > 0) {
    console.error(`[aidevops] Config hook: ${parts.join(", ")}`);
  }
  if (versionDrift) {
    console.error(`[aidevops] Version drift: ${versionDrift}`);
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

    const agents = registerAgents(config, agentsDir);
    ensureAgentGuard(config, workspaceDir);

    const mcps = registerMcpServers(config);
    const agentTools = applyAgentMcpTools(config);
    const poolCleaned = registerPoolProvider(config);
    const anthropic = registerAnthropicModels(config);

    // Discover and register proxy provider models
    const { getCursorModels } = await import("./cursor/models.js");
    const { discoverGoogleModels } = await import("./google-proxy.mjs");

    const cursor = await discoverAndRegisterModels({
      provider: "cursor",
      port: getCursorProxyPort(),
      discoverModels: getCursorModels,
      registerProvider: registerCursorProvider,
      config,
    });

    const google = await discoverAndRegisterModels({
      provider: "google",
      port: getGoogleProxyPort(),
      discoverModels: discoverGoogleModels,
      registerProvider: registerGoogleProvider,
      config,
    });

    const claude = registerClaudeCliModels(config);

    logConfigSummary(
      { agents, mcps, agentTools, poolCleaned, anthropic, cursor, google, claude },
      checkOpenCodeVersionDrift(pluginDir),
    );
  };
}
