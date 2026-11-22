// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Account rotation, rate-limit tracking, and rate-limit signal detection
 * for the Claude CLI proxy.
 *
 * Extracted from claude-proxy.mjs as part of t2070 to drop file complexity
 * and keep the streaming path focused on transport. The proxy maintains a
 * pool of OAuth tokens (one per Anthropic account) and rotates through them
 * when one hits a rate limit, marking the offender unavailable until its
 * cooldown expires. Rate-limit signals come back via two channels:
 *   - JSON mode: `{ is_error: true, result: "...hit your limit..." }`
 *   - Stream mode: `rate_limit_event` or `assistant` event with `error: "rate_limit"`
 *
 * Module-level state (`rateLimitedAccounts`) is intentional — it's process
 * lifetime cooldown bookkeeping that all callers share.
 */

import {
  ensureValidToken, getAccounts, patchAccount, poolAccountKey, poolAccountLabel,
} from "./oauth-pool.mjs";
import { compareByReset, shouldReplaceUsage, usagePatchFromRateLimitInfo } from "./oauth-pool-ordering.mjs";

/** Default cooldown (ms) before retrying a rate-limited account. */
const RATE_LIMIT_COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes

/**
 * Map<seatKey, expiryTimestamp> — seats known to be rate-limited. Keyed by
 * poolAccountKey (email + optional orgId, GH#38959) so a limited Team seat
 * does not also bench the same-email Personal seat.
 */
const rateLimitedAccounts = new Map();

/**
 * Sort accounts by descending priority then ascending seat key for stable order.
 */
function sortAccountsByPriority(accounts) {
  return [...accounts].sort((a, b) => {
    const pa = Number(a?.priority || 0);
    const pb = Number(b?.priority || 0);
    if (pa !== pb) return pb - pa;
    const byReset = compareByReset(a, b);
    if (byReset !== 0) return byReset;
    return poolAccountKey(a).localeCompare(poolAccountKey(b));
  });
}

/**
 * Mark a seat as rate-limited so subsequent requests skip it.
 * @param {{key: string, label?: string}} account - entry from getAvailableAccounts()
 * @param {string} [resetsAt] - optional ISO/epoch from Claude's rate_limit_event
 */
export function markAccountRateLimited(account, resetsAt) {
  let expiry = Date.now() + RATE_LIMIT_COOLDOWN_MS;
  if (resetsAt) {
    const parsed = Number(resetsAt) > 1e9 ? Number(resetsAt) * 1000 : Date.parse(resetsAt);
    if (!isNaN(parsed) && parsed > Date.now()) {
      expiry = parsed;
    }
  }
  rateLimitedAccounts.set(account.key, expiry);
  console.error(
    `[aidevops] Claude proxy: account ${account.label || account.key} rate-limited until ${new Date(expiry).toISOString()}`,
  );
}

/** @param {string} seatKey */
export function isAccountRateLimited(seatKey) {
  const expiry = rateLimitedAccounts.get(seatKey);
  if (!expiry) return false;
  if (Date.now() >= expiry) {
    rateLimitedAccounts.delete(seatKey);
    return false;
  }
  return true;
}

/**
 * Get all available accounts with valid tokens, skipping rate-limited ones.
 * Returns array of `{ email, key, label, token }` in priority order.
 */
export async function getAvailableAccounts() {
  const accounts = sortAccountsByPriority(getAccounts("anthropic"));
  const available = [];
  for (const account of accounts) {
    const key = poolAccountKey(account) || "unknown";
    if (isAccountRateLimited(key)) continue;
    const token = await ensureValidToken("anthropic", account);
    if (token) {
      available.push({ email: account?.email || "unknown", key, label: poolAccountLabel(account), token });
    }
  }
  return available;
}

/**
 * Build a child-process env for a Claude CLI subprocess.
 *
 * When `token` is a pool OAuth token: inject it via `CLAUDE_CODE_OAUTH_TOKEN`
 * and strip `ANTHROPIC_API_KEY` so it cannot win precedence.
 *
 * When `token` is null (native CLI fallback): clear only `CLAUDE_CODE_OAUTH_TOKEN`
 * and leave `ANTHROPIC_API_KEY` intact so the CLI can use whatever credential
 * it has available (env API key, ~/.claude.json OAuth, etc.).
 */
export function buildChildEnvWithToken(token) {
  const childEnv = { ...process.env };
  if (token !== null) {
    // Injecting pool OAuth token — strip API key so it doesn't win precedence.
    delete childEnv.ANTHROPIC_API_KEY;
    childEnv.CLAUDE_CODE_OAUTH_TOKEN = token;
  } else {
    // Native CLI auth — clear injected token only; keep ANTHROPIC_API_KEY.
    delete childEnv.CLAUDE_CODE_OAUTH_TOKEN;
  }
  return childEnv;
}

/**
 * Synthetic "account" representing the Claude CLI's own stored credentials
 * (`~/.claude.json`). Used as the final fallback when all OAuth pool accounts
 * are rate-limited or unavailable. `token: null` signals `buildChildEnvWithToken`
 * to clear injected credentials so the CLI uses its native auth.
 */
export function getNativeCliFallback() {
  return { email: "native-cli-auth", key: "native-cli-auth", label: "native-cli-auth", token: null };
}

/**
 * Persist the usage window carried by a stream `rate_limit_event` onto the
 * seat (t19125) so rotation can prefer the soonest-resetting seat. Best-effort:
 * never throws, never logs tokens or headers.
 * @param {{key: string}|null|undefined} account - entry from getAvailableAccounts()
 * @param {object} event - parsed stream event
 */
export function recordAccountUsage(account, event) {
  if (!account?.key || event?.type !== "rate_limit_event") return;
  try {
    const patch = usagePatchFromRateLimitInfo(event.rate_limit_info);
    if (!patch) return;
    const current = getAccounts("anthropic").find((a) => poolAccountKey(a) === account.key);
    if (current && shouldReplaceUsage(current, patch)) patchAccount("anthropic", account.key, patch);
  } catch {
    /* usage capture must never block the request path */
  }
}

/**
 * Detect a rate-limit signal in Claude CLI JSON output.
 * @param {object} parsed - parsed JSON from Claude CLI
 * @returns {string|null|undefined}
 *   - `null`: rate-limited (no explicit reset time)
 *   - `undefined`: not rate-limited
 */
export function detectRateLimitJson(parsed) {
  if (parsed?.is_error && typeof parsed?.result === "string" && parsed.result.includes("hit your limit")) {
    return null;
  }
  return undefined;
}

/**
 * Detect a rate-limit signal in a stream-json event line.
 * @param {object} event - parsed stream event
 * @returns {{ rateLimited: boolean, resetsAt?: string }}
 */
export function detectRateLimitStream(event) {
  if (event?.type === "rate_limit_event" && event?.rate_limit_info?.status === "rejected") {
    return { rateLimited: true, resetsAt: event?.rate_limit_info?.resetsAt };
  }
  if (event?.type === "assistant" && event?.error === "rate_limit") {
    return { rateLimited: true };
  }
  return { rateLimited: false };
}
