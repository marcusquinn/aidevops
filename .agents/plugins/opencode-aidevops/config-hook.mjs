// ---------------------------------------------------------------------------
// Config Hook — agent registration, MCP setup, provider cleanup
// Extracted from index.mjs (t1914).
// ---------------------------------------------------------------------------

import { existsSync, readFileSync, appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { execFileSync } from "child_process";
import { createHash } from "crypto";
import { loadAgentIndex, applyAgentMcpTools } from "./agent-loader.mjs";
import { registerMcpServers } from "./mcp-registry.mjs";
import { registerPoolProvider, getAccounts, ensureValidToken } from "./oauth-pool.mjs";
import { getCursorProxyPort, registerCursorProvider } from "./cursor-proxy.mjs";
import { getGoogleProxyPort, registerGoogleProvider } from "./google-proxy.mjs";
import { getClaudeProxyPort, registerClaudeProvider } from "./claude-proxy.mjs";
import { checkOpenCodeVersionDriftAsync } from "./version-tracking.mjs";
import {
  CLAUDE_MODEL_LIMITS,
  GPT56_CONTEXT_DEFAULT,
  GPT56_INPUT_DEFAULT,
  GPT56_MODEL_IDS,
  GPT56_OUTPUT_DEFAULT,
} from "./model-limits.mjs";

const MANAGED_EXTERNAL_DIRECTORIES = [
  "~/.aidevops",
  "~/.aidevops/**",
  "~/.config/aidevops",
  "~/.config/aidevops/**",
  "~/.config/opencode/command",
  "~/.config/opencode/command/**",
  "~/Git/_worktrees",
  "~/Git/_worktrees/**",
];

const PATTERN_CAPABLE_PERMISSIONS = new Set(["bash", "external_directory"]);
const FORBIDDEN_GRANT_PATTERN = /(?:approval-keys\/private|\/(?:\.ssh|\.gnupg|\.aws|\.azure|\.kube)(?:\/|$)|\/(?:\.config\/(?:gh|gcloud|glab-cli|hub)|\.docker)(?:\/|$)|\/(?:\.netrc|\.npmrc|\.pypirc|\.git-credentials)(?:$|\*)|auth\.json(?:$|\*)|credentials?(?:\.|\/|$)|(?:^|\/)\.env(?:\.|$|\/))/i;
const UNBOUNDED_GRANT_PATTERN = /^(?:\*|\*\*|\/\*\*|~\/\*\*|\$WORKTREE\/\*\*)$/;
const MAX_PERMISSION_GRANT_MS = 4 * 60 * 60 * 1000;

/**
 * Allow OpenCode to use aidevops-managed state and linked worktrees without
 * repeatedly asking for external-directory approval. Keep the exception
 * narrow: unrelated paths retain the user's existing permission policy.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} number of managed allow rules added or corrected
 */
function addManagedDirectoryRules(target) {
  if (typeof target.permission === "string") {
    const defaultPermission = target.permission;
    target.permission = {
      "*": defaultPermission,
      external_directory: { "*": defaultPermission },
    };
  } else if (!target.permission) {
    target.permission = {};
  }

  const existing = target.permission.external_directory;
  if (existing === "allow") return 0;

  const rules = typeof existing === "string"
    ? { "*": existing }
    : { ...existing };
  let count = 0;
  for (const path of MANAGED_EXTERNAL_DIRECTORIES) {
    if (rules[path] !== "allow") count++;
    // OpenCode uses the last matching rule, so managed exceptions must follow
    // broad user defaults such as `"*": "ask"`.
    delete rules[path];
    rules[path] = "allow";
  }
  target.permission.external_directory = rules;
  return count;
}

export function registerManagedDirectoryPermissions(config) {
  let count = addManagedDirectoryRules(config);
  for (const agent of Object.values(config.agent || {})) {
    count += addManagedDirectoryRules(agent);
  }
  return count;
}

function readPermissionGrantFile(grantPath) {
  try {
    return JSON.parse(readFileSync(grantPath, "utf8"));
  } catch {
    return null;
  }
}

function parsePermissionGrantPayload(payload) {
  try {
    return JSON.parse(payload);
  } catch {
    return null;
  }
}

function verifyPermissionGrantSignature(grant, publicKey, tempBase) {
  let verifyDir = "";
  let verified = false;
  try {
    mkdirSync(tempBase, { recursive: true });
    verifyDir = mkdtempSync(join(tempBase, "permission-grant-"));
    const signaturePath = join(verifyDir, "signature");
    const signersPath = join(verifyDir, "allowed-signers");
    writeFileSync(signaturePath, grant.signature, { mode: 0o600 });
    const key = readFileSync(publicKey, "utf8").trim();
    writeFileSync(signersPath, `approval@aidevops.sh namespaces="aidevops-approve" ${key}\n`, { mode: 0o600 });
    execFileSync("ssh-keygen", [
      "-Y", "verify", "-f", signersPath, "-I", "approval@aidevops.sh",
      "-n", "aidevops-approve", "-s", signaturePath,
    ], { input: grant.payload, stdio: ["pipe", "ignore", "ignore"] });
    verified = true;
  } catch {
    verified = false;
  } finally {
    if (verifyDir) {
      try {
        rmSync(verifyDir, { recursive: true, force: true });
      } catch {
        // Verification already completed; temporary cleanup remains best effort.
      }
    }
  }
  return verified;
}

function verifyPermissionGrant(grantPath, options = {}) {
  if (!grantPath || !existsSync(grantPath)) return null;
  const publicKey = options.publicKey || join(homedir(), ".aidevops", "approval-keys", "approval.pub");
  if (!existsSync(publicKey)) return null;
  const grant = readPermissionGrantFile(grantPath);
  if (typeof grant?.payload !== "string" || typeof grant?.signature !== "string") return null;
  const tempBase = options.tempBase || process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  if (!verifyPermissionGrantSignature(grant, publicKey, tempBase)) return null;
  return parsePermissionGrantPayload(grant.payload);
}

function ensurePermissionMap(target) {
  if (typeof target.permission === "string") {
    const fallback = target.permission;
    target.permission = { "*": fallback, external_directory: { "*": fallback } };
  } else if (!target.permission) {
    target.permission = {};
  }
}

function addApprovedCapabilityRule(target, capability) {
  const permission = capability.permission;
  const patterns = Array.isArray(capability.patterns) ? capability.patterns : [];
  if (!PATTERN_CAPABLE_PERMISSIONS.has(permission) || patterns.length === 0) return 0;
  const existing = target.permission[permission];
  if (existing === "allow") return 0;
  const rules = typeof existing === "string" ? { "*": existing } : { ...existing };
  let count = 0;
  for (const pattern of patterns) {
    if (typeof pattern !== "string" || pattern.length === 0 || pattern.length > 500) continue;
    delete rules[pattern];
    rules[pattern] = "allow";
    count++;
  }
  target.permission[permission] = rules;
  return count;
}

function addApprovedCapabilityRules(target, capabilities) {
  ensurePermissionMap(target);
  let count = 0;
  for (const capability of capabilities) {
    count += addApprovedCapabilityRule(target, capability);
  }
  return count;
}

function permissionGrantTargetMatches(grant) {
  if (grant?.schema !== "aidevops-permission-grant/v1") return false;
  if (grant.authority !== "worker-permissions") return false;
  const issue = String(process.env.WORKER_ISSUE_NUMBER || "");
  const repo = String(process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "").toLowerCase();
  if (String(grant.target?.number || "") !== issue) return false;
  return String(grant.target?.repository || "").toLowerCase() === repo;
}

function permissionGrantTimeValid(grant) {
  const issued = Date.parse(grant.issued_at || "");
  const expires = Date.parse(grant.expires_at || "");
  const now = Date.now();
  if (!Number.isFinite(issued) || !Number.isFinite(expires)) return false;
  if (issued > now + 5 * 60 * 1000 || expires <= now) return false;
  return expires > issued && expires - issued <= MAX_PERMISSION_GRANT_MS;
}

function permissionGrantRequestValid(grant) {
  if (!/^perm-[0-9a-f]{16}$/.test(grant.request_id || "")) return false;
  return /^[0-9a-f]{64}$/.test(grant.request_sha256 || "");
}

function currentWorkerBranch(options, repositoryDir) {
  if (options.currentBranch !== undefined) return options.currentBranch;
  try {
    return execFileSync("git", ["-C", repositoryDir, "branch", "--show-current"], { encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

function permissionGrantBranchMatches(grantBranch, currentBranch) {
  if (typeof currentBranch !== "string" || currentBranch.length === 0) return false;
  if (typeof grantBranch !== "string" || grantBranch.length === 0) return false;
  return grantBranch === currentBranch;
}

function permissionGrantWorkerMatches(grant, options) {
  const pendingRequest = String(options.pendingRequest || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || "");
  if (!pendingRequest || grant.request_id !== pendingRequest) return false;
  const repositoryDir = String(options.repositoryDir || "");
  if (!repositoryDir) return false;
  const expectedWorktree = createHash("sha256").update(repositoryDir).digest("hex");
  if (grant.worker?.worktree_sha256 !== expectedWorktree) return false;
  const currentSession = String(options.currentSession || process.env.WORKER_SESSION_KEY || "");
  if (!currentSession || grant.worker?.session !== currentSession) return false;
  const currentBranch = currentWorkerBranch(options, repositoryDir);
  return permissionGrantBranchMatches(grant.worker?.branch, currentBranch);
}

function permissionGrantPatternSafe(pattern) {
  if (typeof pattern !== "string") return false;
  if (pattern.length === 0 || pattern.length > 500) return false;
  if (FORBIDDEN_GRANT_PATTERN.test(pattern)) return false;
  return !UNBOUNDED_GRANT_PATTERN.test(pattern);
}

function permissionGrantCapabilitySafe(item) {
  if (item?.risk?.grantable !== true) return false;
  if (!PATTERN_CAPABLE_PERMISSIONS.has(item?.permission || "")) return false;
  if (!Array.isArray(item.patterns)) return false;
  if (item.patterns.length === 0 || item.patterns.length > 20) return false;
  return item.patterns.every(permissionGrantPatternSafe);
}

function permissionGrantCapabilitiesSafe(grant) {
  if (!Array.isArray(grant.capabilities)) return false;
  if (grant.capabilities.length === 0 || grant.capabilities.length > 20) return false;
  return grant.capabilities.every(permissionGrantCapabilitySafe);
}

function permissionGrantUsable(grant, options) {
  const checks = [
    permissionGrantTargetMatches(grant),
    permissionGrantTimeValid(grant),
    permissionGrantRequestValid(grant),
    permissionGrantWorkerMatches(grant, options),
    permissionGrantCapabilitiesSafe(grant),
  ];
  return checks.every(Boolean);
}

export function registerApprovedWorkerPermissions(config, options = {}) {
  const grantPath = options.grantPath || process.env.AIDEVOPS_PERMISSION_GRANT_FILE || "";
  const grant = verifyPermissionGrant(grantPath, options);
  if (!grant || !permissionGrantUsable(grant, options)) return 0;
  let count = addApprovedCapabilityRules(config, grant.capabilities);
  for (const agent of Object.values(config.agent || {})) {
    count += addApprovedCapabilityRules(agent, grant.capabilities);
  }
  return count;
}

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
 * Build a provider model map from CLAUDE_MODEL_LIMITS with provider-specific
 * display names. Preserves backward compatibility with the previous
 * ANTHROPIC_MODELS / CLAUDECLI_MODELS shapes.
 *
 * Note: CLAUDE_MODEL_LIMITS lives in `model-limits.mjs` so claude-proxy.mjs
 * (the Claude CLI proxy provider drift-copy that previously hardcoded the
 * same numbers) can share it. See model-limits.mjs for the env-var override
 * (AIDEVOPS_OPUS_47_CONTEXT) and the MRCR rationale.
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
 * Return whether aidevops should advertise a cost-aware 300K GPT-5.6 window.
 * The feature defaults on; users can opt out with `aidevops gpt56-context
 * disable`, which writes the durable preference consumed here on startup.
 * @returns {boolean}
 */
export function gpt56ContextCapEnabled() {
  const settingsPath = process.env.AIDEVOPS_SETTINGS_FILE ||
    join(homedir(), ".config", "aidevops", "settings.json");
  try {
    if (!existsSync(settingsPath)) return true;
    const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
    return settings?.runtime?.opencode?.gpt56_context_cap !== false;
  } catch {
    return true;
  }
}

/**
 * Override built-in OpenAI GPT-5.6 model metadata without replacing any other
 * model fields. OpenCode validates plugin-added model entries before merging
 * built-in registry metadata, so every limit must include required fields.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} number of model limits applied
 */
export function registerGpt56ContextLimits(config) {
  if (!gpt56ContextCapEnabled()) return 0;
  if (!config.provider) config.provider = {};
  if (!config.provider.openai) config.provider.openai = {};
  if (!config.provider.openai.models) config.provider.openai.models = {};

  for (const id of GPT56_MODEL_IDS) {
    const existing = config.provider.openai.models[id] || {};
    config.provider.openai.models[id] = {
      ...existing,
      limit: {
        output: GPT56_OUTPUT_DEFAULT,
        ...existing.limit,
        context: GPT56_CONTEXT_DEFAULT,
        input: GPT56_INPUT_DEFAULT,
      },
    };
  }
  return GPT56_MODEL_IDS.length;
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
 * Register Claude CLI proxy models when the proxy is already running.
 *
 * When the proxy is NOT yet running (lazy-start path, GH#21944), the
 * `claudecli` provider entry was already eagerly registered by
 * `registerAnthropicModels` above with the hardcoded default port — leave
 * it intact so the models stay visible in the picker. The proxy will be
 * brought up by the system.transform hook on the first claudecli/* request.
 *
 * Historical behaviour deleted the entry when the proxy was absent, which
 * worked under the eager-startup model (the proxy was always running by
 * the time this hook fired) but would silently strip claudecli/* from the
 * picker now that startup is deferred. See GH#21944.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of models registered
 */
function registerClaudeCliModels(config) {
  const claudeProxyPort = getClaudeProxyPort();
  if (!claudeProxyPort) {
    // Proxy not running yet — registerAnthropicModels already populated the
    // provider with the hardcoded default port; lazy-start will bring up
    // the listener on the same port when needed.
    return 0;
  }
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

/**
 * Log a summary of config hook changes (silent when nothing changed).
 * @param {object} counts - config registration counts
 */
function logConfigSummary(counts) {
  const labels = [
    [counts.agents, "agents"],
    [counts.mcps, "MCPs"],
    [counts.agentTools, "agent tool perms"],
    [counts.directories, "managed directory perms"],
    [counts.permissionGrants, "signed worker permission grants"],
    [counts.poolCleaned, `cleaned ${counts.poolCleaned} stale pool provider${counts.poolCleaned === 1 ? "" : "s"}`],
    [counts.anthropic, "anthropic models"],
    [counts.openai, "OpenAI context limits"],
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
}

/**
 * Check OpenCode/plugin version drift without blocking startup.
 * @param {string} pluginDir
 */
function logVersionDriftAsync(pluginDir) {
  checkOpenCodeVersionDriftAsync(pluginDir, (versionDrift) => {
    console.error(`[aidevops] Version drift: ${versionDrift}`);
  });
}

/**
 * Create the config hook function.
 * @param {object} deps - { agentsDir, workspaceDir, pluginDir, repositoryDir }
 * @returns {Function} Config hook
 */
export function createConfigHook(deps) {
  const { agentsDir, workspaceDir, pluginDir, repositoryDir } = deps;

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
    const directories = registerManagedDirectoryPermissions(config);
    const permissionGrants = registerApprovedWorkerPermissions(config, { repositoryDir });
    const poolCleaned = registerPoolProvider(config);
    const anthropic = registerAnthropicModels(config);
    const openai = registerGpt56ContextLimits(config);
    // Discover and register proxy provider models only when a proxy listener is
    // already active. The normal startup path intentionally leaves these ports
    // null until first use, so unconditional imports/discovery here made config
    // hook latency depend on optional providers. See GH#22157.
    let cursor = 0;
    let google = 0;

    const cursorProxyPort = getCursorProxyPort();
    if (cursorProxyPort) {
      const { getCursorModels } = await import("./cursor/models.js");
      cursor = await discoverAndRegisterModels({
        provider: "cursor",
        port: cursorProxyPort,
        discoverModels: getCursorModels,
        registerProvider: registerCursorProvider,
        config,
      });
    }

    const googleProxyPort = getGoogleProxyPort();
    if (googleProxyPort) {
      const { discoverGoogleModels } = await import("./google-proxy.mjs");
      google = await discoverAndRegisterModels({
        provider: "google",
        port: googleProxyPort,
        discoverModels: discoverGoogleModels,
        registerProvider: registerGoogleProvider,
        config,
      });
    }

    const claude = registerClaudeCliModels(config);

    logConfigSummary(
      { agents, mcps, agentTools, directories, permissionGrants, poolCleaned, anthropic, openai, cursor, google, claude },
    );
    logVersionDriftAsync(pluginDir);
  };
}
