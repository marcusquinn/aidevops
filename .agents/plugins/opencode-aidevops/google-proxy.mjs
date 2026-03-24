/**
 * Google Auth-Translating Proxy (issue #5622)
 *
 * Bridges our OAuth pool system with OpenCode's built-in Google provider
 * (@ai-sdk/google). The SDK sends requests with `x-goog-api-key` headers,
 * but our pool tokens are OAuth Bearer tokens — Google's API rejects OAuth
 * tokens sent as API keys. This proxy translates between the two auth methods.
 *
 * Architecture:
 *   Pool token → pickAccount("google") + ensureValidToken() per request
 *   → Bun.serve on fixed port 32124 → strips x-goog-api-key, adds
 *     Authorization: Bearer <pool-token> → forwards to
 *     generativelanguage.googleapis.com → pipes response back (including SSE)
 *
 * On startup, discovers available models via GET /v1beta/models with the
 * OAuth token, then registers them as an OpenCode provider so they appear
 * in the Ctrl+T model picker.
 *
 * Simpler than cursor-proxy.mjs: HTTP-to-HTTP with header rewriting only,
 * no gRPC/protobuf translation needed.
 *
 * References:
 *   - Google OAuth pool: issue #5614, PR #5615
 *   - Cursor proxy (reference pattern): cursor-proxy.mjs
 *   - Google Generative AI API: https://ai.google.dev/api/rest
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { getAccounts, ensureValidToken, patchAccount } from "./oauth-pool.mjs";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Fixed port for the Google proxy. Using a deterministic port ensures the
 * URL in opencode.json survives across sessions — the proxy always starts
 * on the same port, so OpenCode can connect immediately without waiting
 * for the plugin to update the config.
 *
 * Port 32124 chosen to avoid collision with Cursor proxy (32123).
 * Override with GOOGLE_PROXY_PORT env var if needed.
 */
const GOOGLE_PROXY_DEFAULT_PORT = parseInt(process.env.GOOGLE_PROXY_PORT || "32124", 10);

const GOOGLE_API_BASE = "https://generativelanguage.googleapis.com";

/** Default cooldown when rate limited (ms) */
const RATE_LIMIT_COOLDOWN_MS = 60_000;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** @type {object | null} Bun.serve server instance */
let proxyServer = null;

/** @type {number | null} */
let proxyPort = null;

/** @type {boolean} */
let proxyStarting = false;

// activeAccountEmail removed — each request now tracks its own email via
// getAccessToken() return value to avoid concurrent-request misattribution.

// ---------------------------------------------------------------------------
// Token provider for the proxy
// ---------------------------------------------------------------------------

/**
 * Get a valid Google access token from the pool.
 * Called on every proxied request to get the current token.
 * Returns both the token and the selected account email so callers can
 * pass the email to rotateOnRateLimit() — avoiding the module-global
 * activeAccountEmail that caused concurrent-request misattribution.
 *
 * @returns {Promise<{ token: string, email: string }>}
 */
async function getAccessToken() {
  const accounts = getAccounts("google");
  if (accounts.length === 0) {
    throw new Error("No Google accounts in pool");
  }

  const now = Date.now();

  // Pick the best available account (LRU, skip rate-limited)
  const sorted = [...accounts]
    .filter(
      (a) =>
        (a.status === "active" || a.status === "idle") &&
        (!a.cooldownUntil || a.cooldownUntil <= now),
    )
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));

  for (const candidate of sorted) {
    const token = await ensureValidToken("google", candidate);
    if (token) {
      patchAccount("google", candidate.email, {
        lastUsed: new Date().toISOString(),
        status: "active",
      });
      return { token, email: candidate.email };
    }
  }

  throw new Error("All Google pool accounts exhausted or expired");
}

/**
 * Handle a 429 response by rotating to the next account.
 * Marks the throttled account as rate-limited and picks the next one.
 * Accepts the email of the account that produced the 429 so concurrent
 * requests don't misattribute cooldowns via a shared global.
 *
 * @param {string | null} currentEmail - Email of the account that got rate-limited
 * @returns {Promise<{ token: string, email: string } | null>} New token+email, or null
 */
async function rotateOnRateLimit(currentEmail) {
  if (currentEmail) {
    patchAccount("google", currentEmail, {
      status: "rate-limited",
      cooldownUntil: Date.now() + RATE_LIMIT_COOLDOWN_MS,
    });
  }

  const accounts = getAccounts("google");
  const now = Date.now();
  const available = accounts
    .filter(
      (a) =>
        a.email !== currentEmail &&
        (a.status === "active" || a.status === "idle") &&
        (!a.cooldownUntil || a.cooldownUntil <= now),
    )
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));

  for (const candidate of available) {
    const token = await ensureValidToken("google", candidate);
    if (token) {
      patchAccount("google", candidate.email, {
        lastUsed: new Date().toISOString(),
        status: "active",
      });
      console.error(`[aidevops] Google proxy: rotated to ${candidate.email} after 429`);
      return { token, email: candidate.email };
    }
  }

  console.error("[aidevops] Google proxy: no alternate account available after 429");
  return null;
}

// ---------------------------------------------------------------------------
// Model discovery
// ---------------------------------------------------------------------------

/**
 * Discover available Gemini models from the Google Generative AI API.
 * Calls GET /v1beta/models with the OAuth token and returns model metadata.
 *
 * @param {string} accessToken - Valid OAuth access token
 * @returns {Promise<Array<{ id: string, name: string, contextWindow: number, maxTokens: number }>>}
 */
export async function discoverGoogleModels(accessToken) {
  const models = [];

  try {
    const resp = await fetch(`${GOOGLE_API_BASE}/v1beta/models`, {
      headers: {
        "Authorization": `Bearer ${accessToken}`,
      },
    });

    if (!resp.ok) {
      console.error(`[aidevops] Google proxy: model discovery failed: HTTP ${resp.status}`);
      return models;
    }

    const data = await resp.json();
    if (!data.models || !Array.isArray(data.models)) {
      return models;
    }

    for (const model of data.models) {
      // Only include generateContent-capable models (chat/completion models)
      const methods = model.supportedGenerationMethods || [];
      if (!methods.includes("generateContent")) continue;

      // Extract the model ID from the full name (e.g., "models/gemini-2.5-flash" → "gemini-2.5-flash")
      const modelId = model.name?.replace(/^models\//, "") || "";
      if (!modelId) continue;

      // Skip embedding models, AQA models, and other non-chat models
      if (modelId.includes("embedding") || modelId.includes("aqa") || modelId.includes("imagen")) continue;

      models.push({
        id: modelId,
        name: model.displayName || modelId,
        contextWindow: model.inputTokenLimit || 1048576,
        maxTokens: model.outputTokenLimit || 65536,
      });
    }

    console.error(`[aidevops] Google proxy: discovered ${models.length} models`);
  } catch (err) {
    console.error(`[aidevops] Google proxy: model discovery error: ${err.message}`);
  }

  return models;
}

// ---------------------------------------------------------------------------
// Proxy server
// ---------------------------------------------------------------------------

/**
 * Start the Google auth-translating proxy.
 * Returns the proxy port and discovered models, or null if no Google accounts.
 *
 * The proxy:
 *   1. Accepts requests from @ai-sdk/google (which sends x-goog-api-key)
 *   2. Strips x-goog-api-key header
 *   3. Adds Authorization: Bearer <pool-token>
 *   4. Forwards to generativelanguage.googleapis.com
 *   5. Pipes response back (including SSE streams for streamGenerateContent)
 *   6. On 429, rotates to next pool account and retries once
 *
 * @param {any} client - OpenCode SDK client (for provider registration)
 * @returns {Promise<{ port: number, models: Array<{ id: string, name: string }> } | null>}
 */
export async function startGoogleProxy(client) {
  const accounts = getAccounts("google");
  if (accounts.length === 0) {
    return null;
  }

  // Prevent concurrent startup
  if (proxyStarting) {
    console.error("[aidevops] Google proxy: startup already in progress");
    return null;
  }

  if (proxyPort) {
    console.error(`[aidevops] Google proxy: already running on port ${proxyPort}`);
    return { port: proxyPort, models: [] };
  }

  proxyStarting = true;

  try {
    // Get an initial valid token for model discovery
    const { token: initialToken } = await getAccessToken();

    // Discover available models
    let models;
    try {
      models = await discoverGoogleModels(initialToken);
    } catch (err) {
      console.error(`[aidevops] Google proxy: model discovery failed (${err.message}), using empty list`);
      models = [];
    }

    // Start the HTTP proxy
    proxyServer = Bun.serve({
      port: GOOGLE_PROXY_DEFAULT_PORT,
      hostname: "127.0.0.1",

      async fetch(req) {
        const url = new URL(req.url);

        // Health check endpoint
        if (url.pathname === "/health") {
          return new Response(JSON.stringify({ status: "ok", provider: "google" }), {
            headers: { "Content-Type": "application/json" },
          });
        }

        // Forward all other requests to Google's API
        try {
          const targetUrl = `${GOOGLE_API_BASE}${url.pathname}${url.search}`;

          // Get a valid pool token — returns {token, email} so the 429 handler
          // can mark the correct account without relying on a shared global.
          let accessToken;
          let accountEmail;
          try {
            const result = await getAccessToken();
            accessToken = result.token;
            accountEmail = result.email;
          } catch (err) {
            return new Response(JSON.stringify({
              error: { message: `Google proxy: ${err.message}`, status: "UNAVAILABLE" },
            }), {
              status: 503,
              headers: { "Content-Type": "application/json" },
            });
          }

          // Build forwarded headers — strip x-goog-api-key, add Bearer auth
          const forwardHeaders = new Headers();
          for (const [key, value] of req.headers.entries()) {
            const lowerKey = key.toLowerCase();
            // Skip hop-by-hop headers and the API key header
            if (lowerKey === "x-goog-api-key") continue;
            if (lowerKey === "host") continue;
            if (lowerKey === "connection") continue;
            if (lowerKey === "transfer-encoding") continue;
            forwardHeaders.set(key, value);
          }
          forwardHeaders.set("Authorization", `Bearer ${accessToken}`);

          // Buffer the request body up-front so the 429 retry can reuse it.
          // req.body is a one-shot ReadableStream per the WHATWG Fetch spec —
          // once consumed by the first fetch() call, it cannot be read again.
          let body = null;
          if (req.method !== "GET" && req.method !== "HEAD") {
            body = await req.arrayBuffer();
          }

          let response = await fetch(targetUrl, {
            method: req.method,
            headers: forwardHeaders,
            body,
          });

          // Handle 429 — rotate account and retry once with the buffered body
          if (response.status === 429) {
            console.error(`[aidevops] Google proxy: 429 from Google API, attempting rotation`);
            const rotated = await rotateOnRateLimit(accountEmail);
            if (rotated) {
              forwardHeaders.set("Authorization", `Bearer ${rotated.token}`);
              response = await fetch(targetUrl, {
                method: req.method,
                headers: forwardHeaders,
                body,
              });
            }
          }

          // Pipe the response back — preserves SSE streaming for streamGenerateContent
          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: response.headers,
          });
        } catch (err) {
          console.error(`[aidevops] Google proxy: request error: ${err.message}`);
          return new Response(JSON.stringify({
            error: { message: `Google proxy error: ${err.message}`, status: "INTERNAL" },
          }), {
            status: 502,
            headers: { "Content-Type": "application/json" },
          });
        }
      },

      error(err) {
        console.error(`[aidevops] Google proxy: server error: ${err.message}`);
        return new Response("Internal Server Error", { status: 500 });
      },
    });

    proxyPort = proxyServer.port;
    console.error(`[aidevops] Google proxy: started on port ${proxyPort}`);

    // Persist Google provider + models to opencode.json
    if (models.length > 0) {
      try {
        persistGoogleProvider(proxyPort, models);
      } catch (err) {
        console.error(`[aidevops] Google proxy: failed to persist provider to opencode.json: ${err.message}`);
      }
    }

    return { port: proxyPort, models };
  } catch (err) {
    console.error(`[aidevops] Google proxy: failed to start: ${err.message}`);
    return null;
  } finally {
    proxyStarting = false;
  }
}

/**
 * Stop the Google proxy.
 */
export function stopGoogleProxy() {
  if (proxyServer) {
    try {
      proxyServer.stop();
    } catch {
      // Server may already be stopped
    }
    proxyServer = null;
    proxyPort = null;
    console.error("[aidevops] Google proxy: stopped");
  }
}

/**
 * Get the current proxy port, or null if not running.
 * @returns {number | null}
 */
export function getGoogleProxyPort() {
  return proxyPort;
}

// ---------------------------------------------------------------------------
// Provider registration for OpenCode config
// ---------------------------------------------------------------------------

/**
 * Build OpenCode provider model entries from discovered Google models.
 * These entries tell OpenCode what models are available and where to route requests.
 *
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 * @returns {Record<string, object>}
 */
export function buildGoogleProviderModels(models) {
  const entries = {};
  for (const model of models) {
    entries[model.id] = {
      name: model.name,
      attachment: true,
      tool_call: true,
      temperature: true,
      reasoning: model.id.includes("thinking") || false,
      modalities: { input: ["text", "image"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: {
        context: model.contextWindow || 1048576,
        output: model.maxTokens || 65536,
      },
      family: "google",
    };
  }
  return entries;
}

/**
 * Register the Google provider in OpenCode config with discovered models.
 * Called from the config hook after the proxy has started.
 *
 * @param {object} config - OpenCode config object (mutable)
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 * @returns {boolean} true if provider was registered/updated
 */
export function registerGoogleProvider(config, port, models) {
  if (!config.provider) config.provider = {};

  const providerModels = buildGoogleProviderModels(models);
  const baseURL = `http://127.0.0.1:${port}/v1beta`;

  const newProvider = {
    name: "Google (via aidevops proxy)",
    npm: "@ai-sdk/google",
    api: baseURL,
    models: providerModels,
  };

  const existing = config.provider.google;
  if (!existing || JSON.stringify(existing) !== JSON.stringify(newProvider)) {
    config.provider.google = newProvider;
    return true;
  }

  return false;
}

// ---------------------------------------------------------------------------
// Persist Google provider to opencode.json on disk
// ---------------------------------------------------------------------------

const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");

/**
 * Write the Google provider entry (with models) to opencode.json on disk.
 *
 * OpenCode reads opencode.json from disk for the model list — the config hook
 * only modifies the in-memory config. Without this, Google models don't appear
 * in the Ctrl+T model picker.
 *
 * The port is fixed (32124), so this only needs to run when models change.
 * We read-modify-write the JSON file atomically.
 *
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 */
function persistGoogleProvider(port, models) {
  // Start from an empty config on first run (ENOENT) so fresh setups get
  // Google models registered even before opencode.json exists.
  let config = {};
  try {
    const raw = readFileSync(OPENCODE_CONFIG_PATH, "utf-8");
    config = JSON.parse(raw);
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error(`[aidevops] Google proxy: cannot read opencode.json: ${err.message}`);
      return;
    }
    // ENOENT — file doesn't exist yet; proceed with empty config
  }

  if (!config.provider) config.provider = {};

  const providerModels = buildGoogleProviderModels(models);
  const baseURL = `http://127.0.0.1:${port}/v1beta`;

  config.provider.google = {
    name: "Google (via aidevops proxy)",
    npm: "@ai-sdk/google",
    api: baseURL,
    models: providerModels,
  };

  // Also set the placeholder API key env var to prevent SDK "missing key" error
  // The proxy handles real auth — this is just to satisfy the SDK's key check
  if (!process.env.GOOGLE_GENERATIVE_AI_API_KEY) {
    process.env.GOOGLE_GENERATIVE_AI_API_KEY = "google-pool-proxy";
  }

  try {
    // Ensure parent directory exists (e.g., ~/.config/opencode/ on first run)
    mkdirSync(dirname(OPENCODE_CONFIG_PATH), { recursive: true });
    writeFileSync(OPENCODE_CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf-8");
    console.error(`[aidevops] Google proxy: persisted ${models.length} models to opencode.json (port ${port})`);
  } catch (err) {
    console.error(`[aidevops] Google proxy: failed to write opencode.json: ${err.message}`);
  }
}
