/**
 * Anthropic Provider Auth (t1543, t1714)
 *
 * Handles OAuth authentication for the built-in "anthropic" provider.
 * Re-implements the essential functionality of the removed opencode-anthropic-auth
 * plugin with our fixes applied:
 *   - Token endpoint: platform.claude.com (not console.anthropic.com)
 *   - Updated scopes including user:sessions:claude_code
 *   - User-Agent matching current Claude CLI version
 *   - Deprecated beta header filtering
 *   - Pool token injection on session start
 *   - Mid-session 401/403 recovery: on invalid/revoked token, force-refreshes
 *     the current account's token first; if that fails, rotates to next pool
 *     account with force-refresh, and retries once
 *   - Mid-session 429 rotation: on rate limit, marks current account as
 *     rate-limited, rotates to next pool account, and retries once
 *   - Session-level account affinity (t1714): each session remembers its
 *     account in closure memory, preventing cross-session token overwrites
 *     when multiple sessions share the same auth store file
 *
 * The pool (oauth-pool.mjs) manages multiple account tokens.
 * This module makes the built-in provider use them correctly.
 */

import { ensureValidToken, getAccounts, patchAccount, getAnthropicUserAgent, normalizeExpiredCooldowns } from "./oauth-pool.mjs";

/** Default cooldown when rate limited mid-session (ms) — 5 seconds.
 *  Anthropic per-minute rate limits reset in seconds. Conservative cooldowns
 *  (60s, then 15s) caused all accounts to appear exhausted simultaneously.
 *  5s is enough to avoid hammering while recovering almost instantly. */
const RATE_LIMIT_COOLDOWN_MS = 5_000;

/**
 * Parse a Retry-After header value string into milliseconds.
 * Returns null if the value cannot be parsed.
 * @param {string} raw
 * @returns {number|null}
 */
function parseRetryAfterValue(raw) {
  const seconds = parseInt(raw, 10);
  if (Number.isFinite(seconds) && seconds > 0) return seconds * 1000;
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return date - Date.now();
  return null;
}

/**
 * Parse Retry-After header into milliseconds (t1835).
 * Supports integer seconds and HTTP-date formats. Falls back to default.
 * @param {Response} response
 * @returns {number} cooldown in ms
 */
function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  const parsed = raw ? parseRetryAfterValue(raw) : null;
  return parsed !== null ? Math.max(parsed, RATE_LIMIT_COOLDOWN_MS) : RATE_LIMIT_COOLDOWN_MS;
}

/** Default cooldown on auth failure (ms) — 5 minutes */
const AUTH_FAILURE_COOLDOWN_MS = 300_000;

/** Max wait time when all accounts are exhausted before giving up (ms) */
const MAX_EXHAUSTION_WAIT_MS = 120_000;

/** Poll interval when waiting for cooldowns to expire (ms) */
const EXHAUSTION_POLL_MS = 5_000;

const TOOL_PREFIX = "mcp_";

const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
];

const DEPRECATED_BETAS = new Set([
  "code-execution-2025-01-24",
  "extended-cache-ttl-2025-04-11",
]);

/** Priority order for account status during pool rotation (lower = tried first). */
const STATUS_ORDER = { active: 0, idle: 1, "rate-limited": 2, "auth-error": 3 };

/**
 * Inject a pool account token into the OpenCode auth store.
 * @param {any} client - OpenCode SDK client
 * @param {object} account - pool account with refresh/access/expires
 * @returns {Promise<void>}
 */
async function injectAccountToken(client, account) {
  await client.auth.set({
    path: { id: "anthropic" },
    body: {
      type: "oauth",
      refresh: account.refresh,
      access: account.access,
      expires: account.expires,
    },
  });
}

/**
 * Compare two accounts: by status priority first, then least-recently-used.
 * @param {object} a
 * @param {object} b
 * @returns {number}
 */
function compareAccountPriority(a, b) {
  const aOrder = STATUS_ORDER[a.status] ?? 99;
  const bOrder = STATUS_ORDER[b.status] ?? 99;
  if (aOrder !== bOrder) return aOrder - bOrder;
  return new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0);
}

/**
 * Sort pool accounts by status priority then least-recently-used.
 * @param {object[]} accounts
 * @returns {object[]} sorted copy
 */
function sortAccountsByPriority(accounts) {
  return [...accounts].sort(compareAccountPriority);
}

/**
 * Check if an account is eligible as an alternate (active/idle, not on cooldown).
 * @param {object} account
 * @param {string} currentEmail
 * @param {number} now
 * @returns {boolean}
 */
function isEligibleAlternate(account, currentEmail, now) {
  return (
    account.email !== currentEmail &&
    (account.status === "active" || account.status === "idle") &&
    (!account.cooldownUntil || account.cooldownUntil <= now)
  );
}

/**
 * Get available alternate accounts (not current, not on cooldown, active/idle).
 * @param {object[]} accounts
 * @param {string} currentEmail
 * @returns {object[]}
 */
function getAvailableAlternates(accounts, currentEmail) {
  const now = Date.now();
  return [...accounts]
    .filter((a) => isEligibleAlternate(a, currentEmail, now))
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));
}

/**
 * Activate an account: patch lastUsed/status and update session affinity.
 * Returns the email for use as the new sessionAccountEmail.
 * @param {string} email
 * @returns {string}
 */
function activateAccount(email) {
  patchAccount("anthropic", email, {
    lastUsed: new Date().toISOString(),
    status: "active",
  });
  return email;
}

/**
 * Try to get a valid token for one account and inject it.
 * Returns the token on success, null on failure.
 * @param {any} client
 * @param {object} account
 * @param {boolean} forceRefresh
 * @returns {Promise<string|null>}
 */
async function tryGetAndInjectToken(client, account, forceRefresh) {
  const accountArg = forceRefresh ? { ...account, expires: 0 } : account;
  let token;
  try {
    token = await ensureValidToken("anthropic", accountArg);
  } catch (err) {
    console.error(`[aidevops] provider-auth: ensureValidToken failed for ${account.email}: ${err.message}`);
    return null;
  }
  if (!token) return null;
  try {
    await injectAccountToken(client, account);
  } catch (err) {
    console.error(`[aidevops] provider-auth: failed to inject token for ${account.email}: ${err.message}`);
    return null;
  }
  return token;
}

/**
 * Rotate to an alternate pool account, injecting its token.
 * Returns { token, email } on success, null on failure.
 * @param {any} client
 * @param {object[]} alternates
 * @param {boolean} forceRefresh
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function rotateToAlternateAccount(client, alternates, forceRefresh) {
  for (const alt of alternates) {
    const token = await tryGetAndInjectToken(client, alt, forceRefresh);
    if (token) return { token, email: alt.email };
  }
  return null;
}

/**
 * Try to get a valid token from a recovered account.
 * Returns { token, email } on success, null if token unavailable.
 * @param {any} client
 * @param {object} account
 * @param {number} waitStart - for elapsed time logging
 * @param {string} logPrefix
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function tryRecoverAccount(client, account, waitStart, logPrefix) {
  let altToken;
  try {
    altToken = await ensureValidToken("anthropic", account);
  } catch {
    return null;
  }
  if (!altToken) return null;

  try { await injectAccountToken(client, account); } catch { /* best-effort */ }

  const elapsed = Math.ceil((Date.now() - waitStart) / 1000);
  console.error(
    `[aidevops] provider-auth: ${logPrefix} recovered via ${account.email} after ${elapsed}s wait`,
  );
  return { token: altToken, email: account.email };
}

/**
 * Log exhaustion status once (first iteration only).
 * @param {object[]} accounts
 * @param {string} currentEmail
 * @param {string} logPrefix
 * @param {number} now
 */
function logExhaustionOnce(accounts, currentEmail, logPrefix, now) {
  const accountSummary = accounts.map((a) => {
    const cd = a.cooldownUntil && a.cooldownUntil > now
      ? ` (${Math.ceil((a.cooldownUntil - now) / 1000)}s)`
      : "";
    return `${a.email}[${a.status}${cd}]`;
  }).join(", ");
  console.error(
    `[aidevops] provider-auth: ${logPrefix} for ${currentEmail} — all accounts on cooldown, waiting... ${accountSummary}`,
  );
}

/**
 * Find the first account that has recovered from cooldown.
 * @param {string} logPrefix
 * @returns {{account: object, now: number}|null}
 */
function findRecoveredAccount(logPrefix) {
  const now = Date.now();
  const freshAccounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", freshAccounts);
  const recovered = freshAccounts.find(
    (a) => a.status !== "auth-error" && (!a.cooldownUntil || a.cooldownUntil <= now),
  );
  return recovered ? { account: recovered, accounts: freshAccounts, now } : null;
}

/**
 * Log exhaustion status on the first poll iteration.
 * @param {boolean} firstIteration
 * @param {string} currentEmail
 * @param {string} logPrefix
 * @returns {boolean} false (to update firstIteration flag)
 */
function maybeLogExhaustion(firstIteration, currentEmail, logPrefix) {
  if (!firstIteration) return false;
  const now = Date.now();
  const freshAccounts = getAccounts("anthropic");
  logExhaustionOnce(freshAccounts, currentEmail, logPrefix, now);
  return false;
}

async function waitForCooldownRecovery(client, currentEmail, logPrefix) {
  const waitStart = Date.now();
  let firstIteration = true;

  while (Date.now() - waitStart < MAX_EXHAUSTION_WAIT_MS) {
    const found = findRecoveredAccount(logPrefix);
    if (found) {
      const result = await tryRecoverAccount(client, found.account, waitStart, logPrefix);
      if (result) return result;
    }
    firstIteration = maybeLogExhaustion(firstIteration, currentEmail, logPrefix);
    await new Promise((r) => setTimeout(r, EXHAUSTION_POLL_MS));
  }

  return null;
}

/**
 * Force-clear all account cooldowns as a last resort.
 * @param {string} logPrefix - for log message
 */
function forceClearAllCooldowns(logPrefix) {
  const accounts = getAccounts("anthropic");
  for (const acc of accounts) {
    patchAccount("anthropic", acc.email, { status: "idle", cooldownUntil: 0 });
  }
  console.error(
    `[aidevops] provider-auth: ${logPrefix} — force-cleared all cooldowns after ${MAX_EXHAUSTION_WAIT_MS / 1000}s. Returning response for opencode retry.`,
  );
}

/**
 * Find the session's own account if it exists and is not on cooldown.
 * @param {object[]} accounts
 * @param {string} sessionAccountEmail
 * @returns {object|null}
 */
function findSessionAccount(accounts, sessionAccountEmail) {
  const account = accounts.find((a) => a.email === sessionAccountEmail);
  if (!account || isOnCooldown(account)) return null;
  return account;
}

/**
 * Try to refresh the session's own account token (t1714 affinity).
 * Returns { token, email } on success, null if unavailable or on cooldown.
 * @param {any} client
 * @param {object[]} accounts
 * @param {string} sessionAccountEmail
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function refreshSessionOwnAccount(client, accounts, sessionAccountEmail) {
  const myAccount = findSessionAccount(accounts, sessionAccountEmail);
  if (!myAccount) return null;
  const token = await ensureValidToken("anthropic", myAccount);
  if (!token) return null;
  try { await injectAccountToken(client, myAccount); } catch { /* best-effort */ }
  activateAccount(myAccount.email);
  console.error(`[aidevops] provider-auth: refreshed session account ${myAccount.email}`);
  return { token, email: myAccount.email };
}

/**
 * Check if an account is currently on cooldown.
 * @param {object} account
 * @returns {boolean}
 */
function isOnCooldown(account) {
  return !!(account.cooldownUntil && account.cooldownUntil > Date.now());
}

/**
 * Try to get a valid token for one account and activate it.
 * Returns { token, email } on success, null on failure.
 * @param {any} client
 * @param {object} account
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function tryActivatePoolAccount(client, account) {
  const token = await ensureValidToken("anthropic", account);
  if (!token) return null;
  try { await injectAccountToken(client, account); } catch { /* best-effort */ }
  activateAccount(account.email);
  console.error(`[aidevops] provider-auth: refreshed via pool account ${account.email}`);
  return { token, email: account.email };
}

/**
 * Try each pool account in priority order until one yields a valid token.
 * Returns { token, email } on success, null if all accounts exhausted.
 * @param {any} client
 * @param {object[]} accounts
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function rotatePoolAccounts(client, accounts) {
  for (const account of sortAccountsByPriority(accounts)) {
    if (isOnCooldown(account)) {
      console.error(`[aidevops] provider-auth: skipping ${account.email} — cooldown active`);
      continue;
    }
    const result = await tryActivatePoolAccount(client, account);
    if (result) return result;
  }
  return null;
}

/**
 * Get the session account's token from the pool if still valid.
 * Returns the token and expiry, or falls back to auth values.
 * @param {string|null} sessionAccountEmail
 * @param {object} auth
 * @returns {{accessToken: string, accessExpires: number}}
 */
function getSessionAccountToken(sessionAccountEmail, auth) {
  if (!sessionAccountEmail) return { accessToken: auth.access, accessExpires: auth.expires };
  const myAccount = getAccounts("anthropic").find((a) => a.email === sessionAccountEmail);
  if (myAccount?.access && myAccount.expires > Date.now()) {
    return { accessToken: myAccount.access, accessExpires: myAccount.expires };
  }
  return { accessToken: auth.access, accessExpires: auth.expires };
}

/**
 * Identify the session account email from a valid access token.
 * @param {string} accessToken
 * @param {string|null} sessionAccountEmail
 * @returns {string|null}
 */
function resolveSessionEmailFromToken(accessToken, sessionAccountEmail) {
  if (sessionAccountEmail) return sessionAccountEmail;
  const owner = getAccounts("anthropic").find((a) => a.access === accessToken);
  return owner ? owner.email : null;
}

/**
 * Resolve the current session's access token.
 * Handles session affinity, pool rotation, and exhaustion wait.
 * Returns { accessToken, sessionAccountEmail } (updated values).
 * @param {any} client
 * @param {object} auth - current auth object from getAuth()
 * @param {string|null} sessionAccountEmail
 * @returns {Promise<{accessToken: string|null, sessionAccountEmail: string|null}>}
 */
/**
 * Wrap a token result into the standard { accessToken, sessionAccountEmail } shape.
 * @param {{token: string, email: string}} result
 * @returns {{accessToken: string, sessionAccountEmail: string}}
 */
function tokenResult(result) {
  return { accessToken: result.token, sessionAccountEmail: result.email };
}

/**
 * Attempt exhaustion recovery: wait for a cooldown to expire, then force-clear as last resort.
 * Returns { accessToken, sessionAccountEmail } or falls back to auth.access.
 * @param {any} client
 * @param {object} auth
 * @param {string|null} sessionAccountEmail
 * @returns {Promise<{accessToken: string, sessionAccountEmail: string|null}>}
 */
async function recoverFromExhaustion(client, auth, sessionAccountEmail) {
  const recovered = await waitForCooldownRecovery(client, "all", "exhaustion");
  if (recovered) {
    process.env.ANTHROPIC_API_KEY = recovered.token;
    activateAccount(recovered.email);
    return tokenResult(recovered);
  }
  forceClearAllCooldowns("exhaustion");
  return { accessToken: auth.access, sessionAccountEmail };
}

async function resolveAccessToken(client, auth, sessionAccountEmail) {
  const { accessToken: poolToken, accessExpires } = getSessionAccountToken(sessionAccountEmail, auth);

  if (poolToken && accessExpires >= Date.now()) {
    return {
      accessToken: poolToken,
      sessionAccountEmail: resolveSessionEmailFromToken(poolToken, sessionAccountEmail),
    };
  }

  // Token expired or missing — refresh
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);

  if (sessionAccountEmail) {
    const result = await refreshSessionOwnAccount(client, accounts, sessionAccountEmail);
    if (result) return tokenResult(result);
  }

  const poolResult = await rotatePoolAccounts(client, accounts);
  if (poolResult) return tokenResult(poolResult);

  return recoverFromExhaustion(client, auth, sessionAccountEmail);
}

/**
 * Copy headers from a Headers instance into target.
 * @param {Headers} target
 * @param {Headers} source
 */
function copyHeadersInstance(target, source) {
  source.forEach((value, key) => target.set(key, value));
}

/**
 * Copy headers from an array of [key, value] pairs into target.
 * @param {Headers} target
 * @param {Array<[string, string]>} entries
 */
function copyHeadersArray(target, entries) {
  for (const [key, value] of entries) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

/**
 * Copy headers from a plain object into target.
 * @param {Headers} target
 * @param {Record<string, string>} obj
 */
function copyHeadersObject(target, obj) {
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

/**
 * Merge init.headers (Headers, array, or plain object) into a Headers instance.
 * @param {Headers} target
 * @param {HeadersInit|undefined} initHeaders
 */
function mergeInitHeaders(target, initHeaders) {
  if (!initHeaders) return;
  if (initHeaders instanceof Headers) {
    copyHeadersInstance(target, initHeaders);
  } else if (Array.isArray(initHeaders)) {
    copyHeadersArray(target, initHeaders);
  } else {
    copyHeadersObject(target, initHeaders);
  }
}

/**
 * Compute merged anthropic-beta header value: required betas + incoming, minus deprecated.
 * @param {Headers} headers - current headers (reads anthropic-beta from here)
 * @returns {string}
 */
function mergeBetaHeaders(headers) {
  const incomingBeta = headers.get("anthropic-beta") || "";
  const incomingList = incomingBeta
    .split(",")
    .map((b) => b.trim())
    .filter((b) => b && !DEPRECATED_BETAS.has(b));
  return [...new Set([...REQUIRED_BETAS, ...incomingList])].join(",");
}

/**
 * Build the outgoing request headers: merge input/init headers, set auth/beta/user-agent.
 * @param {Request|string|URL} input
 * @param {RequestInit} init
 * @param {string} accessToken
 * @returns {Headers}
 */
function buildRequestHeaders(input, init, accessToken) {
  const requestHeaders = new Headers();

  if (input instanceof Request) {
    input.headers.forEach((value, key) => requestHeaders.set(key, value));
  }

  mergeInitHeaders(requestHeaders, init?.headers);

  requestHeaders.set("authorization", `Bearer ${accessToken}`);
  requestHeaders.set("anthropic-beta", mergeBetaHeaders(requestHeaders));
  requestHeaders.set("user-agent", getAnthropicUserAgent());
  requestHeaders.delete("x-api-key");

  return requestHeaders;
}

/**
 * Sanitize system prompt items: replace OpenCode references with Claude Code.
 * @param {object[]} system
 * @returns {object[]}
 */
function sanitizeSystemPrompt(system) {
  return system.map((item) => {
    if (item.type !== "text" || !item.text) return item;
    return {
      ...item,
      text: item.text
        .replace(/OpenCode/g, "Claude Code")
        .replace(/opencode/gi, "Claude"),
    };
  });
}

/**
 * Prefix tool definition names with TOOL_PREFIX.
 * @param {object[]} tools
 * @returns {object[]}
 */
function prefixToolNames(tools) {
  return tools.map((tool) => ({
    ...tool,
    name: tool.name ? `${TOOL_PREFIX}${tool.name}` : tool.name,
  }));
}

/**
 * Prefix tool_use block names in messages with TOOL_PREFIX.
 * @param {object[]} messages
 * @returns {object[]}
 */
function prefixToolUseBlocks(messages) {
  return messages.map((msg) => {
    if (!msg.content || !Array.isArray(msg.content)) return msg;
    return {
      ...msg,
      content: msg.content.map((block) => {
        if (block.type === "tool_use" && block.name) {
          return { ...block, name: `${TOOL_PREFIX}${block.name}` };
        }
        return block;
      }),
    };
  });
}

/**
 * Apply all body transformations to a parsed JSON object in-place.
 * @param {object} parsed
 */
function applyBodyTransforms(parsed) {
  if (Array.isArray(parsed.system)) parsed.system = sanitizeSystemPrompt(parsed.system);
  if (Array.isArray(parsed.tools)) parsed.tools = prefixToolNames(parsed.tools);
  if (Array.isArray(parsed.messages)) parsed.messages = prefixToolUseBlocks(parsed.messages);
}

/**
 * Transform the request body: sanitize system prompt, prefix tool names.
 * Returns the (possibly modified) body string, or the original if not JSON.
 * @param {string|null|undefined} body
 * @returns {string|null|undefined}
 */
function transformRequestBody(body) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);
    applyBodyTransforms(parsed);
    return JSON.stringify(parsed);
  } catch {
    return body;
  }
}

/**
 * Parse the URL from a request input, returning null on failure.
 * @param {Request|string|URL} input
 * @returns {URL|null}
 */
function parseRequestUrl(input) {
  try {
    if (typeof input === "string" || input instanceof URL) {
      return new URL(input.toString());
    }
    if (input instanceof Request) {
      return new URL(input.url);
    }
  } catch {
    /* ignore */
  }
  return null;
}

/**
 * Add ?beta=true to /v1/messages requests if not already present.
 * Returns the (possibly modified) input.
 * @param {Request|string|URL} input
 * @returns {Request|URL|string}
 */
/**
 * Rewrite a URL with ?beta=true added.
 * @param {URL} url
 * @param {Request|string|URL} input - original input for Request wrapping
 * @returns {Request|URL}
 */
function rewriteUrlWithBeta(url, input) {
  url.searchParams.set("beta", "true");
  return input instanceof Request ? new Request(url.toString(), input) : url;
}

function addBetaQueryParam(input) {
  const requestUrl = parseRequestUrl(input);
  if (!requestUrl || requestUrl.pathname !== "/v1/messages" || requestUrl.searchParams.has("beta")) {
    return input;
  }
  return rewriteUrlWithBeta(requestUrl, input);
}

/**
 * Identify the current pool account from session affinity or token match.
 * Falls back to most-recently-used if no match found (GH#15322).
 * @param {object[]} accounts
 * @param {string|null} sessionAccountEmail
 * @param {string} accessToken
 * @returns {object|null}
 */
/**
 * Find the most-recently-used account as a fallback when no token match exists.
 * @param {object[]} accounts
 * @returns {object|null}
 */
function getMostRecentlyUsedAccount(accounts) {
  if (accounts.length === 0) return null;
  const mru = [...accounts].sort(
    (a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0),
  )[0];
  console.error(
    `[aidevops] provider-auth: no token match — assuming ${mru.email} (most recently used)`,
  );
  return mru;
}

function resolveCurrentAccount(accounts, sessionAccountEmail, accessToken) {
  if (sessionAccountEmail) {
    const found = accounts.find((a) => a.email === sessionAccountEmail);
    if (found) return found;
  }
  return accounts.find((a) => a.access === accessToken) ?? getMostRecentlyUsedAccount(accounts);
}

/**
 * Apply a recovered token to headers/env and retry the request.
 * Returns { response, sessionAccountEmail }.
 * @param {string} token
 * @param {string} email
 * @param {{requestHeaders: Headers, requestInput: Request|string|URL, requestInit: RequestInit, body: string|null|undefined}} ctx
 * @returns {Promise<{response: Response, sessionAccountEmail: string}>}
 */
async function applyTokenAndRetry(token, email, ctx) {
  ctx.requestHeaders.set("authorization", `Bearer ${token}`);
  process.env.ANTHROPIC_API_KEY = token;
  const sessionAccountEmail = activateAccount(email);
  const response = await fetch(ctx.requestInput, { ...ctx.requestInit, body: ctx.body, headers: ctx.requestHeaders });
  return { response, sessionAccountEmail };
}

/**
 * Try force-refreshing the current account's token.
 * Returns the fresh token on success, null on failure.
 * @param {any} client
 * @param {object|null} currentAccount
 * @param {string} currentEmail
 * @returns {Promise<string|null>}
 */
async function forceRefreshCurrentAccount(client, currentAccount, currentEmail) {
  if (!currentAccount?.refresh) return null;
  const freshToken = await ensureValidToken("anthropic", { ...currentAccount, expires: 0 });
  if (!freshToken) return null;
  try { await injectAccountToken(client, currentAccount); } catch { /* best-effort */ }
  console.error(`[aidevops] provider-auth: token refreshed for ${currentEmail} — retrying request`);
  return freshToken;
}

/**
 * Mark an account as auth-error and rotate to an alternate.
 * Returns { token, email } on success, null if no alternates available.
 * @param {any} client
 * @param {object[]} accounts
 * @param {object|null} currentAccount
 * @param {string} currentEmail
 * @returns {Promise<{token: string, email: string}|null>}
 */
async function markAndRotateAccount(client, accounts, currentAccount, currentEmail) {
  console.error(`[aidevops] provider-auth: refresh failed for ${currentEmail} — rotating to next account`);
  if (currentAccount) {
    patchAccount("anthropic", currentEmail, {
      status: "auth-error",
      cooldownUntil: Date.now() + AUTH_FAILURE_COOLDOWN_MS,
    });
  }
  const alternates = getAvailableAlternates(accounts, currentEmail);
  return rotateToAlternateAccount(client, alternates, true);
}

/**
 * Resolve the current pool accounts and identify the active account.
 * @param {string|null} sessionAccountEmail
 * @param {string} accessToken
 * @returns {{accounts: object[], currentAccount: object|null, currentEmail: string}}
 */
function resolvePoolState(sessionAccountEmail, accessToken) {
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  const currentAccount = resolveCurrentAccount(accounts, sessionAccountEmail, accessToken);
  return { accounts, currentAccount, currentEmail: currentAccount?.email || "unknown" };
}

/**
 * Handle 401/403 response: try force-refreshing current account, then rotate.
 * @param {any} client
 * @param {Response} response
 * @param {string} accessToken
 * @param {string|null} sessionAccountEmail
 * @param {{requestHeaders: Headers, requestInput: Request|string|URL, requestInit: RequestInit, body: string|null|undefined}} ctx
 * @returns {Promise<{response: Response, sessionAccountEmail: string|null}>}
 */
async function handle401Recovery(client, response, accessToken, sessionAccountEmail, ctx) {
  const { accounts, currentAccount, currentEmail } = resolvePoolState(sessionAccountEmail, accessToken);

  console.error(
    `[aidevops] provider-auth: ${response.status} (invalid/revoked token) for ${currentEmail} — attempting refresh...`,
  );

  const freshToken = await forceRefreshCurrentAccount(client, currentAccount, currentEmail);
  if (freshToken) return applyTokenAndRetry(freshToken, currentEmail, ctx);

  const rotated = await markAndRotateAccount(client, accounts, currentAccount, currentEmail);
  if (rotated) {
    console.error(`[aidevops] provider-auth: rotated to ${rotated.email} — retrying request once`);
    return applyTokenAndRetry(rotated.token, rotated.email, ctx);
  }

  console.error(
    `[aidevops] provider-auth: ${response.status} for ${currentEmail} — all accounts exhausted. ` +
    `Pool has ${accounts.length} account(s). Use /model-accounts-pool to check status.`,
  );
  return { response, sessionAccountEmail };
}

/**
 * Handle 429 response: mark current account rate-limited, rotate to alternate.
 * @param {any} client
 * @param {Response} response
 * @param {string} accessToken
 * @param {string|null} sessionAccountEmail
 * @param {{requestHeaders: Headers, requestInput: Request|string|URL, requestInit: RequestInit, body: string|null|undefined}} ctx
 * @returns {Promise<{response: Response, sessionAccountEmail: string|null}>}
 */
async function handle429Recovery(client, response, accessToken, sessionAccountEmail, ctx) {
  const cooldownMs = parseRetryAfterMs(response);
  const { accounts, currentAccount, currentEmail } = resolvePoolState(sessionAccountEmail, accessToken);

  console.error(
    `[aidevops] provider-auth: 429 rate limit hit for ${currentEmail} mid-session (cooldown ${Math.ceil(cooldownMs / 1000)}s) — attempting pool rotation`,
  );

  if (currentAccount) {
    patchAccount("anthropic", currentEmail, {
      status: "rate-limited",
      cooldownUntil: Date.now() + cooldownMs,
    });
  }

  const alternates = getAvailableAlternates(accounts, currentEmail);
  const rotated = await rotateToAlternateAccount(client, alternates, false);
  if (rotated) {
    console.error(`[aidevops] provider-auth: rotated to ${rotated.email} — retrying request once`);
    return applyTokenAndRetry(rotated.token, rotated.email, ctx);
  }

  // All accounts rate-limited — wait for cooldown recovery
  const recovered = await waitForCooldownRecovery(client, currentEmail, "429");
  if (recovered) return applyTokenAndRetry(recovered.token, recovered.email, ctx);

  forceClearAllCooldowns("429");
  return { response, sessionAccountEmail };
}

/**
 * Strip mcp_ prefix from tool name fields in a text chunk.
 * @param {string} text
 * @returns {string}
 */
function stripMcpPrefix(text) {
  return text.replace(/"name"\s*:\s*"mcp_([^"]+)"/g, '"name": "$1"');
}

/**
 * Build a ReadableStream pull handler that strips mcp_ tool name prefixes.
 * @param {ReadableStreamDefaultReader} reader
 * @param {TextDecoder} decoder
 * @param {TextEncoder} encoder
 * @returns {(controller: ReadableStreamDefaultController) => Promise<void>}
 */
function makeStreamPullHandler(reader, decoder, encoder) {
  return async function pull(controller) {
    const { done, value } = await reader.read();
    if (done) {
      controller.close();
      return;
    }
    controller.enqueue(encoder.encode(stripMcpPrefix(decoder.decode(value, { stream: true }))));
  };
}

/**
 * Wrap a response body stream to strip mcp_ prefix from tool names.
 * @param {Response} response
 * @returns {Response}
 */
function transformResponseStream(response) {
  if (!response.body) return response;

  const reader = response.body.getReader();
  const stream = new ReadableStream({
    pull: makeStreamPullHandler(reader, new TextDecoder(), new TextEncoder()),
  });

  return new Response(stream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

/**
 * Zero out model costs for Max plan accounts.
 * @param {object} provider
 */
function zeroOutModelCosts(provider) {
  for (const model of Object.values(provider.models)) {
    model.cost = { input: 0, output: 0, cache: { read: 0, write: 0 } };
  }
}

/**
 * Execute the authenticated fetch with token resolution, body transform, and error recovery.
 * @param {any} client
 * @param {Function} getAuth
 * @param {Request|string|URL} input
 * @param {RequestInit} init
 * @param {string|null} sessionAccountEmail - mutable via return value
 * @returns {Promise<{response: Response, sessionAccountEmail: string|null}>}
 */
async function executeAuthenticatedFetch(client, getAuth, input, init, sessionAccountEmail) {
  const auth = await getAuth();
  if (auth.type !== "oauth") {
    return { response: await fetch(input, init), sessionAccountEmail };
  }

  const resolved = await resolveAccessToken(client, auth, sessionAccountEmail);
  const accessToken = resolved.accessToken ?? auth.access;
  let currentEmail = resolved.sessionAccountEmail;

  const ctx = {
    requestHeaders: buildRequestHeaders(input, init, accessToken),
    body: transformRequestBody(init?.body),
    requestInput: addBetaQueryParam(input),
    requestInit: init ?? {},
  };

  let response = await fetch(ctx.requestInput, { ...ctx.requestInit, body: ctx.body, headers: ctx.requestHeaders });

  if (response.status === 401 || response.status === 403) {
    ({ response, sessionAccountEmail: currentEmail } = await handle401Recovery(
      client, response, accessToken, currentEmail, ctx,
    ));
  }

  if (response.status === 429) {
    ({ response, sessionAccountEmail: currentEmail } = await handle429Recovery(
      client, response, accessToken, currentEmail, ctx,
    ));
  }

  return { response: transformResponseStream(response), sessionAccountEmail: currentEmail };
}

/**
 * Create the auth hook for the built-in "anthropic" provider.
 * Provides OAuth loader with custom fetch that handles:
 *   - Bearer auth with pool tokens
 *   - Beta headers (required + filtered)
 *   - System prompt sanitization (OpenCode → Claude Code)
 *   - Tool name prefixing (mcp_)
 *   - ?beta=true query param
 *   - Response stream tool name de-prefixing
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createProviderAuthHook(client) {
  return {
    provider: "anthropic",

    async loader(getAuth, provider) {
      const auth = await getAuth();
      if (auth.type !== "oauth") return {};

      zeroOutModelCosts(provider);

      // Session-level account affinity (t1714): each session's fetch closure
      // remembers which pool account it's using. This prevents cross-session
      // token overwrites when multiple OpenCode processes share the same
      // auth.json file.
      let sessionAccountEmail = null;

      return {
        apiKey: "",
        async fetch(input, init) {
          const result = await executeAuthenticatedFetch(client, getAuth, input, init, sessionAccountEmail);
          sessionAccountEmail = result.sessionAccountEmail;
          return result.response;
        },
      };
    },
  };
}
