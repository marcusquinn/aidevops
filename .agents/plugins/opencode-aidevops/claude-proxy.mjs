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

const CLAUDE_PROXY_DEFAULT_PORT = parseInt(process.env.CLAUDE_PROXY_PORT || "32125", 10);
const CLAUDE_PROVIDER_ID = "claudecli";
const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");
/** Opt-in debug request dump — set CLAUDE_PROXY_DEBUG_DUMP=1 to enable. */
const DEBUG_DUMP_ENABLED = process.env.CLAUDE_PROXY_DEBUG_DUMP === "1";
const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

/** @type {ReturnType<Bun["serve"]> | null} */
let proxyServer = null;
/** @type {number | null} */
let proxyPort = null;
/** @type {boolean} */
let proxyStarting = false;

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
  return [
    {
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5 (via Claude CLI)",
      reasoning: true,
      contextWindow: 1000000,
      maxTokens: 32000,
    },
    {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5 (via Claude CLI)",
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 64000,
    },
    {
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6 (via Claude CLI)",
      reasoning: true,
      contextWindow: 1000000,
      maxTokens: 64000,
    },
    {
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5 (via Claude CLI)",
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 64000,
    },
    {
      id: "claude-opus-4-6",
      name: "Claude Opus 4.6 (via Claude CLI)",
      reasoning: true,
      contextWindow: 1000000,
      maxTokens: 64000,
    },
  ];
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
 * Probe whether a proxy server is already listening on CLAUDE_PROXY_DEFAULT_PORT.
 * Used to adopt an existing server after plugin hot-reload (where the module
 * scope resets but the Bun.serve instance from the previous load lives on) or
 * when the plugin runs in a non-Bun JS runtime that cannot call Bun.serve.
 *
 * Returns the port number on success, null if no server is reachable.
 */
async function probeExistingProxy() {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1000);
    const res = await fetch(
      `http://127.0.0.1:${CLAUDE_PROXY_DEFAULT_PORT}/v1/models`,
      { signal: controller.signal },
    );
    clearTimeout(timer);
    if (res.ok) return CLAUDE_PROXY_DEFAULT_PORT;
  } catch {
    // not running or not reachable
  }
  return null;
}

/**
 * Pre-flight gate for `startClaudeProxy`. Returns:
 *   - `null` if the proxy should be skipped (no Bun, no claude CLI, race)
 *   - `{ port, models }` if the proxy is already running (fast-path)
 *   - `undefined` if the caller should proceed with a full launch
 */
function checkProxyPreconditions() {
  if (proxyStarting) return null;
  if (proxyPort) return { port: proxyPort, models: getClaudeProxyModels() };
  return undefined;
}

/**
 * Bring up the Bun.serve listener, register the provider, persist config.
 * Throws on any failure — `startClaudeProxy` translates that into a `null`
 * return so callers always see one of: `{port, models}` or `null`.
 */
async function launchProxyServer(client, directory) {
  proxyServer = Bun.serve({
    port: CLAUDE_PROXY_DEFAULT_PORT,
    hostname: "127.0.0.1",
    idleTimeout: 120,
    fetch: (req) => routeProxyRequest(req, directory),
  });

  proxyPort = proxyServer.port;
  const models = getClaudeProxyModels();

  await registerProxyAuth(client);
  persistClaudeProvider(proxyPort, models);
  console.error(`[aidevops] Claude proxy: started on port ${proxyPort}`);
  return { port: proxyPort, models };
}

export async function startClaudeProxy(client, directory) {
  const earlyExit = checkProxyPreconditions();
  if (earlyExit !== undefined) return earlyExit;

  // Probe first: adopt any existing proxy (handles hot-reload and non-Bun runtimes).
  // This avoids the module-scope reset issue where proxyPort is null after a
  // plugin reload but the Bun.serve instance from the previous load is still live.
  const existingPort = await probeExistingProxy();
  if (existingPort) {
    proxyPort = existingPort;
    console.error(`[aidevops] Claude proxy: adopted existing server on port ${proxyPort}`);
    return { port: proxyPort, models: getClaudeProxyModels() };
  }

  // No existing proxy — try to launch a new Bun.serve instance.
  if (typeof globalThis.Bun === "undefined") {
    console.error("[aidevops] Claude proxy: skipped (not running under Bun and no existing proxy found)");
    return null;
  }
  if (!isClaudeCliAvailable()) return null;

  proxyStarting = true;
  let result = null;
  try {
    result = await launchProxyServer(client, directory);
  } catch (err) {
    console.error(`[aidevops] Claude proxy: failed to start: ${err.message}`);
  } finally {
    proxyStarting = false;
  }
  return result;
}

export function getClaudeProxyPort() {
  return proxyPort;
}
