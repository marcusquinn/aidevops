// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// GH#37649: provider-wide rate-limit state for routing. The OAuth pool is the
// durable cross-process record: the request auth hooks mark an account
// `rate-limited` with `cooldownUntil` on an inference 429/usage-limit response
// (token-refresh failures use `auth-error` instead). A provider is temporarily
// unroutable only while its pool is the active credential path and no account
// can serve a request; it becomes routable again once the earliest cooldown
// expires, with no configuration change.

import { getAccounts, readCurrentOpenAIAuth, readCurrentProviderAuth } from "./oauth-pool.mjs";
import { openAIAuthSignature } from "./model-unavailability.mjs";

export const POOL_RATE_LIMIT_PROVIDERS = Object.freeze(["anthropic", "openai"]);

function accountUsable(account, now) {
  const cooldown = Number(account?.cooldownUntil) || 0;
  // A rate-limit cooldown that has passed counts as recovered.
  return ["active", "idle", "rate-limited"].includes(account?.status) && cooldown <= now;
}

/**
 * Return the earliest rate-limit reset when no pool account is usable and at
 * least one is rate limited; otherwise 0 (routable or a different failure).
 */
export function poolRateLimitedUntil(accounts, now = Date.now()) {
  if (!Array.isArray(accounts) || accounts.length === 0) return 0;
  if (accounts.some((account) => accountUsable(account, now))) return 0;
  const resets = accounts
    .filter((account) => account?.status === "rate-limited")
    .map((account) => Number(account.cooldownUntil) || 0)
    .filter((until) => until > now);
  return resets.length > 0 ? Math.min(...resets) : 0;
}

/** Map provider ID to rate-limit reset for providers whose OAuth pool is exhausted. */
export function rateLimitedProviders({
  now = Date.now(),
  readAuth = readCurrentProviderAuth,
  readAccounts = getAccounts,
} = {}) {
  const limited = {};
  for (const provider of POOL_RATE_LIMIT_PROVIDERS) {
    try {
      if (readAuth(provider)?.type !== "oauth") continue;
      const until = poolRateLimitedUntil(readAccounts(provider), now);
      if (until) limited[provider] = until;
    } catch {
      // Availability is advisory: an unreadable pool never blocks routing.
    }
  }
  return limited;
}

/**
 * Routing availability read fresh on every decision: exhausted OAuth pools
 * plus the current OpenAI OAuth signature for entitlement rejections.
 */
export function resolveRoutingAvailability({
  readRateLimits = rateLimitedProviders,
  readOpenAIAuth = readCurrentOpenAIAuth,
} = {}) {
  const availability = { rateLimitedProviders: readRateLimits() };
  const auth = readOpenAIAuth();
  if (auth?.type !== "oauth" || !auth.access) return availability;
  return { ...availability, authSignature: openAIAuthSignature(auth.access), openAIAuthType: auth.type };
}
