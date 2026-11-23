// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Account Management Actions
 *
 * Mutating pool tool actions for account removal, cooldown resets, pending
 * token assignment, and priority updates.
 *
 * Seat selection (GH#38959): one email can hold several Anthropic seats
 * (e.g. Team org + Personal). When it does, actions require an `org`
 * selector (organization name or UUID prefix) and refuse otherwise.
 *
 * @module oauth-pool-account-actions
 */

import {
  getAccounts, getPendingToken, removeAccount, assignPendingToken,
  withPoolLock, loadPool, savePool, findAccountIndex, poolAccountLabel, selectSeat,
} from "./oauth-pool-storage.mjs";
import { resetEndpointCooldown } from "./oauth-pool-token-endpoint.mjs";

function seatChoice(account) {
  const org = account.orgId ? ` (org: ${String(account.orgId).slice(0, 8)})` : " (no org recorded)";
  return `  - ${poolAccountLabel(account)}${org}`;
}

/**
 * Resolve the target seat or return a user-facing error message.
 * @returns {{seat: object|null, message: string}}
 */
function resolveSeat(provider, email, org) {
  const { account, error, candidates } = selectSeat(getAccounts(provider), email, org);
  if (account) return { seat: account, message: "" };
  if (error === "ambiguous") {
    return {
      seat: null,
      message: [
        `${email} has ${candidates.length} seats in the ${provider} pool. Pass org (organization name or UUID prefix) to choose one:`,
        ...candidates.map(seatChoice),
      ].join("\n"),
    };
  }
  const suffix = org ? ` with org "${org}"` : "";
  return { seat: null, message: `Account ${email}${suffix} not found in ${provider} pool.` };
}

export function poolActionRemove(provider, email, org) {
  if (!email) return "Error: email is required for remove action. Usage: remove <email> [org]";
  const { seat, message } = resolveSeat(provider, email, org);
  if (!seat) return message;
  if (!removeAccount(provider, seat)) return `Account ${poolAccountLabel(seat)} not found in ${provider} pool.`;
  const remaining = getAccounts(provider).length;
  return `Removed ${poolAccountLabel(seat)} from ${provider} pool (${remaining} account${remaining === 1 ? "" : "s"} remaining).`;
}

export function poolActionResetCooldowns(provider) {
  const wasGated = resetEndpointCooldown(provider);
  const resetCount = withPoolLock(() => {
    const pool = loadPool();
    let count = 0;
    if (pool[provider]) {
      for (const a of pool[provider]) {
        if (a.cooldownUntil) { a.cooldownUntil = null; a.status = "idle"; count++; }
      }
      savePool(pool);
    }
    return count;
  });
  const parts = [];
  if (wasGated) parts.push("token endpoint cooldown cleared");
  if (resetCount > 0) parts.push(`${resetCount} account cooldown${resetCount === 1 ? "" : "s"} cleared`);
  if (parts.length === 0) parts.push("no active cooldowns");
  return `Reset (${provider}): ${parts.join(", ")}. Token endpoint requests will proceed on next attempt.`;
}

export function poolActionAssignPending(provider, accounts, email, org) {
  const pending = getPendingToken(provider);
  if (!pending) return `No pending token for ${provider}.`;
  const available = accounts.map(poolAccountLabel).join(", ");
  if (!email) {
    return `Pending ${provider} token found (added: ${pending.added}). Assign to: ${available}\n\nUsage: assign-pending with email parameter (and org when the email has several seats).`;
  }
  const { seat, message } = resolveSeat(provider, email, org);
  if (!seat) return `Failed: ${message} Available: ${available}`;
  return assignPendingToken(provider, seat)
    ? `Assigned pending token to ${poolAccountLabel(seat)} in ${provider} pool.`
    : `Failed: account ${poolAccountLabel(seat)} not found. Available: ${available}`;
}

export function poolActionSetPriority(provider, email, priority, org) {
  if (!email) return "Error: email is required for set-priority action.";
  if (priority === undefined || priority === null) return "Error: priority (integer) is required.";
  const p = Number(priority);
  if (!Number.isInteger(p)) return `Error: priority must be an integer, got: ${priority}`;
  const { seat, message } = resolveSeat(provider, email, org);
  if (!seat) return message;
  const label = poolAccountLabel(seat);
  return withPoolLock(() => {
    const pool = loadPool();
    const accts = pool[provider] || [];
    const idx = findAccountIndex(accts, seat);
    if (idx < 0) return `Account ${label} not found in ${provider} pool.`;
    if (p === 0) delete accts[idx].priority; else accts[idx].priority = p;
    savePool(pool);
    return p === 0
      ? `Cleared priority for ${label} (defaults to LRU order).`
      : `Set priority ${p} for ${label}. Higher-priority accounts preferred during rotation.`;
  });
}
