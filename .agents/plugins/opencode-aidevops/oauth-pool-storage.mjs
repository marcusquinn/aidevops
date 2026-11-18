/**
 * OAuth Pool — Pool File Storage (t2128)
 *
 * CRUD operations for the pool credential file (~/.aidevops/oauth-pool.json).
 * Handles atomic writes, advisory locking, and account management.
 *
 * @module oauth-pool-storage
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, rmdirSync, unlinkSync,
  renameSync, chmodSync, statSync,
} from "fs";
import { randomUUID } from "crypto";
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
 * @property {string} [orgId] Anthropic organization UUID; part of the identity key
 * @property {string} [orgName] Anthropic organization name; display only
 * @property {number} [priority]
 * @property {number} [authRefreshFailures]
 * @property {number} [authRefreshLastFailureAt]
 */

// ---------------------------------------------------------------------------
// Account identity (GH#38959)
// ---------------------------------------------------------------------------

/**
 * Stable pool identity: email plus the optional Anthropic organization UUID,
 * so one login email can hold separate seats (e.g. a Team org and a Personal
 * plan). Entries without orgId keep the legacy email-only key, so single-seat
 * pools behave exactly as before. The key embeds the org UUID: log
 * poolAccountLabel(), never the key.
 * @param {{email?: string, orgId?: string}|null|undefined} account
 * @returns {string}
 */
export function poolAccountKey(account) {
  const email = account?.email || "";
  return account?.orgId ? `${email}#${account.orgId}` : email;
}

/**
 * Human-readable seat label: "email", "email [Org name]" or
 * "email [org:1234abcd]" when only the UUID is known.
 * @param {{email?: string, orgId?: string, orgName?: string}|null|undefined} account
 * @returns {string}
 */
export function poolAccountLabel(account) {
  const email = account?.email || "unknown";
  if (account?.orgName) return `${email} [${account.orgName}]`;
  if (account?.orgId) return `${email} [org:${String(account.orgId).slice(0, 8)}]`;
  return email;
}

function seatIndicesForEmail(accounts, email) {
  const indices = [];
  accounts.forEach((account, idx) => { if (account?.email === email) indices.push(idx); });
  return indices;
}

/**
 * Resolve an account reference to its index. A ref is an account object
 * (matched by key) or a string key. Legacy refs (a plain email, or an object
 * read before its orgId was backfilled) still resolve while that email
 * identifies exactly one seat; an ambiguous email matches nothing.
 * @param {PoolAccount[]} accounts
 * @param {string|{email?: string, orgId?: string}} ref
 * @returns {number}
 */
export function findAccountIndex(accounts, ref) {
  if (!ref || !Array.isArray(accounts)) return -1;
  const key = typeof ref === "string" ? ref : poolAccountKey(ref);
  const exact = accounts.findIndex((account) => poolAccountKey(account) === key);
  if (exact >= 0) return exact;
  const email = typeof ref === "string" ? ref : (ref.orgId ? "" : ref.email);
  const seats = email ? seatIndicesForEmail(accounts, email) : [];
  return seats.length === 1 ? seats[0] : -1;
}

/**
 * True when an org selector picks the account: a case-insensitive orgId
 * prefix or exact orgName. An empty selector matches every account.
 * @param {PoolAccount} account
 * @param {string|undefined} org
 */
export function accountMatchesOrg(account, org) {
  const needle = String(org || "").trim().toLowerCase();
  if (!needle) return true;
  return String(account?.orgId || "").toLowerCase().startsWith(needle) ||
    String(account?.orgName || "").toLowerCase() === needle;
}

/**
 * Select one seat by email plus an optional org selector. Used by user-facing
 * actions (remove, set-priority, assign-pending) so a shared email never
 * silently acts on the wrong seat.
 * @param {PoolAccount[]} accounts
 * @param {string} email
 * @param {string} [org]
 * @returns {{account: PoolAccount|null, error: ""|"not_found"|"ambiguous", candidates: PoolAccount[]}}
 */
export function selectSeat(accounts, email, org) {
  const candidates = (accounts || []).filter((account) => account?.email === email);
  const matches = candidates.filter((account) => accountMatchesOrg(account, org));
  if (matches.length === 1) return { account: matches[0], error: "", candidates };
  return { account: null, error: matches.length === 0 ? "not_found" : "ambiguous", candidates };
}

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
  const dir = dirname(POOL_FILE);
  let tmp = "";
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    tmp = `${POOL_FILE}.tmp.${process.pid}.${randomUUID()}`;
    writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, POOL_FILE);
  } catch (err) {
    if (tmp) {
      try { unlinkSync(tmp); } catch { /* absent or already renamed */ }
    }
    console.error(`[aidevops] OAuth pool: failed to save pool file: ${err.message}`);
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Pool lock helpers (used only by withPoolLock)
// ---------------------------------------------------------------------------

const LOCK_DIR = POOL_LOCK_FILE + ".d";
const OWNER_FILE = LOCK_DIR + "/owner";
const LOCK_WAIT_MS = 30000;
const OWNERLESS_LOCK_GRACE_MS = 30000;
let activeAsyncLockToken = "";
let asyncLockTail = Promise.resolve();

function ensurePoolDirectory() {
  const dir = dirname(POOL_FILE);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
}

function processIsLive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM";
  }
}

/** Return a stable snapshot only when the current lock can be reclaimed. */
function staleLockSnapshot() {
  try {
    const raw = readFileSync(OWNER_FILE, "utf-8");
    const owner = JSON.parse(raw);
    return processIsLive(owner.pid) ? null : raw;
  } catch {
    try {
      return Date.now() - statSync(LOCK_DIR).mtimeMs >= OWNERLESS_LOCK_GRACE_MS ? "" : null;
    } catch {
      return null;
    }
  }
}

/** Remove only the unchanged stale lock observed by staleLockSnapshot. */
function removeStaleLock(snapshot) {
  try {
    const current = readFileSync(OWNER_FILE, "utf-8");
    if (current !== snapshot) return;
  } catch {
    if (snapshot !== "") return;
  }
  try { unlinkSync(OWNER_FILE); } catch { /* race */ }
  try { rmdirSync(LOCK_DIR); } catch { /* race */ }
}

function tryAcquireLock() {
  const token = randomUUID();
  try {
    mkdirSync(LOCK_DIR, { mode: 0o700 });
  } catch (err) {
    if (err?.code === "EEXIST") return "";
    throw err;
  }
  try {
    chmodSync(LOCK_DIR, 0o700);
    writeFileSync(
      OWNER_FILE,
      JSON.stringify({ schema: "aidevops.oauth-lock/v1", pid: process.pid, token, createdAt: Date.now() }),
      { flag: "wx", mode: 0o600 },
    );
    chmodSync(OWNER_FILE, 0o600);
    return token;
  } catch (err) {
    try { unlinkSync(OWNER_FILE); } catch { /* absent */ }
    try { rmdirSync(LOCK_DIR); } catch { /* retained for diagnosis */ }
    throw err;
  }
}

/** Release the lock only when its unguessable owner token still matches. */
function releaseLock(token) {
  try {
    const owner = JSON.parse(readFileSync(OWNER_FILE, "utf-8"));
    if (owner.pid !== process.pid || owner.token !== token) return;
    try { unlinkSync(OWNER_FILE); } catch { /* ignore */ }
    try { rmdirSync(LOCK_DIR); } catch { /* ignore */ }
  } catch { /* lock dir already gone — that's fine */ }
}

function waitForLockSync() {
  const deadline = Date.now() + LOCK_WAIT_MS;
  const sleepBuf = new Int32Array(new SharedArrayBuffer(4));
  while (Date.now() < deadline) {
    const token = tryAcquireLock();
    if (token) return token;
    const snapshot = staleLockSnapshot();
    if (snapshot !== null) {
      removeStaleLock(snapshot);
      continue;
    }
    Atomics.wait(sleepBuf, 0, 0, 50);
  }
  throw new Error("[aidevops] OAuth pool: timed out waiting for pool lock");
}

async function waitForLockAsync() {
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    const token = tryAcquireLock();
    if (token) return token;
    const snapshot = staleLockSnapshot();
    if (snapshot !== null) {
      removeStaleLock(snapshot);
      continue;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("[aidevops] OAuth pool: timed out waiting for pool lock");
}

/**
 * Execute a read-modify-write operation on the pool file with cross-process
 * advisory locking via atomic directory creation (mkdirSync is POSIX-atomic).
 *
 * An owner file records { pid, ts } on acquisition; stale locks from crashed
 * processes are reclaimed automatically. Times out after 5 s.
 *
 * @template T
 * @param {() => T} fn
 * @returns {T}
 */
export function withPoolLock(fn) {
  ensurePoolDirectory();
  if (activeAsyncLockToken) return fn();
  const token = waitForLockSync();
  try { return fn(); }
  finally { releaseLock(token); }
}

/**
 * Execute an async refresh transaction under the same cross-process lock.
 * Synchronous same-process mutations remain re-entrant and complete before the
 * awaiting refresh continuation resumes on the JavaScript event loop.
 *
 * @template T
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
export async function withPoolLockAsync(fn) {
  ensurePoolDirectory();
  const previous = asyncLockTail;
  let advanceQueue = () => {};
  asyncLockTail = new Promise((resolve) => { advanceQueue = resolve; });
  await previous;

  let token = "";
  try {
    token = await waitForLockAsync();
    activeAsyncLockToken = token;
    return await fn();
  } finally {
    activeAsyncLockToken = "";
    if (token) releaseLock(token);
    advanceQueue();
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
 * Decide which existing row a new grant replaces (GH#38959).
 *
 * - Same key (email + orgId) → replace that seat only.
 * - Grant with orgId and exactly one legacy same-email row (no orgId):
 *   if `legacyOrg` resolved to a different org, record it on the legacy row
 *   and add a new seat; otherwise update the legacy row in place (today's
 *   behaviour) and backfill the grant's orgId.
 * - Grant without orgId → today's email match, refused when it is ambiguous.
 * @returns {{idx: number, note?: "split"|"unresolved", ambiguous?: boolean, legacy?: PoolAccount}}
 */
function findUpsertTarget(accounts, account, legacyOrg) {
  const key = poolAccountKey(account);
  const exact = accounts.findIndex((candidate) => poolAccountKey(candidate) === key);
  if (exact >= 0) return { idx: exact };
  const seats = seatIndicesForEmail(accounts, account.email);
  return account.orgId
    ? legacySeatTarget(accounts, seats, account, legacyOrg)
    : emailOnlyTarget(seats);
}

/** Grant without orgId: the email's only seat; several seats is ambiguous. */
function emailOnlyTarget(seats) {
  if (seats.length > 1) return { idx: -1, ambiguous: true };
  return { idx: seats.length === 1 ? seats[0] : -1 };
}

/** Grant with orgId: split from or update the email's single legacy seat. */
function legacySeatTarget(accounts, seats, account, legacyOrg) {
  const legacySeats = seats.filter((idx) => !accounts[idx].orgId);
  if (legacySeats.length !== 1) return { idx: -1 };
  const legacy = accounts[legacySeats[0]];
  if (legacyOrg?.orgId && legacyOrg.orgId !== account.orgId) {
    legacy.orgId = legacyOrg.orgId;
    if (legacyOrg.orgName) legacy.orgName = legacyOrg.orgName;
    return { idx: -1, note: "split", legacy };
  }
  return { idx: legacySeats[0], note: legacyOrg?.orgId ? undefined : "unresolved" };
}

/**
 * A grant without org that updates an org-tagged seat keeps that seat's org,
 * so the update never changes the seat's identity. Mirrors Python cmd_upsert,
 * which updates the row in place (GH#38959).
 */
function retainSeatOrg(existing, account) {
  if (account.orgId || !existing?.orgId) return;
  account.orgId = existing.orgId;
  if (existing.orgName) account.orgName = existing.orgName;
}

function logUpsertNote(target, account) {
  const label = poolAccountLabel(account);
  if (target.note === "split") {
    console.error(
      `[aidevops] OAuth pool: added a separate seat ${label}; the existing seat is now recorded as ${poolAccountLabel(target.legacy)}.`,
    );
  } else if (target.note === "unresolved") {
    console.error(
      [
        `[aidevops] OAuth pool: ${account.email} had one seat with no recorded organization, so it was updated in place and now holds ${label}.`,
        "If that seat belonged to a different organization (e.g. Team vs Personal), re-add it now; it will be stored as a separate seat.",
      ].join(" "),
    );
  }
}

/**
 * Add or update an account in the pool.
 * Identity is poolAccountKey(): the same email + orgId updates that seat; a
 * different orgId for the same email adds a separate seat (GH#38959).
 * @param {string} provider
 * @param {PoolAccount} account
 * @param {{legacyOrg?: {orgId: string, orgName?: string}|null}} [options]
 *   legacyOrg: the organization resolved for the single legacy (no orgId)
 *   row of this email, or null when it could not be resolved
 * @returns {boolean}
 */
export function upsertAccount(provider, account, options = {}) {
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

    const target = findUpsertTarget(pool[provider], account, options.legacyOrg);
    if (target.ambiguous) {
      console.error(
        [
          `[aidevops] OAuth pool: REFUSED to save a grant for ${account.email}: that email has several seats`,
          "and the grant carries no organization, so the target seat is unknown.",
          "Use assign-pending with the email and org to choose the seat.",
        ].join(" "),
      );
      return false;
    }
    if (target.idx >= 0) {
      retainSeatOrg(pool[provider][target.idx], account);
      pool[provider][target.idx] = account;
    } else {
      pool[provider].push(account);
    }
    savePool(pool);
    logUpsertNote(target, account);
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
 * Assign a pending token to an existing account.
 * @param {string} provider
 * @param {string|PoolAccount} ref account object, key, or unambiguous email
 * @returns {boolean}
 */
export function assignPendingToken(provider, ref) {
  return withPoolLock(() => {
    const pool = loadPool();
    const pendingKey = `_pending_${provider}`;
    const pending = pool[pendingKey];
    if (!pending) return false;

    if (!pool[provider]) pool[provider] = [];
    const idx = findAccountIndex(pool[provider], ref);
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
    console.error(`[aidevops] OAuth pool: assigned pending token to ${poolAccountLabel(pool[provider][idx])}`);
    return true;
  });
}

/**
 * Remove one account (seat) from the pool.
 * @param {string} provider
 * @param {string|PoolAccount} ref account object, key, or unambiguous email
 * @returns {boolean}
 */
export function removeAccount(provider, ref) {
  return withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return false;
    const idx = findAccountIndex(pool[provider], ref);
    if (idx < 0) return false;
    pool[provider].splice(idx, 1);
    savePool(pool);
    return true;
  });
}

/**
 * Update an account's status and cooldown in the pool.
 * @param {string} provider
 * @param {string|PoolAccount} ref account object, key, or unambiguous email
 * @param {Partial<PoolAccount>} patch
 */
export function patchAccount(provider, ref, patch) {
  withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return;
    const idx = findAccountIndex(pool[provider], ref);
    if (idx < 0) return;
    Object.assign(pool[provider][idx], patch);
    savePool(pool);
  });
}

/** Get the pool file path. */
export function getPoolFilePath() { return POOL_FILE; }
