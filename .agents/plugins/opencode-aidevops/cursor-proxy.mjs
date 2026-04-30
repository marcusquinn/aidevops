/**
 * Cursor gRPC Proxy Integration (t1551)
 *
 * Bridges our OAuth pool system with the vendored opencode-cursor-oauth proxy.
 * Reads Cursor tokens from ~/.aidevops/oauth-pool.json, starts the gRPC proxy
 * that translates OpenAI-compatible requests to Cursor's protobuf/HTTP2 protocol,
 * discovers available models, and registers them as an OpenCode provider.
 *
 * This replaces the cursor-agent CLI proxy with a direct gRPC connection,
 * bypassing OpenCode's broken auth hook system entirely.
 *
 * Architecture:
 *   Pool token → refreshCursorToken (if expired) → startProxy(getAccessToken, models)
 *   → Bun.serve on random port → OpenCode provider pointing at localhost:{port}/v1
 *
 * Vendored from: opencode-cursor-oauth@0.0.7 (ephraimduncan/opencode-cursor)
 * Dependencies: @bufbuild/protobuf, zod (available in OpenCode's node_modules)
 */

import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { getAccounts, ensureValidToken, patchAccount } from "./oauth-pool.mjs";
import { createProxyLifecycle, resolveProxyPort } from "./proxy-lifecycle.mjs";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Fixed port for the Cursor proxy. Using a deterministic port ensures the
 * URL in opencode.json survives across sessions — the proxy always starts
 * on the same port, so OpenCode can connect immediately without waiting
 * for the plugin to update the config.
 *
 * Override with CURSOR_PROXY_PORT env var if port 32123 conflicts.
 * (Nomadcxx/opencode-cursor uses 32124, so we use 32123 to avoid collision.)
 */
const CURSOR_PROXY_PORT_DEFAULT = 32123;
const CURSOR_PROXY_PORT_ENV = "CURSOR_PROXY_PORT";

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/**
 * Lifecycle factory — owns probe / EADDRINUSE-adopt / retry state for
 * the Cursor gRPC proxy listener bind. The bind is now LAZY (post
 * GH#21948): plugin init eagerly discovers models and registers the
 * provider in opencode.json, but defers the `Bun.serve` listener bind
 * to the first cursor/* request. See proxy-lifecycle.mjs for the full
 * state machine.
 */
const cursorLifecycle = createProxyLifecycle({
  name: "Cursor",
  defaultPort: CURSOR_PROXY_PORT_DEFAULT,
  envPortVar: CURSOR_PROXY_PORT_ENV,
  providerID: "cursor",
  probePath: "/v1/models",
});

/**
 * Cached model list discovered eagerly during plugin init. Reused by
 * the lazy listener bind so we don't re-fetch from the upstream Cursor
 * API on every adoption. May be `null` (discovery not yet attempted)
 * or `[]` (discovery failed, fallback to empty list).
 *
 * @type {Array<{id: string, name: string, reasoning?: boolean, contextWindow?: number, maxTokens?: number}> | null}
 */
let cachedModels = null;

/** @type {string | null} */
let activeAccountEmail = null;

// ---------------------------------------------------------------------------
// Token provider for the gRPC proxy
// ---------------------------------------------------------------------------

/**
 * Get a valid Cursor access token from the pool.
 * This is called by the proxy on every request to get the current token.
 * Handles rotation: if the current account is rate-limited, picks the next.
 *
 * @returns {Promise<string>}
 */
async function getAccessToken() {
  const accounts = getAccounts("cursor");
  if (accounts.length === 0) {
    throw new Error("No Cursor accounts in pool");
  }

  const now = Date.now();

  // Try the active account first
  if (activeAccountEmail) {
    const active = accounts.find((a) => a.email === activeAccountEmail);
    if (active && active.status === "active" && (!active.cooldownUntil || active.cooldownUntil <= now)) {
      const token = await ensureValidToken("cursor", active);
      if (token) return token;
    }
  }

  // Rotate to the best available account (LRU)
  const sorted = [...accounts]
    .filter(
      (a) =>
        (a.status === "active" || a.status === "idle") &&
        (!a.cooldownUntil || a.cooldownUntil <= now),
    )
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));

  for (const candidate of sorted) {
    const token = await ensureValidToken("cursor", candidate);
    if (token) {
      activeAccountEmail = candidate.email;
      patchAccount("cursor", candidate.email, {
        lastUsed: new Date().toISOString(),
        status: "active",
      });
      return token;
    }
  }

  throw new Error("All Cursor pool accounts exhausted or expired");
}

// ---------------------------------------------------------------------------
// Proxy lifecycle
// ---------------------------------------------------------------------------

/**
 * Set the auth entry for the cursor provider so OpenCode routes requests
 * through our local proxy URL. Best-effort — failure is logged but never
 * fatal (the proxy still works; OpenCode just falls back to its own auth
 * prompt flow if needed).
 *
 * @param {any} client - OpenCode SDK client
 */
async function setCursorAuth(client) {
  try {
    await client.auth.set({
      path: { id: "cursor" },
      body: { type: "api", key: "cursor-proxy" },
    });
  } catch (err) {
    console.error(`[aidevops] Cursor proxy: failed to set auth entry: ${err.message}`);
  }
}

/**
 * Discover available Cursor models via the upstream gRPC API. Falls back
 * to an empty list if discovery fails — the lazy listener bind still
 * happens, but the model picker will be empty until a subsequent eager
 * refresh succeeds.
 *
 * @returns {Promise<Array<{id: string, name: string, reasoning?: boolean, contextWindow?: number, maxTokens?: number}>>}
 */
async function discoverCursorModels() {
  const initialToken = await getAccessToken();
  const { getCursorModels } = await import("./cursor/models.js");
  try {
    const models = await getCursorModels(initialToken);
    console.error(`[aidevops] Cursor proxy: discovered ${models.length} models`);
    return models;
  } catch (err) {
    console.error(`[aidevops] Cursor proxy: model discovery failed (${err.message}), using fallback list`);
    return [];
  }
}

/**
 * Eagerly prepare the Cursor proxy: discover models, register the
 * provider in opencode.json, and set the auth entry. Does NOT bind the
 * `Bun.serve` listener — that's deferred to the first cursor/* request
 * via `ensureCursorProxyServer`. Returns `{port, models}` on success or
 * `null` if no Cursor accounts are configured.
 *
 * Called once during plugin init (in index.mjs). Skips silently when
 * the pool has no Cursor accounts; logs and continues on individual
 * failures (model discovery, persist, auth) so a partial degradation
 * doesn't block other proxies from starting.
 *
 * Multi-instance is safe: every concurrent eager call resolves to the
 * same deterministic port and the persist/auth side effects are
 * idempotent. The race-prone `Bun.serve` bind only happens lazily and
 * is protected by the lifecycle helper's probe-first-then-adopt path.
 *
 * @param {any} client - OpenCode SDK client (for auth.set)
 * @returns {Promise<{ port: number, models: Array<{ id: string, name: string }> } | null>}
 */
export async function startCursorProxy(client) {
  const accounts = getAccounts("cursor");
  if (accounts.length === 0) return null;

  cachedModels = await discoverCursorModels();

  const port = resolveProxyPort(CURSOR_PROXY_PORT_ENV, CURSOR_PROXY_PORT_DEFAULT);

  if (cachedModels.length > 0) {
    try {
      persistCursorProvider(port, cachedModels);
    } catch (err) {
      console.error(`[aidevops] Cursor proxy: failed to persist provider to opencode.json: ${err.message}`);
    }
  }

  await setCursorAuth(client);

  return { port, models: cachedModels };
}

/**
 * Lazily bind the Cursor proxy listener. Called from the composed
 * `experimental.chat.system.transform` hook on the first request whose
 * `model.providerID === "cursor"`. The shared lifecycle helper handles
 * probe-first adoption (sibling OpenCode session already serving),
 * EADDRINUSE → adopt-with-retry (sibling won the bind race), and
 * idempotent re-entry (cached port returned without re-binding).
 *
 * Falls back gracefully when called before `startCursorProxy` has
 * populated `cachedModels` — passes an empty list to the upstream
 * `cursor/proxy.js::startProxy`, which serves a model picker with no
 * entries until eager discovery completes. Models are also retrieved
 * fresh by `cursor/proxy.js` from the request stream when the
 * underlying gRPC call runs, so this is a transient cosmetic state.
 *
 * @returns {Promise<{port: number, adopted: boolean} | null>}
 */
export async function ensureCursorProxyServer() {
  return cursorLifecycle.ensureStarted({
    credentialsAvailable: () => getAccounts("cursor").length > 0,
    launch: async () => {
      const { startProxy } = await import("./cursor/proxy.js");
      const port = await startProxy(getAccessToken, cachedModels || []);
      console.error(`[aidevops] Cursor proxy: gRPC proxy started on port ${port}`);
      return { port };
    },
  });
}

/**
 * Stop the Cursor gRPC proxy. Tears down the upstream `cursor/proxy.js`
 * Bun.serve listener but does NOT clear the lifecycle helper's port
 * cache — re-running `ensureCursorProxyServer` after stop will probe,
 * fail, and bind a fresh listener.
 *
 * Currently unused by the plugin (no shutdown hook calls into here);
 * retained for future cleanup paths and parity with the cursor proxy
 * API surface.
 */
export async function stopCursorGrpcProxy() {
  if (cursorLifecycle.getPort() !== null) {
    try {
      const { stopProxy } = await import("./cursor/proxy.js");
      stopProxy();
    } catch {
      // Module may not be loaded
    }
    activeAccountEmail = null;
    console.error("[aidevops] Cursor proxy: stopped");
  }
}

/**
 * Get the current proxy port, or null if not yet bound.
 * @returns {number | null}
 */
export function getCursorProxyPort() {
  return cursorLifecycle.getPort();
}

// ---------------------------------------------------------------------------
// Provider registration for OpenCode config
// ---------------------------------------------------------------------------

/**
 * Build OpenCode provider model entries from discovered Cursor models.
 * These entries tell OpenCode what models are available and where to route requests.
 *
 * @param {Array<{ id: string, name: string, reasoning?: boolean, contextWindow?: number, maxTokens?: number }>} models
 * @param {number} port - Proxy port
 * @returns {Record<string, object>}
 */
export function buildCursorProviderModels(models, port) {
  return Object.fromEntries(models.map((model) => [
    model.id,
    {
      name: model.name,
      attachment: false,
      tool_call: false,
      temperature: true,
      reasoning: model.reasoning || false,
      modalities: { input: ["text"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: { context: model.contextWindow || 200000, output: model.maxTokens || 64000 },
      family: "cursor",
    },
  ]));
}

/**
 * Register the cursor provider in OpenCode config with discovered models.
 * Called from the config hook after the proxy has started.
 *
 * @param {object} config - OpenCode config object (mutable)
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, reasoning?: boolean, contextWindow?: number, maxTokens?: number }>} models
 * @returns {boolean} true if provider was registered/updated
 */
export function registerCursorProvider(config, port, models) {
  if (!config.provider) config.provider = {};

  const providerModels = buildCursorProviderModels(models, port);
  const baseURL = `http://127.0.0.1:${port}/v1`;

  const existing = config.provider.cursor;
  const newProvider = {
    name: "Cursor (via aidevops proxy)",
    npm: "@ai-sdk/openai-compatible",
    api: baseURL,
    models: providerModels,
  };

  if (!existing || JSON.stringify(existing) !== JSON.stringify(newProvider)) {
    config.provider.cursor = newProvider;
    return true;
  }

  return false;
}

// ---------------------------------------------------------------------------
// Persist cursor provider to opencode.json on disk
// ---------------------------------------------------------------------------

const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");

/**
 * Write the cursor provider entry (with models) to opencode.json on disk.
 *
 * OpenCode reads opencode.json from disk for the model list — the config hook
 * only modifies the in-memory config. Without this, Cursor models don't appear
 * in the Ctrl+T model picker.
 *
 * The port changes on every startup (Bun.serve port: 0), so this must run
 * every time the proxy starts. We read-modify-write the JSON file atomically.
 *
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, reasoning?: boolean, contextWindow?: number, maxTokens?: number }>} models
 */
function persistCursorProvider(port, models) {
  let config;
  try {
    const raw = readFileSync(OPENCODE_CONFIG_PATH, "utf-8");
    config = JSON.parse(raw);
  } catch {
    console.error("[aidevops] Cursor proxy: cannot read opencode.json, skipping persist");
    return;
  }

  if (!config.provider) config.provider = {};

  const providerModels = buildCursorProviderModels(models, port);
  const baseURL = `http://127.0.0.1:${port}/v1`;

  config.provider.cursor = {
    name: "Cursor (via aidevops proxy)",
    npm: "@ai-sdk/openai-compatible",
    api: baseURL,
    models: providerModels,
  };

  try {
    writeFileSync(OPENCODE_CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf-8");
    console.error(`[aidevops] Cursor proxy: persisted ${models.length} models to opencode.json (port ${port})`);
  } catch (err) {
    console.error(`[aidevops] Cursor proxy: failed to write opencode.json: ${err.message}`);
  }
}
