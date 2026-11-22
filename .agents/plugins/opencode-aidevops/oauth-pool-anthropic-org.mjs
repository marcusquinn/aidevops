// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Anthropic organization (seat) resolution
 *
 * Each Anthropic OAuth grant is org-scoped, so one email can hold a Team and
 * a Personal seat. Pool identity is email + orgId (GH#38959); this module
 * resolves the org for a new grant and for the email's legacy no-org seat.
 * Python mirrors live in oauth-pool-lib/pool_ops_token_utils.py.
 *
 * @module oauth-pool-anthropic-org
 */

import { ANTHROPIC_PROFILE_URL } from "./oauth-pool-constants.mjs";
import { getAccounts } from "./oauth-pool-storage.mjs";
import { ANTHROPIC_USER_AGENT } from "./oauth-pool-token-endpoint.mjs";

/**
 * Extract the organization from an Anthropic token or profile response.
 * The token exchange returns `organization: { uuid, name }`.
 * @param {any} payload
 * @returns {{orgId: string, orgName: string}|null}
 */
export function extractAnthropicOrg(payload) {
  const org = payload?.organization;
  const orgId = typeof org?.uuid === "string" ? org.uuid.trim() : "";
  if (!orgId) return null;
  return { orgId, orgName: typeof org.name === "string" ? org.name.trim() : "" };
}

async function fetchAnthropicOrg(accessToken) {
  if (!accessToken) return null;
  try {
    const resp = await fetch(ANTHROPIC_PROFILE_URL, {
      headers: { "Authorization": `Bearer ${accessToken}`, "User-Agent": ANTHROPIC_USER_AGENT },
      signal: AbortSignal.timeout(10_000),
    });
    if (!resp.ok) return null;
    return extractAnthropicOrg(await resp.json());
  } catch {
    return null;
  }
}

/**
 * Resolve the organization of the single legacy (no orgId) seat for `email`
 * with that seat's own unexpired access token, so a new grant for a different
 * org adds a seat instead of overwriting it. Returns null when it cannot be
 * resolved (upsert then keeps today's update-in-place behaviour and warns).
 * Never refreshes the legacy token: enrolling one seat must not mutate another.
 */
async function resolveLegacySeatOrg(email) {
  const legacy = getAccounts("anthropic").filter((a) => a.email === email && !a.orgId);
  if (legacy.length !== 1) return null;
  const [seat] = legacy;
  if (!seat.access || !(Number(seat.expires) > Date.now())) return null;
  return fetchAnthropicOrg(seat.access);
}

/**
 * Seat identity for a fresh Anthropic grant: `extras` to store on the account
 * and `upsertOptions` for upsertAccount(). Prefers the token response, falls
 * back to the profile endpoint; without either the seat keeps the email-only
 * key and both objects are empty.
 * @param {any} tokenJson token-exchange response
 * @param {string} email resolved account email
 * @returns {Promise<{extras: object, upsertOptions: object}>}
 */
export async function resolveAnthropicSeat(tokenJson, email) {
  const org = extractAnthropicOrg(tokenJson) || await fetchAnthropicOrg(tokenJson?.access_token);
  if (!org) return { extras: {}, upsertOptions: {} };
  const extras = org.orgName ? { orgId: org.orgId, orgName: org.orgName } : { orgId: org.orgId };
  return { extras, upsertOptions: { legacyOrg: await resolveLegacySeatOrg(email) } };
}
