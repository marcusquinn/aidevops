// ---------------------------------------------------------------------------
// aidevops OpenCode Plugin — Entry Point (t1914 decomposition)
//
// This file is a thin orchestrator that wires together extracted modules:
//   - config-hook.mjs    — agent/MCP/provider registration
//   - quality-hooks.mjs  — pre/post tool execution quality gates
//   - shell-env.mjs      — shell environment variable injection
//   - compaction.mjs     — context preservation across resets
//   - intent-tracing.mjs — LLM intent extraction and storage
//   - mcp-registry.mjs   — MCP server catalog and registration
//   - version-tracking.mjs — opencode version drift detection
//
// Existing modules (unchanged):
//   - tools.mjs           — custom tool definitions
//   - observability.mjs   — LLM observability (SQLite)
//   - agent-loader.mjs    — subagent index loading
//   - validators.mjs      — shell script validators
//   - quality-pipeline.mjs — markdown quality checks
//   - ttsr.mjs            — soft TTSR rule enforcement
//   - oauth-pool.mjs      — OAuth multi-account pool
//   - provider-auth.mjs   — provider auth hook
//   - cursor-proxy.mjs    — Cursor gRPC proxy
//   - google-proxy.mjs    — Google auth-translating proxy
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { execSync } from "child_process";

// Extracted modules
import { createConfigHook } from "./config-hook.mjs";
import { createQualityHooks } from "./quality-hooks.mjs";
import { createShellEnvHook } from "./shell-env.mjs";
import { compactingHook } from "./compaction.mjs";
import { INTENT_FIELD } from "./intent-tracing.mjs";

// Existing modules
import { createTools } from "./tools.mjs";
import { initObservability, handleEvent } from "./observability.mjs";
import { createTtsrHooks } from "./ttsr.mjs";
import { createPoolAuthHook, createPoolTool, initPoolAuth, getAccounts } from "./oauth-pool.mjs";
import { createProviderAuthHook } from "./provider-auth.mjs";
import { startCursorProxy } from "./cursor-proxy.mjs";
import { startGoogleProxy } from "./google-proxy.mjs";
import { startClaudeProxy } from "./claude-proxy.mjs";

// ---------------------------------------------------------------------------
// Directory constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const PLUGIN_DIR = join(AGENTS_DIR, "plugins", "opencode-aidevops");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function run(cmd, timeout = 5000) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
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

// ---------------------------------------------------------------------------
// Main Plugin Export
// ---------------------------------------------------------------------------

/**
 * aidevops OpenCode Plugin
 *
 * Provides:
 * 1. Config hook — lightweight agent index + MCP server registration (t1040)
 * 2. Custom tools — aidevops CLI, memory, pre-edit check, OAuth pool
 * 3. Quality hooks — full pre-commit pipeline on Write/Edit operations
 * 4. Shell environment — aidevops paths and variables
 * 5. Soft TTSR — preventative rule enforcement (t1304)
 * 6. LLM observability — event-driven data collection to SQLite (t1308)
 * 7. Intent tracing — logs LLM-provided intent alongside tool calls (t1309)
 * 8. Compaction context — preserves operational state across context resets
 * 9. OAuth multi-account pool — Anthropic, OpenAI, Cursor, Google (t1543+)
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory, client }) {
  // Initialise LLM observability
  initObservability();

  // Cursor gRPC proxy
  const cursorAccounts = getAccounts("cursor");
  if (cursorAccounts.length > 0) {
    try {
      const cursorProxyResult = await startCursorProxy(client);
      if (cursorProxyResult) {
        console.error(`[aidevops] Cursor gRPC proxy started on port ${cursorProxyResult.port} with ${cursorProxyResult.models.length} models`);
      }
    } catch (err) {
      console.error(`[aidevops] Cursor gRPC proxy failed to start: ${err.message}`);
    }
  }

  // Google auth-translating proxy
  const googleAccounts = getAccounts("google");
  if (googleAccounts.length > 0) {
    try {
      const googleProxyResult = await startGoogleProxy(client);
      if (googleProxyResult) {
        if (!process.env.GOOGLE_GENERATIVE_AI_API_KEY) {
          process.env.GOOGLE_GENERATIVE_AI_API_KEY = "google-pool-proxy";
        }
        console.error(`[aidevops] Google proxy started on port ${googleProxyResult.port} with ${googleProxyResult.models.length} models`);
      }
    } catch (err) {
      console.error(`[aidevops] Google proxy failed to start: ${err.message}`);
    }
  }

  // Claude CLI transport proxy
  try {
    const claudeProxyResult = await startClaudeProxy(client, directory);
    if (claudeProxyResult) {
      console.error(`[aidevops] Claude proxy started on port ${claudeProxyResult.port} with ${claudeProxyResult.models.length} models`);
    }
  } catch (err) {
    console.error(`[aidevops] Claude proxy failed to start: ${err.message}`);
  }

  // Create tools
  const baseTools = createTools(SCRIPTS_DIR, run);
  baseTools["model-accounts-pool"] = createPoolTool(client);

  // Create hooks from extracted modules
  const configHook = createConfigHook({
    agentsDir: AGENTS_DIR,
    workspaceDir: WORKSPACE_DIR,
    pluginDir: PLUGIN_DIR,
  });

  const { toolExecuteBefore, toolExecuteAfter, qualityLog } = createQualityHooks({
    scriptsDir: SCRIPTS_DIR,
    logsDir: LOGS_DIR,
  });

  const shellEnvHook = createShellEnvHook({
    agentsDir: AGENTS_DIR,
    scriptsDir: SCRIPTS_DIR,
    workspaceDir: WORKSPACE_DIR,
  });

  // TTSR hooks
  const {
    systemTransformHook,
    messagesTransformHook,
    textCompleteHook,
  } = createTtsrHooks({
    agentsDir: AGENTS_DIR,
    scriptsDir: SCRIPTS_DIR,
    readIfExists,
    qualityLog,
    run,
    intentField: INTENT_FIELD,
  });

  return {
    // Config: agent index, MCP registration, OAuth pool injection
    config: async (config) => {
      await initPoolAuth(client);
      return configHook(config);
    },

    // Custom tools + pool management
    tool: baseTools,

    // Quality hooks
    "tool.execute.before": toolExecuteBefore,
    "tool.execute.after": toolExecuteAfter,

    // Shell environment
    "shell.env": shellEnvHook,

    // Soft TTSR — rule enforcement
    "experimental.chat.system.transform": systemTransformHook,
    "experimental.chat.messages.transform": messagesTransformHook,
    "experimental.text.complete": textCompleteHook,

    // LLM observability
    event: async (input) => handleEvent(input),

    // OAuth multi-account pool + provider auth
    auth: (() => {
      const poolHook = createPoolAuthHook(client);
      const providerHook = createProviderAuthHook(client);
      return {
        provider: "anthropic",
        methods: poolHook.methods,
        loader: providerHook.loader,
      };
    })(),

    // Compaction context
    "experimental.session.compacting": async (input, output) =>
      compactingHook(
        { workspaceDir: WORKSPACE_DIR, scriptsDir: SCRIPTS_DIR },
        input,
        output,
        directory,
      ),
  };
}
