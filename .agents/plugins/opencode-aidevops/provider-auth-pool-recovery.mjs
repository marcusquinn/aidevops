/**
 * OAuth pool exhaustion recovery helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import {
  ensureValidToken, getAccounts, patchAccount, normalizeExpiredCooldowns, poolAccountLabel,
} from "./oauth-pool.mjs";
import {
  injectAccountToken, activateAccount, isOnCooldown, tokenResult, findSeat, seatResult,
} from "./provider-auth-pool.mjs";

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
  console.error(`[aidevops] provider-auth: ${logPrefix} recovered via ${poolAccountLabel(account)} after ${elapsed}s wait`);
  return seatResult(altToken, account);
}

/** @param {object[]} accounts @param {string} currentEmail @param {string} logPrefix @param {number} now */
export function logExhaustionOnce(accounts, currentEmail, logPrefix, now) {
  const accountSummary = accounts.map((a) => {
    const cd = a.cooldownUntil && a.cooldownUntil > now ? ` (${Math.ceil((a.cooldownUntil - now) / 1000)}s)` : "";
    return `${poolAccountLabel(a)}[${a.status}${cd}]`;
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
  for (const acc of accounts) patchAccount("anthropic", acc, { status: "idle", cooldownUntil: 0 });
  console.error(`[aidevops] provider-auth: ${logPrefix} — force-cleared all cooldowns after ${MAX_EXHAUSTION_WAIT_MS / 1000}s. Returning response for opencode retry.`);
}

/** @param {object[]} accounts @param {string} sessionAccountKey */
export function findSessionAccount(accounts, sessionAccountKey) {
  const account = findSeat(accounts, sessionAccountKey);
  if (!account || isOnCooldown(account)) return null;
  return account;
}

/** @param {any} client @param {object[]} accounts @param {string} sessionAccountKey */
export async function refreshSessionOwnAccount(client, accounts, sessionAccountKey) {
  const myAccount = findSessionAccount(accounts, sessionAccountKey);
  if (!myAccount) return null;
  const token = await ensureValidToken("anthropic", myAccount);
  if (!token) return null;
  try { await injectAccountToken(client, myAccount); } catch { /* best-effort */ }
  activateAccount(myAccount);
  console.error(`[aidevops] provider-auth: refreshed session account ${poolAccountLabel(myAccount)}`);
  return seatResult(token, myAccount);
}

/** @param {any} client @param {object} auth @param {string|null} sessionAccountKey */
export async function recoverFromExhaustion(client, auth, sessionAccountKey) {
  const recovered = await waitForCooldownRecovery(client, "all", "exhaustion");
  if (recovered) {
    process.env.ANTHROPIC_API_KEY = recovered.token;
    process.env.AIDEVOPS_ANTHROPIC_API_KEY_SOURCE = "oauth-pool"; // GH#36707
    activateAccount(recovered.key);
    return tokenResult(recovered);
  }
  forceClearAllCooldowns("exhaustion");
  return { accessToken: auth.access, sessionAccountKey };
}
