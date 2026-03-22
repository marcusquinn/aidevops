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
const CURSOR_PROXY_DEFAULT_PORT = parseInt(process.env.CURSOR_PROXY_PORT || "32123", 10);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** @type {number | null} */
let proxyPort = null;

/** @type {boolean} */
let proxyStarting = false;

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
 * Start the Cursor gRPC proxy and discover models.
 * Returns the proxy port, or null if no Cursor accounts are available.
 *
 * The proxy translates OpenAI-compatible HTTP requests to Cursor's
 * protobuf/HTTP2 Connect protocol via a Node.js H2 bridge subprocess.
 *
 * @param {any} client - OpenCode SDK client (for auth.set and provider registration)
 * @returns {Promise<{ port: number, models: Array<{ id: string, name: string }> } | null>}
 */
export async function startCursorProxy(client) {
  const accounts = getAccounts("cursor");
  if (accounts.length === 0) {
    return null;
  }

  // Prevent concurrent startup
  if (proxyStarting) {
    console.error("[aidevops] Cursor proxy: startup already in progress");
    return null;
  }

  if (proxyPort) {
    console.error(`[aidevops] Cursor proxy: already running on port ${proxyPort}`);
    return { port: proxyPort, models: [] };
  }

  proxyStarting = true;

  try {
    // Get an initial valid token for model discovery
    const initialToken = await getAccessToken();

    // Discover available models via gRPC
    const { getCursorModels } = await import("./cursor/models.js");
    let models;
    try {
      models = await getCursorModels(initialToken);
      console.error(`[aidevops] Cursor proxy: discovered ${models.length} models`);
    } catch (err) {
      console.error(`[aidevops] Cursor proxy: model discovery failed (${err.message}), using fallback list`);
      models = null;
    }

    // Start the proxy — it binds to a random port
    const { startProxy } = await import("./cursor/proxy.js");
    const port = await startProxy(getAccessToken, models || []);
    proxyPort = port;

    console.error(`[aidevops] Cursor proxy: gRPC proxy started on port ${port}`);

    // Inject auth into the cursor provider so OpenCode can route requests
    try {
      await client.auth.set({
        path: { id: "cursor" },
        body: {
          type: "api",
          key: "cursor-proxy",
        },
      });
    } catch (err) {
      console.error(`[aidevops] Cursor proxy: failed to set auth entry: ${err.message}`);
    }

    // Persist cursor provider + models to opencode.json so they appear in
    // the model picker. The config hook only modifies the in-memory config;
    // OpenCode reads opencode.json from disk for the model list.
    const effectiveModels = models || [];
    if (effectiveModels.length > 0) {
      try {
        persistCursorProvider(port, effectiveModels);
      } catch (err) {
        console.error(`[aidevops] Cursor proxy: failed to persist provider to opencode.json: ${err.message}`);
      }
    }

    return { port, models: effectiveModels };
  } catch (err) {
    console.error(`[aidevops] Cursor proxy: failed to start: ${err.message}`);
    return null;
  } finally {
    proxyStarting = false;
  }
}

/**
 * Stop the Cursor gRPC proxy.
 */
export async function stopCursorGrpcProxy() {
  if (proxyPort) {
    try {
      const { stopProxy } = await import("./cursor/proxy.js");
      stopProxy();
    } catch {
      // Module may not be loaded
    }
    proxyPort = null;
    activeAccountEmail = null;
    console.error("[aidevops] Cursor proxy: stopped");
  }
}

/**
 * Get the current proxy port, or null if not running.
 * @returns {number | null}
 */
export function getCursorProxyPort() {
  return proxyPort;
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
  const entries = {};
  for (const model of models) {
    entries[model.id] = {
      name: model.name,
      attachment: false,
      tool_call: true,
      temperature: true,
      reasoning: model.reasoning || false,
      modalities: { input: ["text"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: {
        context: model.contextWindow || 200000,
        output: model.maxTokens || 64000,
      },
      family: "cursor",
    };
  }
  return entries;
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
