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

import { join } from "path";
import { getAccounts, ensureValidToken, patchAccount } from "./oauth-pool.mjs";
export { buildGoogleProviderModels, registerGoogleProvider, persistGoogleProvider, discoverGoogleModels } from "./google-proxy-config.mjs";
import { persistGoogleProvider, discoverGoogleModels } from "./google-proxy-config.mjs";
import { jsonResponse, textResponse } from "./response-helpers.mjs";

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

// discoverGoogleModels — see ./google-proxy-config.mjs (re-exported above)

// ---------------------------------------------------------------------------
// Proxy server — request handler (module-level for complexity isolation)
// ---------------------------------------------------------------------------

// Hop-by-hop headers and API key header to strip when forwarding.
const GOOGLE_PROXY_SKIP_HEADERS = new Set(["x-goog-api-key", "host", "connection", "transfer-encoding"]);

/**
 * Build forwarded headers: strip API key / hop-by-hop, add Bearer auth.
 * @param {Request} req
 * @param {string} accessToken
 * @returns {Headers}
 */
function buildGoogleForwardHeaders(req, accessToken) {
  const forwardHeaders = new Headers();
  for (const [key, value] of req.headers.entries()) {
    if (!GOOGLE_PROXY_SKIP_HEADERS.has(key.toLowerCase())) {
      forwardHeaders.set(key, value);
    }
  }
  forwardHeaders.set("Authorization", `Bearer ${accessToken}`);
  return forwardHeaders;
}

/**
 * Retry a forwarded request with a rotated account token after a 429.
 * Returns the retried Response, or null if no rotation is possible (caller uses original).
 * @param {string} accountEmail
 * @param {Headers} forwardHeaders
 * @param {string} targetUrl
 * @param {string} method
 * @param {ArrayBuffer|null} body
 * @returns {Promise<Response|null>}
 */
async function retryWithRotatedGoogleAccount(accountEmail, forwardHeaders, targetUrl, method, body) {
  console.error("[aidevops] Google proxy: 429 from Google API, attempting rotation");
  const rotated = await rotateOnRateLimit(accountEmail);
  if (!rotated) return null;
  forwardHeaders.set("Authorization", `Bearer ${rotated.token}`);
  return fetch(targetUrl, { method, headers: forwardHeaders, body });
}

/**
 * Forward a non-health-check request to the Google API with auth translation.
 * @param {Request} req
 * @param {URL} url
 * @returns {Promise<Response>}
 */
async function forwardToGoogleApi(req, url) {
  const targetUrl = `${GOOGLE_API_BASE}${url.pathname}${url.search}`;

  let accessToken;
  let accountEmail;
  try {
    const result = await getAccessToken();
    accessToken = result.token;
    accountEmail = result.email;
  } catch (err) {
    return jsonResponse(
      { error: { message: `Google proxy: ${err.message}`, status: "UNAVAILABLE" } },
      { status: 503 },
    );
  }

  const forwardHeaders = buildGoogleForwardHeaders(req, accessToken);

  // Buffer the request body up-front so the 429 retry can reuse it.
  // req.body is a one-shot ReadableStream per the WHATWG Fetch spec —
  // once consumed by the first fetch() call, it cannot be read again.
  const body = (req.method !== "GET" && req.method !== "HEAD")
    ? await req.arrayBuffer()
    : null;

  let response = await fetch(targetUrl, { method: req.method, headers: forwardHeaders, body });

  if (response.status === 429) {
    const rotated = await retryWithRotatedGoogleAccount(accountEmail, forwardHeaders, targetUrl, req.method, body);
    if (rotated) response = rotated;
  }

  // Pipe the response back — preserves SSE streaming for streamGenerateContent
  return textResponse(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

/**
 * Top-level fetch handler for the Google proxy Bun.serve instance.
 * @param {Request} req
 * @returns {Promise<Response>}
 */
async function handleGoogleProxyFetch(req) {
  const url = new URL(req.url);

  if (url.pathname === "/health") {
    return jsonResponse({ status: "ok", provider: "google" });
  }

  try {
    return await forwardToGoogleApi(req, url);
  } catch (err) {
    console.error(`[aidevops] Google proxy: request error: ${err.message}`);
    return jsonResponse(
      { error: { message: `Google proxy error: ${err.message}`, status: "INTERNAL" } },
      { status: 502 },
    );
  }
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
/** Bun.serve error handler for the Google proxy. */
function handleGoogleProxyServerError(err) {
  console.error(`[aidevops] Google proxy: server error: ${err.message}`);
  return textResponse("Internal Server Error", { status: 500 });
}

/** Discover models and start proxy; throws on failure (caller wraps in try/catch). */
async function startGoogleProxyServer() {
  const { token: initialToken } = await getAccessToken();
  let models;
  try {
    models = await discoverGoogleModels(initialToken);
  } catch (err) {
    console.error(`[aidevops] Google proxy: model discovery failed (${err.message}), using empty list`);
    models = [];
  }
  const server = Bun.serve({
    port: GOOGLE_PROXY_DEFAULT_PORT,
    hostname: "127.0.0.1",
    fetch: handleGoogleProxyFetch,
    error: handleGoogleProxyServerError,
  });
  return { server, models };
}

export async function startGoogleProxy(client) {
  const accounts = getAccounts("google");
  if (accounts.length === 0) return null;

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
    const { server, models } = await startGoogleProxyServer();
    proxyServer = server;
    proxyPort = proxyServer.port;
    console.error(`[aidevops] Google proxy: started on port ${proxyPort}`);

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

// Provider registration and config-persistence are in ./google-proxy-config.mjs
// (re-exported above for backward compatibility with callers).
