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

import { ensureValidToken, getAccounts, patchAccount, normalizeExpiredCooldowns, markAuthRefreshFailure } from "./oauth-pool.mjs";
import {
  injectAccountToken, activateAccount, tokenResult,
  getSessionAccountToken, resolveSessionEmailFromToken,
  rotatePoolAccounts, getAvailableAlternates, rotateToAlternateAccount,
  resolveCurrentAccount,
} from "./provider-auth-pool.mjs";
import {
  parseRetryAfterMs,
  recoverFromExhaustion, refreshSessionOwnAccount,
} from "./provider-auth-pool-recovery.mjs";
import { buildRequestHeaders, transformRequestBody, addBetaQueryParam, transformResponseStream } from "./provider-auth-request.mjs";

/**
 * Apply a recovered token to headers/env and retry the request.
 * @param {string} token @param {string} email @param {object} ctx
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
 * @param {any} client @param {object|null} currentAccount @param {string} currentEmail
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
 * @param {any} client @param {object[]} accounts @param {object|null} currentAccount @param {string} currentEmail
 */
async function markAndRotateAccount(client, accounts, currentAccount, currentEmail) {
  console.error(`[aidevops] provider-auth: refresh failed for ${currentEmail} — rotating to next account`);
  if (currentAccount) {
    markAuthRefreshFailure("anthropic", currentAccount);
  }
  const alternates = getAvailableAlternates(accounts, currentEmail);
  return rotateToAlternateAccount(client, alternates, true);
}

/**
 * Resolve the current pool accounts and identify the active account.
 */
function resolvePoolState(sessionAccountEmail, accessToken) {
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  const currentAccount = resolveCurrentAccount(accounts, sessionAccountEmail, accessToken);
  return { accounts, currentAccount, currentEmail: currentAccount?.email || "unknown" };
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
async function recoverAuthFromPool(client, sessionAccountEmail) {
  const accounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", accounts);
  if (sessionAccountEmail) {
    const own = await refreshSessionOwnAccount(client, accounts, sessionAccountEmail);
    if (own) {
      const account = getAccounts("anthropic").find((a) => a.email === own.email);
      return { auth: buildRecoveredAuth(own.token, account), sessionAccountEmail: own.email };
    }
  }
  const rotated = await rotatePoolAccounts(client, accounts);
  if (!rotated) return null;
  const account = getAccounts("anthropic").find((a) => a.email === rotated.email);
  return { auth: buildRecoveredAuth(rotated.token, account), sessionAccountEmail: rotated.email };
}

/** @param {Function} getAuth @param {any} client @param {string|null} sessionAccountEmail */
async function getAuthWithPoolRecovery(getAuth, client, sessionAccountEmail) {
  try {
    return { auth: await getAuth(), sessionAccountEmail };
  } catch (err) {
    if (!isRefresh401Failure(err)) throw err;
    console.error(
      `[aidevops] provider-auth: built-in token refresh failed before request (${err.message}) — attempting pool recovery`,
    );
    const recovered = await recoverAuthFromPool(client, sessionAccountEmail);
    if (recovered) return recovered;
    throw err;
  }
}

/**
 * Resolve the current session's access token.
 * Handles session affinity, pool rotation, and exhaustion wait.
 */
async function resolveAccessToken(client, auth, sessionAccountEmail) {
  const { accessToken: poolToken, accessExpires } = getSessionAccountToken(sessionAccountEmail, auth);
  if (poolToken && accessExpires >= Date.now()) {
    return {
      accessToken: poolToken,
      sessionAccountEmail: resolveSessionEmailFromToken(poolToken, sessionAccountEmail),
    };
  }
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
 * Handle 401/403 response: try force-refreshing current account, then rotate.
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
 * Context object for handle429Recovery.
 * @typedef {{ accessToken: string, sessionAccountEmail: string|null, requestCtx: object, triedEmails: Set<string>|undefined }} Recovery429Ctx
 */

/**
 * Handle 429 response: mark current account rate-limited, rotate to alternate.
 * @param {any} client @param {Response} response @param {Recovery429Ctx} ctx429
 */
async function handle429Recovery(client, response, ctx429) {
  const { accessToken, sessionAccountEmail, requestCtx } = ctx429;
  const cooldownMs = parseRetryAfterMs(response);
  const { accounts, currentAccount, currentEmail } = resolvePoolState(sessionAccountEmail, accessToken);
  console.error(
    `[aidevops] provider-auth: 429 rate limit hit for ${currentEmail} mid-session (cooldown ${Math.ceil(cooldownMs / 1000)}s) — attempting pool rotation`,
  );
  if (currentAccount) patchAccount("anthropic", currentEmail, { status: "rate-limited", cooldownUntil: Date.now() + cooldownMs });
  const tried = ctx429.triedEmails ?? new Set();
  tried.add(currentEmail);
  const alternates = getAvailableAlternates(accounts, currentEmail).filter((a) => !tried.has(a.email));
  if (alternates.length === 0) {
    console.error(`[aidevops] provider-auth: all ${tried.size} accounts tried — giving up`);
    return { response, sessionAccountEmail };
  }
  const rotated = await rotateToAlternateAccount(client, alternates, false);
  if (rotated) {
    tried.add(rotated.email);
    console.error(`[aidevops] provider-auth: rotated to ${rotated.email} — retrying`);
    const retried = await applyTokenAndRetry(rotated.token, rotated.email, requestCtx);
    if (retried.response.status !== 429) return retried;
    return handle429Recovery(client, retried.response, { accessToken, sessionAccountEmail: rotated.email, requestCtx, triedEmails: tried });
  }
  console.error(`[aidevops] provider-auth: all accounts rate-limited — giving up`);
  return { response, sessionAccountEmail };
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
async function handle400ThirdPartyRecovery(client, response, accessToken, sessionAccountEmail, ctx) {
  const { accounts, currentAccount, currentEmail } = resolvePoolState(sessionAccountEmail, accessToken);
  console.error(
    `[aidevops] provider-auth: 400 third-party billing error for ${currentEmail} — rotating account`,
  );
  if (currentAccount) {
    patchAccount("anthropic", currentEmail, {
      status: "billing-error",
      cooldownUntil: Date.now() + 300_000,
    });
  }
  const alternates = getAvailableAlternates(accounts, currentEmail);
  const rotated = await rotateToAlternateAccount(client, alternates, true);
  if (rotated) {
    console.error(`[aidevops] provider-auth: rotated to ${rotated.email} — retrying request once`);
    return applyTokenAndRetry(rotated.token, rotated.email, ctx);
  }
  console.error(
    `[aidevops] provider-auth: all accounts hit third-party billing error. ` +
    `Enable "extra usage" at claude.ai/settings/usage on at least one account, or check header fingerprint.`,
  );
  return { response, sessionAccountEmail };
}

/**
 * Execute the authenticated fetch with token resolution, body transform, and error recovery.
 */
async function executeAuthenticatedFetch(client, getAuth, input, init, sessionAccountEmail) {
  const authState = await getAuthWithPoolRecovery(getAuth, client, sessionAccountEmail);
  const auth = authState.auth;
  sessionAccountEmail = authState.sessionAccountEmail;
  if (auth.type !== "oauth") return { response: await fetch(input, init), sessionAccountEmail };
  const resolved = await resolveAccessToken(client, auth, sessionAccountEmail);
  const accessToken = resolved.accessToken ?? auth.access;
  let currentEmail = resolved.sessionAccountEmail;
  const ctx = {
    requestHeaders: buildRequestHeaders(input, init, accessToken),
    body: transformRequestBody(init?.body),
    requestInput: addBetaQueryParam(input),
    requestInit: init ?? {},
  };
  const triedEmails = new Set([currentEmail].filter(Boolean));
  let response = await fetch(ctx.requestInput, { ...ctx.requestInit, body: ctx.body, headers: ctx.requestHeaders });
  if (response.status === 401 || response.status === 403) {
    ({ response, sessionAccountEmail: currentEmail } = await handle401Recovery(client, response, accessToken, currentEmail, ctx));
  }
  if (response.status === 400 && await isThirdPartyBillingError(response)) {
    ({ response, sessionAccountEmail: currentEmail } = await handle400ThirdPartyRecovery(client, response, accessToken, currentEmail, ctx));
  }
  if (response.status === 429) {
    ({ response, sessionAccountEmail: currentEmail } = await handle429Recovery(client, response, {
      accessToken, sessionAccountEmail: currentEmail, requestCtx: ctx, triedEmails,
    }));
  }
  return { response: transformResponseStream(response), sessionAccountEmail: currentEmail };
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
      let sessionAccountEmail = initialAuthState.sessionAccountEmail;
      let nextAuthOverride = initialAuthState.auth;
      return {
        apiKey: "",
        async fetch(input, init) {
          const result = await executeAuthenticatedFetch(client, async () => {
            if (!nextAuthOverride) return getAuth();
            const auth = nextAuthOverride;
            nextAuthOverride = null;
            return auth;
          }, input, init, sessionAccountEmail);
          sessionAccountEmail = result.sessionAccountEmail;
          return result.response;
        },
      };
    },
  };
}
