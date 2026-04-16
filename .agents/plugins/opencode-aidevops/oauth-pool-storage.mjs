/**
 * OAuth Pool — Pool File Storage (t2128)
 *
 * CRUD operations for the pool credential file (~/.aidevops/oauth-pool.json).
 * Handles atomic writes, advisory locking, and account management.
 *
 * @module oauth-pool-storage
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, rmdirSync,
  renameSync, chmodSync,
} from "fs";
import { dirname } from "path";
import { POOL_FILE, POOL_LOCK_FILE } from "./oauth-pool-constants.mjs";

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
 * @property {string} [accountId]
 * @property {number} [priority]
 */

/**
 * Load the pool file. Returns empty pool if file doesn't exist.
 * @returns {Object}
 */
export function loadPool() {
  try {
    if (existsSync(POOL_FILE)) {
      const raw = readFileSync(POOL_FILE, "utf-8");
      return JSON.parse(raw);
    }
  } catch {
    // Corrupted file -- start fresh
  }
  return {};
}

/**
 * Save the pool file with 0600 permissions using an atomic write
 * (temp file + renameSync) so a mid-write crash cannot corrupt the pool.
 * @param {Object} data
 */
export function savePool(data) {
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
 * Execute a read-modify-write operation on the pool file with cross-process
 * advisory locking via atomic directory creation (mkdirSync is POSIX-atomic:
 * only one process can create the same directory; all others get EEXIST).
 *
 * Uses Atomics.wait for a non-busy synchronous pause between retries so the
 * main thread is not burned during the spin. Times out after 5 s to avoid
 * indefinite deadlock if a process crashes while holding the lock.
 *
 * @template T
 * @param {() => T} fn
 * @returns {T}
 */
export function withPoolLock(fn) {
  const dir = dirname(POOL_FILE);
  mkdirSync(dir, { recursive: true });

  const LOCK_DIR = POOL_LOCK_FILE + ".d";
  const LOCK_MAX_WAIT_MS = 5000;
  const LOCK_POLL_MS = 50;
  const deadline = Date.now() + LOCK_MAX_WAIT_MS;
  const sleepBuf = new Int32Array(new SharedArrayBuffer(4));

  // Acquire exclusive lock via atomic directory creation.
  while (true) {
    try {
      mkdirSync(LOCK_DIR); // throws EEXIST if another process holds the lock
      break;               // lock acquired
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      if (Date.now() >= deadline) {
        throw new Error("[aidevops] OAuth pool: timed out waiting for pool lock");
      }
      // Synchronous wait: Atomics.wait works in the Node.js main thread
      Atomics.wait(sleepBuf, 0, 0, LOCK_POLL_MS);
    }
  }

  try {
    return fn();
  } finally {
    try { rmdirSync(LOCK_DIR); } catch { /* ignore */ }
  }
}

// ---------------------------------------------------------------------------
// Account accessors
// ---------------------------------------------------------------------------

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
 * @returns {boolean}
 */
export function upsertAccount(provider, account) {
  return withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) pool[provider] = [];

    // Refuse "unknown" email when named accounts exist
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
 * @param {string} provider
 * @param {object} tokenData
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
 * @param {string} provider
 * @param {string} email
 * @returns {boolean}
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
 * @returns {boolean}
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

/** Get the pool file path. */
export function getPoolFilePath() { return POOL_FILE; }
