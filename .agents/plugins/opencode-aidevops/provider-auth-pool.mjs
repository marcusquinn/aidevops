/**
 * OAuth pool account selection and rotation helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import {
  ensureValidToken, getAccounts, patchAccount, findAccountIndex, poolAccountKey, poolAccountLabel,
} from "./oauth-pool.mjs";

/** Priority order for account status during pool rotation (lower = tried first). */
export const STATUS_ORDER = { active: 0, idle: 1, "rate-limited": 2, "auth-error": 3 };

/**
 * Session identity is the seat key (email + optional orgId, GH#38959), so
 * same-email Team and Personal seats rotate independently. Logs use labels.
 * @param {object[]} accounts @param {string|null} key
 */
export function findSeat(accounts, key) {
  const idx = findAccountIndex(accounts, key);
  return idx >= 0 ? accounts[idx] : undefined;
}

/** Rotation result for one seat: token plus identity key and display label. */
export function seatResult(token, account) {
  return { token, email: account.email, key: poolAccountKey(account), label: poolAccountLabel(account) };
}

/**
 * Inject a pool account token into the OpenCode auth store.
 * @param {any} client
 * @param {object} account
 */
export async function injectAccountToken(client, account) {
  await client.auth.set({
    path: { id: "anthropic" },
    body: { type: "oauth", refresh: account.refresh, access: account.access, expires: account.expires },
  });
}

/** @param {object} a @param {object} b */
export function compareAccountPriority(a, b) {
  const aOrder = STATUS_ORDER[a.status] ?? 99;
  const bOrder = STATUS_ORDER[b.status] ?? 99;
  if (aOrder !== bOrder) return aOrder - bOrder;
  return new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0);
}

/** @param {object[]} accounts @returns {object[]} */
export function sortAccountsByPriority(accounts) {
  return [...accounts].sort(compareAccountPriority);
}

/** @param {object} account @param {string} currentKey @param {number} now */
export function isEligibleAlternate(account, currentKey, now) {
  return (
    poolAccountKey(account) !== currentKey &&
    (account.status === "active" || account.status === "idle") &&
    (!account.cooldownUntil || account.cooldownUntil <= now)
  );
}

/** @param {object[]} accounts @param {string} currentKey @returns {object[]} */
export function getAvailableAlternates(accounts, currentKey) {
  const now = Date.now();
  return [...accounts]
    .filter((a) => isEligibleAlternate(a, currentKey, now))
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));
}

/**
 * Activate an account: patch lastUsed/status. Returns its seat key.
 * @param {string|object} ref seat key or account object
 */
export function activateAccount(ref) {
  patchAccount("anthropic", ref, { lastUsed: new Date().toISOString(), status: "active" });
  return typeof ref === "string" ? ref : poolAccountKey(ref);
}

/** @param {object} account @returns {boolean} */
export function isOnCooldown(account) {
  return !!(account.cooldownUntil && account.cooldownUntil > Date.now());
}

/** @param {any} client @param {object} account @param {boolean} forceRefresh */
export async function tryGetAndInjectToken(client, account, forceRefresh) {
  const accountArg = forceRefresh ? { ...account, expires: 0 } : account;
  let token;
  try {
    token = await ensureValidToken("anthropic", accountArg);
  } catch (err) {
    console.error(`[aidevops] provider-auth: ensureValidToken failed for ${poolAccountLabel(account)}: ${err.message}`);
    return null;
  }
  if (!token) return null;
  try {
    await injectAccountToken(client, account);
  } catch (err) {
    console.error(`[aidevops] provider-auth: failed to inject token for ${poolAccountLabel(account)}: ${err.message}`);
    return null;
  }
  return token;
}

/** @param {any} client @param {object[]} alternates @param {boolean} forceRefresh */
export async function rotateToAlternateAccount(client, alternates, forceRefresh) {
  for (const alt of alternates) {
    const token = await tryGetAndInjectToken(client, alt, forceRefresh);
    if (token) return seatResult(token, alt);
  }
  return null;
}

/** @param {any} client @param {object} account */
export async function tryActivatePoolAccount(client, account) {
  const token = await ensureValidToken("anthropic", account);
  if (!token) return null;
  try { await injectAccountToken(client, account); } catch { /* best-effort */ }
  activateAccount(account);
  console.error(`[aidevops] provider-auth: refreshed via pool account ${poolAccountLabel(account)}`);
  return seatResult(token, account);
}

/** @param {any} client @param {object[]} accounts */
export async function rotatePoolAccounts(client, accounts) {
  for (const account of sortAccountsByPriority(accounts)) {
    if (isOnCooldown(account)) {
      console.error(`[aidevops] provider-auth: skipping ${poolAccountLabel(account)} — cooldown active`);
      continue;
    }
    const result = await tryActivatePoolAccount(client, account);
    if (result) return result;
  }
  return null;
}

/** @param {string|null} sessionAccountKey @param {object} auth */
export function getSessionAccountToken(sessionAccountKey, auth) {
  if (!sessionAccountKey) return { accessToken: auth.access, accessExpires: auth.expires };
  const myAccount = findSeat(getAccounts("anthropic"), sessionAccountKey);
  if (myAccount?.access && myAccount.expires > Date.now()) {
    return { accessToken: myAccount.access, accessExpires: myAccount.expires };
  }
  return { accessToken: auth.access, accessExpires: auth.expires };
}

/** @param {string} accessToken @param {string|null} sessionAccountKey */
export function resolveSessionKeyFromToken(accessToken, sessionAccountKey) {
  if (sessionAccountKey) return sessionAccountKey;
  const owner = getAccounts("anthropic").find((a) => a.access === accessToken);
  return owner ? poolAccountKey(owner) : null;
}

/** Wrap a token result into { accessToken, sessionAccountKey }. */
export function tokenResult(result) {
  return { accessToken: result.token, sessionAccountKey: result.key };
}

/** @param {object[]} accounts @returns {object|null} */
export function getMostRecentlyUsedAccount(accounts) {
  if (accounts.length === 0) return null;
  const mru = [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  console.error(`[aidevops] provider-auth: no token match — assuming ${poolAccountLabel(mru)} (most recently used)`);
  return mru;
}

/** @param {object[]} accounts @param {string|null} sessionAccountKey @param {string} accessToken */
export function resolveCurrentAccount(accounts, sessionAccountKey, accessToken) {
  if (sessionAccountKey) {
    const found = findSeat(accounts, sessionAccountKey);
    if (found) return found;
  }
  return accounts.find((a) => a.access === accessToken) ?? getMostRecentlyUsedAccount(accounts);
}
