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
 *   - Mid-session 401/403 recovery
 *   - Mid-session 429 rotation
 *   - Session-level account affinity (t1714)
 *
 * Implementation is split across sibling files for complexity management:
 *   - provider-auth-cch.mjs: CCH billing header computation (xxHash64, etc.)
 *   - provider-auth-pool.mjs: pool account selection and rotation
 *   - provider-auth-pool-recovery.mjs: exhaustion recovery, rate-limit handling
 *   - provider-auth-request.mjs: request/response transformation
 */

import {
  ensureValidToken, getAccounts, patchAccount, normalizeExpiredCooldowns, markAuthRefreshFailure,
  poolAccountKey, poolAccountLabel,
} from "./oauth-pool.mjs";
import {
  injectAccountToken, activateAccount, tokenResult,
  getSessionAccountToken, resolveSessionKeyFromToken,
  rotatePoolAccounts, getAvailableAlternates, rotateToAlternateAccount,
  resolveCurrentAccount, findSeat,
} from "./provider-auth-pool.mjs";
import {
  parseRetryAfterMs,
  recoverFromExhaustion, refreshSessionOwnAccount,
} from "./provider-auth-pool-recovery.mjs";
import { buildRequestHeaders, transformRequestBody, addBetaQueryParam, transformResponseStream } from "./provider-auth-request.mjs";
import { usageUpdateFromHeaders } from "./oauth-pool-ordering.mjs";

/**
 * Persist the seat's usage window from Anthropic rate-limit response headers
 * (t19127) so reset-aware ordering works on the built-in provider path.
 * Best-effort: never throws, never reads the body, logs nothing.
 * @param {string|null} seatKey @param {Response} response
 */
function recordSeatUsage(seatKey, response) {
  if (!seatKey || !response?.headers) return;
  try {
    const account = getAccounts("anthropic").find((a) => poolAccountKey(a) === seatKey);
    const patch = account ? usageUpdateFromHeaders(account, response.headers) : null;
    if (patch) patchAccount("anthropic", account, patch);
  } catch {
    /* usage capture must never block the request path */
  }
}

/**
 * Apply a recovered token to headers/env and retry the request.
 * Session identity is the seat key (email + optional orgId, GH#38959).
 * @param {string} token @param {string} seatKey @param {object} ctx
 */
async function applyTokenAndRetry(token, seatKey, ctx) {
  ctx.requestHeaders.set("authorization", `Bearer ${token}`);
  process.env.ANTHROPIC_API_KEY = token;
  process.env.AIDEVOPS_ANTHROPIC_API_KEY_SOURCE = "oauth-pool"; // GH#36707
  const sessionAccountKey = activateAccount(seatKey);
  const response = await fetch(ctx.requestInput, { ...ctx.requestInit, body: ctx.body, headers: ctx.requestHeaders });
  return { response, sessionAccountKey };
}

/**
 * Try force-refreshing the current account's token.
 * @param {any} client @param {object|null} currentAccount @param {string} currentLabel
 */
async function forceRefreshCurrentAccount(client, currentAccount, currentLabel) {
  if (!currentAccount?.refresh) return null;
  const freshToken = await ensureValidToken("anthropic", { ...currentAccount, expires: 0 });
  if (!freshToken) return null;
  try { await injectAccountToken(client, currentAccount); } catch { /* best-effort */ }
  console.error(`[aidevops] provider-auth: token refreshed for ${currentLabel} — retrying request`);
  return freshToken;
}

/**
 * Mark an account as auth-error and rotate to an alternate.
 * @param {any} client @param {{accounts: object[], currentAccount: object|null, currentKey: string, currentLabel: string}} state
 */
async function markAndRotateAccount(client, state) {
  const { accounts, currentAccount, currentKey, currentLabel } = state;
  console.error(`[aidevops] provider-auth: refresh failed for ${currentLabel} — rotating to next account`);
  if (currentAccount) {
    markAuthRefreshFailure("anthropic", currentAccount);
  }
  const alternates = getAvailableAlternates(accounts, currentKey);
  return rotateToAlternateAccount(client, alternates, true);
}

/**
 * Resolve the current pool accounts and identify the active seat: its key
 * for identity, its label for logs.
 */
function resolvePoolState(sessionAccountKey, accessToken) {
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  const currentAccount = resolveCurrentAccount(accounts, sessionAccountKey, accessToken);
  return {
    accounts,
    currentAccount,
    currentKey: currentAccount ? poolAccountKey(currentAccount) : "unknown",
    currentLabel: currentAccount ? poolAccountLabel(currentAccount) : "unknown",
  };
}

/**
 * Detect OpenCode's built-in OAuth refresh failure before our fetch wrapper runs.
 * @param {unknown} err
 */
function isRefresh401Failure(err) {
  const message = String(err?.message || err || "");
  return /token refresh failed:\s*(401|403)/i.test(message);
}

/** @param {string} token @param {object|undefined} account */
function buildRecoveredAuth(token, account) {
  return {
    type: "oauth",
    access: token,
    refresh: account?.refresh || "",
    expires: account?.expires || Date.now() + 3600_000,
  };
}

/**
 * Recover when getAuth() itself throws "Token refresh failed: 401/403".
 * OpenCode refreshes expired built-in OAuth credentials before returning auth,
 * so provider response recovery cannot run unless we catch that preflight error.
 */
async function recoverAuthFromPool(client, sessionAccountKey) {
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  if (sessionAccountKey) {
    const own = await refreshSessionOwnAccount(client, accounts, sessionAccountKey);
    if (own) {
      const account = findSeat(getAccounts("anthropic"), own.key);
      return { auth: buildRecoveredAuth(own.token, account), sessionAccountKey: own.key };
    }
  }
  const rotated = await rotatePoolAccounts(client, accounts);
  if (!rotated) return null;
  const account = findSeat(getAccounts("anthropic"), rotated.key);
  return { auth: buildRecoveredAuth(rotated.token, account), sessionAccountKey: rotated.key };
}

/** @param {Function} getAuth @param {any} client @param {string|null} sessionAccountKey */
async function getAuthWithPoolRecovery(getAuth, client, sessionAccountKey) {
  try {
    return { auth: await getAuth(), sessionAccountKey };
  } catch (err) {
    if (!isRefresh401Failure(err)) throw err;
    console.error(
      `[aidevops] provider-auth: built-in token refresh failed before request (${err.message}) — attempting pool recovery`,
    );
    const recovered = await recoverAuthFromPool(client, sessionAccountKey);
    if (recovered) return recovered;
    throw err;
  }
}

/**
 * Resolve the current session's access token.
 * Handles session affinity, pool rotation, and exhaustion wait.
 */
async function resolveAccessToken(client, auth, sessionAccountKey) {
  const { accessToken: poolToken, accessExpires } = getSessionAccountToken(sessionAccountKey, auth);
  if (poolToken && accessExpires >= Date.now()) {
    return {
      accessToken: poolToken,
      sessionAccountKey: resolveSessionKeyFromToken(poolToken, sessionAccountKey),
    };
  }
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  if (sessionAccountKey) {
    const result = await refreshSessionOwnAccount(client, accounts, sessionAccountKey);
    if (result) return tokenResult(result);
  }
  const poolResult = await rotatePoolAccounts(client, accounts);
  if (poolResult) return tokenResult(poolResult);
  return recoverFromExhaustion(client, auth, sessionAccountKey);
}

/**
 * Handle 401/403 response: try force-refreshing current account, then rotate.
 */
async function handle401Recovery(client, response, accessToken, sessionAccountKey, ctx) {
  const state = resolvePoolState(sessionAccountKey, accessToken);
  const { accounts, currentAccount, currentKey, currentLabel } = state;
  console.error(
    `[aidevops] provider-auth: ${response.status} (invalid/revoked token) for ${currentLabel} — attempting refresh...`,
  );
  const freshToken = await forceRefreshCurrentAccount(client, currentAccount, currentLabel);
  if (freshToken) return applyTokenAndRetry(freshToken, currentKey, ctx);
  const rotated = await markAndRotateAccount(client, state);
  if (rotated) {
    console.error(`[aidevops] provider-auth: rotated to ${rotated.label} — retrying request once`);
    return applyTokenAndRetry(rotated.token, rotated.key, ctx);
  }
  console.error(
    `[aidevops] provider-auth: ${response.status} for ${currentLabel} — all accounts exhausted. ` +
    `Pool has ${accounts.length} account(s). Use /model-accounts-pool to check status.`,
  );
  return { response, sessionAccountKey };
}

/**
 * Context object for handle429Recovery.
 * @typedef {{ accessToken: string, sessionAccountKey: string|null, requestCtx: object, triedKeys: Set<string>|undefined }} Recovery429Ctx
 */

/**
 * Handle 429 response: mark current account rate-limited, rotate to alternate.
 * @param {any} client @param {Response} response @param {Recovery429Ctx} ctx429
 */
async function handle429Recovery(client, response, ctx429) {
  const { accessToken, sessionAccountKey, requestCtx } = ctx429;
  const cooldownMs = parseRetryAfterMs(response);
  const { accounts, currentAccount, currentKey, currentLabel } = resolvePoolState(sessionAccountKey, accessToken);
  console.error(
    `[aidevops] provider-auth: 429 rate limit hit for ${currentLabel} mid-session (cooldown ${Math.ceil(cooldownMs / 1000)}s) — attempting pool rotation`,
  );
  if (currentAccount) patchAccount("anthropic", currentAccount, { status: "rate-limited", cooldownUntil: Date.now() + cooldownMs });
  const tried = ctx429.triedKeys ?? new Set();
  tried.add(currentKey);
  const alternates = getAvailableAlternates(accounts, currentKey).filter((a) => !tried.has(poolAccountKey(a)));
  if (alternates.length === 0) {
    console.error(`[aidevops] provider-auth: all ${tried.size} accounts tried — giving up`);
    return { response, sessionAccountKey };
  }
  const rotated = await rotateToAlternateAccount(client, alternates, false);
  if (rotated) {
    tried.add(rotated.key);
    console.error(`[aidevops] provider-auth: rotated to ${rotated.label} — retrying`);
    const retried = await applyTokenAndRetry(rotated.token, rotated.key, requestCtx);
    if (retried.response.status !== 429) return retried;
    return handle429Recovery(client, retried.response, { accessToken, sessionAccountKey: rotated.key, requestCtx, triedKeys: tried });
  }
  console.error(`[aidevops] provider-auth: all accounts rate-limited — giving up`);
  return { response, sessionAccountKey };
}

function zeroOutModelCosts(provider) {
  for (const model of Object.values(provider.models)) {
    model.cost = { input: 0, output: 0, cache: { read: 0, write: 0 } };
  }
}

/**
 * Check if a response body contains the "third-party apps" billing error.
 * Clones the response so the original remains consumable for the caller.
 * @param {Response} response @returns {Promise<boolean>}
 */
async function isThirdPartyBillingError(response) {
  if (response.status !== 400) return false;
  try {
    const cloned = response.clone();
    const body = await cloned.json();
    return body?.error?.type === "invalid_request_error" &&
      typeof body?.error?.message === "string" &&
      body.error.message.toLowerCase().includes("third-party");
  } catch { return false; }
}

/**
 * Handle 400 "third-party apps" billing error: rotate to another account.
 * This error means Anthropic classified the connection as third-party,
 * which fails when the account doesn't have "extra usage" enabled.
 * Rotating accounts sometimes resolves it (different token = different classification).
 */
async function handle400ThirdPartyRecovery(client, response, accessToken, sessionAccountKey, ctx) {
  const { accounts, currentAccount, currentKey, currentLabel } = resolvePoolState(sessionAccountKey, accessToken);
  console.error(
    `[aidevops] provider-auth: 400 third-party billing error for ${currentLabel} — rotating account`,
  );
  if (currentAccount) {
    patchAccount("anthropic", currentAccount, {
      status: "billing-error",
      cooldownUntil: Date.now() + 300_000,
    });
  }
  const alternates = getAvailableAlternates(accounts, currentKey);
  const rotated = await rotateToAlternateAccount(client, alternates, true);
  if (rotated) {
    console.error(`[aidevops] provider-auth: rotated to ${rotated.label} — retrying request once`);
    return applyTokenAndRetry(rotated.token, rotated.key, ctx);
  }
  console.error(
    `[aidevops] provider-auth: all accounts hit third-party billing error. ` +
    `Enable "extra usage" at claude.ai/settings/usage on at least one account, or check header fingerprint.`,
  );
  return { response, sessionAccountKey };
}

/**
 * Diagnostics only: the host session header that attributes redistribution log
 * lines. Read from the host request because buildRequestHeaders() strips
 * x-session-affinity before the request leaves the plugin.
 */
function hostSessionID(input, init) {
  try {
    const headers = new Headers(input instanceof Request ? input.headers : undefined);
    new Headers(init?.headers ?? undefined).forEach((value, key) => headers.set(key, value));
    return headers.get("x-session-affinity") || headers.get("x-opencode-session") || undefined;
  } catch {
    return undefined;
  }
}

/**
 * Execute the authenticated fetch with token resolution, body transform, and error recovery.
 */
async function executeAuthenticatedFetch(client, getAuth, input, init, sessionAccountKey) {
  const authState = await getAuthWithPoolRecovery(getAuth, client, sessionAccountKey);
  const auth = authState.auth;
  sessionAccountKey = authState.sessionAccountKey;
  if (auth.type !== "oauth") return { response: await fetch(input, init), sessionAccountKey };
  const resolved = await resolveAccessToken(client, auth, sessionAccountKey);
  const accessToken = resolved.accessToken ?? auth.access;
  let currentKey = resolved.sessionAccountKey;
  const requestHeaders = buildRequestHeaders(input, init, accessToken);
  const sessionID = hostSessionID(input, init);
  const ctx = {
    requestHeaders,
    body: transformRequestBody(init?.body, { sessionID }),
    requestInput: addBetaQueryParam(input),
    requestInit: init ?? {},
  };
  const triedKeys = new Set([currentKey].filter(Boolean));
  let response = await fetch(ctx.requestInput, { ...ctx.requestInit, body: ctx.body, headers: ctx.requestHeaders });
  if (response.status === 401 || response.status === 403) {
    ({ response, sessionAccountKey: currentKey } = await handle401Recovery(client, response, accessToken, currentKey, ctx));
  }
  if (response.status === 400 && await isThirdPartyBillingError(response)) {
    ({ response, sessionAccountKey: currentKey } = await handle400ThirdPartyRecovery(client, response, accessToken, currentKey, ctx));
  }
  if (response.status === 429) {
    ({ response, sessionAccountKey: currentKey } = await handle429Recovery(client, response, {
      accessToken, sessionAccountKey: currentKey, requestCtx: ctx, triedKeys,
    }));
  }
  recordSeatUsage(currentKey, response);
  return { response: transformResponseStream(response), sessionAccountKey: currentKey };
}

/**
 * Create the auth hook for the built-in "anthropic" provider.
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createProviderAuthHook(client) {
  return {
    provider: "anthropic",
    async loader(getAuth, provider) {
      const initialAuthState = await getAuthWithPoolRecovery(getAuth, client, null);
      if (initialAuthState.auth.type !== "oauth") return {};
      zeroOutModelCosts(provider);
      let sessionAccountKey = initialAuthState.sessionAccountKey;
      let nextAuthOverride = initialAuthState.auth;
      return {
        apiKey: "",
        async fetch(input, init) {
          const result = await executeAuthenticatedFetch(client, async () => {
            if (!nextAuthOverride) return getAuth();
            const auth = nextAuthOverride;
            nextAuthOverride = null;
            return auth;
          }, input, init, sessionAccountKey);
          sessionAccountKey = result.sessionAccountKey;
          return result.response;
        },
      };
    },
  };
}
