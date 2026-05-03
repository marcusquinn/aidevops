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
import { createGreetingHandler } from "./greeting.mjs";
import { applyImageSizeGuard } from "./quality-hooks-image.mjs";

// Existing modules
import { createTools } from "./tools.mjs";
import { initObservability, handleEvent } from "./observability.mjs";
import { createTtsrHooks } from "./ttsr.mjs";
import { createPoolAuthHook, createPoolTool, initPoolAuth, getAccounts } from "./oauth-pool.mjs";
import { createProviderAuthHook } from "./provider-auth.mjs";
import { startCursorProxy, ensureCursorProxyServer } from "./cursor-proxy.mjs";
import { startGoogleProxy, ensureGoogleProxyServer } from "./google-proxy.mjs";
import { startClaudeProxy } from "./claude-proxy.mjs";
import { isHeadless } from "./proxy-lifecycle.mjs";

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
// Plugin logging — informational messages gated behind AIDEVOPS_PLUGIN_DEBUG
// to avoid stderr text overlapping OpenCode's TUI (GH#TBD).
// Actual errors always use console.error directly.
// ---------------------------------------------------------------------------

/**
 * Plugin stderr suppression — prevents [aidevops] informational messages
 * from rendering over OpenCode's TUI input area. Only actual errors pass
 * through. Set AIDEVOPS_PLUGIN_DEBUG=1 to see all messages.
 *
 * This wraps console.error at the process level so ALL plugin modules
 * benefit without individual imports.
 */
const PLUGIN_DEBUG = !!process.env.AIDEVOPS_PLUGIN_DEBUG;
if (!PLUGIN_DEBUG) {
  const _origConsoleError = console.error;
  console.error = (...args) => {
    // Let actual errors through (stack traces, "failed", "error" in message)
    const msg = typeof args[0] === "string" ? args[0] : "";
    if (msg.startsWith("[aidevops]") && !(/fail|error|warn|disabled/i.test(msg))) {
      return; // suppress informational [aidevops] messages
    }
    _origConsoleError.apply(console, args);
  };
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

  const prepareOptionalProxy = (label, prepare) => {
    prepare()
      .catch((err) => {
        console.error(`[aidevops] ${label} proxy failed to register: ${err.message}`);
      });
  };

  // Cursor gRPC proxy — prepare models/provider in the background so OpenCode
  // startup never waits on network-bound model discovery or OAuth refresh.
  // Listener bind remains LAZY (see systemTransformHook below) — deferred until
  // the first cursor/* request. See GH#21948 and GH#22157.
  const cursorAccounts = getAccounts("cursor");
  if (cursorAccounts.length > 0) {
    prepareOptionalProxy("Cursor gRPC", async () => {
      const cursorProxyResult = await startCursorProxy(client);
      if (cursorProxyResult) {
        console.error(`[aidevops] Cursor gRPC proxy registered on port ${cursorProxyResult.port} with ${cursorProxyResult.models.length} models (listener lazy)`);
      }
    });
  }

  // Google auth-translating proxy — same non-blocking preparation / lazy
  // listener split as Cursor. The picker uses the last persisted provider entry
  // immediately, then refreshes when the background preparation completes.
  const googleAccounts = getAccounts("google");
  if (googleAccounts.length > 0) {
    if (!process.env.GOOGLE_GENERATIVE_AI_API_KEY) {
      process.env.GOOGLE_GENERATIVE_AI_API_KEY = "google-pool-proxy";
    }
    prepareOptionalProxy("Google", async () => {
      const googleProxyResult = await startGoogleProxy(client);
      if (googleProxyResult) {
        console.error(`[aidevops] Google proxy registered on port ${googleProxyResult.port} with ${googleProxyResult.models.length} models (listener lazy)`);
      }
    });
  }

  // Claude CLI transport proxy — lazy-started on first claudecli/* request
  // (see systemTransformHook composition below). Eagerly starting on every
  // plugin init wasted resources in headless workers (which use anthropic/*
  // via OAuth pool, never claudecli/*) and caused N-instance EADDRINUSE
  // races when N OpenCode sessions started simultaneously. See GH#21944
  // for the original Claude-only fix and GH#21948 for the consolidation
  // that brought cursor + google onto the same lazy-start pattern.

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
    systemTransformHook: ttsrSystemTransformHook,
    messagesTransformHook: ttsrMessagesTransformHook,
    textCompleteHook,
  } = createTtsrHooks({
    agentsDir: AGENTS_DIR,
    scriptsDir: SCRIPTS_DIR,
    readIfExists,
    qualityLog,
    run,
    intentField: INTENT_FIELD,
    isHeadless,
  });

  // Lazy-start dispatch table for local proxies. Keys are OpenCode
  // `model.providerID` values; values are thunks that bring up the
  // proxy listener on demand via the shared lifecycle helper (which
  // handles probe-first adoption, EADDRINUSE retry, and idempotent
  // re-entry — see proxy-lifecycle.mjs). Repeat calls per request are
  // cheap because the lifecycle caches the bound port. Headless workers
  // skip dispatch entirely (they only ever target anthropic/* via the
  // OAuth pool). See GH#21944 (Claude-only original) and GH#21948
  // (consolidation across all three proxies).
  const proxyStarters = {
    claudecli: () => startClaudeProxy(client, directory),
    cursor: () => ensureCursorProxyServer(),
    google: () => ensureGoogleProxyServer(),
  };

  // Composed system.transform hook: lazy-start the appropriate local
  // proxy on the first request whose providerID matches, then delegate
  // to TTSR enforcement. Failures here are logged but never block the
  // request — the underlying provider call will surface a clearer error
  // if the proxy is genuinely unreachable.
  const systemTransformHook = async (input, output) => {
    const providerID = input?.model?.providerID;
    if (providerID && !isHeadless()) {
      const starter = proxyStarters[providerID];
      if (starter) {
        try {
          await starter();
        } catch (err) {
          console.error(`[aidevops] ${providerID} proxy lazy-start failed: ${err.message}`);
        }
      }
    }
    await ttsrSystemTransformHook(input, output);
  };

  // Composed messages transform: TTSR enforcement + image size guard (GH#21793).
  // The image guard runs after TTSR so corrections are applied to the final
  // message list. Fail-open — errors in the guard must not block the message.
  const messagesTransformHook = async (input, output) => {
    await ttsrMessagesTransformHook(input, output);
    try {
      applyImageSizeGuard(output, qualityLog);
    } catch (err) {
      qualityLog("WARN", `[image-size-guard] Unexpected error: ${err?.message ?? err}`);
    }
  };

  // Greeting handler (t2724) — emits session-start framework status as
  // TUI toasts via client.tui.showToast(). Fires once per plugin init on
  // the first session.created event. See greeting.mjs for classification
  // and variant rules.
  const greetingHandler = createGreetingHandler({
    scriptsDir: SCRIPTS_DIR,
    client,
  });

  return {
    // Config: agent index, MCP registration, OAuth pool injection
    config: async (config) => {
      // HOTFIX: run initPoolAuth non-blocking — OpenCode 1.4.8 blocks
      // on client.auth.set() inside the config hook. Fire-and-forget so
      // the config hook can complete and the session becomes responsive.
      initPoolAuth(client).catch(() => {});
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

    // LLM observability + session-start toast greeting (t2724).
    // Both run on every event; greeting self-gates to session.created.
    event: async (input) => {
      // Fire both in parallel — neither depends on the other's result.
      await Promise.all([
        handleEvent(input),
        greetingHandler(input).catch((err) => {
          if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
            console.error(`[aidevops] greeting handler error: ${err.message}`);
          }
        }),
      ]);
    },

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
