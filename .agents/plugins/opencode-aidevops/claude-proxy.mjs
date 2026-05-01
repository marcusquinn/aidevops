// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Claude CLI proxy — OpenAI-compatible HTTP front-end for `claude` CLI.
 *
 * This file is the public facade for the proxy plugin. It owns:
 *   - the Bun.serve HTTP listener and lifecycle (`startClaudeProxy`)
 *   - the OpenCode provider registration into `opencode.json`
 *     (`registerClaudeProvider`)
 *   - the top-level HTTP routing for `/v1/models` and `/v1/chat/completions`
 *
 * Implementation is decomposed across sibling modules so each subsystem
 * stays small enough to reason about in isolation:
 *   - claude-proxy-stream.mjs     — pure SSE event handlers (text, tool_use, …)
 *   - claude-proxy-streaming.mjs  — streaming session orchestration + ReadableStream
 *   - claude-proxy-jsonpath.mjs   — non-streaming JSON child orchestration
 *   - claude-proxy-context.mjs    — framework + agent prompts, MCP, args, request parsing
 *   - claude-proxy-retry.mjs      — OAuth account pool + rate-limit detection
 *   - proxy-provider-models.mjs   — shared OpenCode provider entry builder
 *
 * Decomposition history: t2070 (qlty C→A campaign) — earlier cleanup landed
 * in GH#18619 (max-tokens) and GH#18621 (CodeRabbit findings, abort cleanup).
 */

import { spawnSync } from "child_process";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { dirname, join } from "path";
import {
  parseChatMessages,
  resolveAgentAndModel,
  resolveEffortLevel,
} from "./claude-proxy-context.mjs";
import {
  buildOpenAIResponse,
  runClaudeJson,
} from "./claude-proxy-jsonpath.mjs";
import { streamClaudeResponse } from "./claude-proxy-streaming.mjs";
import { buildProviderModels } from "./proxy-provider-models.mjs";
import { jsonResponse, textResponse } from "./response-helpers.mjs";
import { CLAUDE_MODEL_LIMITS } from "./model-limits.mjs";
import { createProxyLifecycle, resolveProxyPort } from "./proxy-lifecycle.mjs";

const CLAUDE_PROVIDER_ID = "claudecli";
const CLAUDE_PROXY_PORT_DEFAULT = 32125;
const CLAUDE_PROXY_PORT_ENV = "CLAUDE_PROXY_PORT";
const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");
/** Opt-in debug request dump — set CLAUDE_PROXY_DEBUG_DUMP=1 to enable. */
const DEBUG_DUMP_ENABLED = process.env.CLAUDE_PROXY_DEBUG_DUMP === "1";

const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

/**
 * Lifecycle factory — owns probe / EADDRINUSE-adopt / retry state. The
 * 1500ms probe timeout is the post-GH#21944 default (the prior 1s was
 * too short when an existing proxy was mid-SSE-stream); override via
 * CLAUDE_PROXY_PROBE_TIMEOUT_MS for slow hosts. See proxy-lifecycle.mjs
 * for the full state machine and GH#21948 for the consolidation that
 * factored the original copy out of this file.
 */
const claudeLifecycle = createProxyLifecycle({
  name: "Claude",
  defaultPort: CLAUDE_PROXY_PORT_DEFAULT,
  envPortVar: CLAUDE_PROXY_PORT_ENV,
  providerID: CLAUDE_PROVIDER_ID,
  probePath: "/v1/models",
  probeTimeoutMs: parseInt(
    process.env.CLAUDE_PROXY_PROBE_TIMEOUT_MS || "1500",
    10,
  ),
});

/** @type {ReturnType<Bun["serve"]> | null} */
let proxyServer = null;

// ---------------------------------------------------------------------------
// Claude CLI availability + model catalogue
// ---------------------------------------------------------------------------

function isClaudeCliAvailable() {
  try {
    const result = spawnSync("claude", ["--version"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000,
    });
    return result.status === 0 && result.stdout.trim().length > 0;
  } catch {
    return false;
  }
}

function getClaudeProxyModels() {
  return Object.entries(CLAUDE_MODEL_LIMITS).map(([id, limit]) => ({
    id,
    name: `${formatClaudeModelName(id)} (via Claude CLI)`,
    reasoning: true,
    contextWindow: limit.context,
    maxTokens: limit.output,
  }));
}

function formatClaudeModelName(id) {
  const [family = id, ...versionParts] = id.replace(/^claude-/, "").split("-");
  const displayFamily = family.charAt(0).toUpperCase() + family.slice(1);
  const version = versionParts.join(".");
  return version ? `Claude ${displayFamily} ${version}` : `Claude ${displayFamily}`;
}

// ---------------------------------------------------------------------------
// OpenCode provider registration
// ---------------------------------------------------------------------------

/**
 * Build the OpenCode provider entries for the claudecli family. Delegates to
 * the shared `buildProviderModels` helper so the schema (modalities, cost,
 * limit, family) is defined in exactly one place across all proxy plugins.
 */
function buildClaudeProviderModels(models) {
  return buildProviderModels(models, { family: "claudecli" });
}

/**
 * Build the canonical provider config object (consumed by both the in-memory
 * registration path and the on-disk persist path so they cannot drift).
 */
function buildClaudeProviderConfig(port, models) {
  return {
    name: "Claude CLI",
    npm: "@ai-sdk/openai-compatible",
    api: `http://127.0.0.1:${port}/v1`,
    models: buildClaudeProviderModels(models),
  };
}

export function registerClaudeProvider(config, port, models) {
  if (!config.provider) config.provider = {};

  const newProvider = buildClaudeProviderConfig(port, models);
  const existing = config.provider[CLAUDE_PROVIDER_ID];
  if (!existing || JSON.stringify(existing) !== JSON.stringify(newProvider)) {
    config.provider[CLAUDE_PROVIDER_ID] = newProvider;
    return true;
  }
  return false;
}

function readOpencodeConfig() {
  try {
    return JSON.parse(readFileSync(OPENCODE_CONFIG_PATH, "utf-8"));
  } catch (err) {
    if (err.code === "ENOENT") return {};
    console.error(`[aidevops] Claude proxy: cannot read opencode.json: ${err.message}`);
    return null;
  }
}

function persistClaudeProvider(port, models) {
  const config = readOpencodeConfig();
  if (config === null) return;

  if (!config.provider) config.provider = {};
  config.provider[CLAUDE_PROVIDER_ID] = buildClaudeProviderConfig(port, models);

  try {
    mkdirSync(dirname(OPENCODE_CONFIG_PATH), { recursive: true });
    writeFileSync(OPENCODE_CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf-8");
    console.error(`[aidevops] Claude proxy: persisted ${models.length} models to opencode.json (port ${port})`);
  } catch (err) {
    console.error(`[aidevops] Claude proxy: failed to write opencode.json: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// HTTP routing
// ---------------------------------------------------------------------------

function maybeDumpDebugRequest(body) {
  if (!DEBUG_DUMP_ENABLED) return;
  try {
    writeFileSync(
      "/tmp/claude-proxy-last-request.json",
      JSON.stringify({ model: body.model, agent: body.agentName, stream: body.stream }, null, 2),
      "utf-8",
    );
  } catch {
    // best effort debugging
  }
}

/**
 * Build the proxy's normalised request body from an OpenAI-compatible
 * incoming chat-completion payload + the fetch Request (for header lookup).
 */
function normaliseRequestBody(req, incoming) {
  const parsed = parseChatMessages(incoming.messages || []);
  const { agentName, resolvedModel } = resolveAgentAndModel(req, incoming);
  return {
    model: resolvedModel,
    agentName,
    systemPrompt: parsed.systemPrompt,
    prompt: parsed.prompt,
    stream: incoming.stream !== false,
    effortLevel: resolveEffortLevel(incoming),
  };
}

async function handleChatCompletions(req, directory) {
  const incoming = await req.json();
  const body = normaliseRequestBody(req, incoming);

  console.error(
    `[aidevops] Claude proxy: request model=${body.model} agent=${body.agentName} stream=${body.stream} systemChars=${body.systemPrompt.length} promptChars=${body.prompt.length}`,
  );
  maybeDumpDebugRequest(body);

  if (incoming.stream === false) {
    // Thread the fetch Request's abort signal into the JSON path so client
    // disconnect terminates the child immediately (GH#18621 Finding 1).
    const result = await runClaudeJson(body, directory, req.signal);
    return jsonResponse(buildOpenAIResponse(body, result.content, result.usage));
  }

  return textResponse(streamClaudeResponse(body, directory), {
    headers: SSE_HEADERS,
  });
}

function buildModelsListResponse() {
  return jsonResponse({
    object: "list",
    data: getClaudeProxyModels().map((model) => ({ id: model.id, object: "model", owned_by: "claude-cli" })),
  });
}

async function handleChatCompletionsWithErrorWrap(req, directory) {
  try {
    return await handleChatCompletions(req, directory);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse(
      { error: { message, type: "server_error", code: "internal_error" } },
      { status: 500 },
    );
  }
}

/**
 * Top-level HTTP request router for the proxy server. Extracted from the
 * Bun.serve fetch closure to keep `startClaudeProxy` shallow.
 */
async function routeProxyRequest(req, directory) {
  const url = new URL(req.url);
  if (req.method === "GET" && url.pathname === "/v1/models") {
    return buildModelsListResponse();
  }
  if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
    return handleChatCompletionsWithErrorWrap(req, directory);
  }
  return textResponse("Not Found", { status: 404 });
}

// ---------------------------------------------------------------------------
// Server lifecycle
// ---------------------------------------------------------------------------

/**
 * Best-effort registration of an opaque API key with OpenCode's auth store
 * so it doesn't prompt the user for credentials on first request. Failures
 * are logged but never fatal — the proxy works without this entry.
 */
async function registerProxyAuth(client) {
  try {
    await client.auth.set({
      path: { id: CLAUDE_PROVIDER_ID },
      body: { type: "api", key: "claude-cli-proxy" },
    });
  } catch {
    // best effort
  }
}

/**
 * Bring up the Bun.serve listener, register the provider, persist config.
 * Called by the shared lifecycle helper as the `launch` callback when no
 * sibling proxy is reachable. Throws on bind failure — the lifecycle
 * helper translates EADDRINUSE into a retry-probe adoption attempt and
 * any other error into a logged `null` return.
 */
async function launchProxyServer(client, directory) {
  proxyServer = Bun.serve({
    port: resolveProxyPort(CLAUDE_PROXY_PORT_ENV, CLAUDE_PROXY_PORT_DEFAULT),
    hostname: "127.0.0.1",
    idleTimeout: 120,
    fetch: (req) => routeProxyRequest(req, directory),
  });

  const models = getClaudeProxyModels();

  await registerProxyAuth(client);
  persistClaudeProvider(proxyServer.port, models);
  console.error(`[aidevops] Claude proxy: started on port ${proxyServer.port}`);
  return { port: proxyServer.port };
}

/**
 * Public entry point for both eager and lazy startup paths. The shared
 * lifecycle helper handles probe-first adoption, EADDRINUSE-retry, and
 * idempotent re-entry (see proxy-lifecycle.mjs). Returns `{port, models}`
 * on success or `null` if the proxy can't run (no Bun, no claude CLI,
 * or a poisoned port).
 *
 * Models are returned for both fresh-launch and adoption paths because
 * the in-memory provider entry is rebuilt from `getClaudeProxyModels()`
 * each call — adoption skips persisting them again (the sibling already
 * did) but the caller still needs the list.
 */
export async function startClaudeProxy(client, directory) {
  const result = await claudeLifecycle.ensureStarted({
    credentialsAvailable: isClaudeCliAvailable,
    launch: () => launchProxyServer(client, directory),
  });
  if (!result) return null;
  return { port: result.port, models: getClaudeProxyModels() };
}

export function getClaudeProxyPort() {
  return claudeLifecycle.getPort();
}
