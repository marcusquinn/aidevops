/**
 * OAuth Multi-Account Pool (t1543, t1548, t1549)
 *
 * Enables multiple OAuth accounts per provider with automatic credential
 * rotation on rate limits (429). Stores credentials in a separate pool file
 * (~/.aidevops/oauth-pool.json) to avoid conflicts with OpenCode's auth.json.
 *
 * Architecture:
 *   - auth hook: registers "anthropic-pool", "openai-pool", and "cursor-pool"
 *     providers with OAuth/credential login flows
 *   - loader: returns a custom fetch wrapper that rotates credentials on 429
 *   - tool: /model-accounts-pool for listing/removing accounts
 *
 * Supported providers:
 *   - anthropic: Claude Pro/Max accounts (claude.ai OAuth)
 *   - openai: ChatGPT Plus/Pro accounts (auth.openai.com OAuth)
 *   - cursor: Cursor Pro accounts (cursor-agent CLI + local proxy sidecar)
 *
 * References:
 *   - Built-in auth plugin: opencode-anthropic-auth@0.0.13
 *   - OpenCode PR #11832 (upstream multi-account proposal)
 *   - Plugin API: @opencode-ai/plugin AuthHook type
 *   - OpenAI OAuth: CLIENT_ID=app_EMoamEEZ73f0CkXaXp7hrann, ISSUER=https://auth.openai.com
 *   - Cursor: opencode-cursor-auth@1.0.16 (POSO-PocketSolutions/opencode-cursor-auth)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { homedir, platform } from "os";
import { createHash, randomBytes } from "crypto";
import { createServer } from "http";
import { execSync, execFileSync, spawn } from "child_process";

// ---------------------------------------------------------------------------
// Dynamic CLI version detection (GH#18329 fix)
//
// Anthropic blanket-rejects token endpoint requests with unrecognised
// User-Agent strings (429). Hardcoding the version means we silently break
// when the CLI updates. Detect at module load time (~50ms), cache for the
// process lifetime, fall back to a known-good version if the CLI isn't found.
//
// Bun's fetch() also injects Origin, Referer, and Sec-Fetch-* headers that
// Anthropic rate-limits on. Token endpoint calls use execSync("curl ...")
// instead of fetch() to send exactly the headers we specify — nothing more.
// See: https://github.com/vinzabe/PERMANENT-opencode-anthropic-oauth-fix
// ---------------------------------------------------------------------------

const FALLBACK_CLAUDE_VERSION = "2.1.80";
const FALLBACK_OPENCODE_VERSION = "1.2.27";

/**
 * Detect the installed Claude CLI version.
 * Uses execFileSync (no shell) to avoid metacharacter issues on Windows
 * and maintain consistency with curlTokenEndpoint().
 * Returns just the version number (e.g. "2.1.80").
 * @returns {string}
 */
function detectClaudeCliVersion() {
  try {
    const raw = execFileSync("claude", ["--version"], {
      timeout: 3000,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    // Output is like "2.1.80 (Claude Code)" or just "2.1.80"
    const match = raw.match(/^(\d+\.\d+\.\d+)/);
    if (match) return match[1];
  } catch {
    // CLI not installed or timed out
  }
  return FALLBACK_CLAUDE_VERSION;
}

/**
 * Detect the installed OpenCode CLI version.
 * Tries "opencode" first, then "oc" as fallback.
 * Uses execFileSync (no shell) for cross-platform safety.
 * Returns just the version number (e.g. "1.2.27").
 * @returns {string}
 */
function detectOpenCodeVersion() {
  for (const bin of ["opencode", "oc"]) {
    try {
      const raw = execFileSync(bin, ["--version"], {
        timeout: 3000,
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      const match = raw.match(/^(\d+\.\d+\.\d+)/);
      if (match) return match[1];
    } catch {
      // Try next binary
    }
  }
  return FALLBACK_OPENCODE_VERSION;
}

// Detect once at module load — cached for process lifetime
const DETECTED_CLAUDE_VERSION = detectClaudeCliVersion();
const DETECTED_OPENCODE_VERSION = detectOpenCodeVersion();
const ANTHROPIC_USER_AGENT = `claude-cli/${DETECTED_CLAUDE_VERSION} (external, cli)`;

console.error(`[aidevops] OAuth pool: detected Claude CLI v${DETECTED_CLAUDE_VERSION}, OpenCode v${DETECTED_OPENCODE_VERSION}`);

/**
 * Get the dynamically-detected Anthropic User-Agent string.
 * Exported for use by provider-auth.mjs on API requests.
 * @returns {string}
 */
export function getAnthropicUserAgent() {
  return ANTHROPIC_USER_AGENT;
}

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
const OPENCODE_USER_AGENT = `opencode/${DETECTED_OPENCODE_VERSION}`;
/** OpenAI uses a local redirect server at port 1455 for its built-in flow.
 *  For the pool's add-account flow we use the same redirect URI so the
 *  authorization code can be pasted back into the terminal prompt. */
const OPENAI_REDIRECT_URI = "http://localhost:1455/auth/callback";
const OPENAI_OAUTH_SCOPES = "openid profile email offline_access";

// ---------------------------------------------------------------------------
// Cursor constants (t1549)
// Cursor uses cursor-agent CLI for authentication and a local HTTP proxy
// sidecar that translates OpenAI-compatible requests to cursor-agent calls.
// Credentials are extracted from the local Cursor installation (SQLite DB
// on Linux, auth.json on macOS) or via `cursor-agent login`.
// ---------------------------------------------------------------------------

const CURSOR_PROVIDER_ID = "cursor";
const CURSOR_PROXY_HOST = "127.0.0.1";
const CURSOR_PROXY_DEFAULT_PORT = 32123;
const CURSOR_PROXY_BASE_URL = `http://${CURSOR_PROXY_HOST}:${CURSOR_PROXY_DEFAULT_PORT}/v1`;

/**
 * Get the path to cursor-agent's auth.json based on platform.
 * @returns {string}
 */
function getCursorAgentAuthPath() {
  const plat = platform();
  if (plat === "darwin") {
    return join(HOME, ".cursor", "auth.json");
  }
  if (plat === "win32") {
    const appData = process.env.APPDATA || join(HOME, "AppData", "Roaming");
    return join(appData, "Cursor", "auth.json");
  }
  // Linux and others
  const configDir = process.env.XDG_CONFIG_HOME || join(HOME, ".config");
  return join(configDir, "cursor", "auth.json");
}

/**
 * Get the path to Cursor IDE's state database (for local credential extraction).
 * @returns {string}
 */
function getCursorStateDbPath() {
  const plat = platform();
  if (plat === "darwin") {
    return join(HOME, "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb");
  }
  if (plat === "win32") {
    const appData = process.env.APPDATA || join(HOME, "AppData", "Roaming");
    return join(appData, "Cursor", "User", "globalStorage", "state.vscdb");
  }
  // Linux
  return join(HOME, ".config", "Cursor", "User", "globalStorage", "state.vscdb");
}

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
 * In-memory timestamp of the last 429 from the Cursor proxy (t1549).
 * @type {number}
 */
let cursorProxyCooldownUntil = 0;

/**
 * Execute a curl request to a token endpoint, returning a Response-like object.
 *
 * Uses curl instead of fetch() because Bun's fetch injects Origin, Referer,
 * and Sec-Fetch-* headers automatically. Anthropic's token endpoint
 * rate-limits/blocks requests with these extra browser-like headers (429).
 * curl only sends exactly the headers we specify.
 *
 * See: https://github.com/vinzabe/PERMANENT-opencode-anthropic-oauth-fix (Bug 3)
 *
 * @param {string} url - Token endpoint URL
 * @param {Object} options - { headers: Record<string,string>, body: string, contentType?: string }
 * @param {string} context - description for logging
 * @returns {{ ok: boolean, status: number, statusText: string, headers: { get(k: string): string|null }, json(): Promise<any>, text(): Promise<string> }}
 */
function curlTokenEndpoint(url, options, context) {
  const args = [
    "-sS",                          // silent but show errors
    "-i",                           // include response headers in output
    "-w", "\n%{http_code}",         // append HTTP status on last line
    "-X", "POST",
    "-H", `Content-Type: ${options.contentType || "application/json"}`,
    "-H", `User-Agent: ${options.headers["User-Agent"]}`,
    "--data-binary", "@-",          // read body from stdin (keeps secrets off argv/ps)
    "--max-time", "15",             // hard timeout
    url,
  ];

  try {
    // Use execFileSync (no shell) to avoid metacharacter issues with
    // parentheses in User-Agent. Body is passed via stdin to keep
    // OAuth secrets (refresh_token, authorization_code) off the process
    // command line where they'd be visible via ps/proc.
    const raw = execFileSync("curl", args, {
      encoding: "utf-8",
      timeout: 20_000,
      input: options.body,
    });

    // Output format with -i: headers\r\n\r\nbody\n<http_code>
    // Last line is the HTTP status code from -w
    const lines = raw.trimEnd().split("\n");
    const statusCode = parseInt(lines.pop(), 10) || 500;
    const fullOutput = lines.join("\n");

    // Split headers from body at the blank line (\r\n\r\n)
    const headerBodySplit = fullOutput.indexOf("\r\n\r\n");
    let responseHeaders = {};
    let responseBody = fullOutput;

    if (headerBodySplit !== -1) {
      const headerBlock = fullOutput.substring(0, headerBodySplit);
      responseBody = fullOutput.substring(headerBodySplit + 4);

      // Parse response headers into a case-insensitive map
      for (const line of headerBlock.split("\r\n")) {
        const colonIdx = line.indexOf(":");
        if (colonIdx > 0) {
          const key = line.substring(0, colonIdx).trim().toLowerCase();
          const value = line.substring(colonIdx + 1).trim();
          responseHeaders[key] = value;
        }
      }
    }

    const statusText = statusCode === 200 ? "OK"
      : statusCode === 429 ? "Too Many Requests"
      : statusCode === 401 ? "Unauthorized"
      : statusCode === 400 ? "Bad Request"
      : `HTTP ${statusCode}`;

    return {
      ok: statusCode >= 200 && statusCode < 300,
      status: statusCode,
      statusText,
      headers: {
        get(key) {
          return responseHeaders[key.toLowerCase()] ?? null;
        },
      },
      async json() { return JSON.parse(responseBody); },
      async text() { return responseBody; },
    };
  } catch (err) {
    // Log only the error code/status — never err.message which may
    // contain the request body with OAuth secrets
    const reason = err?.code || `exit ${err?.status ?? "unknown"}`;
    console.error(`[aidevops] OAuth pool: ${context} curl failed (${reason})`);
    return {
      ok: false,
      status: 500,
      statusText: "curl failed",
      headers: { get() { return null; } },
      async json() { return { error: reason }; },
      async text() { return reason; },
    };
  }
}

/**
 * Fetch from the Anthropic token endpoint. Single attempt with 429 cooldown gate.
 *
 * If a previous call got 429 within the cooldown window, this returns a
 * synthetic 429 response immediately — no network request made. This prevents
 * every session start from hitting the endpoint and extending the rate limit.
 *
 * Uses curl instead of fetch() to avoid Bun's automatic header injection
 * (Origin, Referer, Sec-Fetch-*) which Anthropic rate-limits on.
 *
 * @param {string} body - JSON string body
 * @param {string} context - description for logging
 * @returns {Promise<{ ok: boolean, status: number, statusText: string, headers: { get(k: string): string|null }, json(): Promise<any>, text(): Promise<string> }>}
 */
async function fetchTokenEndpoint(body, context) {
  // Check cooldown gate — skip the request entirely if rate limited recently
  const now = Date.now();
  if (tokenEndpointCooldownUntil > now) {
    const remainingSeconds = Math.ceil((tokenEndpointCooldownUntil - now) / 1000);
    const remainingMinutes = Math.ceil(remainingSeconds / 60);
    console.error(
      [
        `[aidevops] OAuth pool: ${context} skipped — token endpoint rate limited,`,
        `cooldown ${remainingMinutes}m remaining.`,
        "Use /model-accounts-pool reset-cooldowns to clear manually.",
      ].join(" "),
    );
    return {
      ok: false,
      status: 429,
      statusText: "Rate Limited (cooldown)",
      headers: { get() { return null; } },
      async json() { return { error: "Rate limited (cooldown)" }; },
      async text() { return "Rate limited (cooldown)"; },
    };
  }

  const response = curlTokenEndpoint(ANTHROPIC_TOKEN_ENDPOINT, {
    headers: { "User-Agent": ANTHROPIC_USER_AGENT },
    body,
  }, context);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    const cooldownMs = parseRetryAfterCooldown(retryAfter);
    tokenEndpointCooldownUntil = Date.now() + cooldownMs;
    const cooldownMinutes = Math.ceil(cooldownMs / 60000);
    console.error(
      [
        `[aidevops] OAuth pool: ${context} failed: rate limited by Anthropic.`,
        `Cooldown set for ${cooldownMinutes}m — no further token requests until then.`,
        "Use /model-accounts-pool reset-cooldowns to clear manually.",
      ].join(" "),
    );
  } else if (!response.ok) {
    console.error(`[aidevops] OAuth pool: ${context} failed: HTTP ${response.status}`);
  }

  return response;
}

/**
 * Fetch from the OpenAI token endpoint using form-encoded body (t1548).
 * OpenAI uses application/x-www-form-urlencoded, not JSON.
 * Uses curl to avoid Bun's automatic header injection.
 *
 * @param {URLSearchParams} params - Form parameters
 * @param {string} context - description for logging
 * @returns {Promise<{ ok: boolean, status: number, statusText: string, headers: { get(k: string): string|null }, json(): Promise<any>, text(): Promise<string> }>}
 */
async function fetchOpenAITokenEndpoint(params, context) {
  const now = Date.now();
  if (openaiTokenEndpointCooldownUntil > now) {
    const remainingMinutes = Math.ceil((openaiTokenEndpointCooldownUntil - now) / 60000);
    console.error(
      [
        `[aidevops] OAuth pool: ${context} skipped — OpenAI token endpoint rate limited,`,
        `cooldown ${remainingMinutes}m remaining.`,
        "Use /model-accounts-pool reset-cooldowns to clear manually.",
      ].join(" "),
    );
    return {
      ok: false,
      status: 429,
      statusText: "Rate Limited (cooldown)",
      headers: { get() { return null; } },
      async json() { return { error: "Rate limited (cooldown)" }; },
      async text() { return "Rate limited (cooldown)"; },
    };
  }

  const response = curlTokenEndpoint(OPENAI_TOKEN_ENDPOINT, {
    headers: { "User-Agent": OPENCODE_USER_AGENT },
    body: params.toString(),
    contentType: "application/x-www-form-urlencoded",
  }, context);

  if (response.status === 429) {
    const retryAfter = response.headers.get("retry-after");
    const cooldownMs = parseRetryAfterCooldown(retryAfter);
    openaiTokenEndpointCooldownUntil = Date.now() + cooldownMs;
    const cooldownMinutes = Math.ceil(cooldownMs / 60000);
    console.error(
      [
        `[aidevops] OAuth pool: ${context} failed: rate limited by OpenAI.`,
        `Cooldown set for ${cooldownMinutes}m — no further token requests until then.`,
        "Use /model-accounts-pool reset-cooldowns to clear manually.",
      ].join(" "),
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
 * @returns {{ promise: Promise<string>, ready: Promise<boolean>, close: () => void }}
 *   - promise: resolves with the authorization code, rejects on timeout/error
 *   - ready: resolves true when listening, false on startup failure
 *   - close: manually close the server (cleanup)
 */
function startOAuthCallbackServer() {
  let resolveCode;
  let rejectCode;
  let server;
  let timeoutId;
  let resolveReady;

  const promise = new Promise((resolve, reject) => {
    resolveCode = resolve;
    rejectCode = reject;
  });

  /** Resolves true when the server is listening, false on startup failure. */
  const ready = new Promise((resolve) => {
    resolveReady = resolve;
  });

  /** Escape HTML special characters to prevent injection in error pages. */
  const escapeHtml = (unsafe) => unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#039;");

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

    // Only handle the OAuth callback path — reject everything else
    if (reqUrl.pathname !== "/auth/callback") {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not found");
      return;
    }

    const code = reqUrl.searchParams.get("code");
    const error = reqUrl.searchParams.get("error");

    if (error) {
      const safeError = escapeHtml(error);
      const safeDescription = escapeHtml(reqUrl.searchParams.get("error_description") || "");
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body>
        <h2>Authorization Failed</h2>
        <p>Error: ${safeError}</p>
        <p>${safeDescription}</p>
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

    // No code or error on the callback path
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("Waiting for OAuth callback...");
  });

  function cleanup() {
    if (timeoutId) clearTimeout(timeoutId);
    if (server) {
      try { server.close(); } catch { /* ignore */ }
    }
  }

  server.on("error", (err) => {
    cleanup();
    if (err.code === "EADDRINUSE") {
      console.error(
        [
          `[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use —`,
          "OpenCode's built-in auth may be running.",
          "The user will need to copy the code from the browser URL bar manually.",
        ].join(" "),
      );
      resolveReady(false);
      return;
    } else {
      console.error(`[aidevops] OAuth pool: callback server error: ${err.message}`);
    }
    resolveReady(false);
    rejectCode(err);
  });

  server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => {
    console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`);
    resolveReady(true);
  });

  // Auto-close after timeout
  timeoutId = setTimeout(() => {
    console.error(`[aidevops] OAuth pool: callback server timed out after ${OAUTH_CALLBACK_TIMEOUT_MS / 1000}s`);
    cleanup();
    rejectCode(new Error("OAuth callback timeout"));
  }, OAUTH_CALLBACK_TIMEOUT_MS);

  return { promise, ready, close: cleanup };
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
 * @property {PoolAccount[]} [cursor]
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

  // Refuse to save "unknown" email when named accounts already exist.
  // This prevents phantom entries when the auth UI skips the email prompt
  // and the profile API fails to resolve the email.
  if (account.email === "unknown") {
    const namedAccounts = pool[provider].filter((a) => a.email !== "unknown");
    if (namedAccounts.length > 0) {
      const emails = namedAccounts.map((a) => a.email).join(", ");
      console.error(
        [
          "[aidevops] OAuth pool: REFUSED to save account with unknown email.",
          `${namedAccounts.length} named account(s) exist: ${emails}.`,
          'Re-auth via "Add Account to Pool" and enter the email when prompted,',
          "or use /model-accounts-pool to manage accounts.",
        ].join(" "),
      );
      return false;
    }
  }

  // Match by email
  const idx = pool[provider].findIndex((a) => a.email === account.email);

  if (idx >= 0) {
    pool[provider][idx] = account;
  } else {
    pool[provider].push(account);
  }
  savePool(pool);
  return true;
}

/**
 * Save a token to the pending area when email couldn't be resolved.
 * Pending tokens are stored in the pool file under a `_pending` key
 * so they survive restarts. The user assigns them to accounts via
 * the MCP tool or they are offered on next session start.
 * @param {string} provider
 * @param {object} tokenData - { refresh, access, expires, added, ... }
 */
function savePendingToken(provider, tokenData) {
  const pool = loadPool();
  const pendingKey = `_pending_${provider}`;
  pool[pendingKey] = tokenData;
  savePool(pool);
  const existing = (pool[provider] || []).map((a) => a.email).join(", ");
  console.error(
    [
      `[aidevops] OAuth pool: token saved to pending for ${provider}.`,
      `Existing accounts: ${existing}.`,
      "Use /model-accounts-pool to assign this token to an account.",
    ].join(" "),
  );
}

/**
 * Get a pending token for a provider, if one exists.
 * @param {string} provider
 * @returns {object|null}
 */
function getPendingToken(provider) {
  const pool = loadPool();
  return pool[`_pending_${provider}`] || null;
}

/**
 * Assign a pending token to an existing account by email.
 * Removes the pending entry after assignment.
 * @param {string} provider
 * @param {string} email
 * @returns {boolean} true if assigned
 */
function assignPendingToken(provider, email) {
  const pool = loadPool();
  const pendingKey = `_pending_${provider}`;
  const pending = pool[pendingKey];
  if (!pending) return false;

  if (!pool[provider]) pool[provider] = [];
  const idx = pool[provider].findIndex((a) => a.email === email);
  if (idx < 0) return false;

  // Update the existing account with the pending token
  const updates = {
    refresh: pending.refresh,
    access: pending.access,
    expires: pending.expires,
    lastUsed: new Date().toISOString(),
    status: "active",
    cooldownUntil: null,
  };
  if (pending.accountId) {
    updates.accountId = pending.accountId;
  }
  Object.assign(pool[provider][idx], updates);

  // Remove pending entry
  delete pool[pendingKey];
  savePool(pool);
  console.error(`[aidevops] OAuth pool: assigned pending token to ${email}`);
  return true;
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
 * Refresh a Cursor access token by re-reading from cursor-agent's local store (t1549).
 * Cursor doesn't have a standard OAuth refresh endpoint — tokens are managed
 * by the Cursor IDE and cursor-agent CLI. We re-read the local auth file
 * to pick up any token refreshes done by the IDE.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
async function refreshCursorAccessToken(account) {
  try {
    // Try cursor-agent auth.json first
    const authPath = getCursorAgentAuthPath();
    if (existsSync(authPath)) {
      const content = readFileSync(authPath, "utf-8");
      const data = JSON.parse(content);
      if (data.accessToken) {
        const tokenInfo = decodeCursorJWT(data.accessToken);
        // Only use this token if it matches the account email (or email is unknown)
        if (!tokenInfo.email || tokenInfo.email === account.email || account.email === "unknown") {
          return {
            access: data.accessToken,
            refresh: data.refreshToken || account.refresh,
            expires: tokenInfo.expiresAt || (Date.now() + 3600_000),
          };
        }
      }
    }

    // Fallback: try Cursor IDE's state database (SQLite)
    const dbPath = getCursorStateDbPath();
    if (existsSync(dbPath)) {
      const accessToken = readCursorStateDbValue(dbPath, "cursorAuth/accessToken");
      if (accessToken) {
        const refreshToken = readCursorStateDbValue(dbPath, "cursorAuth/refreshToken") || account.refresh;
        const tokenInfo = decodeCursorJWT(accessToken);
        if (!tokenInfo.email || tokenInfo.email === account.email || account.email === "unknown") {
          return {
            access: accessToken,
            refresh: refreshToken,
            expires: tokenInfo.expiresAt || (Date.now() + 3600_000),
          };
        }
      }
    }

    console.error(
      [
        `[aidevops] OAuth pool: Cursor token refresh failed for ${account.email} —`,
        "no valid token found in cursor-agent auth or Cursor IDE state",
      ].join(" "),
    );
    return null;
  } catch (err) {
    console.error(
      `[aidevops] OAuth pool: Cursor token refresh error for ${account.email}: ${err.message}`,
    );
    return null;
  }
}

/**
 * Decode a Cursor JWT to extract email and expiry. No signature verification.
 * @param {string} token
 * @returns {{ email: string|undefined, expiresAt: number|undefined }}
 */
function decodeCursorJWT(token) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return {};
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    return {
      email: payload.email || undefined,
      expiresAt: typeof payload.exp === "number" ? payload.exp * 1000 : undefined,
    };
  } catch {
    return {};
  }
}

/**
 * Read a value from Cursor's state.vscdb SQLite database.
 * Uses sqlite3 CLI to avoid native module dependencies.
 * @param {string} dbPath
 * @param {string} key
 * @returns {string|null}
 */
function readCursorStateDbValue(dbPath, key) {
  // Validate key to prevent SQL injection — keys are dotted identifiers
  // like "cursorAuth/accessToken" or "storage.serviceMachineId"
  if (!/^[\w./:@-]+$/.test(key)) {
    return null;
  }
  try {
    const result = execSync(
      `sqlite3 "${dbPath}" "SELECT value FROM ItemTable WHERE key = '${key}'" 2>/dev/null`,
      { encoding: "utf-8", timeout: 5000 },
    ).trim();
    return result || null;
  } catch {
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
  let tokens;
  if (provider === "cursor") {
    tokens = await refreshCursorAccessToken(account);
  } else if (provider === "openai") {
    tokens = await refreshOpenAIAccessToken(account);
  } else {
    tokens = await refreshAccessToken(account);
  }
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
 * @param {"anthropic"|"openai"|"cursor"} provider
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

  let injectFn;
  if (provider === "cursor") {
    injectFn = injectCursorPoolToken;
  } else if (provider === "openai") {
    injectFn = injectOpenAIPoolToken;
  } else {
    injectFn = injectPoolToken;
  }
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
 * Seeds auth entries for anthropic-pool, openai-pool, and cursor-pool providers.
 * @param {any} client - OpenCode SDK client
 */
export async function initPoolAuth(client) {
  // Seed pool provider entries (for "Add Account" flows)
  await seedPoolAuthEntry(client, "anthropic-pool");
  await seedPoolAuthEntry(client, "openai-pool");
  await seedPoolAuthEntry(client, "cursor-pool");

  // Inject pool tokens into built-in providers
  await injectPoolToken(client);
  await injectOpenAIPoolToken(client);
  await injectCursorPoolToken(client);
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

// ---------------------------------------------------------------------------
// Cursor proxy sidecar lifecycle (t1549)
// ---------------------------------------------------------------------------

/**
 * In-memory reference to the cursor-agent proxy sidecar process.
 * The proxy translates OpenAI-compatible HTTP requests to cursor-agent CLI calls.
 * @type {{ process: import("child_process").ChildProcess | null, port: number, baseURL: string }}
 */
const cursorProxy = {
  process: null,
  port: CURSOR_PROXY_DEFAULT_PORT,
  baseURL: CURSOR_PROXY_BASE_URL,
};

/**
 * Check if cursor-agent CLI is available.
 * @returns {boolean}
 */
function isCursorAgentAvailable() {
  try {
    execSync("cursor-agent --version", {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * Check if the cursor proxy sidecar is healthy.
 * @returns {Promise<boolean>}
 */
async function isCursorProxyHealthy() {
  try {
    const res = await fetch(`http://${CURSOR_PROXY_HOST}:${cursorProxy.port}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Start the cursor-agent proxy sidecar if not already running.
 * The proxy is a lightweight HTTP server that spawns cursor-agent for each request.
 * Uses Node's built-in http.createServer (no Bun dependency).
 *
 * @param {string} [workspaceDir] - Workspace directory for cursor-agent
 * @returns {Promise<string>} Base URL of the proxy
 */
export async function ensureCursorProxy(workspaceDir) {
  // Check if proxy is already running (ours or external)
  if (await isCursorProxyHealthy()) {
    return cursorProxy.baseURL;
  }

  if (!isCursorAgentAvailable()) {
    throw new Error(
      "cursor-agent not found. Install it: curl -fsS https://cursor.com/install | bash",
    );
  }

  const effectiveWorkspace = workspaceDir || process.cwd();

  return new Promise((resolve, reject) => {
    const server = createServer(async (req, res) => {
      // Health check endpoint
      if (req.url === "/health") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, provider: "cursor-pool" }));
        return;
      }

      // Only handle chat completions
      if (req.url !== "/v1/chat/completions" && req.url !== "/chat/completions") {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: `Unsupported path: ${req.url}` } }));
        return;
      }

      // Read request body
      let body = "";
      for await (const chunk of req) {
        body += chunk;
      }

      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: "Invalid JSON body" } }));
        return;
      }

      const model = normalizeCursorModel(parsed.model || "auto");
      const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
      const isStream = parsed.stream === true;

      // Build prompt from messages
      const prompt = messages.map((m) => {
        const role = (m.role || "user").toUpperCase();
        const content = typeof m.content === "string"
          ? m.content
          : Array.isArray(m.content)
            ? m.content.filter((p) => p.type === "text").map((p) => p.text).join("\n")
            : "";
        return `${role}: ${content}`;
      }).join("\n\n");

      try {
        const child = spawn("cursor-agent", [
          "--print",
          "--output-format", "text",
          "--workspace", effectiveWorkspace,
          "--model", model,
          prompt,
        ], {
          stdio: ["pipe", "pipe", "pipe"],
          env: process.env,
        });

        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (data) => { stdout += data.toString(); });
        child.stderr.on("data", (data) => { stderr += data.toString(); });

        child.on("close", (code) => {
          const content = stdout.trim() || stderr.trim() || "(empty response)";

          // On non-zero exit, return a proper OpenAI-compatible error response
          // instead of wrapping stderr in a chat completion body.
          if (code !== 0) {
            const errorMsg = stderr.trim() || `cursor-agent exited with code ${code}`;
            res.writeHead(502, { "Content-Type": "application/json" });
            res.end(JSON.stringify({
              error: {
                message: errorMsg,
                type: "server_error",
                code: 502,
              },
            }));
            return;
          }

          // NOTE: Streaming limitation — cursor-agent writes its entire response
          // to stdout on exit, so we cannot stream incrementally. The full response
          // is buffered and sent as a single SSE chunk. True incremental streaming
          // would require cursor-agent to support a streaming output mode (e.g.,
          // writing partial results to stdout as they arrive from the upstream model).
          if (isStream) {
            res.writeHead(200, {
              "Content-Type": "text/event-stream",
              "Cache-Control": "no-cache",
              "Connection": "keep-alive",
            });
            const chunk = {
              id: `cursor-pool-${Date.now()}`,
              object: "chat.completion.chunk",
              created: Math.floor(Date.now() / 1000),
              model,
              choices: [{
                index: 0,
                delta: { content },
                finish_reason: "stop",
              }],
            };
            res.write(`data: ${JSON.stringify(chunk)}\n\n`);
            res.write("data: [DONE]\n\n");
            res.end();
          } else {
            const payload = {
              id: `cursor-pool-${Date.now()}`,
              object: "chat.completion",
              created: Math.floor(Date.now() / 1000),
              model,
              choices: [{
                index: 0,
                message: { role: "assistant", content },
                finish_reason: "stop",
              }],
            };
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify(payload));
          }
        });

        child.on("error", (err) => {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: { message: `cursor-agent error: ${err.message}` } }));
        });
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: `Proxy error: ${err.message}` } }));
      }
    });

    server.on("error", (err) => {
      if (err.code === "EADDRINUSE") {
        // Port in use — check if it's our proxy
        isCursorProxyHealthy().then((healthy) => {
          if (healthy) {
            resolve(cursorProxy.baseURL);
          } else {
            // Try a random port
            server.listen(0, CURSOR_PROXY_HOST, () => {
              const addr = server.address();
              cursorProxy.port = addr.port;
              cursorProxy.baseURL = `http://${CURSOR_PROXY_HOST}:${addr.port}/v1`;
              console.error(`[aidevops] OAuth pool: cursor proxy started on port ${addr.port} (default port in use)`);
              resolve(cursorProxy.baseURL);
            });
          }
        });
        return;
      }
      reject(err);
    });

    server.listen(CURSOR_PROXY_DEFAULT_PORT, CURSOR_PROXY_HOST, () => {
      cursorProxy.port = CURSOR_PROXY_DEFAULT_PORT;
      cursorProxy.baseURL = CURSOR_PROXY_BASE_URL;
      console.error(`[aidevops] OAuth pool: cursor proxy started on port ${CURSOR_PROXY_DEFAULT_PORT}`);
      resolve(cursorProxy.baseURL);
    });

    // Store server reference for cleanup
    cursorProxy.process = server;
  });
}

/**
 * Normalize Cursor model names (aliases).
 * @param {string} model
 * @returns {string}
 */
function normalizeCursorModel(model) {
  const aliases = {
    "gpt-5": "gpt-5.2",
    "sonnet-4": "sonnet-4.5",
  };
  return aliases[model] || model;
}

/**
 * Stop the cursor proxy sidecar if running.
 */
export function stopCursorProxy() {
  if (cursorProxy.process) {
    try {
      cursorProxy.process.close();
    } catch {
      // ignore
    }
    cursorProxy.process = null;
    console.error("[aidevops] OAuth pool: cursor proxy stopped");
  }
}

/**
 * Pick the best Cursor pool account and inject its token into the built-in "cursor"
 * provider's auth entry (t1549). Also ensures the proxy sidecar is running.
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {Promise<boolean>} true if a token was injected
 */
export async function injectCursorPoolToken(client, skipEmail) {
  const accounts = getAccounts("cursor");
  if (accounts.length === 0) return false;

  const now = Date.now();
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
    const accessToken = await ensureValidToken("cursor", candidate);
    if (!accessToken) {
      console.error(`[aidevops] OAuth pool: skipping invalid Cursor token for ${candidate.email}`);
      continue;
    }
    account = candidate;
    break;
  }

  if (!account) return false;

  // Ensure the proxy sidecar is running
  try {
    await ensureCursorProxy();
  } catch (err) {
    console.error(`[aidevops] OAuth pool: cursor proxy failed to start: ${err.message}`);
    // Continue anyway — the proxy might be started externally
  }

  // Write to the cursor provider's auth entry
  try {
    await client.auth.set({
      path: { id: CURSOR_PROVIDER_ID },
      body: {
        type: "api",
        key: "cursor-pool",
      },
    });

    patchAccount("cursor", account.email, {
      lastUsed: new Date().toISOString(),
      status: "active",
    });

    console.error(`[aidevops] OAuth pool: injected Cursor token for ${account.email}`);
    return true;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to inject Cursor token: ${err.message}`);
    return false;
  }
}

/**
 * Create the auth hook for the anthropic-pool provider.
 * This provider exists solely for the "Add Account to Pool" OAuth flow.
 * It has no models — users select models from the built-in "anthropic" provider,
 * which uses pool tokens injected into auth.json by initPoolAuth/injectPoolToken.
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createPoolAuthHook(client) {
  return {
    provider: "anthropic-pool",

    methods: [
      {
        get label() {
          const accounts = getAccounts("anthropic");
          if (accounts.length === 0) {
            return "Add Account to Pool (Claude Pro/Max)";
          }
          return `Add Account to Pool (${accounts.length} account${accounts.length === 1 ? "" : "s"})`;
        },
        type: "oauth",
        prompts: [
          {
            type: "text",
            key: "email",
            get message() {
              const accounts = getAccounts("anthropic");
              if (accounts.length === 0) {
                return "Account email (required to match tokens to accounts)";
              }
              const emails = accounts.map((a, i) => `  ${i + 1}. ${a.email}`).join("\n");
              return `Existing accounts:\n${emails}\nEnter email (existing to re-auth, or new to add)`;
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
                        "User-Agent": ANTHROPIC_USER_AGENT,
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
                  console.error("[aidevops] OAuth pool: could not resolve email from profile API");
                }
              }

              const tokenData = {
                refresh: json.refresh_token,
                access: json.access_token,
                expires: Date.now() + json.expires_in * 1000,
              };

              const saved = upsertAccount("anthropic", {
                email: resolvedEmail,
                ...tokenData,
                added: new Date().toISOString(),
                lastUsed: new Date().toISOString(),
                status: "active",
                cooldownUntil: null,
              });

              if (!saved) {
                // upsertAccount refused — unknown email with named accounts.
                // Save to pending so the token isn't lost. The user can assign
                // it to an account via /model-accounts-pool or it will be
                // offered on next session start.
                savePendingToken("anthropic", {
                  ...tokenData,
                  added: new Date().toISOString(),
                });
                // Also inject into the built-in provider for this session
                try {
                  await client.auth.set({
                    path: { id: "anthropic" },
                    body: { type: "oauth", ...tokenData },
                  });
                } catch {
                  // Best-effort session injection
                }
                return { type: "success", ...tokenData };
              }

              const totalAccounts = getAccounts("anthropic").length;
              console.error(
                `[aidevops] OAuth pool: added ${resolvedEmail} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
              );
              console.error(
                `[aidevops] OAuth pool: Account added successfully. Now switch to the "Anthropic" provider and select a model (e.g. claude-sonnet) to start chatting. The "Anthropic Pool" provider is for account management only.`,
              );

              // Inject the new token into the built-in anthropic provider
              await injectPoolToken(client);

              return { type: "success", ...tokenData };
            },
          };
        },
      },
    ],
  };
}

/**
 * Create the auth hook for the openai-pool provider (t1548).
 * This provider exists solely for the "Add Account to Pool" OAuth flow.
 * It has no models — users select models from the built-in "openai" provider,
 * which uses pool tokens injected into auth.json by injectOpenAIPoolToken.
 *
 * OpenAI OAuth uses form-encoded bodies and a local redirect server (port 1455)
 * for its built-in flow. For the pool's add-account flow we use the same
 * redirect URI with a code-paste UX (same as Anthropic pool).
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createOpenAIPoolAuthHook(client) {
  return {
    provider: "openai-pool",

    methods: [
      {
        get label() {
          const accounts = getAccounts("openai");
          if (accounts.length === 0) {
            return "Add Account to Pool (ChatGPT Plus/Pro)";
          }
          return `Add Account to Pool (${accounts.length} account${accounts.length === 1 ? "" : "s"})`;
        },
        type: "oauth",
        prompts: [
          {
            type: "text",
            key: "email",
            get message() {
              const accounts = getAccounts("openai");
              if (accounts.length === 0) {
                return "Account email (required to match tokens to accounts)";
              }
              const emails = accounts.map((a, i) => `  ${i + 1}. ${a.email}`).join("\n");
              return `Existing accounts:\n${emails}\nEnter email (existing to re-auth, or new to add)`;
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
          let autoCaptureReady = false;
          try {
            callbackServer = startOAuthCallbackServer();
            autoCaptureReady = await callbackServer.ready.catch(() => false);
            if (autoCaptureReady) {
              // Store the code when the server catches it (non-blocking)
              callbackServer.promise
                .then((code) => { serverCode = code; })
                .catch(() => {
                  /* timeout or error — user can paste manually */
                  callbackServer = null;
                });
            } else {
              // Server failed to bind (EADDRINUSE etc.) — fall back to manual paste
              console.error("[aidevops] OAuth pool: callback server failed to start — manual code paste required");
              callbackServer = null;
            }
          } catch {
            // Server construction failed — fall back to manual paste
            console.error("[aidevops] OAuth pool: callback server failed to start — manual code paste required");
            callbackServer = null;
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
              autoCaptureReady
                ? `3. After authorizing, the code will be captured automatically`
                : `3. After authorizing, copy the authorization code from the browser URL`,
              autoCaptureReady
                ? `4. Press Enter here to complete (or paste the code manually if needed): `
                : `4. Paste the authorization code here: `,
            ].join("\n"),
            method: "code",
            callback: async (code) => {
              // Use server-captured code if available, otherwise use manual input
              let authCode = code?.trim();
              if ((!authCode || authCode.length < 5) && serverCode) {
                authCode = serverCode;
                console.error("[aidevops] OAuth pool: using auto-captured code from callback server");
              } else if ((!authCode || authCode.length < 5) && autoCaptureReady && callbackServer) {
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

              const tokenData = {
                refresh: json.refresh_token || "",
                access: json.access_token,
                expires: Date.now() + (json.expires_in || 3600) * 1000,
              };

              const saved = upsertAccount("openai", {
                email: resolvedEmail,
                ...tokenData,
                added: new Date().toISOString(),
                lastUsed: new Date().toISOString(),
                status: "active",
                cooldownUntil: null,
                accountId,
              });

              if (!saved) {
                // upsertAccount refused — unknown email with named accounts.
                // Save to pending so the token isn't lost.
                savePendingToken("openai", {
                  ...tokenData,
                  added: new Date().toISOString(),
                  accountId,
                });
                // Also inject into the built-in provider for this session
                try {
                  await client.auth.set({
                    path: { id: "openai" },
                    body: { type: "oauth", ...tokenData, accountId },
                  });
                } catch {
                  // Best-effort session injection
                }
                return { type: "success", ...tokenData };
              }

              const totalAccounts = getAccounts("openai").length;
              console.error(
                `[aidevops] OAuth pool: added OpenAI ${resolvedEmail} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
              );
              console.error(
                `[aidevops] OAuth pool: Account added successfully. Now switch to the "OpenAI" provider and select a model (e.g. gpt-4o) to start chatting. The "OpenAI Pool" provider is for account management only.`,
              );

              // Inject the new token into the built-in openai provider
              await injectOpenAIPoolToken(client);

              return { type: "success", ...tokenData };
            },
          };
        },
      },
    ],
  };
}

/**
 * Create the auth hook for the cursor-pool provider (t1549).
 * This provider exists solely for the "Add Account to Pool" flow.
 * It has no models — users select models from the built-in "cursor" provider,
 * which uses pool tokens injected by injectCursorPoolToken.
 *
 * Cursor authentication works differently from Anthropic/OpenAI:
 *   1. Credentials are extracted from the local Cursor installation
 *      (cursor-agent auth.json or Cursor IDE's state.vscdb)
 *   2. If no local credentials exist, `cursor-agent login` opens a browser
 *   3. The proxy sidecar translates OpenAI-compatible requests to cursor-agent CLI calls
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createCursorPoolAuthHook(client) {
  return {
    provider: "cursor-pool",

    methods: [
      {
        get label() {
          const accounts = getAccounts("cursor");
          if (accounts.length === 0) {
            return "Add Account to Pool (Cursor Pro)";
          }
          return `Add Account to Pool (${accounts.length} account${accounts.length === 1 ? "" : "s"})`;
        },
        type: "api",
        prompts: [
          {
            type: "text",
            key: "email",
            get message() {
              const accounts = getAccounts("cursor");
              if (accounts.length === 0) {
                return "Account email (required to match tokens to accounts)";
              }
              const emails = accounts.map((a, i) => `  ${i + 1}. ${a.email}`).join("\n");
              return `Existing accounts:\n${emails}\nEnter email (existing to re-auth, or new to add)`;
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

          // Strategy 1: Extract from cursor-agent auth.json
          const authPath = getCursorAgentAuthPath();
          let accessToken = null;
          let refreshToken = "";
          let resolvedEmail = email;

          if (existsSync(authPath)) {
            try {
              const content = readFileSync(authPath, "utf-8");
              const data = JSON.parse(content);
              if (data.accessToken) {
                accessToken = data.accessToken;
                refreshToken = data.refreshToken || "";
                const tokenInfo = decodeCursorJWT(accessToken);
                if (tokenInfo.email && resolvedEmail === "unknown") {
                  resolvedEmail = tokenInfo.email;
                }
                console.error(`[aidevops] OAuth pool: found Cursor credentials in ${authPath}`);
              }
            } catch (err) {
              console.error(`[aidevops] OAuth pool: failed to read cursor-agent auth: ${err.message}`);
            }
          }

          // Strategy 2: Try Cursor IDE's state database
          if (!accessToken) {
            const dbPath = getCursorStateDbPath();
            if (existsSync(dbPath)) {
              accessToken = readCursorStateDbValue(dbPath, "cursorAuth/accessToken");
              refreshToken = readCursorStateDbValue(dbPath, "cursorAuth/refreshToken") || "";
              if (accessToken) {
                const cachedEmail = readCursorStateDbValue(dbPath, "cursorAuth/cachedEmail");
                if (cachedEmail && resolvedEmail === "unknown") {
                  resolvedEmail = cachedEmail;
                }
                if (resolvedEmail === "unknown") {
                  const tokenInfo = decodeCursorJWT(accessToken);
                  if (tokenInfo.email) resolvedEmail = tokenInfo.email;
                }
                console.error(`[aidevops] OAuth pool: found Cursor credentials in state DB`);
              }
            }
          }

          // Strategy 3: Run cursor-agent login (opens browser)
          if (!accessToken) {
            if (!isCursorAgentAvailable()) {
              console.error(
                `[aidevops] OAuth pool: cursor-agent not found. Install it: curl -fsS https://cursor.com/install | bash`,
              );
              return { type: "failed" };
            }

            console.error("[aidevops] OAuth pool: no local Cursor credentials found, running cursor-agent login...");
            try {
              execSync("cursor-agent login", {
                encoding: "utf-8",
                timeout: 120_000,
                stdio: ["inherit", "pipe", "pipe"],
              });
              // Re-read auth after login
              if (existsSync(authPath)) {
                const content = readFileSync(authPath, "utf-8");
                const data = JSON.parse(content);
                if (data.accessToken) {
                  accessToken = data.accessToken;
                  refreshToken = data.refreshToken || "";
                  const tokenInfo = decodeCursorJWT(accessToken);
                  if (tokenInfo.email && resolvedEmail === "unknown") {
                    resolvedEmail = tokenInfo.email;
                  }
                }
              }
            } catch (err) {
              console.error(`[aidevops] OAuth pool: cursor-agent login failed: ${err.message}`);
              return { type: "failed" };
            }
          }

          if (!accessToken) {
            console.error("[aidevops] OAuth pool: no Cursor access token obtained");
            return { type: "failed" };
          }

          const tokenInfo = decodeCursorJWT(accessToken);
          const tokenData = {
            refresh: refreshToken,
            access: accessToken,
            expires: tokenInfo.expiresAt || (Date.now() + 3600_000),
          };

          const saved = upsertAccount("cursor", {
            email: resolvedEmail,
            ...tokenData,
            added: new Date().toISOString(),
            lastUsed: new Date().toISOString(),
            status: "active",
            cooldownUntil: null,
          });

          if (!saved) {
            savePendingToken("cursor", {
              ...tokenData,
              added: new Date().toISOString(),
            });
            return { type: "success", key: "cursor-pool" };
          }

          const totalAccounts = getAccounts("cursor").length;
          console.error(
            `[aidevops] OAuth pool: added Cursor ${resolvedEmail} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
          );
          console.error(
            `[aidevops] OAuth pool: Account added successfully. Now switch to the "Cursor" provider and select a model to start chatting. The "Cursor Pool" provider is for account management only.`,
          );

          // Inject the new token and start proxy
          await injectCursorPoolToken(client);

          return { type: "success", key: "cursor-pool" };
        },
      },
    ],
  };
}

/**
 * Register the pool provider for the auth dialog display name.
 *
 * The auth hook (provider: "anthropic-pool") automatically appears in the
 * Ctrl+A auth dialog via OpenCode's resolvePluginProviders(). However, the
 * display name comes from config.provider[id].name — without a config entry
 * it shows the raw ID "anthropic-pool".
 *
 * We register a config entry with NO models so it provides the display name
 * but doesn't appear in the model picker. Previous versions had dummy models
 * which caused the provider to show up as a selectable (but broken) model.
 *
 * Models are served by the built-in providers ("anthropic", "openai", "cursor"),
 * which use pool tokens injected into auth.json by initPoolAuth/injectPoolToken/
 * injectOpenAIPoolToken/injectCursorPoolToken.
 *
 * @param {any} config - OpenCode config object
 * @returns {number} number of changes made
 */
export function registerPoolProvider(config) {
  if (!config.provider) config.provider = {};
  let registered = 0;

  // A dummy model is required for the provider to appear in the "Connect a
  // provider" auth dialog (Ctrl+A). Without at least one model entry, OpenCode
  // filters the provider out of the dialog entirely. The model uses minimal
  // limits and zero cost so it doesn't appear as a usable model in the picker.
  // Register or migrate: create if absent, or update if present but missing
  // the dummy model (e.g. from a previous version that stored no models).
  const poolAccountModel = {
    "pool-account-management": {
      name: "[Account Setup Only] Use Anthropic provider for models",
      attachment: false, tool_call: false, temperature: false,
      modalities: { input: ["text"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: { context: 1000, output: 100 },
      family: "pool",
    },
  };

  // Pool provider definitions — model names are always force-updated to fix
  // stale names from prior versions (the condition previously only wrote when
  // the provider was absent, leaving old "Add/Manage Accounts" names in place).
  const poolProviders = [
    {
      id: "anthropic-pool",
      name: "Anthropic Pool (Account Management)",
      npm: "@ai-sdk/anthropic",
      api: "https://api.anthropic.com/v1",
      modelName: "[Account Setup Only] Use Anthropic provider for models",
    },
    {
      id: "openai-pool",
      name: "OpenAI Pool (Account Management)",
      npm: "@ai-sdk/openai",
      api: "https://api.openai.com/v1",
      modelName: "[Account Setup Only] Use OpenAI provider for models",
    },
    {
      id: "cursor-pool",
      name: "Cursor Pool (Account Management)",
      npm: "@ai-sdk/openai-compatible",
      api: CURSOR_PROXY_BASE_URL,
      modelName: "[Account Setup Only] Use Cursor provider for models",
    },
  ];

  for (const def of poolProviders) {
    const models = {
      "pool-account-management": {
        name: def.modelName,
        attachment: false, tool_call: false, temperature: false,
        modalities: { input: ["text"], output: ["text"] },
        cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
        limit: { context: 1000, output: 100 },
        family: "pool",
      },
    };

    if (!config.provider[def.id]) {
      config.provider[def.id] = {
        name: def.name,
        npm: def.npm,
        api: def.api,
        models,
      };
      registered++;
    } else {
      // Compare full provider object — only update+increment when any field differs
      const existing = config.provider[def.id];
      const modelsChanged = JSON.stringify(existing.models) !== JSON.stringify(models);
      if (existing.name !== def.name || existing.npm !== def.npm ||
          existing.api !== def.api || modelsChanged) {
        existing.name = def.name;
        existing.npm = def.npm;
        existing.api = def.api;
        existing.models = models;
        registered++;
      }
    }
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
    description: [
      "Manage OAuth account pool for provider credential rotation.",
      "Use 'list' to see all accounts and their status,",
      "'rotate' to switch to the next pool account,",
      "'remove <email>' to remove an account,",
      "'assign-pending <email>' to assign a pending unidentified token to an account,",
      "'check' to test token validity for all accounts,",
      "'status' for rotation statistics.",
      "Supports providers: anthropic (Claude Pro/Max), openai (ChatGPT Plus/Pro),",
      "and cursor (Cursor Pro).",
      "The agent should route natural language requests about managing",
      "provider accounts, OAuth pools, or credential rotation to this tool.",
    ].join(" "),
    parameters: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["list", "remove", "status", "reset-cooldowns", "rotate", "assign-pending", "check"],
          description:
            "Action to perform: list accounts, remove an account, show status, reset cooldowns, rotate to next account, assign a pending token, or check token validity",
        },
        email: {
          type: "string",
          description: "Account email (required for 'remove' and 'assign-pending' actions)",
        },
        provider: {
          type: "string",
          enum: ["anthropic", "openai", "cursor"],
          description: "Provider name: 'anthropic' (default), 'openai', or 'cursor'",
        },
      },
      required: ["action"],
    },
    async execute(args) {
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);

      // Provider-specific add-account instructions
      const addAccountHints = {
        anthropic: `To add an account: run \`opencode auth login\` and select "Anthropic Pool".`,
        openai: `To add an account: run \`opencode auth login\` and select "OpenAI Pool".`,
        cursor: `To add an account: run \`opencode auth login\` and select "Cursor Pool". Requires cursor-agent CLI.`,
      };
      const addAccountHint = addAccountHints[provider] || addAccountHints.anthropic;

      // Provider-specific token endpoint cooldown
      const now = Date.now();
      const endpointCooldowns = {
        anthropic: tokenEndpointCooldownUntil,
        openai: openaiTokenEndpointCooldownUntil,
        cursor: cursorProxyCooldownUntil,
      };
      const endpointCooldownUntil = endpointCooldowns[provider] || 0;

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
          // Check for pending unassigned tokens
          const pending = getPendingToken(provider);
          const pendingLine = pending
            ? `\n\nPENDING: Unassigned token (added: ${pending.added}). Use assign-pending <email> to assign it.`
            : "";
          return `${provider} pool (${accounts.length} account${accounts.length === 1 ? "" : "s"}):\n\n${lines.join("\n")}${pendingLine}`;
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
          if (provider === "cursor") {
            wasGated = cursorProxyCooldownUntil > Date.now();
            cursorProxyCooldownUntil = 0;
          } else if (provider === "openai") {
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
            const poolNames = { anthropic: "Anthropic Pool", openai: "OpenAI Pool", cursor: "Cursor Pool" };
            const poolName = poolNames[provider] || "Pool";
            return `Cannot rotate: only ${accounts.length} account(s) in pool. Add more accounts via Ctrl+A → ${poolName}.`;
          }

          // Find which account is currently injected (most recently used)
          const current = [...accounts].sort(
            (a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0),
          )[0];

          let injectFn;
          if (provider === "cursor") {
            injectFn = injectCursorPoolToken;
          } else if (provider === "openai") {
            injectFn = injectOpenAIPoolToken;
          } else {
            injectFn = injectPoolToken;
          }
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

        case "assign-pending": {
          const pending = getPendingToken(provider);
          if (!pending) {
            return `No pending token for ${provider}. Pending tokens are created when you re-auth via the Pool provider but the email couldn't be identified.`;
          }
          if (!args.email) {
            const emails = accounts.map((a) => a.email).join(", ");
            return `Pending ${provider} token found (added: ${pending.added}). Assign it to one of: ${emails}\n\nUsage: assign-pending with email parameter.`;
          }
          const assigned = assignPendingToken(provider, args.email);
          if (assigned) {
            return `Assigned pending token to ${args.email} in ${provider} pool. Token is now active.`;
          }
          return `Failed to assign: account ${args.email} not found in ${provider} pool. Available: ${accounts.map((a) => a.email).join(", ")}`;
        }

        case "check": {
          // Health check: test token validity for all accounts across all
          // providers (or a specific provider if specified)
          const providersToCheck = args.provider
            ? [args.provider]
            : ["anthropic", "openai", "cursor"];

          const results = [];

          for (const prov of providersToCheck) {
            const provAccounts = getAccounts(prov);
            if (provAccounts.length === 0) continue;

            results.push(`\n## ${prov} (${provAccounts.length} account${provAccounts.length === 1 ? "" : "s"})`);

            for (const account of provAccounts) {
              const lines = [];
              lines.push(`  ${account.email}:`);

              // Token expiry
              const expiresIn = account.expires - now;
              if (expiresIn <= 0) {
                lines.push(`    Token: EXPIRED (${new Date(account.expires).toLocaleString()})`);
              } else {
                const mins = Math.floor(expiresIn / 60000);
                const hours = Math.floor(mins / 60);
                const timeStr = hours > 0 ? `${hours}h ${mins % 60}m` : `${mins}m`;
                lines.push(`    Token: expires in ${timeStr}`);
              }

              // Status and cooldown
              lines.push(`    Status: ${account.status}`);
              if (account.cooldownUntil && account.cooldownUntil > now) {
                const cdMins = Math.ceil((account.cooldownUntil - now) / 60000);
                lines.push(`    Cooldown: ${cdMins}m remaining`);
              }

              // Last used
              if (account.lastUsed) {
                const lastUsedAgo = now - new Date(account.lastUsed).getTime();
                const lastMins = Math.floor(lastUsedAgo / 60000);
                const lastHours = Math.floor(lastMins / 60);
                const lastStr = lastHours > 0 ? `${lastHours}h ${lastMins % 60}m ago` : `${lastMins}m ago`;
                lines.push(`    Last used: ${lastStr}`);
              }

              // Refresh token presence (not the value)
              lines.push(`    Refresh token: ${account.refresh ? "present" : "MISSING"}`);

              // Test token validity via a lightweight /v1/models GET request
              if (account.access && expiresIn > 0) {
                try {
                  let testOk = false;
                  if (prov === "anthropic") {
                    const testResp = await fetch("https://api.anthropic.com/v1/models", {
                      method: "GET",
                      headers: {
                        "Authorization": `Bearer ${account.access}`,
                        "User-Agent": ANTHROPIC_USER_AGENT,
                        "anthropic-version": "2023-06-01",
                        "anthropic-beta": "oauth-2025-04-20",
                      },
                    });
                    testOk = testResp.ok || testResp.status === 403;
                    // 403 means token is valid but lacks scope — still proves auth works
                    if (testResp.status === 401) {
                      lines.push(`    Validity: INVALID (401 — needs refresh)`);
                    } else if (testOk) {
                      lines.push(`    Validity: OK`);
                    } else {
                      lines.push(`    Validity: HTTP ${testResp.status}`);
                    }
                  } else if (prov === "openai") {
                    const testResp = await fetch("https://api.openai.com/v1/models", {
                      headers: {
                        "Authorization": `Bearer ${account.access}`,
                        "User-Agent": OPENCODE_USER_AGENT,
                      },
                    });
                    testOk = testResp.ok;
                    if (testResp.status === 401) {
                      lines.push(`    Validity: INVALID (401 — needs refresh)`);
                    } else if (testOk) {
                      lines.push(`    Validity: OK`);
                    } else {
                      lines.push(`    Validity: HTTP ${testResp.status}`);
                    }
                  } else {
                    lines.push(`    Validity: (skipped — ${prov} uses proxy)`);
                  }
                } catch (err) {
                  lines.push(`    Validity: ERROR (${err.code || err.message})`);
                }
              } else if (expiresIn <= 0) {
                lines.push(`    Validity: EXPIRED — will auto-refresh on next use`);
              } else {
                lines.push(`    Validity: no access token`);
              }

              results.push(lines.join("\n"));
            }

            // Token endpoint status for this provider
            const epCooldown = prov === "anthropic" ? tokenEndpointCooldownUntil
              : prov === "openai" ? openaiTokenEndpointCooldownUntil
              : cursorProxyCooldownUntil;
            if (epCooldown > now) {
              results.push(`  Token endpoint: RATE LIMITED (${Math.ceil((epCooldown - now) / 60000)}m remaining)`);
            } else {
              results.push(`  Token endpoint: OK`);
            }

            // Pending tokens
            const pending = getPendingToken(prov);
            if (pending) {
              results.push(`  PENDING: Unassigned token (added: ${pending.added})`);
            }
          }

          if (results.length === 0) {
            const poolNames = { anthropic: "Anthropic Pool", openai: "OpenAI Pool", cursor: "Cursor Pool" };
            return `No accounts in any pool.\n\nTo add an account:\n1. Run \`opencode auth login\` (or Ctrl+A)\n2. Select a pool provider (${Object.values(poolNames).join(", ")})\n3. Enter your account email and complete the OAuth flow\n4. After success, switch to the main provider and select a model`;
          }

          return `OAuth Pool Health Check${results.join("\n")}`;
        }

        default:
          return `Unknown action: ${args.action}. Available: list, rotate, remove, assign-pending, status, reset-cooldowns, check`;
      }
    },
  };
}
