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
import { jsonResponse, textResponse } from "./response-helpers.mjs";
import { createProxyLifecycle, resolveProxyPort } from "./proxy-lifecycle.mjs";
// Import + export: `export { … } from "./module"` is re-export only and
// does NOT create a local binding. discoverGoogleModels and
// persistGoogleProvider are both called locally below (see lines ~300 and
// ~338), so they must be imported into this module's scope. Same class of
// bug as the quality-hooks.mjs hotfix.
import {
  buildGoogleProviderModels,
  registerGoogleProvider,
  persistGoogleProvider,
  discoverGoogleModels,
} from "./google-proxy-config.mjs";

export {
  buildGoogleProviderModels,
  registerGoogleProvider,
  persistGoogleProvider,
  discoverGoogleModels,
};

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
const GOOGLE_PROXY_PORT_DEFAULT = 32124;
const GOOGLE_PROXY_PORT_ENV = "GOOGLE_PROXY_PORT";

const GOOGLE_API_BASE = "https://generativelanguage.googleapis.com";

/** Default cooldown when rate limited (ms) */
const RATE_LIMIT_COOLDOWN_MS = 60_000;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/**
 * Lifecycle factory — owns probe / EADDRINUSE-adopt / retry state for
 * the Google auth-translating proxy listener bind. The bind is now LAZY
 * (post GH#21948): plugin init eagerly discovers models and registers
 * the provider in opencode.json, but defers the `Bun.serve` listener
 * bind to the first google/* request. Probes `/health` rather than
 * `/v1/models` because the Google proxy's `/v1/...` paths forward
 * straight upstream. See proxy-lifecycle.mjs for the full state
 * machine.
 */
const googleLifecycle = createProxyLifecycle({
  name: "Google",
  defaultPort: GOOGLE_PROXY_PORT_DEFAULT,
  envPortVar: GOOGLE_PROXY_PORT_ENV,
  providerID: "google",
  probePath: "/health",
});

/** @type {object | null} Bun.serve server instance — held for stop() */
let proxyServer = null;

/**
 * Cached model list discovered eagerly during plugin init. Currently
 * informational only (the Google proxy forwards requests transparently
 * rather than serving a `/v1/models` endpoint), but kept for symmetry
 * with cursor-proxy.mjs and to support future model-picker refresh.
 *
 * @type {Array<{id: string, name: string}> | null}
 */
let cachedModels = null;

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

/** Bun.serve error handler for the Google proxy. */
function handleGoogleProxyServerError(err) {
  console.error(`[aidevops] Google proxy: server error: ${err.message}`);
  return textResponse("Internal Server Error", { status: 500 });
}

/**
 * Discover Google models via the upstream Generative Language API.
 * Falls back to an empty list on any failure — the lazy listener bind
 * still happens, but the model picker will be empty until a subsequent
 * eager refresh succeeds.
 *
 * @returns {Promise<Array<{id: string, name: string}>>}
 */
async function discoverModelsForGoogleProxy() {
  let initialToken;
  try {
    const result = await getAccessToken();
    initialToken = result.token;
  } catch (err) {
    console.error(`[aidevops] Google proxy: failed to get token for discovery: ${err.message}`);
    return [];
  }

  try {
    return await discoverGoogleModels(initialToken);
  } catch (err) {
    console.error(`[aidevops] Google proxy: model discovery failed (${err.message}), using empty list`);
    return [];
  }
}

/**
 * Eagerly prepare the Google auth-translating proxy: discover models
 * and register the provider in opencode.json. Does NOT bind the
 * `Bun.serve` listener — that's deferred to the first google/* request
 * via `ensureGoogleProxyServer`. Returns `{port, models}` on success or
 * `null` if no Google accounts are configured.
 *
 * Called once during plugin init (in index.mjs). Skips silently when
 * the pool has no Google accounts; logs and continues on individual
 * failures (model discovery, persist) so a partial degradation doesn't
 * block other proxies from starting.
 *
 * Multi-instance is safe: every concurrent eager call resolves to the
 * same deterministic port and the persist side effect is idempotent.
 * The race-prone `Bun.serve` bind only happens lazily and is protected
 * by the lifecycle helper's probe-first-then-adopt path.
 *
 * @param {any} _client - OpenCode SDK client (currently unused, kept
 *   for parity with cursor-proxy startCursorProxy signature in case
 *   future hooks need client access during eager phase)
 * @returns {Promise<{ port: number, models: Array<{ id: string, name: string }> } | null>}
 */
// eslint-disable-next-line no-unused-vars
export async function startGoogleProxy(_client) {
  const accounts = getAccounts("google");
  if (accounts.length === 0) return null;

  cachedModels = await discoverModelsForGoogleProxy();

  const port = resolveProxyPort(GOOGLE_PROXY_PORT_ENV, GOOGLE_PROXY_PORT_DEFAULT);

  if (cachedModels.length > 0) {
    try {
      persistGoogleProvider(port, cachedModels);
    } catch (err) {
      console.error(`[aidevops] Google proxy: failed to persist provider to opencode.json: ${err.message}`);
    }
  }

  return { port, models: cachedModels };
}

/**
 * Lazily bind the Google proxy listener. Called from the composed
 * `experimental.chat.system.transform` hook on the first request whose
 * `model.providerID === "google"`. The shared lifecycle helper handles
 * probe-first adoption (sibling OpenCode session already serving),
 * EADDRINUSE → adopt-with-retry (sibling won the bind race), and
 * idempotent re-entry (cached port returned without re-binding).
 *
 * The proxy:
 *   1. Accepts requests from @ai-sdk/google (which sends x-goog-api-key)
 *   2. Strips x-goog-api-key header
 *   3. Adds Authorization: Bearer <pool-token>
 *   4. Forwards to generativelanguage.googleapis.com
 *   5. Pipes response back (including SSE streams for streamGenerateContent)
 *   6. On 429, rotates to next pool account and retries once
 *
 * @returns {Promise<{port: number, adopted: boolean} | null>}
 */
export async function ensureGoogleProxyServer() {
  return googleLifecycle.ensureStarted({
    credentialsAvailable: () => getAccounts("google").length > 0,
    launch: async () => {
      const server = Bun.serve({
        port: resolveProxyPort(GOOGLE_PROXY_PORT_ENV, GOOGLE_PROXY_PORT_DEFAULT),
        hostname: "127.0.0.1",
        fetch: handleGoogleProxyFetch,
        error: handleGoogleProxyServerError,
      });
      proxyServer = server;
      console.error(`[aidevops] Google proxy: started on port ${server.port}`);
      return { port: server.port };
    },
  });
}

/**
 * Stop the Google proxy listener. Tears down the `Bun.serve` instance
 * but does NOT clear the lifecycle helper's port cache — re-running
 * `ensureGoogleProxyServer` after stop will probe, fail, and bind a
 * fresh listener.
 *
 * Currently unused by the plugin (no shutdown hook calls into here);
 * retained for future cleanup paths and parity with the Google proxy
 * API surface.
 */
export function stopGoogleProxy() {
  if (proxyServer) {
    try {
      proxyServer.stop();
    } catch {
      // Server may already be stopped
    }
    proxyServer = null;
    console.error("[aidevops] Google proxy: stopped");
  }
}

/**
 * Get the current proxy port, or null if not yet bound.
 * @returns {number | null}
 */
export function getGoogleProxyPort() {
  return googleLifecycle.getPort();
}

// Provider registration and config-persistence are in ./google-proxy-config.mjs
// (re-exported above for backward compatibility with callers).
