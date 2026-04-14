/**
 * OAuth pool exhaustion recovery helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import { ensureValidToken, getAccounts, patchAccount, normalizeExpiredCooldowns } from "./oauth-pool.mjs";
import { injectAccountToken, activateAccount, isOnCooldown, tokenResult } from "./provider-auth-pool.mjs";

/** Default cooldown when rate limited mid-session (ms) */
export const RATE_LIMIT_COOLDOWN_MS = 5_000;
/** Default cooldown on auth failure (ms) */
export const AUTH_FAILURE_COOLDOWN_MS = 300_000;
/** Max wait when all accounts exhausted (ms) */
const MAX_EXHAUSTION_WAIT_MS = 15_000;
/** Poll interval when waiting for cooldowns (ms) */
const EXHAUSTION_POLL_MS = 5_000;

/**
 * Parse a Retry-After header value string into milliseconds.
 * @param {string} raw @returns {number|null}
 */
export function parseRetryAfterValue(raw) {
  const seconds = parseInt(raw, 10);
  if (Number.isFinite(seconds) && seconds > 0) return seconds * 1000;
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return date - Date.now();
  return null;
}

/**
 * Parse Retry-After header into milliseconds. Falls back to RATE_LIMIT_COOLDOWN_MS.
 * @param {Response} response @returns {number}
 */
export function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  const parsed = raw ? parseRetryAfterValue(raw) : null;
  return parsed !== null ? Math.max(parsed, RATE_LIMIT_COOLDOWN_MS) : RATE_LIMIT_COOLDOWN_MS;
}

/** @param {any} client @param {object} account @param {number} waitStart @param {string} logPrefix */
export async function tryRecoverAccount(client, account, waitStart, logPrefix) {
  let altToken;
  try { altToken = await ensureValidToken("anthropic", account); } catch { return null; }
  if (!altToken) return null;
  try { await injectAccountToken(client, account); } catch { /* best-effort */ }
  const elapsed = Math.ceil((Date.now() - waitStart) / 1000);
  console.error(`[aidevops] provider-auth: ${logPrefix} recovered via ${account.email} after ${elapsed}s wait`);
  return { token: altToken, email: account.email };
}

/** @param {object[]} accounts @param {string} currentEmail @param {string} logPrefix @param {number} now */
export function logExhaustionOnce(accounts, currentEmail, logPrefix, now) {
  const accountSummary = accounts.map((a) => {
    const cd = a.cooldownUntil && a.cooldownUntil > now ? ` (${Math.ceil((a.cooldownUntil - now) / 1000)}s)` : "";
    return `${a.email}[${a.status}${cd}]`;
  }).join(", ");
  console.error(`[aidevops] provider-auth: ${logPrefix} for ${currentEmail} — all accounts on cooldown, waiting... ${accountSummary}`);
}

/** @param {string} logPrefix @returns {{account: object, accounts: object[], now: number}|null} */
export function findRecoveredAccount(logPrefix) {
  const now = Date.now();
  const freshAccounts = getAccounts("anthropic");
  normalizeExpiredCooldowns("anthropic", freshAccounts);
  const recovered = freshAccounts.find(
    (a) => a.status !== "auth-error" && (!a.cooldownUntil || a.cooldownUntil <= now),
  );
  return recovered ? { account: recovered, accounts: freshAccounts, now } : null;
}

/** @param {boolean} firstIteration @param {string} currentEmail @param {string} logPrefix */
export function maybeLogExhaustion(firstIteration, currentEmail, logPrefix) {
  if (!firstIteration) return false;
  const now = Date.now();
  const freshAccounts = getAccounts("anthropic");
  logExhaustionOnce(freshAccounts, currentEmail, logPrefix, now);
  return false;
}

/** @param {any} client @param {string} currentEmail @param {string} logPrefix */
export async function waitForCooldownRecovery(client, currentEmail, logPrefix) {
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

/** @param {string} logPrefix */
export function forceClearAllCooldowns(logPrefix) {
  const accounts = getAccounts("anthropic");
  for (const acc of accounts) patchAccount("anthropic", acc.email, { status: "idle", cooldownUntil: 0 });
  console.error(`[aidevops] provider-auth: ${logPrefix} — force-cleared all cooldowns after ${MAX_EXHAUSTION_WAIT_MS / 1000}s. Returning response for opencode retry.`);
}

/** @param {object[]} accounts @param {string} sessionAccountEmail */
export function findSessionAccount(accounts, sessionAccountEmail) {
  const account = accounts.find((a) => a.email === sessionAccountEmail);
  if (!account || isOnCooldown(account)) return null;
  return account;
}

/** @param {any} client @param {object[]} accounts @param {string} sessionAccountEmail */
export async function refreshSessionOwnAccount(client, accounts, sessionAccountEmail) {
  const myAccount = findSessionAccount(accounts, sessionAccountEmail);
  if (!myAccount) return null;
  const token = await ensureValidToken("anthropic", myAccount);
  if (!token) return null;
  try { await injectAccountToken(client, myAccount); } catch { /* best-effort */ }
  activateAccount(myAccount.email);
  console.error(`[aidevops] provider-auth: refreshed session account ${myAccount.email}`);
  return { token, email: myAccount.email };
}

/** @param {any} client @param {object} auth @param {string|null} sessionAccountEmail */
export async function recoverFromExhaustion(client, auth, sessionAccountEmail) {
  const recovered = await waitForCooldownRecovery(client, "all", "exhaustion");
  if (recovered) {
    process.env.ANTHROPIC_API_KEY = recovered.token;
    activateAccount(recovered.email);
    return tokenResult(recovered);
  }
  forceClearAllCooldowns("exhaustion");
  return { accessToken: auth.access, sessionAccountEmail };
}
