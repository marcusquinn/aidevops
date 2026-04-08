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
 *   - tool: /model-accounts-pool for list/rotate/remove/check/status/assign-pending/reset-cooldowns
 *   - shell: oauth-pool-helper.sh for add/check/list/remove/rotate/status (no OpenCode SDK needed)
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

import {
  readFileSync, writeFileSync, existsSync, mkdirSync,
  openSync, closeSync, renameSync, chmodSync,
  constants as fsConstants,
} from "fs";
import { join, dirname } from "path";
import { homedir, platform } from "os";
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
/** Detect a CLI version by trying binaries. Returns first match or fallback. */
function detectCliVersion(binaries, fallback) {
  for (const bin of binaries) {
    try {
      const raw = execFileSync(bin, ["--version"], { timeout: 3000, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      const match = raw.match(/^(\d+\.\d+\.\d+)/);
      if (match) return match[1];
    } catch { /* not installed */ }
  }
  return fallback;
}
function detectClaudeCliVersion() { return detectCliVersion(["claude"], FALLBACK_CLAUDE_VERSION); }
function detectOpenCodeVersion() { return detectCliVersion(["opencode", "oc"], FALLBACK_OPENCODE_VERSION); }

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
// Advisory lock file — shared with oauth-pool-helper.sh (flock-based).
// Both writers must acquire this lock for read-modify-write operations.
const POOL_LOCK_FILE = POOL_FILE + ".lock";

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
// Google OAuth constants (issue #5614)
// Google AI Pro/Ultra/Workspace subscription accounts.
// Tokens are injected as ADC bearer tokens (GOOGLE_OAUTH_ACCESS_TOKEN env var)
// which Gemini CLI, Vertex AI SDK, and generativelanguage.googleapis.com pick up.
// Health check: GET /v1beta/models?pageSize=1 on generativelanguage.googleapis.com
// Isolation: separate in-memory cooldown, separate pool key — failures never
// cascade to anthropic/openai/cursor providers.
// ---------------------------------------------------------------------------

const GOOGLE_CLIENT_ID = "681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com";
const GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
/** OOB redirect — code is displayed in the browser for manual paste */
const GOOGLE_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob";
const GOOGLE_OAUTH_SCOPES = "https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/cloud-platform openid email profile";
const GOOGLE_HEALTH_CHECK_URL = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1";

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

/** Platform-specific path resolution for Cursor directories. */
const CURSOR_PATHS = (() => {
  const plat = platform();
  if (plat === "darwin") return { auth: join(HOME, ".cursor", "auth.json"), db: join(HOME, "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb") };
  if (plat === "win32") { const ad = process.env.APPDATA || join(HOME, "AppData", "Roaming"); return { auth: join(ad, "Cursor", "auth.json"), db: join(ad, "Cursor", "User", "globalStorage", "state.vscdb") }; }
  const cd = process.env.XDG_CONFIG_HOME || join(HOME, ".config");
  return { auth: join(cd, "cursor", "auth.json"), db: join(cd, "Cursor", "User", "globalStorage", "state.vscdb") };
})();
function getCursorAgentAuthPath() { return CURSOR_PATHS.auth; }
function getCursorStateDbPath() { return CURSOR_PATHS.db; }

// ---------------------------------------------------------------------------
// Shared cooldown constants
// ---------------------------------------------------------------------------

/** Default cooldown on auth failure (ms) */
const AUTH_FAILURE_COOLDOWN_MS = 300_000;

/** Cooldown after a 429 on the token endpoint (ms) — 5 minutes */
const TOKEN_ENDPOINT_COOLDOWN_MS = 300_000;

// ---------------------------------------------------------------------------
// Token endpoint helpers
// ---------------------------------------------------------------------------

// formatDuration → oauth-pool-tool.mjs

// formatAgo → oauth-pool-tool.mjs

/**
 * Parse Retry-After header and return a bounded cooldown.
 * Supports both integer seconds and HTTP-date formats.
 * @param {string|null} retryAfter
 * @returns {number}
 */
function parseRetryAfterCooldown(retryAfter) {
  if (!retryAfter) return TOKEN_ENDPOINT_COOLDOWN_MS;
  const secs = Number.parseInt(retryAfter, 10);
  const ms = Number.isFinite(secs) ? secs * 1000 : Math.max((Date.parse(retryAfter) || 0) - Date.now(), 0);
  return Math.max(ms, TOKEN_ENDPOINT_COOLDOWN_MS);
}

/**
 * Handle a 429 response from a token endpoint: parse Retry-After, set the
 * cooldown variable, and log a message. Returns the cooldown duration (ms).
 *
 * @param {object} response - Response-like object with headers.get()
 * @param {string} context - description for logging
 * @param {string} providerLabel - e.g. "Anthropic", "OpenAI", "Google"
 * @param {(until: number) => void} setCooldown - setter for the cooldown variable
 * @returns {number} cooldown duration in ms
 */
// handleTokenEndpoint429 inlined into fetchProviderTokenEndpoint

/**
 * Check whether a token endpoint is currently rate-limited (in cooldown).
 * If so, logs a message and returns a synthetic 429 response.
 * Returns null if the endpoint is available.
 *
 * @param {number} cooldownUntil - timestamp until which the endpoint is gated
 * @param {string} context - description for logging
 * @param {string} providerLabel - e.g. "OpenAI", "Google"
 * @returns {{ ok: false, status: 429, statusText: string, headers: object, json(): Promise<any>, text(): Promise<string> } | null}
 */
/** Synthetic 429 response for cooldown-gated endpoints. */
const COOLDOWN_RESPONSE = { ok: false, status: 429, statusText: "Rate Limited (cooldown)", headers: { get() { return null; } }, async json() { return { error: "Rate limited (cooldown)" }; }, async text() { return "Rate limited (cooldown)"; } };

function checkCooldownGate(cooldownUntil, context, providerLabel) {
  if (cooldownUntil <= Date.now()) return null;
  console.error(`[aidevops] OAuth pool: ${context} skipped — ${providerLabel} rate limited, ${Math.ceil((cooldownUntil - Date.now()) / 60000)}m remaining.`);
  return COOLDOWN_RESPONSE;
}

/**
 * Resolve the inject function for a given provider.
 * @param {"anthropic"|"openai"|"cursor"|"google"} provider
 * @returns {Function}
 */
const INJECT_FN_MAP = { cursor: injectCursorPoolToken, openai: injectOpenAIPoolToken, google: injectGooglePoolToken };
export function resolveInjectFn(provider) { return INJECT_FN_MAP[provider] || injectPoolToken; }

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
 * In-memory timestamp of the last 429 from the Google token endpoint (issue #5614).
 * Isolated from other providers — Google failures never affect anthropic/openai/cursor.
 * @type {number}
 */
let googleTokenEndpointCooldownUntil = 0;

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
// Curl response parsing helpers (extracted for complexity reduction)
function parseCurlResponse(raw) {
  const lines = raw.trimEnd().split("\n");
  const statusCode = parseInt(lines.pop(), 10) || 500;
  const fullOutput = lines.join("\n");
  const splitIdx = fullOutput.indexOf("\r\n\r\n");
  const headers = {};
  let body = fullOutput;
  if (splitIdx !== -1) {
    for (const line of fullOutput.substring(0, splitIdx).split("\r\n")) {
      const ci = line.indexOf(":");
      if (ci > 0) headers[line.substring(0, ci).trim().toLowerCase()] = line.substring(ci + 1).trim();
    }
    body = fullOutput.substring(splitIdx + 4);
  }
  return { statusCode, headers, body };
}
const STATUS_TEXT_MAP = { 200: "OK", 400: "Bad Request", 401: "Unauthorized", 429: "Too Many Requests" };
function statusCodeToText(sc) { return STATUS_TEXT_MAP[sc] || `HTTP ${sc}`; }
function buildCurlResponseObject(p) {
  return { ok: p.statusCode >= 200 && p.statusCode < 300, status: p.statusCode, statusText: statusCodeToText(p.statusCode),
    headers: { get(k) { return p.headers[k.toLowerCase()] ?? null; } }, async json() { return JSON.parse(p.body); }, async text() { return p.body; } };
}
function buildCurlErrorResponse(reason) {
  return { ok: false, status: 500, statusText: "curl failed", headers: { get() { return null; } }, async json() { return { error: reason }; }, async text() { return reason; } };
}

function curlTokenEndpoint(url, options, context) {
  const args = ["-sS", "-i", "-w", "\n%{http_code}", "-X", "POST",
    "-H", `Content-Type: ${options.contentType || "application/json"}`,
    "-H", `User-Agent: ${options.headers["User-Agent"]}`,
    "--data-binary", "@-", "--max-time", "15", url];
  try {
    const raw = execFileSync("curl", args, { encoding: "utf-8", timeout: 20_000, input: options.body });
    return buildCurlResponseObject(parseCurlResponse(raw));
  } catch (err) {
    const reason = err?.code || `exit ${err?.status ?? "unknown"}`;
    console.error(`[aidevops] OAuth pool: ${context} curl failed (${reason})`);
    return buildCurlErrorResponse(reason);
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
/**
 * Generic token endpoint fetch with cooldown gate and 429 handling.
 * All three provider-specific fetch functions delegate here.
 *
 * @param {{ url: string, userAgent: string, body: string, contentType?: string, cooldownUntil: number, providerLabel: string, setCooldown: (until: number) => void }} opts
 * @param {string} context - description for logging
 * @returns {Promise<{ ok: boolean, status: number, statusText: string, headers: object, json(): Promise<any>, text(): Promise<string> }>}
 */
async function fetchProviderTokenEndpoint(opts, context) {
  const gated = checkCooldownGate(opts.cooldownUntil, context, opts.providerLabel);
  if (gated) return gated;

  const response = curlTokenEndpoint(opts.url, {
    headers: { "User-Agent": opts.userAgent },
    body: opts.body,
    contentType: opts.contentType,
  }, context);

  if (response.status === 429) {
    const cdMs = parseRetryAfterCooldown(response.headers.get("retry-after"));
    opts.setCooldown(Date.now() + cdMs);
    console.error(`[aidevops] OAuth pool: ${context} rate limited by ${opts.providerLabel}. Cooldown ${Math.ceil(cdMs / 60000)}m.`);
  } else if (!response.ok) {
    console.error(`[aidevops] OAuth pool: ${context} failed: HTTP ${response.status}`);
  }

  return response;
}

export async function fetchTokenEndpoint(body, context) {
  return fetchProviderTokenEndpoint({
    url: ANTHROPIC_TOKEN_ENDPOINT,
    userAgent: ANTHROPIC_USER_AGENT,
    body,
    cooldownUntil: tokenEndpointCooldownUntil,
    providerLabel: "Anthropic",
    setCooldown: (until) => { tokenEndpointCooldownUntil = until; },
  }, context);
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
export async function fetchOpenAITokenEndpoint(params, context) {
  return fetchProviderTokenEndpoint({
    url: OPENAI_TOKEN_ENDPOINT,
    userAgent: OPENCODE_USER_AGENT,
    body: params.toString(),
    contentType: "application/x-www-form-urlencoded",
    cooldownUntil: openaiTokenEndpointCooldownUntil,
    providerLabel: "OpenAI",
    setCooldown: (until) => { openaiTokenEndpointCooldownUntil = until; },
  }, context);
}

/**
 * Fetch from the Google OAuth2 token endpoint (issue #5614).
 * Google uses JSON bodies (same as Anthropic, unlike OpenAI's form-encoded).
 * Uses curl to avoid Bun's automatic header injection.
 * Isolated cooldown — Google 429s never affect other providers.
 *
 * @param {string} body - JSON string body
 * @param {string} context - description for logging
 * @returns {Promise<{ ok: boolean, status: number, statusText: string, headers: { get(k: string): string|null }, json(): Promise<any>, text(): Promise<string> }>}
 */
export async function fetchGoogleTokenEndpoint(body, context) {
  return fetchProviderTokenEndpoint({
    url: GOOGLE_TOKEN_ENDPOINT,
    userAgent: ANTHROPIC_USER_AGENT,
    body,
    cooldownUntil: googleTokenEndpointCooldownUntil,
    providerLabel: "Google",
    setCooldown: (until) => { googleTokenEndpointCooldownUntil = until; },
  }, context);
}

// PKCE helpers → oauth-pool-auth.mjs

// OAuth callback server → oauth-pool-auth.mjs

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
 * @property {number} [priority] - Rotation priority (higher = preferred; missing/0 = default LRU)
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
 * Save the pool file with 0600 permissions using an atomic write
 * (temp file in the same directory + renameSync) so a mid-write crash
 * cannot corrupt the pool file.
 * @param {PoolData} data
 */
function savePool(data) {
  try {
    const dir = dirname(POOL_FILE);
    mkdirSync(dir, { recursive: true });
    const tmp = POOL_FILE + ".tmp." + process.pid;
    writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, POOL_FILE);
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to save pool file: ${err.message}`);
  }
}

/**
 * Execute a read-modify-write operation on the pool file with best-effort
 * cross-process coordination.
 *
 * Locking strategy:
 *   - Primary defense: savePool() uses atomic temp+rename, so partial writes
 *     never corrupt the file. Even without locking, the worst case is a lost
 *     update (last writer wins), not data corruption.
 *   - Advisory lock: oauth-pool-helper.sh uses Python's fcntl.flock() on
 *     POOL_LOCK_FILE. Node.js doesn't expose flock() natively. We open the
 *     same lock file as a coordination signal — if a future Node.js version
 *     or native addon adds flock support, it can be wired in here.
 *   - The lock file path (POOL_LOCK_FILE) is shared between both writers so
 *     they can be coordinated when a proper flock binding is available.
 *
 * @template T
 * @param {() => T} fn - Function to execute (should call loadPool/savePool)
 * @returns {T}
 */
function withPoolLock(fn) {
  const dir = dirname(POOL_FILE);
  mkdirSync(dir, { recursive: true });

  // Open the lock file to signal intent. On Linux with flock(1) available,
  // the shell script's flock will see this fd and coordinate. Without native
  // flock(), this is advisory-only — atomic writes are the real safety net.
  let lockFd = -1;
  try {
    lockFd = openSync(POOL_LOCK_FILE, fsConstants.O_WRONLY | fsConstants.O_CREAT, 0o600);
    return fn();
  } finally {
    if (lockFd >= 0) {
      try { closeSync(lockFd); } catch { /* ignore */ }
    }
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
export function upsertAccount(provider, account) {
  return withPoolLock(() => {
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
  });
}

/**
 * Save a token to the pending area when email couldn't be resolved.
 * Pending tokens are stored in the pool file under a `_pending` key
 * so they survive restarts. The user assigns them to accounts via
 * the MCP tool or they are offered on next session start.
 * @param {string} provider
 * @param {object} tokenData - { refresh, access, expires, added, ... }
 */
export function savePendingToken(provider, tokenData) {
  withPoolLock(() => {
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
  });
}

/**
 * Get a pending token for a provider, if one exists.
 * @param {string} provider
 * @returns {object|null}
 */
export function getPendingToken(provider) {
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
export function assignPendingToken(provider, email) {
  return withPoolLock(() => {
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
  });
}

/**
 * Remove an account from the pool by email.
 * @param {string} provider
 * @param {string} email
 * @returns {boolean} true if removed
 */
export function removeAccount(provider, email) {
  return withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return false;
    const before = pool[provider].length;
    pool[provider] = pool[provider].filter((a) => a.email !== email);
    if (pool[provider].length === before) return false;
    savePool(pool);
    return true;
  });
}

/**
 * Update an account's status and cooldown in the pool.
 * @param {string} provider
 * @param {string} email
 * @param {Partial<PoolAccount>} patch
 */
export function patchAccount(provider, email, patch) {
  withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return;
    const account = pool[provider].find((a) => a.email === email);
    if (!account) return;
    Object.assign(account, patch);
    savePool(pool);
  });
}

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------

/**
 * Refresh an expired Anthropic access token using the refresh token.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
/** Generic OAuth token refresh — shared by Anthropic, OpenAI, and Google. */
async function refreshProviderToken(account, fetchFn, label) {
  try {
    const response = await fetchFn(account);
    if (!response.ok) return null;
    const json = await response.json();
    return { access: json.access_token, refresh: json.refresh_token || account.refresh, expires: Date.now() + (json.expires_in || 3600) * 1000 };
  } catch (err) {
    console.error(`[aidevops] OAuth pool: ${label} token refresh error for ${account.email}: ${err.message}`);
    return null;
  }
}

async function refreshAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchTokenEndpoint(
    JSON.stringify({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: ANTHROPIC_CLIENT_ID }),
    `refresh for ${a.email}`,
  ), "Anthropic");
}

async function refreshOpenAIAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchOpenAITokenEndpoint(
    new URLSearchParams({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: OPENAI_CLIENT_ID }),
    `refresh for ${a.email}`,
  ), "OpenAI");
}

/**
 * Refresh a Cursor access token by re-reading from cursor-agent's local store (t1549).
 * Cursor doesn't have a standard OAuth refresh endpoint — tokens are managed
 * by the Cursor IDE and cursor-agent CLI. We re-read the local auth file
 * to pick up any token refreshes done by the IDE.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
// Cursor credential helpers (shared by refresh + auth hook)
function isCursorTokenForAccount(tokenEmail, accountEmail) {
  return !tokenEmail || tokenEmail === accountEmail || accountEmail === "unknown";
}
export function readCursorAuthJsonCredentials(accountEmail) {
  const authPath = getCursorAgentAuthPath();
  if (!existsSync(authPath)) return null;
  try {
    const data = JSON.parse(readFileSync(authPath, "utf-8"));
    if (!data.accessToken) return null;
    const ti = decodeCursorJWT(data.accessToken);
    if (!isCursorTokenForAccount(ti.email, accountEmail)) return null;
    return { access: data.accessToken, refresh: data.refreshToken, expires: ti.expiresAt || (Date.now() + 3600_000), email: ti.email };
  } catch { return null; }
}
export function readCursorStateDbCredentials(accountEmail) {
  const dbPath = getCursorStateDbPath();
  if (!existsSync(dbPath)) return null;
  const at = readCursorStateDbValue(dbPath, "cursorAuth/accessToken");
  if (!at) return null;
  const ti = decodeCursorJWT(at);
  if (!isCursorTokenForAccount(ti.email, accountEmail)) return null;
  return { access: at, refresh: readCursorStateDbValue(dbPath, "cursorAuth/refreshToken"), expires: ti.expiresAt || (Date.now() + 3600_000), email: ti.email || readCursorStateDbValue(dbPath, "cursorAuth/cachedEmail") };
}
export function isCursorAgentAvailable() {
  try { execFileSync("cursor-agent", ["--version"], { timeout: 3000, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }); return true; } catch { return false; }
}

async function refreshCursorAccessToken(account) {
  try {
    const creds = readCursorAuthJsonCredentials(account.email) || readCursorStateDbCredentials(account.email);
    if (creds) return { access: creds.access, refresh: creds.refresh || account.refresh, expires: creds.expires };
    // Keychain fallback (macOS)
    if (platform() === "darwin") {
      try {
        const at = execSync('security find-generic-password -s "cursor-access-token" -a "cursor-user" -w 2>/dev/null', { encoding: "utf-8", timeout: 5000 }).trim();
        if (at && at.length > 10) {
          let rt = account.refresh;
          try { rt = execSync('security find-generic-password -s "cursor-refresh-token" -a "cursor-user" -w 2>/dev/null', { encoding: "utf-8", timeout: 5000 }).trim(); } catch { /* not found */ }
          const ti = decodeCursorJWT(at);
          return { access: at, refresh: rt || account.refresh, expires: ti.expiresAt || (Date.now() + 3600_000) };
        }
      } catch { /* not found */ }
    }
    console.error(`[aidevops] OAuth pool: Cursor token refresh failed for ${account.email}`);
    return null;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: Cursor token refresh error for ${account.email}: ${err.message}`);
    return null;
  }
}

async function refreshGoogleAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchGoogleTokenEndpoint(
    JSON.stringify({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: GOOGLE_CLIENT_ID }),
    `Google refresh for ${a.email}`,
  ), "Google");
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

// ---------------------------------------------------------------------------
// Proactive refresh (DISABLED — kept for future use)
//
// Initially added when we thought Anthropic was revoking tokens server-side
// before the 8h local expiry. The actual root cause was the provider auth
// hook not being wired into the plugin export — tokens were sent as
// x-api-key (API key mode) instead of Authorization: Bearer (OAuth mode).
// With the auth hook fix in index.mjs, tokens last their full claimed
// lifetime and proactive refresh is unnecessary.
//
// If server-side revocation is ever confirmed as a real issue (not a header
// bug), uncomment this constant and the age check inside ensureValidToken()
// below. The 401/403 handler in provider-auth.mjs is the primary safety net.
//
// const PROACTIVE_REFRESH_MAX_AGE_MS = 30 * 60_000; // 30 minutes
// ---------------------------------------------------------------------------

/**
 * Ensure an account has a valid (non-expired) access token.
 * Routes to the correct refresh function based on provider.
 *
 * Relies on the local `expires` timestamp to decide when to refresh.
 * If Anthropic revokes a token server-side before local expiry, the
 * 401/403 handler in provider-auth.mjs catches it and force-refreshes
 * by calling this function with `expires: 0`.
 *
 * @param {string} provider
 * @param {PoolAccount} account
 * @returns {Promise<string|null>} access token or null on failure
 */
export async function ensureValidToken(provider, account) {
  if (account.access && account.expires > Date.now()) {
    // Proactive refresh (DISABLED — uncomment if server-side revocation recurs):
    // const totalLifetime = 28800_000; // 8h in ms (Anthropic default)
    // const remaining = account.expires - Date.now();
    // const age = totalLifetime - remaining;
    // if (age >= PROACTIVE_REFRESH_MAX_AGE_MS) {
    //   console.error(
    //     `[aidevops] OAuth pool: proactive refresh for ${account.email} — ` +
    //     `token ~${Math.round(age / 60000)}m old`,
    //   );
    //   // Fall through to refresh below
    // } else {
    return account.access;
    // }
  }
  const REFRESH_FN = { cursor: refreshCursorAccessToken, openai: refreshOpenAIAccessToken, google: refreshGoogleAccessToken };
  const tokens = await (REFRESH_FN[provider] || refreshAccessToken)(account);
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
// Expired cooldown normalization (MJS counterpart of shell's auto_clear_expired_cooldowns)
// ---------------------------------------------------------------------------

/**
 * Auto-clear expired cooldowns for a provider's accounts.
 *
 * Accounts with status "rate-limited" or "auth-error" whose cooldownUntil
 * has passed are reset to "idle" with cooldownUntil cleared. Without this,
 * the inject functions' status filter (`["active", "idle"].includes(...)`)
 * permanently excludes these accounts even after their cooldown expires —
 * causing rotation to skip them (the "only 2 of 3 accounts" bug).
 *
 * The shell script handles this via auto_clear_expired_cooldowns() called
 * before cmd_rotate(). This function is the MJS counterpart, called before
 * account selection in inject functions (the mid-session rotation path).
 *
 * Modifies accounts in-place AND persists changes to disk.
 *
 * @param {string} provider
 * @param {PoolAccount[]} accounts - mutable array from getAccounts()
 * @returns {number} count of accounts normalized
 */
/** Check if an account has an expired cooldown. */
function hasExpiredCooldown(a, now) {
  return a.cooldownUntil && a.cooldownUntil <= now && (a.status === "rate-limited" || a.status === "auth-error");
}

export function normalizeExpiredCooldowns(provider, accounts) {
  const now = Date.now();
  let normalized = 0;
  for (const a of accounts) {
    if (hasExpiredCooldown(a, now)) { a.status = "idle"; a.cooldownUntil = null; normalized++; }
  }
  if (normalized > 0) {
    withPoolLock(() => {
      const pool = loadPool();
      let changed = false;
      for (const a of pool[provider] || []) {
        if (hasExpiredCooldown(a, Date.now())) { a.status = "idle"; a.cooldownUntil = null; changed = true; }
      }
      if (changed) savePool(pool);
    });
    console.error(`[aidevops] OAuth pool: auto-cleared ${normalized} expired cooldown(s) for ${provider}`);
  }
  return normalized;
}

// ---------------------------------------------------------------------------
// Account selection (rotation)
// ---------------------------------------------------------------------------

/**
 * Compare two accounts for rotation preference.
 * Primary: priority descending (higher priority first; missing/0 = default).
 * Secondary: lastUsed ascending (least recently used first, i.e. LRU).
 * @param {PoolAccount} a
 * @param {PoolAccount} b
 * @returns {number}
 */
function compareAccountPriority(a, b) {
  const pa = a.priority || 0;
  const pb = b.priority || 0;
  if (pa !== pb) return pb - pa; // higher priority first
  return new Date(a.lastUsed || 0).getTime() - new Date(b.lastUsed || 0).getTime();
}

// pickAccount and pickNextAccount replaced by selectPoolAccount above

// fetchWithPoolFailover + rotateAndRetry: removed (exported but never imported by external modules)

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
  const body = { type: "pending", refresh: "", access: "", expires: 0 };
  try { await client.auth.set({ path: { id: providerId }, body }); } catch { /* already exists or no auth API */ }
}

const POOL_PROVIDERS = ["anthropic-pool", "openai-pool", "cursor-pool", "google-pool"];
const INJECT_FNS = [injectPoolToken, injectOpenAIPoolToken, injectCursorPoolToken, injectGooglePoolToken];

export async function initPoolAuth(client) {
  for (const id of POOL_PROVIDERS) await seedPoolAuthEntry(client, id);
  for (const fn of INJECT_FNS) {
    try { await fn(client); } catch (err) { console.error(`[aidevops] OAuth pool: injection failed (isolated): ${err.message}`); }
  }
}

/**
 * Pick the best pool account and inject its token into the built-in "anthropic"
 * provider's auth.json entry. The built-in provider handles all SDK magic.
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {boolean} true if a token was injected
 */
// Generic pool account selection (shared by all inject functions)
async function selectPoolAccount(provider, skipEmail) {
  const accounts = getAccounts(provider);
  if (accounts.length === 0) return null;
  normalizeExpiredCooldowns(provider, accounts);
  const now = Date.now();
  const isAvailable = (a) => ["active", "idle"].includes(a.status) && (!a.cooldownUntil || a.cooldownUntil <= now);
  const sorted = [...accounts].filter((a) => isAvailable(a) && a.email !== skipEmail).sort(compareAccountPriority);
  for (const c of sorted) { if (await ensureValidToken(provider, c)) return c; console.error(`[aidevops] OAuth pool: skipping invalid ${provider} token for ${c.email}`); }
  const fb = accounts.find(isAvailable);
  if (fb && await ensureValidToken(provider, fb)) return fb;
  return null;
}

export async function injectPoolToken(client, skipEmail) {
  const account = await selectPoolAccount("anthropic", skipEmail);
  if (!account) return false;

  process.env.ANTHROPIC_API_KEY = account.access;
  try { await client.auth.set({ path: { id: "anthropic" }, body: { type: "oauth", refresh: account.refresh, access: account.access, expires: account.expires } }); } catch { /* best-effort */ }
  patchAccount("anthropic", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in anthropic provider`);
  return true;
}

/**
 * Pick the best OpenAI pool account and inject its token into the built-in "openai"
 * provider's auth.json entry (t1548). Same token injection architecture as Anthropic pool.
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {boolean} true if a token was injected
 */
export async function injectOpenAIPoolToken(client, skipEmail) {
  const account = await selectPoolAccount("openai", skipEmail);
  if (!account) return false;
  process.env.OPENAI_API_KEY = account.access;
  try { await client.auth.set({ path: { id: "openai" }, body: { type: "oauth", refresh: account.refresh, access: account.access, expires: account.expires, accountId: account.accountId || "" } }); } catch { /* best-effort */ }
  patchAccount("openai", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in openai provider`);
  return true;
}

// ---------------------------------------------------------------------------
// Cursor gRPC proxy lifecycle (t1549, t1551)
//
// t1551: Replaced cursor-agent CLI proxy with gRPC proxy from
// opencode-cursor-oauth. The gRPC proxy translates OpenAI-compatible
// requests directly to Cursor's protobuf/HTTP2 Connect protocol via
// a Node.js H2 bridge subprocess. This provides:
//   - True streaming (SSE chunks as they arrive from Cursor)
//   - Tool calling support (Cursor's native MCP tool protocol)
//   - Model discovery via gRPC (GetUsableModels RPC)
//   - No dependency on cursor-agent CLI
//
// The proxy is started by cursor-proxy.mjs and managed here for
// backward compatibility with the pool injection flow.
// ---------------------------------------------------------------------------

/**
 * In-memory reference to the cursor gRPC proxy state.
 * @type {{ port: number | null, baseURL: string }}
 */
const cursorProxy = {
  port: null,
  baseURL: CURSOR_PROXY_BASE_URL,
};

/**
 * Ensure the Cursor gRPC proxy is running (t1551).
 * Delegates to cursor-proxy.mjs which manages the vendored
 * opencode-cursor-oauth proxy. Falls back gracefully if the
 * gRPC proxy cannot start.
 *
 * @param {any} [client] - OpenCode SDK client (optional, for model registration)
 * @returns {Promise<string>} Base URL of the proxy
 */
export async function ensureCursorProxy(client) {
  // If proxy is already known to be running, return its URL
  if (cursorProxy.port) {
    return cursorProxy.baseURL;
  }

  try {
    const { startCursorProxy, getCursorProxyPort } = await import("./cursor-proxy.mjs");

    // Check if already started by a prior call
    const existingPort = getCursorProxyPort();
    if (existingPort) {
      cursorProxy.port = existingPort;
      cursorProxy.baseURL = `http://${CURSOR_PROXY_HOST}:${existingPort}/v1`;
      return cursorProxy.baseURL;
    }

    // Start the gRPC proxy
    const result = await startCursorProxy(client);
    if (result && result.port) {
      cursorProxy.port = result.port;
      cursorProxy.baseURL = `http://${CURSOR_PROXY_HOST}:${result.port}/v1`;
      console.error(`[aidevops] OAuth pool: cursor gRPC proxy running on port ${result.port}`);
      return cursorProxy.baseURL;
    }

    throw new Error("gRPC proxy returned no port");
  } catch (err) {
    console.error(`[aidevops] OAuth pool: cursor gRPC proxy failed: ${err.message}`);
    throw err;
  }
}

/**
 * Stop the cursor gRPC proxy if running (t1551).
 */
export function stopCursorProxy() {
  if (cursorProxy.port) {
    try {
      import("./cursor-proxy.mjs").then(({ stopCursorGrpcProxy }) => {
        stopCursorGrpcProxy();
      }).catch(() => {});
    } catch {
      // ignore
    }
    cursorProxy.port = null;
    cursorProxy.baseURL = CURSOR_PROXY_BASE_URL;
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
  const account = await selectPoolAccount("cursor", skipEmail);
  if (!account) return false;

  // Ensure the gRPC proxy is running (t1551)
  try {
    await ensureCursorProxy(client);
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
 * Pick the best Google pool account and inject its token as GOOGLE_OAUTH_ACCESS_TOKEN
 * (ADC bearer token) for Gemini CLI / Vertex AI / generativelanguage.googleapis.com (issue #5614).
 *
 * Isolation guarantee: this function only touches the "google" pool key and
 * GOOGLE_OAUTH_ACCESS_TOKEN env var. It never modifies anthropic/openai/cursor
 * pool entries or their env vars. A Google failure returns false without
 * affecting other providers.
 *
 * @param {any} client - OpenCode SDK client
 * @param {string} [skipEmail] - email to skip (for rotation on 429)
 * @returns {Promise<boolean>} true if a token was injected
 */
export async function injectGooglePoolToken(client, skipEmail) {
  const account = await selectPoolAccount("google", skipEmail);
  if (!account) return false;
  process.env.GOOGLE_OAUTH_ACCESS_TOKEN = account.access;
  patchAccount("google", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected Google token for ${account.email} as GOOGLE_OAUTH_ACCESS_TOKEN`);
  return true;
}

// Auth hooks, handlers, helpers, and registerPoolProvider → oauth-pool-auth.mjs
// Re-export for backward compatibility
export { createPoolAuthHook, createOpenAIPoolAuthHook, createCursorPoolAuthHook, createGooglePoolAuthHook, registerPoolProvider } from "./oauth-pool-auth.mjs";


// Tool → oauth-pool-tool.mjs
export { createPoolTool } from "./oauth-pool-tool.mjs";

// Sub-module exports (needed by oauth-pool-auth.mjs and oauth-pool-tool.mjs)
export { ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT, GOOGLE_HEALTH_CHECK_URL };
export { withPoolLock, loadPool, savePool, decodeCursorJWT };

export function getEndpointCooldownValue(prov) {
  const map = { anthropic: tokenEndpointCooldownUntil, openai: openaiTokenEndpointCooldownUntil, google: googleTokenEndpointCooldownUntil };
  return map[prov] ?? cursorProxyCooldownUntil;
}
export function resetEndpointCooldown(prov) {
  const setters = {
    cursor: () => { const g = cursorProxyCooldownUntil > Date.now(); cursorProxyCooldownUntil = 0; return g; },
    openai: () => { const g = openaiTokenEndpointCooldownUntil > Date.now(); openaiTokenEndpointCooldownUntil = 0; return g; },
    google: () => { const g = googleTokenEndpointCooldownUntil > Date.now(); googleTokenEndpointCooldownUntil = 0; return g; },
    anthropic: () => { const g = tokenEndpointCooldownUntil > Date.now(); tokenEndpointCooldownUntil = 0; return g; },
  };
  return (setters[prov] || setters.anthropic)();
}
export function getPoolFilePath() { return POOL_FILE; }
