/**
 * OAuth Multi-Account Pool (t1543)
 *
 * Enables multiple OAuth accounts per provider with automatic credential
 * rotation on rate limits (429). Stores credentials in a separate pool file
 * (~/.aidevops/oauth-pool.json) to avoid conflicts with OpenCode's auth.json.
 *
 * Architecture:
 *   - auth hook: registers "anthropic-pool" provider with OAuth login flow
 *   - loader: returns a custom fetch wrapper that rotates credentials on 429
 *   - tool: /model-accounts-pool for listing/removing accounts
 *
 * References:
 *   - Built-in auth plugin: opencode-anthropic-auth@0.0.13
 *   - OpenCode PR #11832 (upstream multi-account proposal)
 *   - Plugin API: @opencode-ai/plugin AuthHook type
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { createHash, randomBytes } from "crypto";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const POOL_FILE = join(HOME, ".aidevops", "oauth-pool.json");
const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const TOKEN_ENDPOINT = "https://console.anthropic.com/v1/oauth/token";
const OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
const OAUTH_SCOPES = "org:create_api_key user:profile user:inference";

/** Default cooldown when rate limited (ms) */
const RATE_LIMIT_COOLDOWN_MS = 60_000;

/** Default cooldown on auth failure (ms) */
const AUTH_FAILURE_COOLDOWN_MS = 300_000;

/** Cooldown after a 429 on the token endpoint (ms) — 5 minutes */
const TOKEN_ENDPOINT_COOLDOWN_MS = 300_000;

/** Max retry attempts per request across pool accounts */
const MAX_ROTATION_ATTEMPTS = 5;

const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
];

// ---------------------------------------------------------------------------
// Token endpoint helpers
// ---------------------------------------------------------------------------

/**
 * In-memory timestamp of the last 429 from the token endpoint.
 * When set, all token endpoint calls are skipped until the cooldown expires.
 * This prevents hammering the endpoint and extending the rate limit window.
 * @type {number}
 */
let tokenEndpointCooldownUntil = 0;

/**
 * Fetch from the token endpoint. Single attempt with 429 cooldown gate.
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

  const response = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });

  if (response.status === 429) {
    // Parse Retry-After header if present, otherwise use default cooldown
    const retryAfter = response.headers.get("retry-after");
    const cooldownMs = retryAfter
      ? Math.max(parseInt(retryAfter, 10) * 1000, TOKEN_ENDPOINT_COOLDOWN_MS)
      : TOKEN_ENDPOINT_COOLDOWN_MS;
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

const TOOL_PREFIX = "mcp_";

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
 */

/**
 * @typedef {Object} PoolData
 * @property {PoolAccount[]} [anthropic]
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
function getAccounts(provider) {
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
  const idx = pool[provider].findIndex((a) => a.email === account.email);
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
function patchAccount(provider, email, patch) {
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
 * Refresh an expired access token using the refresh token.
 * @param {PoolAccount} account
 * @returns {Promise<{access: string, refresh: string, expires: number} | null>}
 */
async function refreshAccessToken(account) {
  try {
    const response = await fetchTokenEndpoint(
      JSON.stringify({
        grant_type: "refresh_token",
        refresh_token: account.refresh,
        client_id: CLIENT_ID,
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
 * Ensure an account has a valid (non-expired) access token.
 * Refreshes if needed and updates the pool file.
 * @param {string} provider
 * @param {PoolAccount} account
 * @returns {Promise<string|null>} access token or null on failure
 */
async function ensureValidToken(provider, account) {
  if (account.access && account.expires > Date.now()) {
    return account.access;
  }
  const tokens = await refreshAccessToken(account);
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

// ---------------------------------------------------------------------------
// Request transformation (matches built-in anthropic auth plugin)
// ---------------------------------------------------------------------------

/**
 * Build request headers for an OAuth API call.
 * Merges incoming headers, sets Bearer auth, required betas, user-agent.
 * @param {any} input - fetch input (string, URL, or Request)
 * @param {any} init - fetch init options
 * @param {string} accessToken
 * @returns {Headers}
 */
function buildOAuthHeaders(input, init, accessToken) {
  const requestHeaders = new Headers();

  if (input instanceof Request) {
    input.headers.forEach((value, key) => {
      requestHeaders.set(key, value);
    });
  }

  const initHeaders = init?.headers;
  if (initHeaders) {
    if (initHeaders instanceof Headers) {
      initHeaders.forEach((value, key) => {
        requestHeaders.set(key, value);
      });
    } else if (Array.isArray(initHeaders)) {
      for (const [key, value] of initHeaders) {
        if (typeof value !== "undefined") {
          requestHeaders.set(key, String(value));
        }
      }
    } else {
      for (const [key, value] of Object.entries(initHeaders)) {
        if (typeof value !== "undefined") {
          requestHeaders.set(key, String(value));
        }
      }
    }
  }

  // Merge beta headers
  const incomingBeta = requestHeaders.get("anthropic-beta") || "";
  const incomingBetasList = incomingBeta
    .split(",")
    .map((b) => b.trim())
    .filter(Boolean);
  const mergedBetas = [
    ...new Set([...REQUIRED_BETAS, ...incomingBetasList]),
  ].join(",");

  requestHeaders.set("authorization", `Bearer ${accessToken}`);
  requestHeaders.set("anthropic-beta", mergedBetas);
  requestHeaders.set("user-agent", "claude-cli/2.1.2 (external, cli)");
  requestHeaders.delete("x-api-key");

  return requestHeaders;
}

/**
 * Transform request body: prefix tool names with mcp_, sanitize system prompt.
 * Matches the built-in anthropic auth plugin behaviour.
 * @param {string|undefined} body
 * @returns {string|undefined}
 */
function transformRequestBody(body) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);

    // Sanitize system prompt — Anthropic server blocks "OpenCode" string
    if (parsed.system && Array.isArray(parsed.system)) {
      parsed.system = parsed.system.map((item) => {
        if (item.type === "text" && item.text) {
          return {
            ...item,
            text: item.text
              .replace(/OpenCode/g, "Claude Code")
              .replace(/opencode/gi, "Claude"),
          };
        }
        return item;
      });
    }

    // Prefix tool definitions
    if (parsed.tools && Array.isArray(parsed.tools)) {
      parsed.tools = parsed.tools.map((tool) => ({
        ...tool,
        name: tool.name ? `${TOOL_PREFIX}${tool.name}` : tool.name,
      }));
    }

    // Prefix tool_use blocks in messages
    if (parsed.messages && Array.isArray(parsed.messages)) {
      parsed.messages = parsed.messages.map((msg) => {
        if (msg.content && Array.isArray(msg.content)) {
          msg.content = msg.content.map((block) => {
            if (block.type === "tool_use" && block.name) {
              return { ...block, name: `${TOOL_PREFIX}${block.name}` };
            }
            return block;
          });
        }
        return msg;
      });
    }

    return JSON.stringify(parsed);
  } catch {
    return body;
  }
}

/**
 * Transform response: strip mcp_ prefix from tool names in streaming response.
 * @param {Response} response
 * @returns {Response}
 */
function transformResponse(response) {
  if (!response.body) return response;

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        controller.close();
        return;
      }
      let text = decoder.decode(value, { stream: true });
      text = text.replace(/"name"\s*:\s*"mcp_([^"]+)"/g, '"name": "$1"');
      controller.enqueue(encoder.encode(text));
    },
  });

  return new Response(stream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

/**
 * Add ?beta=true to /v1/messages requests if not already present.
 * @param {any} input
 * @returns {{ input: any, url: URL|null }}
 */
function maybeAddBetaParam(input) {
  let requestUrl = null;
  try {
    if (typeof input === "string" || input instanceof URL) {
      requestUrl = new URL(input.toString());
    } else if (input instanceof Request) {
      requestUrl = new URL(input.url);
    }
  } catch {
    requestUrl = null;
  }

  if (
    requestUrl &&
    requestUrl.pathname === "/v1/messages" &&
    !requestUrl.searchParams.has("beta")
  ) {
    requestUrl.searchParams.set("beta", "true");
    const newInput =
      input instanceof Request
        ? new Request(requestUrl.toString(), input)
        : requestUrl;
    return { input: newInput, url: requestUrl };
  }

  return { input, url: requestUrl };
}

// ---------------------------------------------------------------------------
// Pool fetch wrapper (the core rotation logic)
// ---------------------------------------------------------------------------

/**
 * Create a fetch function that rotates through pool accounts on rate limits.
 * @param {string} provider
 * @returns {(input: any, init?: any) => Promise<Response>}
 */
function createPoolFetch(provider) {
  return async function poolFetch(input, init) {
    let currentAccount = pickAccount(provider);
    if (!currentAccount) {
      // No accounts available — fall through to default fetch (will likely fail)
      return fetch(input, init);
    }

    for (let attempt = 0; attempt < MAX_ROTATION_ATTEMPTS; attempt++) {
      const accessToken = await ensureValidToken(provider, currentAccount);
      if (!accessToken) {
        // Token refresh failed — try next account
        currentAccount = pickNextAccount(provider, currentAccount.email);
        if (!currentAccount) break;
        continue;
      }

      // Mark as used
      patchAccount(provider, currentAccount.email, {
        lastUsed: new Date().toISOString(),
        status: "active",
      });

      // Build the request
      const headers = buildOAuthHeaders(input, init, accessToken);
      const body = transformRequestBody(init?.body);
      const { input: finalInput } = maybeAddBetaParam(input);

      const response = await fetch(finalInput, {
        ...init,
        body,
        headers,
      });

      // Success — transform and return
      if (response.ok || (response.status >= 200 && response.status < 400)) {
        return transformResponse(response);
      }

      // Rate limited — rotate to next account
      if (response.status === 429) {
        const retryAfter = response.headers.get("retry-after");
        const cooldownMs = retryAfter
          ? parseInt(retryAfter, 10) * 1000
          : RATE_LIMIT_COOLDOWN_MS;

        patchAccount(provider, currentAccount.email, {
          status: "rate-limited",
          cooldownUntil: Date.now() + cooldownMs,
        });

        const next = pickNextAccount(provider, currentAccount.email);
        if (!next) {
          // All accounts exhausted — return the 429 response
          return transformResponse(response);
        }
        currentAccount = next;
        continue;
      }

      // Auth error — mark and rotate
      if (response.status === 401 || response.status === 403) {
        patchAccount(provider, currentAccount.email, {
          status: "auth-error",
          cooldownUntil: Date.now() + AUTH_FAILURE_COOLDOWN_MS,
        });

        const next = pickNextAccount(provider, currentAccount.email);
        if (!next) {
          return transformResponse(response);
        }
        currentAccount = next;
        continue;
      }

      // Other error — return as-is (don't rotate on 4xx/5xx that aren't rate/auth)
      return transformResponse(response);
    }

    // All attempts exhausted — make a plain fetch as last resort
    return fetch(input, init);
  };
}

// ---------------------------------------------------------------------------
// Auth hook (registers the pool provider)
// ---------------------------------------------------------------------------

/**
 * Create the auth hook that replaces the built-in anthropic auth plugin.
 *
 * By registering provider: "anthropic", this hook overrides the built-in
 * opencode-anthropic-auth plugin (our plugin loads after BUILTIN plugins,
 * and Record.fromEntries gives last-writer-wins on duplicate keys).
 *
 * Behavior:
 *   - Pool has accounts → pool fetch wrapper with rotation on 429
 *   - Pool empty, auth.json has OAuth → single-account fallback (same as built-in)
 *   - Pool empty, no auth → empty (prompt to add account)
 *
 * This ensures the existing OAuth token keeps working until pool accounts
 * are added, at which point rotation takes over seamlessly.
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createPoolAuthHook(client) {
  return {
    provider: "anthropic",

    /**
     * Loader: called when OpenCode needs credentials for this provider.
     *
     * Three modes:
     * 1. Pool accounts exist → pool fetch wrapper (rotation on 429)
     * 2. No pool accounts, auth.json has OAuth → single-account fallback
     * 3. No pool accounts, no auth → empty options
     */
    async loader(getAuth, provider) {
      const accounts = getAccounts("anthropic");

      // Zero out costs for OAuth (Max plan pricing) regardless of mode
      const auth = await getAuth();
      if (auth?.type === "oauth" || accounts.length > 0) {
        for (const model of Object.values(provider.models)) {
          model.cost = {
            input: 0,
            output: 0,
            cache: { read: 0, write: 0 },
          };
        }
      }

      // Mode 1: Pool accounts exist — use rotation
      if (accounts.length > 0) {
        return {
          apiKey: "",
          fetch: createPoolFetch("anthropic"),
        };
      }

      // Mode 2: No pool accounts — fall back to single-account (built-in behavior)
      // This preserves the existing OAuth token until pool accounts are added.
      if (auth?.type === "oauth") {
        return {
          apiKey: "",
          /**
           * Single-account fetch wrapper — replicates the built-in
           * opencode-anthropic-auth plugin's behavior exactly.
           * @param {any} input
           * @param {any} init
           */
          async fetch(input, init) {
            const currentAuth = await getAuth();
            if (currentAuth?.type !== "oauth") return fetch(input, init);

            // Refresh token if expired (with retry on 429)
            if (!currentAuth.access || currentAuth.expires < Date.now()) {
              const response = await fetchTokenEndpoint(
                JSON.stringify({
                  grant_type: "refresh_token",
                  refresh_token: currentAuth.refresh,
                  client_id: CLIENT_ID,
                }),
                "single-account refresh",
              );
              if (!response.ok) {
                throw new Error(`Token refresh failed: ${response.status}`);
              }
              const json = await response.json();
              await client.auth.set({
                path: { id: "anthropic" },
                body: {
                  type: "oauth",
                  refresh: json.refresh_token,
                  access: json.access_token,
                  expires: Date.now() + json.expires_in * 1000,
                },
              });
              currentAuth.access = json.access_token;
            }

            const headers = buildOAuthHeaders(input, init, currentAuth.access);
            const body = transformRequestBody(init?.body);
            const { input: finalInput } = maybeAddBetaParam(input);

            const response = await fetch(finalInput, {
              ...init,
              body,
              headers,
            });

            return transformResponse(response);
          },
        };
      }

      // Mode 3: No auth at all
      return {};
    },

    methods: [
      {
        // Dynamic label — shows pool account count each time the dialog opens.
        // Uses a getter so the label is recomputed on every access.
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
            // Dynamic message — shows existing account emails as context.
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

          const url = new URL(OAUTH_AUTHORIZE_URL);
          url.searchParams.set("code", "true");
          url.searchParams.set("client_id", CLIENT_ID);
          url.searchParams.set("response_type", "code");
          url.searchParams.set("redirect_uri", REDIRECT_URI);
          url.searchParams.set("scope", OAUTH_SCOPES);
          url.searchParams.set("code_challenge", pkce.challenge);
          url.searchParams.set("code_challenge_method", "S256");
          url.searchParams.set("state", pkce.verifier);

          return {
            url: url.toString(),
            instructions: `Adding account: ${email}\nPaste the authorization code here: `,
            method: "code",
            callback: async (code) => {
              // Anthropic's OAuth callback returns code#state format
              const hashIdx = code.indexOf("#");
              const authCode = hashIdx >= 0 ? code.substring(0, hashIdx) : code;
              const state = hashIdx >= 0 ? code.substring(hashIdx + 1) : undefined;

              const result = await fetchTokenEndpoint(
                JSON.stringify({
                  code: authCode,
                  state,
                  grant_type: "authorization_code",
                  client_id: CLIENT_ID,
                  redirect_uri: REDIRECT_URI,
                  code_verifier: pkce.verifier,
                }),
                "token exchange",
              );

              if (!result.ok) {
                // fetchTokenEndpoint already logged the error
                return { type: "failed" };
              }

              const json = await result.json();

              // Store in our pool file (not auth.json)
              upsertAccount("anthropic", {
                email,
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
                `[aidevops] OAuth pool: added ${email} (${totalAccounts} account${totalAccounts === 1 ? "" : "s"} total)`,
              );

              // Return success — OpenCode stores this in auth.json for "anthropic"
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
      {
        label: "Create an API Key",
        type: "oauth",
        authorize: async () => {
          const pkce = generatePKCE();
          const url = new URL("https://console.anthropic.com/oauth/authorize");
          url.searchParams.set("code", "true");
          url.searchParams.set("client_id", CLIENT_ID);
          url.searchParams.set("response_type", "code");
          url.searchParams.set("redirect_uri", REDIRECT_URI);
          url.searchParams.set("scope", OAUTH_SCOPES);
          url.searchParams.set("code_challenge", pkce.challenge);
          url.searchParams.set("code_challenge_method", "S256");
          url.searchParams.set("state", pkce.verifier);
          return {
            url: url.toString(),
            instructions: "Paste the authorization code here: ",
            method: "code",
            callback: async (code) => {
              const hashIdx = code.indexOf("#");
              const authCode = hashIdx >= 0 ? code.substring(0, hashIdx) : code;
              const codeState = hashIdx >= 0 ? code.substring(hashIdx + 1) : undefined;
              const response = await fetchTokenEndpoint(
                JSON.stringify({
                  code: authCode,
                  state: codeState,
                  grant_type: "authorization_code",
                  client_id: CLIENT_ID,
                  redirect_uri: REDIRECT_URI,
                  code_verifier: pkce.verifier,
                }),
                "API key token exchange",
              );
              if (!response.ok) {
                // fetchTokenEndpoint already logged the error
                return { type: "failed" };
              }
              const credentials = await response.json();
              const apiKeyResponse = await fetch(
                "https://api.anthropic.com/api/oauth/claude_cli/create_api_key",
                {
                  method: "POST",
                  headers: {
                    "Content-Type": "application/json",
                    authorization: `Bearer ${credentials.access_token}`,
                  },
                },
              );
              if (!apiKeyResponse.ok) {
                console.error(
                  `[aidevops] OAuth pool: API key creation failed: HTTP ${apiKeyResponse.status}`,
                );
                return { type: "failed" };
              }
              let apiKeyResult;
              try {
                apiKeyResult = await apiKeyResponse.json();
              } catch {
                console.error("[aidevops] OAuth pool: API key creation response was not valid JSON");
                return { type: "failed" };
              }
              if (!apiKeyResult || typeof apiKeyResult.raw_key !== "string") {
                console.error("[aidevops] OAuth pool: API key creation response missing raw_key");
                return { type: "failed" };
              }
              return { type: "success", key: apiKeyResult.raw_key };
            },
          };
        },
      },
      {
        provider: "anthropic",
        label: "Manually enter API Key",
        type: "api",
      },
    ],
  };
}

// registerPoolProvider and initPoolAuth are no longer needed.
// By using provider: "anthropic" (same as the built-in), we inherit:
// - All models from models.dev (auto-populated by OpenCode)
// - The existing auth.json entry (no seeding needed)
// - "Popular" category placement in the connect dialog

// ---------------------------------------------------------------------------
// Custom tool: /model-accounts-pool
// ---------------------------------------------------------------------------

/**
 * Create the model-accounts-pool tool definition.
 * @returns {import('@opencode-ai/plugin').ToolDefinition}
 */
export function createPoolTool() {
  return {
    description:
      "Manage OAuth account pool for provider credential rotation. " +
      "Use 'list' to see all accounts and their status, " +
      "'remove <email>' to remove an account, " +
      "'status' for rotation statistics. " +
      "The agent should route natural language requests about managing " +
      "provider accounts, OAuth pools, or credential rotation to this tool.",
    parameters: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["list", "remove", "status", "reset-cooldowns"],
          description:
            "Action to perform: list accounts, remove an account, show status, or reset cooldowns",
        },
        email: {
          type: "string",
          description: "Account email (required for 'remove' action)",
        },
        provider: {
          type: "string",
          description: "Provider name (default: anthropic)",
        },
      },
      required: ["action"],
    },
    async execute(args) {
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);

      switch (args.action) {
        case "list": {
          if (accounts.length === 0) {
            return `No accounts in the ${provider} pool.\n\nTo add an account: run \`opencode auth login\` and select "Anthropic Pool".`;
          }
          const now = Date.now();
          const lines = accounts.map((a, i) => {
            const cooldown =
              a.cooldownUntil && a.cooldownUntil > now
                ? ` (cooldown: ${Math.ceil((a.cooldownUntil - now) / 60000)}m remaining)`
                : "";
            const lastUsed = a.lastUsed
              ? ` | last used: ${new Date(a.lastUsed).toLocaleString()}`
              : "";
            return `${i + 1}. ${a.email} [${a.status}]${cooldown}${lastUsed}`;
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
            return `No accounts in the ${provider} pool.`;
          }
          const now = Date.now();
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

          const tokenGated = tokenEndpointCooldownUntil > now;
          const tokenGateInfo = tokenGated
            ? `  TOKEN ENDPOINT: RATE LIMITED (${Math.ceil((tokenEndpointCooldownUntil - now) / 60000)}m remaining)`
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
          // Reset token endpoint cooldown (in-memory)
          const wasGated = tokenEndpointCooldownUntil > Date.now();
          tokenEndpointCooldownUntil = 0;

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
          return `Reset: ${parts.join(", ")}. Token endpoint requests will proceed on next attempt.`;
        }

        default:
          return `Unknown action: ${args.action}. Available: list, remove, status, reset-cooldowns`;
      }
    },
  };
}
