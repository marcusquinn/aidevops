// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Reset-aware seat ordering (t19125).
 *
 * Usage windows are use-it-or-lose-it, so within one `priority` tier a seat
 * whose window resets soonest (and still has quota) is preferred: earliest
 * deadline first. Seats with no usable data compare equal to each other and
 * sort after known-good seats, so callers' own tiebreak (LRU or seat key)
 * keeps today's behaviour when no data exists.
 *
 * Data source: Claude CLI stream-json `rate_limit_event.rate_limit_info`
 * (`status`, `resetsAt`, `rateLimitType`, optional `utilization`), observed in
 * claude-proxy-streaming.mjs. Only the numeric/enum fields are persisted.
 *
 * Mirrored in .agents/scripts/oauth-pool-lib/pool_ops_rotate.py.
 */

/** Seats at or below this remaining percentage are not preferred on reset grounds. */
export const USAGE_REMAINING_FLOOR_PCT = 5;

/** Observations older than this are unknown even if the reset is still in the future. */
export const USAGE_MAX_AGE_MS = 8 * 24 * 60 * 60 * 1000;

/** Window types, weekly first. Unknown window names rank last. */
const WINDOW_RANK = { seven_day: 0, seven_day_opus: 0, seven_day_sonnet: 0, five_hour: 1 };

function toMs(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n < 1e12 ? n * 1000 : n; // epoch seconds -> ms
}

/**
 * Returns the seat's usable reset time (epoch ms) or null when unknown:
 * no data, reset already passed, observation too old, or quota at/below floor.
 * @param {object} account @param {number} [now]
 * @returns {number|null}
 */
export function usableResetAt(account, now = Date.now()) {
  const reset = toMs(account?.usageResetAt);
  if (!reset || reset <= now) return null;
  const observed = toMs(account?.usageObservedAt);
  if (observed && now - observed > USAGE_MAX_AGE_MS) return null;
  const pct = account?.usageRemainingPct;
  if (typeof pct === "number" && pct <= USAGE_REMAINING_FLOOR_PCT) return null;
  return reset;
}

/**
 * Compare two seats of equal priority by reset time. Returns 0 when neither
 * has usable data or the resets are equal, so the caller's tiebreak applies.
 * @param {object} a @param {object} b @param {number} [now]
 */
export function compareByReset(a, b, now = Date.now()) {
  const ra = usableResetAt(a, now);
  const rb = usableResetAt(b, now);
  if (ra === null && rb === null) return 0;
  if (ra === null) return 1;
  if (rb === null) return -1;
  return ra - rb;
}

/**
 * Build a patch from a Claude CLI `rate_limit_info` object. Returns null when
 * the event carries nothing usable. Never includes tokens or headers.
 * @param {object} info
 * @param {number} [now]
 */
export function usagePatchFromRateLimitInfo(info, now = Date.now()) {
  if (!info || typeof info !== "object") return null;
  const resetAt = toMs(info.resetsAt);
  if (!resetAt || resetAt <= now) return null;
  let remaining = null;
  if (info.status === "rejected") {
    remaining = 0;
  } else if (typeof info.utilization === "number" && info.utilization >= 0) {
    // Fraction (0-1) from the CLI; tolerate percentages above 1.
    const used = info.utilization <= 1 ? info.utilization * 100 : info.utilization;
    remaining = Math.max(0, Math.min(100, Math.round(100 - used)));
  }
  return {
    usageResetAt: resetAt,
    usageRemainingPct: remaining,
    usageWindow: typeof info.rateLimitType === "string" ? info.rateLimitType : null,
    usageObservedAt: now,
  };
}

/**
 * Decide whether a new observation should replace the stored one. Weekly
 * windows win over shorter ones; otherwise the newer observation wins.
 * @param {object} account @param {object} patch @param {number} [now]
 */
export function shouldReplaceUsage(account, patch, now = Date.now()) {
  if (!patch) return false;
  const existingReset = toMs(account?.usageResetAt);
  if (!existingReset || existingReset <= now) return true;
  const rank = (w) => WINDOW_RANK[w] ?? 2;
  const er = rank(account?.usageWindow);
  const nr = rank(patch.usageWindow);
  if (nr !== er) return nr < er;
  return toMs(patch.usageObservedAt) >= toMs(account?.usageObservedAt);
}

/** Unchanged observations newer than this are not rewritten (limits pool-lock churn). */
export const USAGE_REWRITE_INTERVAL_MS = 10 * 60 * 1000;

const UNIFIED_HEADER_PREFIX = "anthropic-ratelimit-unified-";

/** Header-name window segments, weekly first, mapped to `rateLimitType` names. */
const HEADER_WINDOWS = [["7d", "seven_day"], ["5h", "five_hour"]];

function headerNumber(headers, name) {
  const raw = headers.get(UNIFIED_HEADER_PREFIX + name);
  if (raw === null || raw === "") return undefined;
  const n = Number(raw);
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Build a `rate_limit_info`-shaped object from Anthropic response headers
 * (t19127). Names verified against the installed Claude CLI and a live OAuth
 * response: `anthropic-ratelimit-unified-{7d,5h}-{reset,utilization,status}`
 * (reset in epoch seconds, utilization a 0-1 fraction), with the aggregate
 * `anthropic-ratelimit-unified-{reset,status,representative-claim}` fallback.
 * Reads only those headers. Returns null when none are present.
 * @param {Headers|undefined|null} headers
 */
export function rateLimitInfoFromHeaders(headers) {
  if (!headers || typeof headers.get !== "function") return null;
  for (const [segment, window] of HEADER_WINDOWS) {
    const resetsAt = headerNumber(headers, `${segment}-reset`);
    if (resetsAt === undefined) continue;
    return {
      status: headers.get(`${UNIFIED_HEADER_PREFIX}${segment}-status`) || undefined,
      resetsAt,
      rateLimitType: window,
      utilization: headerNumber(headers, `${segment}-utilization`),
    };
  }
  const resetsAt = headerNumber(headers, "reset");
  if (resetsAt === undefined) return null;
  return {
    status: headers.get(`${UNIFIED_HEADER_PREFIX}status`) || undefined,
    resetsAt,
    rateLimitType: headers.get(`${UNIFIED_HEADER_PREFIX}representative-claim`) || undefined,
  };
}

/**
 * Return the usage patch to persist for a seat from response headers, or null
 * when there is nothing new: no headers, an observation that should not
 * replace the stored one, or an unchanged reading written recently.
 * @param {object} account - stored pool entry
 * @param {Headers|undefined|null} headers
 * @param {number} [now]
 */
export function usageUpdateFromHeaders(account, headers, now = Date.now()) {
  const patch = usagePatchFromRateLimitInfo(rateLimitInfoFromHeaders(headers), now);
  if (!patch || !shouldReplaceUsage(account, patch, now)) return null;
  const unchanged = toMs(account?.usageResetAt) === patch.usageResetAt &&
    account?.usageRemainingPct === patch.usageRemainingPct &&
    account?.usageWindow === patch.usageWindow;
  if (unchanged && now - toMs(account?.usageObservedAt) < USAGE_REWRITE_INTERVAL_MS) return null;
  return patch;
}

/** Human-readable usage summary for `model-accounts-pool list`. */
export function describeUsage(account, now = Date.now()) {
  const reset = toMs(account?.usageResetAt);
  if (!reset || reset <= now) return "unknown";
  const hours = Math.round((reset - now) / 3600000);
  const when = hours >= 48 ? `${Math.round(hours / 24)}d` : `${hours}h`;
  const pct = typeof account?.usageRemainingPct === "number" ? `${account.usageRemainingPct}% left` : "remaining unknown";
  return `resets in ${when} (${new Date(reset).toISOString()}), ${pct}`;
}
