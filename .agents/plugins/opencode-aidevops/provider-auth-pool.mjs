/**
 * OAuth pool account selection and rotation helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import { ensureValidToken, getAccounts, patchAccount } from "./oauth-pool.mjs";

/** Priority order for account status during pool rotation (lower = tried first). */
export const STATUS_ORDER = { active: 0, idle: 1, "rate-limited": 2, "auth-error": 3 };

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

/** @param {object} account @param {string} currentEmail @param {number} now */
export function isEligibleAlternate(account, currentEmail, now) {
  return (
    account.email !== currentEmail &&
    (account.status === "active" || account.status === "idle") &&
    (!account.cooldownUntil || account.cooldownUntil <= now)
  );
}

/** @param {object[]} accounts @param {string} currentEmail @returns {object[]} */
export function getAvailableAlternates(accounts, currentEmail) {
  const now = Date.now();
  return [...accounts]
    .filter((a) => isEligibleAlternate(a, currentEmail, now))
    .sort((a, b) => new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0));
}

/** Activate an account: patch lastUsed/status. Returns email. */
export function activateAccount(email) {
  patchAccount("anthropic", email, { lastUsed: new Date().toISOString(), status: "active" });
  return email;
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

/** @param {any} client @param {object[]} alternates @param {boolean} forceRefresh */
export async function rotateToAlternateAccount(client, alternates, forceRefresh) {
  for (const alt of alternates) {
    const token = await tryGetAndInjectToken(client, alt, forceRefresh);
    if (token) return { token, email: alt.email };
  }
  return null;
}

/** @param {any} client @param {object} account */
export async function tryActivatePoolAccount(client, account) {
  const token = await ensureValidToken("anthropic", account);
  if (!token) return null;
  try { await injectAccountToken(client, account); } catch { /* best-effort */ }
  activateAccount(account.email);
  console.error(`[aidevops] provider-auth: refreshed via pool account ${account.email}`);
  return { token, email: account.email };
}

/** @param {any} client @param {object[]} accounts */
export async function rotatePoolAccounts(client, accounts) {
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

/** @param {string|null} sessionAccountEmail @param {object} auth */
export function getSessionAccountToken(sessionAccountEmail, auth) {
  if (!sessionAccountEmail) return { accessToken: auth.access, accessExpires: auth.expires };
  const myAccount = getAccounts("anthropic").find((a) => a.email === sessionAccountEmail);
  if (myAccount?.access && myAccount.expires > Date.now()) {
    return { accessToken: myAccount.access, accessExpires: myAccount.expires };
  }
  return { accessToken: auth.access, accessExpires: auth.expires };
}

/** @param {string} accessToken @param {string|null} sessionAccountEmail */
export function resolveSessionEmailFromToken(accessToken, sessionAccountEmail) {
  if (sessionAccountEmail) return sessionAccountEmail;
  const owner = getAccounts("anthropic").find((a) => a.access === accessToken);
  return owner ? owner.email : null;
}

/** Wrap a token result into { accessToken, sessionAccountEmail }. */
export function tokenResult(result) {
  return { accessToken: result.token, sessionAccountEmail: result.email };
}

/** @param {object[]} accounts @returns {object|null} */
export function getMostRecentlyUsedAccount(accounts) {
  if (accounts.length === 0) return null;
  const mru = [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  console.error(`[aidevops] provider-auth: no token match — assuming ${mru.email} (most recently used)`);
  return mru;
}

/** @param {object[]} accounts @param {string|null} sessionAccountEmail @param {string} accessToken */
export function resolveCurrentAccount(accounts, sessionAccountEmail, accessToken) {
  if (sessionAccountEmail) {
    const found = accounts.find((a) => a.email === sessionAccountEmail);
    if (found) return found;
  }
  return accounts.find((a) => a.access === accessToken) ?? getMostRecentlyUsedAccount(accounts);
}
