/**
 * OAuth Multi-Account Pool (t1543, t1548)
 *
 * Enables multiple OAuth accounts per provider with automatic credential
 * rotation on rate limits (429). Stores credentials in a separate pool file
 * (~/.aidevops/oauth-pool.json) to avoid conflicts with OpenCode's auth.json.
 *
 * Architecture:
 *   - auth hook: single "anthropic-pool" provider with both Anthropic and OpenAI
 *     OAuth methods (OpenCode 1.2.27 only supports one auth hook per plugin)
 *   - loader: returns a custom fetch wrapper that rotates credentials on 429
 *   - tool: /model-accounts-pool for listing/removing accounts
 *
 * Supported providers:
 *   - anthropic: Claude Pro/Max accounts (claude.ai OAuth)
 *   - openai: ChatGPT Plus/Pro accounts (auth.openai.com OAuth)
 *
 * References:
 *   - Built-in auth plugin: opencode-anthropic-auth@0.0.13
 *   - OpenCode PR #11832 (upstream multi-account proposal)
 *   - Plugin API: @opencode-ai/plugin AuthHook type
 *   - OpenAI OAuth: CLIENT_ID=app_EMoamEEZ73f0CkXaXp7hrann, ISSUER=https://auth.openai.com
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { createHash, randomBytes } from "crypto";
import { createServer } from "http";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const POOL_FILE = join(HOME, ".aidevops", "oauth-pool.json");

// ---------------------------------------------------------------------------
// Anthropic OAuth constants
// ---------------------------------------------------------------------------

const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ANTHROPIC_TOKEN_ENDPOINT = "https://platform.claude.com/v1/oauth/token";
const ANTHROPIC_OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const ANTHROPIC_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
const ANTHROPIC_OAUTH_SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

// ---------------------------------------------------------------------------
// OpenAI OAuth constants (t1548)
// Extracted from OpenCode binary: CLIENT_ID=app_EMoamEEZ73f0CkXaXp7hrann
// ISSUER=https://auth.openai.com, OAUTH_PORT=1455
// ---------------------------------------------------------------------------

const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_ISSUER = "https://auth.openai.com";
const OPENAI_TOKEN_ENDPOINT = `${OPENAI_ISSUER}/oauth/token`;
const OPENAI_OAUTH_AUTHORIZE_URL = `${OPENAI_ISSUER}/oauth/authorize`;
const OPENCODE_USER_AGENT = "opencode/1.2.27";
/** OpenAI uses a local redirect server at port 1455 for its built-in flow.
 *  For the pool's add-account flow we use the same redirect URI so the
 *  authorization code can be pasted back into the terminal prompt. */
const OPENAI_REDIRECT_URI = "http://localhost:1455/auth/callback";
const OPENAI_OAUTH_SCOPES = "openid profile email offline_access";

// ---------------------------------------------------------------------------
// Shared cooldown constants
// ---------------------------------------------------------------------------

/** Default cooldown when rate limited (ms) */
const RATE_LIMIT_COOLDOWN_MS = 60_000;

/** Default cooldown on auth failure (ms) */
const AUTH_FAILURE_COOLDOWN_MS = 300_000;

/** Cooldown after a 429 on the token endpoint (ms) — 5 minutes */
const TOKEN_ENDPOINT_COOLDOWN_MS = 300_000;

// ---------------------------------------------------------------------------
// Legacy aliases (kept for backward compatibility — Anthropic was the only
// provider before t1548, so existing code used bare constant names)
// ---------------------------------------------------------------------------

/** @deprecated Use ANTHROPIC_CLIENT_ID */
const CLIENT_ID = ANTHROPIC_CLIENT_ID;
/** @deprecated Use ANTHROPIC_TOKEN_ENDPOINT */
const TOKEN_ENDPOINT = ANTHROPIC_TOKEN_ENDPOINT;

// ---------------------------------------------------------------------------
// Token endpoint helpers
// ---------------------------------------------------------------------------

/**
 * Parse Retry-After header and return a bounded cooldown.
 * Supports both integer seconds and HTTP-date formats.
 * @param {string|null} retryAfter
 * @returns {number}
 */
function parseRetryAfterCooldown(retryAfter) {
  if (!retryAfter) return TOKEN_ENDPOINT_COOLDOWN_MS;

  const seconds = Number.parseInt(retryAfter, 10);
  if (Number.isFinite(seconds)) {
    return Math.max(seconds * 1000, TOKEN_ENDPOINT_COOLDOWN_MS);
  }

  const retryAt = Date.parse(retryAfter);
  if (Number.isFinite(retryAt)) {
    const remainingMs = Math.max(retryAt - Date.now(), 0);
    return Math.max(remainingMs, TOKEN_ENDPOINT_COOLDOWN_MS);
  }

  return TOKEN_ENDPOINT_COOLDOWN_MS;
}

/**
 * In-memory timestamp of the last 429 from the Anthropic token endpoint.
 * When set, all Anthropic token endpoint calls are skipped until the cooldown expires.
 * @type {number}
 */
let tokenEndpointCooldownUntil = 0;

/**
 * In-memory timestamp of the last 429 from the OpenAI token endpoint (t1548).
 * @type {number}
 */
let openaiTokenEndpointCooldownUntil = 0;

/**
 * Fetch from the Anthropic token endpoint. Single attempt with 429 cooldown gate.
 *
 * If a previous call got 429 within the cooldown window, this returns a
 * synthetic 429 response immediately — no network request made. This prevents
 * every session start from hitting the endpoint and extending the rate limit.
 *
 * @param {string} body - JSON string body
 * @param {string} context - description for logging
 * @returns {Promise<Response>}
 */
async function fetchTokenEndpoint(body, context) {
  // Check cooldown gate — skip the request entirely if rate limited recently
  const now = Date.now();
  if (tokenEndpointCooldownUntil > now) {
    const remainingSeconds = Math.ceil((tokenEndpointCooldownUntil - now) / 1000);
    const remainingMinutes = Math.ceil(remainingSeconds / 60);
    console.error(
      `[aidevops] OAuth pool: ${context} skipped — token endpoint rate limited, cooldown ${remainingMinutes}m remaining. ` +
      `Use /model-accounts-pool reset-cooldowns to clear manually.`,
    );
    return new Response(null, { status: 429, statusText: "Rate Limited (cooldown)" });
  }

  const response = await fetch(ANTHROPIC_TOKEN_ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "claude-cli/2.1.80 (external, cli)",
    },
    body,
  });

  if (response.status === 429) {
    // Parse Retry-After header if present, otherwise use default cooldown
    const retryAfter = response.headers.get("retry-after");
    const cooldownMs = parseRetryAfterCooldown(retryAfter);
    tokenEndpointCooldownUntil = Date.now() + cooldownMs;
    const cooldownMinutes = Math.ceil(cooldownMs / 60000);
    console.error(
      `[aidevops] OAuth pool: ${context} failed: rate limited by Anthropic. ` +
      `Cooldown set for ${cooldownMinutes}m — no further token requests until then. ` +
      `Use /model-accounts-pool reset-cooldowns to clear manually.`,
    );
  } else if (!response.ok) {
    console.error(`[aidevops] OAuth pool: ${context} failed: HTTP ${response.status}`);
  }

  return response;
}

/**
 * Fetch from the OpenAI token endpoint using form-encoded body (t1548).
 * OpenAI uses application/x-www-form-urlencoded, not JSON.
 *
 * @param {URLSearchParams} params - Form parameters
 * @param {string} context - description for logging
 * @returns {Promise<Response>}
 */
async function fetchOpenAITokenEndpoint(params, context) {
  const now = Date.now();
  if (openaiTokenEndpointCooldownUntil > now) {
    const remainingMinutes = Math.ceil((openaiTokenEndpointCooldownUntil - now) / 60000);
    console.error(
      `[aidevops] OAuth pool: ${context} skipped — OpenAI token endpoint rate limited, cooldown ${remainingMinutes}m remaining. ` +
      `Use /model-accounts-pool reset-cooldowns to clear manually.`,
    );
    return new Response(null, { status: 429, statusText: "Rate Limited (cooldown)" });
  }

  const response = await fetch(OPENAI_TOKEN_ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": OPENCODE_USER_AGENT,
    },
    body: params.toString(),
  });

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    const cooldownMs = parseRetryAfterCooldown(retryAfter);
    openaiTokenEndpointCooldownUntil = Date.now() + cooldownMs;
    const cooldownMinutes = Math.ceil(cooldownMs / 60000);
    console.error(
      `[aidevops] OAuth pool: ${context} failed: rate limited by OpenAI. ` +
      `Cooldown set for ${cooldownMinutes}m — no further token requests until then. ` +
      `Use /model-accounts-pool reset-cooldowns to clear manually.`,
    );
  } else if (!response.ok) {
    console.error(`[aidevops] OAuth pool: ${context} failed: HTTP ${response.status}`);
  }

  return response;
}

// ---------------------------------------------------------------------------
// PKCE helpers (no external dependency — pure crypto)
// ---------------------------------------------------------------------------

/**
 * Generate a PKCE code verifier and challenge.
 * Uses crypto.randomBytes + SHA-256 — no dependency on @openauthjs/openauth.
 * @returns {{ verifier: string, challenge: string }}
 */
function generatePKCE() {
  const verifier = randomBytes(32)
    .toString("base64url")
    .replace(/[^a-zA-Z0-9\-._~]/g, "")
    .slice(0, 128);
  const challenge = createHash("sha256")
    .update(verifier)
    .digest("base64url");
  return { verifier, challenge };
}

// ---------------------------------------------------------------------------
// OAuth callback server (t1548)
// ---------------------------------------------------------------------------

/** Port for the OpenAI OAuth callback server (matches OpenCode's built-in) */
const OAUTH_CALLBACK_PORT = 1455;

/** Timeout for the callback server (ms) — auto-closes if no callback received */
const OAUTH_CALLBACK_TIMEOUT_MS = 300_000; // 5 minutes

/**
 * Start a temporary HTTP server to catch the OpenAI OAuth callback.
 *
 * OpenAI's OAuth redirects to http://localhost:1455/auth/callback?code=XXX.
 * OpenCode's built-in auth spins up a server on that port, but our pool flow
 * runs through the plugin auth hook which doesn't. Without this server, the
 * browser shows "connection refused" and the user can't get the code.
 *
 * The server:
 *   1. Listens on port 1455
 *   2. Catches the /auth/callback redirect
 *   3. Extracts the `code` query parameter
 *   4. Shows a success page telling the user the code was captured
 *   5. Resolves the returned promise with the code
 *   6. Auto-closes after the first request or after timeout
 *
 * @returns {{ promise: Promise<string>, close: () => void }}
 *   - promise: resolves with the authorization code, rejects on timeout/error
 *   - close: manually close the server (cleanup)
 */
function startOAuthCallbackServer() {
  let resolveCode;
  let rejectCode;
  let server;
  let timeoutId;

  const promise = new Promise((resolve, reject) => {
    resolveCode = resolve;
    rejectCode = reject;
  });

  server = createServer((req, res) => {
    // Parse the URL to extract query parameters
    let reqUrl;
    try {
      reqUrl = new URL(req.url, `http://localhost:${OAUTH_CALLBACK_PORT}`);
    } catch {
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Bad request");
      return;
    }

    const code = reqUrl.searchParams.get("code");
    const error = reqUrl.searchParams.get("error");

    if (error) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body>
        <h2>Authorization Failed</h2>
        <p>Error: ${error}</p>
        <p>${reqUrl.searchParams.get("error_description") || ""}</p>
        <p>You can close this tab.</p>
      </body></html>`);
      cleanup();
      rejectCode(new Error(`OAuth error: ${error}`));
      return;
    }

    if (code) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body>
        <h2>Authorization Successful</h2>
        <p>The authorization code has been captured.</p>
        <p>Return to OpenCode — the code will be submitted automatically.</p>
        <p>You can close this tab.</p>
      </body></html>`);
      cleanup();
      resolveCode(code);
      return;
    }

    // No code or error — probably a favicon request or similar
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("Waiting for OAuth callback...");
  });

  function cleanup() {
    if (timeoutId) clearTimeout(timeoutId);
    if (server) {
      try { server.close(); } catch { /* ignore */ }
    }
  }

  // Handle port-in-use (OpenCode's built-in auth may have it)
  server.on("error", (err) => {
    if (err.code === "EADDRINUSE") {
      console.error(
        `[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use — ` +
        `OpenCode's built-in auth may be running. The user will need to ` +
        `copy the code from the browser URL bar manually.`,
      );
      // Don't reject — let the user paste the code manually
    } else {
      console.error(`[aidevops] OAuth pool: callback server error: ${err.message}`);
    }
    cleanup();
    rejectCode(err);
  });

  server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => {
    console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`);
  });

  // Auto-close after timeout
  timeoutId = setTimeout(() => {
    console.error(`[aidevops] OAuth pool: callback server timed out after ${OAUTH_CALLBACK_TIMEOUT_MS / 1000}s`);
    cleanup();
    rejectCode(new Error("OAuth callback timeout"));
  }, OAUTH_CALLBACK_TIMEOUT_MS);

  return { promise, close: cleanup };
}

// ---------------------------------------------------------------------------
// Pool file I/O
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} PoolAccount
 * @property {string} email
 * @property {string} refresh
 * @property {string} access
 * @property {number} expires
 * @property {string} added
 * @property {string} lastUsed
 * @property {"active"|"idle"|"rate-limited"|"auth-error"} status
 * @property {number|null} cooldownUntil
 * @property {string} [accountId] - OpenAI account ID (chatgpt_account_id from JWT claims)
 */

/**
 * @typedef {Object} PoolData
 * @property {PoolAccount[]} [anthropic]
 * @property {PoolAccount[]} [openai]
 */

/**
 * Load the pool file. Returns empty pool if file doesn't exist.
 * @returns {PoolData}
 */
function loadPool() {
  try {
    if (existsSync(POOL_FILE)) {
      const raw = readFileSync(POOL_FILE, "utf-8");
      return JSON.parse(raw);
    }
  } catch {
    // Corrupted file — start fresh
  }
  return {};
}

/**
 * Save the pool file with 0600 permissions.
 * @param {PoolData} data
 */
function savePool(data) {
  try {
    const dir = dirname(POOL_FILE);
    mkdirSync(dir, { recursive: true });
    writeFileSync(POOL_FILE, JSON.stringify(data, null, 2), { mode: 0o600 });
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to save pool file: ${err.message}`);
  }
}

/**
 * Get accounts for a provider.
 * @param {string} provider
 * @returns {PoolAccount[]}
 */
export function getAccounts(provider) {
  const pool = loadPool();
  return pool[provider] || [];
}

/**
 * Add or update an account in the pool.
 * If an account with the same email exists, it is updated (not duplicated).
 * @param {string} provider
 * @param {PoolAccount} account
 */
function upsertAccount(provider, account) {
  const pool = loadPool();
  if (!pool[provider]) pool[provider] = [];

  // Match by email. When email is "unknown" and there's exactly one existing
  // account (also "unknown"), replace it rather than creating duplicates.
  let idx = pool[provider].findIndex((a) => a.email === account.email);
  if (idx < 0 && account.email === "unknown") {
    const unknownIdx = pool[provider].findIndex((a) => a.email === "unknown");
    if (unknownIdx >= 0) idx = unknownIdx;
  }

  if (idx >= 0) {
    pool[provider][idx] = account;
  } else {
    pool[provider].push(account);
  }
  savePool(pool);
}

/**
 * Remove an account from the pool by email.
 * @param {string} provider
 * @param {string} email
 * @returns {boolean} true if removed
 */
function removeAccount(provider, email) {
  const pool = loadPool();
  if (!pool[provider]) return false;
  const before = pool[provider].length;
  pool[provider] = pool[provider].filter((a) => a.email !== email);
  if (pool[provider].length === before) return false;
  savePool(pool);
  return true;
}

/**
 * Update an account's status and cooldown in the pool.
 * @param {string} provider
 * @param {string} email
 * @param {Partial<PoolAccount>} patch
 */
export function patchAccount(provider, email, patch) {
  const pool = loadPool();
  if (!pool[provider]) return;
  const account = pool[provider].find((a) => a.email === email);
  if (!account) return;
  Object.assign(account, patch);
  savePool(pool);
}

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------

/**
 * Refresh an expired Anthropic access token using the refresh token.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
async function refreshAccessToken(account) {
  try {
    const response = await fetchTokenEndpoint(
      JSON.stringify({
        grant_type: "refresh_token",
        refresh_token: account.refresh,
        client_id: ANTHROPIC_CLIENT_ID,
      }),
      `refresh for ${account.email}`,
    );
    if (!response.ok) {
      // fetchTokenEndpoint already logged the error
      return null;
    }
    const json = await response.json();
    return {
      access: json.access_token,
      refresh: json.refresh_token,
      expires: Date.now() + json.expires_in * 1000,
    };
  } catch (err) {
    console.error(
      `[aidevops] OAuth pool: token refresh error for ${account.email}: ${err.message}`,
    );
    return null;
  }
}

/**
 * Refresh an expired OpenAI access token using the refresh token (t1548).
 * OpenAI uses form-encoded bodies, not JSON.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
async function refreshOpenAIAccessToken(account) {
  try {
    const params = new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: account.refresh,
      client_id: OPENAI_CLIENT_ID,
    });
    const response = await fetchOpenAITokenEndpoint(params, `refresh for ${account.email}`);
    if (!response.ok) {
      return null;
    }
    const json = await response.json();
    return {
      access: json.access_token,
      refresh: json.refresh_token || account.refresh,
      expires: Date.now() + (json.expires_in || 3600) * 1000,
    };
  } catch (err) {
    console.error(
      `[aidevops] OAuth pool: OpenAI token refresh error for ${account.email}: ${err.message}`,
    );
    return null;
  }
}

/**
 * Ensure an account has a valid (non-expired) access token.
 * Routes to the correct refresh function based on provider.
 * @param {string} provider
 * @param {PoolAccount} account
 * @returns {Promise<string|null>} access token or null on failure
 */
export async function ensureValidToken(provider, account) {
  if (account.access && account.expires > Date.now()) {
    return account.access;
  }
  const tokens = provider === "openai"
    ? await refreshOpenAIAccessToken(account)
    : await refreshAccessToken(account);
  if (!tokens) {
    patchAccount(provider, account.email, {
      status: "auth-error",
      cooldownUntil: Date.now() + AUTH_FAILURE_COOLDOWN_MS,
    });
    return null;
  }
  patchAccount(provider, account.email, {
    access: tokens.access,
    refresh: tokens.refresh,
    expires: tokens.expires,
    status: "active",
    cooldownUntil: null,
  });
  account.access = tokens.access;
  account.refresh = tokens.refresh;
  account.expires = tokens.expires;
  return tokens.access;
}

// ---------------------------------------------------------------------------
// Account selection (rotation)
// ---------------------------------------------------------------------------

/**
 * Pick the best available account from the pool.
 * Skips accounts that are in cooldown. Prefers least-recently-used.
 * @param {string} provider
 * @returns {PoolAccount|null}
 */
function pickAccount(provider) {
  const accounts = getAccounts(provider);
  const now = Date.now();
  const available = accounts.filter(
    (a) => !a.cooldownUntil || a.cooldownUntil <= now,
  );
  if (available.length === 0) return null;
  // Sort by lastUsed ascending (least recently used first)
  available.sort(
    (a, b) => new Date(a.lastUsed).getTime() - new Date(b.lastUsed).getTime(),
  );
  return available[0];
}

/**
 * Pick the next available account, excluding a specific email.
 * @param {string} provider
 * @param {string} excludeEmail
 * @returns {PoolAccount|null}
 */
function pickNextAccount(provider, excludeEmail) {
  const accounts = getAccounts(provider);
  const now = Date.now();
  const available = accounts.filter(
    (a) =>
      a.email !== excludeEmail &&
      (!a.cooldownUntil || a.cooldownUntil <= now),
  );
  if (available.length === 0) return null;
  available.sort(
    (a, b) => new Date(a.lastUsed).getTime() - new Date(b.lastUsed).getTime(),
  );
  return available[0];
}

/**
 * Execute a fetch with one-time pool failover on HTTP 429.
 * Marks the current account rate-limited, rotates to the next account, then retries once.
 *
 * @param {any} client - OpenCode SDK client
 * @param {"anthropic"|"openai"} provider
 * @param {string} currentEmail - current account email to skip on rotation
 * @param {() => Promise<Response>} request
 * @returns {Promise<Response>}
 */
export async function fetchWithPoolFailover(client, provider, currentEmail, request) {
  const response = await request();
  if (response.status !== 429 || !currentEmail) {
    return response;
  }

  patchAccount(provider, currentEmail, {
    status: "rate-limited",
    cooldownUntil: Date.now() + RATE_LIMIT_COOLDOWN_MS,
  });

  const injectFn = provider === "openai" ? injectOpenAIPoolToken : injectPoolToken;
  const rotated = await injectFn(client, currentEmail);
  if (!rotated) {
    console.error(
      `[aidevops] OAuth pool: ${provider} 429 for ${currentEmail}; no alternate account available for failover.`,
    );
    return response;
  }

  console.error(
    `[aidevops] OAuth pool: ${provider} 429 for ${currentEmail}; rotated account and retrying once.`,
  );

  return request();
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Auth hook (registers the pool provider for account management only)
// ---------------------------------------------------------------------------

/**
 * Seed a pool provider auth entry so it appears in the connect dialog.
 * @param {any} client - OpenCode SDK client
 * @param {string} providerId - e.g. "anthropic-pool" or "openai-pool"
 */
async function seedPoolAuthEntry(client, providerId) {
  try {
    const existing = await client.auth.get({ path: { id: providerId } });
    if (!existing?.data) {
      await client.auth.set({
        path: { id: providerId },
        body: { type: "pending", refresh: "", access: "", expires: 0 },
      });
      console.error(`[aidevops] OAuth pool: seeded auth entry for ${providerId}`);
    }
  } catch {
    try {
      await client.auth.set({
        path: { id: providerId },
        body: { type: "pending", refresh: "", access: "", expires: 0 },
      });
      console.error(`[aidevops] OAuth pool: seeded auth entry for ${providerId}`);
    } catch (err) {
      console.error(`[aidevops] OAuth pool: failed to seed auth entry for ${providerId}: ${err.message}`);
    }
  }
}

/**
 * Inject pool tokens into built-in providers on session start.
 * Seeds the anthropic-pool auth entry (which hosts both Anthropic and OpenAI
 * OAuth methods — OpenCode 1.2.27 only supports one auth hook per plugin).
 * @param {any} client - OpenCode SDK client
 */
export async function initPoolAuth(client) {
  // Seed pool provider entry (hosts both Anthropic + OpenAI OAuth methods)
  await seedPoolAuthEntry(client, "anthropic-pool");

  // Inject pool tokens into built-in providers
  await injectPoolToken(client);
  await injectOpenAIPoolToken(client);
}

/**
 * Pick the best pool account and inject its token into the built-in "anthropic"
 * provider's auth.json entry. The built-in provider handles all SDK magic.
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {boolean} true if a token was injected
 */
export async function injectPoolToken(client, skipEmail) {
  const accounts = getAccounts("anthropic");
  if (accounts.length === 0) return false;

  // Pick least-recently-used account, optionally skipping one
  let account = null;
  const sorted = [...accounts]
    .filter((a) => a.status === "active" && a.email !== skipEmail)
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));

  if (sorted.length === 0) {
    // All accounts skipped or inactive — try any active account
    account = accounts.find((a) => a.status === "active");
  } else {
    account = sorted[0];
  }

  if (!account) return false;

  // Ensure token is valid (refresh if needed)
  const accessToken = await ensureValidToken("anthropic", account);
  if (!accessToken) {
    console.error(`[aidevops] OAuth pool: failed to get valid token for ${account.email}`);
    return false;
  }

  // Write to built-in anthropic provider's auth entry
  try {
    await client.auth.set({
      path: { id: "anthropic" },
      body: {
        type: "oauth",
        refresh: account.refresh,
        access: account.access,
        expires: account.expires,
      },
    });

    // Mark as used
    patchAccount("anthropic", account.email, {
      lastUsed: new Date().toISOString(),
      status: "active",
    });

    console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in anthropic provider`);
    return true;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to inject token: ${err.message}`);
    return false;
  }
}

/**
 * Pick the best OpenAI pool account and inject its token into the built-in "openai"
 * provider's auth.json entry (t1548). Same token injection architecture as Anthropic pool.
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {boolean} true if a token was injected
 */
export async function injectOpenAIPoolToken(client, skipEmail) {
  const accounts = getAccounts("openai");
  if (accounts.length === 0) return false;

  const now = Date.now();
  // Pick least-recently-used eligible account, optionally skipping one.
  // Retry token validation across all candidates before failing.
  let account = null;
  const sorted = [...accounts]
    .filter(
      (a) =>
        (a.status === "active" || a.status === "idle") &&
        a.email !== skipEmail &&
        (!a.cooldownUntil || a.cooldownUntil <= now),
    )
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));

  for (const candidate of sorted) {
    const accessToken = await ensureValidToken("openai", candidate);
    if (!accessToken) {
      console.error(`[aidevops] OAuth pool: skipping invalid OpenAI token for ${candidate.email}`);
      continue;
    }
    account = candidate;
    break;
  }

  if (!account) return false;

  // Write to built-in openai provider's auth entry
  // OpenAI auth.json structure: { type, access, refresh, expires, accountId }
  try {
    await client.auth.set({
      path: { id: "openai" },
      body: {
        type: "oauth",
        refresh: account.refresh,
        access: account.access,
        expires: account.expires,
        accountId: account.accountId || "",
      },
    });

    // Mark as used
    patchAccount("openai", account.email, {
      lastUsed: new Date().toISOString(),
      status: "active",
    });

    console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in openai provider`);
    return true;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to inject OpenAI token: ${err.message}`);
    return false;
  }
}

/**
 * Create the unified auth hook for the pool provider (t1543, t1548).
 *
 * OpenCode 1.2.27 only supports a single auth hook object per plugin — arrays
 * crash with "Expected string, got undefined". This function returns one auth
 * hook with both Anthropic and OpenAI OAuth methods in its `methods` array.
 *
 * The `provider` field ("anthropic-pool") determines which provider entry the
 * auth dialog shows under. Both methods appear as selectable options. The actual
 * token injection targets the correct built-in providers ("anthropic" and
 * "openai") via client.auth.set() inside each method's callback.
 *
 * When OpenCode supports auth arrays (v1.2.30+), this can be split back into
 * separate hooks per provider if desired — but the merged approach is simpler.
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createPoolAuthHook(client) {
  return {
    provider: "anthropic-pool",

    methods: [
      // --- Anthropic pool method (Claude Pro/Max) ---
      {
        get label() {
          const accounts = getAccounts("anthropic");
          if (accounts.length === 0) {
            return "Add Anthropic Account (Claude Pro/Max)";
          }
          return `Add Anthropic Account (${accounts.length} account${accounts.length === 1 ? "" : "s"})`;
        },
        type: "oauth",
        prompts: [
          {
            type: "text",
            key: "email",
            get message() {
              const accounts = getAccounts("anthropic");
              if (accounts.length === 0) {
                return "Account email";
              }
              const emails = accounts.map((a) => a.email).join(", ");
              return `Current: ${emails}\nNew account email`;
            },
            placeholder: "you@example.com",
            validate: (value) => {
              if (!value || !value.includes("@")) {
                return "Please enter a valid email address";
              }
              return undefined;
            },
          },
        ],
        authorize: async (inputs) => {
          const email = inputs?.email || "unknown";
          const pkce = generatePKCE();

          const url = new URL(ANTHROPIC_OAUTH_AUTHORIZE_URL);
          url.searchParams.set("code", "true");
          url.searchParams.set("client_id", ANTHROPIC_CLIENT_ID);
          url.searchParams.set("response_type", "code");
          url.searchParams.set("redirect_uri", ANTHROPIC_REDIRECT_URI);
          url.searchParams.set("scope", ANTHROPIC_OAUTH_SCOPES);
          url.searchParams.set("code_challenge", pkce.challenge);
          url.searchParams.set("code_challenge_method", "S256");
          url.searchParams.set("state", pkce.verifier);

          return {
            url: url.toString(),
            instructions: `Adding account: ${email}\nPaste the authorization code here: `,
            method: "code",
            callback: async (code) => {
              const hashIdx = code.indexOf("#");
              const authCode = hashIdx >= 0 ? code.substring(0, hashIdx) : code;
              const state = hashIdx >= 0 ? code.substring(hashIdx + 1) : undefined;

              const result = await fetchTokenEndpoint(
                JSON.stringify({
                  code: authCode,
                  state,
                  grant_type: "authorization_code",
                  client_id: ANTHROPIC_CLIENT_ID,
                  redirect_uri: ANTHROPIC_REDIRECT_URI,
                  code_verifier: pkce.verifier,
                }),
                "token exchange",
              );

              if (!result.ok) {
                return { type: "failed" };
              }

              const json = await result.json();

              // Resolve account email from user profile if prompts were skipped
              let resolvedEmail = email;
              if (resolvedEmail === "unknown" && json.access_token) {
                const profileEndpoints = [
                  "https://console.anthropic.com/api/auth/user",
                  "https://api.anthropic.com/api/auth/user",
                ];
                for (const endpoint of profileEndpoints) {
                  try {
                    const profileResp = await fetch(endpoint, {
                      headers: {
                        "Authorization": `Bearer ${json.access_token}`,
                        "User-Agent": "claude-cli/2.1.80 (external, cli)",
                      },
                      redirect: "follow",
                    });
                    if (profileResp.ok) {
                      const profile = await profileResp.json();
                      const found = profile.email || profile.email_address
                        || profile.user?.email || profile.account?.email;
                      if (found) {
                        resolvedEmail = found;
                        console.error(`[aidevops] OAuth pool: resolved email ${found} from ${endpoint}`);
                        break;
                      }
                    }
                  } catch {
                    // Try next endpoint
                  }
                }
                if (resolvedEmail === "unknown") {
                  console.error("[aidevops] OAuth pool: could not resolve email from profile API — account stored as 'unknown'");
                }
              }

              upsertAccount("anthropic", {
                email: resolvedEmail,
                refresh: json.refresh_token,
                access: json.access_token,
                expires: Date.now() + json.expires_in * 1000,
                added: new Date().toISOString(),
                lastUsed: new Date().toISOString(),
                status: "active",
                cooldownUntil: null,
              });

              const totalAccounts = getAccounts("anthropic").length;
              console.error(
                `[aidevops] OAuth pool: added ${resolvedEmail} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
              );

              // Inject the new token into the built-in anthropic provider
              await injectPoolToken(client);

              return {
                type: "success",
                refresh: json.refresh_token,
                access: json.access_token,
                expires: Date.now() + json.expires_in * 1000,
              };
            },
          };
        },
      },

      // --- OpenAI pool method (ChatGPT Plus/Pro) (t1548) ---
      {
        get label() {
          const accounts = getAccounts("openai");
          if (accounts.length === 0) {
            return "Add OpenAI Account (ChatGPT Plus/Pro)";
          }
          return `Add OpenAI Account (${accounts.length} account${accounts.length === 1 ? "" : "s"})`;
        },
        type: "oauth",
        prompts: [
          {
            type: "text",
            key: "email",
            get message() {
              const accounts = getAccounts("openai");
              if (accounts.length === 0) {
                return "Account email";
              }
              const emails = accounts.map((a) => a.email).join(", ");
              return `Current: ${emails}\nNew account email`;
            },
            placeholder: "you@example.com",
            validate: (value) => {
              if (!value || !value.includes("@")) {
                return "Please enter a valid email address";
              }
              return undefined;
            },
          },
        ],
        authorize: async (inputs) => {
          const email = inputs?.email || "unknown";
          const pkce = generatePKCE();

          // Start a local callback server to catch the OAuth redirect.
          // OpenAI redirects to localhost:1455 — without this server the
          // browser shows "connection refused" and the user can't get the code.
          let callbackServer = null;
          let serverCode = null;
          try {
            callbackServer = startOAuthCallbackServer();
            // Store the code when the server catches it (non-blocking)
            callbackServer.promise
              .then((code) => { serverCode = code; })
              .catch(() => { /* timeout or error — user can paste manually */ });
          } catch {
            // Server failed to start (port in use, etc.) — fall back to manual paste
            console.error("[aidevops] OAuth pool: callback server failed to start — manual code paste required");
          }

          const url = new URL(OPENAI_OAUTH_AUTHORIZE_URL);
          url.searchParams.set("client_id", OPENAI_CLIENT_ID);
          url.searchParams.set("response_type", "code");
          url.searchParams.set("redirect_uri", OPENAI_REDIRECT_URI);
          url.searchParams.set("scope", OPENAI_OAUTH_SCOPES);
          url.searchParams.set("code_challenge", pkce.challenge);
          url.searchParams.set("code_challenge_method", "S256");

          return {
            url: url.toString(),
            instructions: [
              `Adding OpenAI account: ${email}`,
              `1. A browser window will open to auth.openai.com`,
              `2. Sign in with your ChatGPT Plus/Pro account`,
              `3. After authorizing, the code will be captured automatically`,
              `4. Press Enter here to complete (or paste the code manually if needed): `,
            ].join("\n"),
            method: "code",
            callback: async (code) => {
              // Use server-captured code if available, otherwise use manual input
              let authCode = code?.trim();
              if ((!authCode || authCode.length < 5) && serverCode) {
                authCode = serverCode;
                console.error("[aidevops] OAuth pool: using auto-captured code from callback server");
              } else if ((!authCode || authCode.length < 5) && callbackServer) {
                // Server hasn't caught the code yet — wait briefly
                try {
                  authCode = await Promise.race([
                    callbackServer.promise,
                    new Promise((_, reject) =>
                      setTimeout(() => reject(new Error("timeout")), 30_000),
                    ),
                  ]);
                  console.error("[aidevops] OAuth pool: received code from callback server");
                } catch {
                  console.error("[aidevops] OAuth pool: no code received — authorization failed");
                  if (callbackServer) callbackServer.close();
                  return { type: "failed" };
                }
              }

              // Clean up the callback server
              if (callbackServer) callbackServer.close();

              if (!authCode || authCode.length < 5) {
                return { type: "failed" };
              }

              // Strip any URL fragment or extra parameters
              const cleanCode = authCode.split(/[&#?]/)[0];

              const params = new URLSearchParams({
                grant_type: "authorization_code",
                code: cleanCode,
                redirect_uri: OPENAI_REDIRECT_URI,
                client_id: OPENAI_CLIENT_ID,
                code_verifier: pkce.verifier,
              });

              const result = await fetchOpenAITokenEndpoint(params, "token exchange");

              if (!result.ok) {
                return { type: "failed" };
              }

              const json = await result.json();

              // Resolve account email and accountId from JWT claims
              let resolvedEmail = email;
              let accountId = "";
              if (json.access_token) {
                try {
                  // Decode JWT payload (base64url, no verification needed here)
                  const parts = json.access_token.split(".");
                  if (parts.length >= 2) {
                    const payload = JSON.parse(
                      Buffer.from(parts[1], "base64url").toString("utf-8"),
                    );
                    // OpenAI JWT claims: chatgpt_account_id or https://api.openai.com/auth.chatgpt_account_id
                    accountId = payload.chatgpt_account_id
                      || payload["https://api.openai.com/auth"]?.chatgpt_account_id
                      || payload.organizations?.[0]?.id
                      || "";
                    // Email from standard OIDC claims
                    if (resolvedEmail === "unknown") {
                      resolvedEmail = payload.email || payload.sub || "unknown";
                    }
                  }
                } catch {
                  // JWT decode failed — continue with provided email
                }

                // Fallback: try OpenAI userinfo endpoint
                if (resolvedEmail === "unknown") {
                  try {
                    const userResp = await fetch(`${OPENAI_ISSUER}/userinfo`, {
                      headers: {
                        "Authorization": `Bearer ${json.access_token}`,
                        "User-Agent": OPENCODE_USER_AGENT,
                      },
                    });
                    if (userResp.ok) {
                      const userInfo = await userResp.json();
                      resolvedEmail = userInfo.email || userInfo.sub || "unknown";
                      console.error(`[aidevops] OAuth pool: resolved OpenAI email ${resolvedEmail} from userinfo`);
                    }
                  } catch {
                    // Userinfo endpoint unavailable
                  }
                }
              }

              upsertAccount("openai", {
                email: resolvedEmail,
                refresh: json.refresh_token || "",
                access: json.access_token,
                expires: Date.now() + (json.expires_in || 3600) * 1000,
                added: new Date().toISOString(),
                lastUsed: new Date().toISOString(),
                status: "active",
                cooldownUntil: null,
                accountId,
              });

              const totalAccounts = getAccounts("openai").length;
              console.error(
                `[aidevops] OAuth pool: added OpenAI ${resolvedEmail} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
              );

              // Inject the new token into the built-in openai provider
              await injectOpenAIPoolToken(client);

              return {
                type: "success",
                refresh: json.refresh_token || "",
                access: json.access_token,
                expires: Date.now() + (json.expires_in || 3600) * 1000,
              };
            },
          };
        },
      },
    ],
  };
}

/**
 * Register the pool provider (auth-only, no real models).
 *
 * A single "anthropic-pool" provider hosts both Anthropic and OpenAI OAuth
 * methods (OpenCode 1.2.27 only supports one auth hook per plugin). The
 * provider name is "OAuth Account Pool" to reflect that it handles both.
 *
 * Models are served by the built-in providers ("anthropic", "openai"), which
 * use pool tokens injected into auth.json by initPoolAuth/injectPoolToken/
 * injectOpenAIPoolToken.
 *
 * @param {any} config - OpenCode config object
 * @returns {number} number of providers newly registered (0 or 1)
 */
export function registerPoolProvider(config) {
  if (!config.provider) config.provider = {};
  let registered = 0;

  if (!config.provider["anthropic-pool"]) {
    config.provider["anthropic-pool"] = {
      name: "OAuth Account Pool (Anthropic + OpenAI)",
      npm: "@ai-sdk/anthropic",
      api: "https://api.anthropic.com/v1",
      models: {
        "pool-account-management": {
          name: "Add/Manage Accounts (select models from Anthropic or OpenAI provider)",
          attachment: false, tool_call: false, temperature: false,
          modalities: { input: ["text"], output: ["text"] },
          cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
          limit: { context: 1000, output: 100 },
          family: "pool",
        },
      },
    };
    registered++;
  } else {
    // Update name from old "Anthropic Pool (Account Management)" to new unified name
    config.provider["anthropic-pool"].name = "OAuth Account Pool (Anthropic + OpenAI)";
  }

  // Clean up stale "openai-pool" provider from previous versions (t1548).
  // It had no auth hook and showed a confusing API key input. Both OAuth
  // methods are now in the single "anthropic-pool" auth hook above.
  if (config.provider["openai-pool"]) {
    delete config.provider["openai-pool"];
  }

  return registered;
}

// ---------------------------------------------------------------------------
// Custom tool: /model-accounts-pool
// ---------------------------------------------------------------------------

/**
 * Create the model-accounts-pool tool definition.
 * @param {any} client - OpenCode SDK client (for token injection)
 * @returns {import('@opencode-ai/plugin').ToolDefinition}
 */
export function createPoolTool(client) {
  return {
    description:
      "Manage OAuth account pool for provider credential rotation. " +
      "Use 'list' to see all accounts and their status, " +
      "'rotate' to switch to the next pool account, " +
      "'remove <email>' to remove an account, " +
      "'status' for rotation statistics. " +
      "Supports providers: anthropic (Claude Pro/Max) and openai (ChatGPT Plus/Pro). " +
      "The agent should route natural language requests about managing " +
      "provider accounts, OAuth pools, or credential rotation to this tool.",
    parameters: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["list", "remove", "status", "reset-cooldowns", "rotate"],
          description:
            "Action to perform: list accounts, remove an account, show status, reset cooldowns, or rotate to next account",
        },
        email: {
          type: "string",
          description: "Account email (required for 'remove' action)",
        },
        provider: {
          type: "string",
          enum: ["anthropic", "openai"],
          description: "Provider name: 'anthropic' (default) or 'openai'",
        },
      },
      required: ["action"],
    },
    async execute(args) {
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);

      // Add-account instructions (both providers use the same pool auth dialog)
      const providerLabel = provider === "openai" ? "ChatGPT Plus/Pro" : "Claude Pro/Max";
      const addAccountHint = `To add an account: run \`opencode auth login\` and select "OAuth Account Pool" → "${providerLabel}".`;

      // Provider-specific token endpoint cooldown
      const now = Date.now();
      const endpointCooldownUntil = provider === "openai"
        ? openaiTokenEndpointCooldownUntil
        : tokenEndpointCooldownUntil;

      switch (args.action) {
        case "list": {
          if (accounts.length === 0) {
            return `No accounts in the ${provider} pool.\n\n${addAccountHint}`;
          }
          const lines = accounts.map((a, i) => {
            const cooldown =
              a.cooldownUntil && a.cooldownUntil > now
                ? ` (cooldown: ${Math.ceil((a.cooldownUntil - now) / 60000)}m remaining)`
                : "";
            const lastUsed = a.lastUsed
              ? ` | last used: ${new Date(a.lastUsed).toLocaleString()}`
              : "";
            const accountIdSuffix = a.accountId ? ` | id: ${a.accountId.slice(0, 8)}...` : "";
            return `${i + 1}. ${a.email} [${a.status}]${cooldown}${lastUsed}${accountIdSuffix}`;
          });
          return `${provider} pool (${accounts.length} account${accounts.length === 1 ? "" : "s"}):\n\n${lines.join("\n")}`;
        }

        case "remove": {
          if (!args.email) {
            return "Error: email is required for remove action. Usage: remove <email>";
          }
          const removed = removeAccount(provider, args.email);
          if (removed) {
            const remaining = getAccounts(provider).length;
            return `Removed ${args.email} from ${provider} pool (${remaining} account${remaining === 1 ? "" : "s"} remaining).`;
          }
          return `Account ${args.email} not found in ${provider} pool.`;
        }

        case "status": {
          if (accounts.length === 0) {
            return `No accounts in the ${provider} pool.\n\n${addAccountHint}`;
          }
          const active = accounts.filter(
            (a) => a.status === "active" || a.status === "idle",
          ).length;
          const rateLimited = accounts.filter(
            (a) =>
              a.status === "rate-limited" &&
              a.cooldownUntil &&
              a.cooldownUntil > now,
          ).length;
          const authError = accounts.filter(
            (a) => a.status === "auth-error",
          ).length;
          const available = accounts.filter(
            (a) => !a.cooldownUntil || a.cooldownUntil <= now,
          ).length;

          const tokenGated = endpointCooldownUntil > now;
          const tokenGateInfo = tokenGated
            ? `  TOKEN ENDPOINT: RATE LIMITED (${Math.ceil((endpointCooldownUntil - now) / 60000)}m remaining)`
            : `  Token endpoint: OK`;

          return [
            `${provider} pool status:`,
            `  Total accounts: ${accounts.length}`,
            `  Available now:  ${available}`,
            `  Active/idle:    ${active}`,
            `  Rate limited:   ${rateLimited}`,
            `  Auth errors:    ${authError}`,
            "",
            tokenGateInfo,
            `Pool file: ${POOL_FILE}`,
          ].join("\n");
        }

        case "reset-cooldowns": {
          // Reset token endpoint cooldown (in-memory) for the selected provider
          let wasGated = false;
          if (provider === "openai") {
            wasGated = openaiTokenEndpointCooldownUntil > Date.now();
            openaiTokenEndpointCooldownUntil = 0;
          } else {
            wasGated = tokenEndpointCooldownUntil > Date.now();
            tokenEndpointCooldownUntil = 0;
          }

          // Reset per-account cooldowns (pool file)
          const pool = loadPool();
          let resetCount = 0;
          if (pool[provider]) {
            for (const account of pool[provider]) {
              if (account.cooldownUntil) {
                account.cooldownUntil = null;
                account.status = "idle";
                resetCount++;
              }
            }
            savePool(pool);
          }

          const parts = [];
          if (wasGated) parts.push("token endpoint cooldown cleared");
          if (resetCount > 0) parts.push(`${resetCount} account cooldown${resetCount === 1 ? "" : "s"} cleared`);
          if (parts.length === 0) parts.push("no active cooldowns");
          return `Reset (${provider}): ${parts.join(", ")}. Token endpoint requests will proceed on next attempt.`;
        }

        case "rotate": {
          if (accounts.length < 2) {
            return `Cannot rotate: only ${accounts.length} account(s) in pool. Add more accounts via Ctrl+A → OAuth Account Pool.`;
          }

          // Find which account is currently injected (most recently used)
          const current = [...accounts].sort(
            (a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0),
          )[0];

          const injectFn = provider === "openai" ? injectOpenAIPoolToken : injectPoolToken;
          const injected = await injectFn(client, current?.email);
          if (injected) {
            // Find which account was injected
            const nowAccounts = getAccounts(provider);
            const newest = [...nowAccounts].sort(
              (a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0),
            )[0];
            return `Rotated (${provider}): now using ${newest?.email || "unknown"}. Previous: ${current?.email || "unknown"}.`;
          }
          return `Rotation failed (${provider}) — no other active accounts available.`;
        }

        default:
          return `Unknown action: ${args.action}. Available: list, rotate, remove, status, reset-cooldowns`;
      }
    },
  };
}
