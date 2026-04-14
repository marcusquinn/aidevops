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

import { ensureValidToken, getAccounts } from "./oauth-pool.mjs";

/** Default cooldown (ms) before retrying a rate-limited account. */
const RATE_LIMIT_COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes

/** Map<email, expiryTimestamp> — accounts known to be rate-limited. */
const rateLimitedAccounts = new Map();

/**
 * Sort accounts by descending priority then ascending email for stable order.
 */
function sortAccountsByPriority(accounts) {
  return [...accounts].sort((a, b) => {
    const pa = Number(a?.priority || 0);
    const pb = Number(b?.priority || 0);
    if (pa !== pb) return pb - pa;
    return (a?.email || "").localeCompare(b?.email || "");
  });
}

/**
 * Mark an account as rate-limited so subsequent requests skip it.
 * @param {string} email
 * @param {string} [resetsAt] - optional ISO/epoch from Claude's rate_limit_event
 */
export function markAccountRateLimited(email, resetsAt) {
  let expiry = Date.now() + RATE_LIMIT_COOLDOWN_MS;
  if (resetsAt) {
    const parsed = Number(resetsAt) > 1e9 ? Number(resetsAt) * 1000 : Date.parse(resetsAt);
    if (!isNaN(parsed) && parsed > Date.now()) {
      expiry = parsed;
    }
  }
  rateLimitedAccounts.set(email, expiry);
  console.error(
    `[aidevops] Claude proxy: account ${email} rate-limited until ${new Date(expiry).toISOString()}`,
  );
}

export function isAccountRateLimited(email) {
  const expiry = rateLimitedAccounts.get(email);
  if (!expiry) return false;
  if (Date.now() >= expiry) {
    rateLimitedAccounts.delete(email);
    return false;
  }
  return true;
}

/**
 * Get all available accounts with valid tokens, skipping rate-limited ones.
 * Returns array of `{ email, token }` in priority order.
 */
export async function getAvailableAccounts() {
  const accounts = sortAccountsByPriority(getAccounts("anthropic"));
  const available = [];
  for (const account of accounts) {
    const email = account?.email || "unknown";
    if (isAccountRateLimited(email)) continue;
    const token = await ensureValidToken("anthropic", account);
    if (token) {
      available.push({ email, token });
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
  return { email: "native-cli-auth", token: null };
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
  if (event?.type === "rate_limit_event") {
    return { rateLimited: true, resetsAt: event?.rate_limit_info?.resetsAt };
  }
  if (event?.type === "assistant" && event?.error === "rate_limit") {
    return { rateLimited: true };
  }
  return { rateLimited: false };
}
