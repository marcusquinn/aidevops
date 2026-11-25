// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/**
 * Prompt-cache keep-warm while a tool call runs (t19356 / GH#40251).
 *
 * Anthropic's default prompt cache lives 5 minutes from its last read. A tool
 * call that runs longer (lock waits, dependency installs, merge waits,
 * subagent tasks) lets the cache expire. The next request then re-writes the
 * whole context at 1.25x input price: about 30% of one data-pipeline worker fleet's cache
 * writes in the issue evidence. Re-sending the last request with
 * `max_tokens: 1` reads the same prefix at 0.1x and resets the TTL.
 *
 * Rules:
 * - Only agent requests are recorded: streamed, with tools, HTTP 2xx.
 * - A refresh fires only while a tool call is still running for that session.
 *   A new LLM request means every tool of the previous step has finished.
 * - Refreshes per gap are capped. Past roughly 12 refreshes a rebuild would be
 *   cheaper, and most long calls end within 20 minutes.
 * - Requests with a fixed thinking budget are skipped. `max_tokens` must exceed
 *   the budget, and changing the budget would itself invalidate the message
 *   cache.
 * - Fail-open: any error stops keep-warm for that gap. It never affects the
 *   real request path.
 *
 * Opt out with AIDEVOPS_CACHE_KEEPALIVE=0.
 */

const DEFAULT_INTERVAL_MS = 240_000;
const DEFAULT_MAX_REFRESHES = 5;
const DEFAULT_MAX_SESSIONS = 64;

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

/**
 * Build the refresh body from the host's original (pre-transform) body.
 * Returns null when a refresh could change the cache key or is not useful.
 * @param {string} rawBody
 * @returns {string|null}
 */
export function buildKeepaliveBody(rawBody) {
  if (typeof rawBody !== "string" || rawBody.length === 0) return null;
  let parsed;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (!Array.isArray(parsed?.tools) || parsed.tools.length === 0) return null;
  if (!Array.isArray(parsed?.messages) || parsed.messages.length === 0) return null;
  if (parsed.stream !== true) return null;
  if (parsed.thinking?.type === "enabled") return null;
  parsed.max_tokens = 1;
  parsed.stream = false;
  return JSON.stringify(parsed);
}

/**
 * @param {{
 *   send: (request: object, body: string) => Promise<Response>,
 *   setTimer?: typeof setTimeout,
 *   clearTimer?: typeof clearTimeout,
 *   enabled?: () => boolean,
 *   log?: (line: string) => void,
 *   intervalMs?: number,
 *   maxRefreshes?: number,
 *   maxSessions?: number,
 * }} options
 */
export function createCacheKeepalive(options) {
  const send = options.send;
  // globalThis lookups keep module creation safe in isolated VM contexts
  // (oauth-pool-rotation-probe.mjs) that expose no timers or process.
  const env = globalThis.process?.env ?? {};
  const setTimer = options.setTimer ?? globalThis.setTimeout;
  const clearTimer = options.clearTimer ?? globalThis.clearTimeout;
  const enabled = options.enabled ?? (() => env.AIDEVOPS_CACHE_KEEPALIVE !== "0" && typeof setTimer === "function");
  const log = options.log ?? ((line) => globalThis.console?.error(line));
  const intervalMs = options.intervalMs ?? positiveInt(env.AIDEVOPS_CACHE_KEEPALIVE_INTERVAL_MS, DEFAULT_INTERVAL_MS);
  const maxRefreshes = options.maxRefreshes ?? positiveInt(env.AIDEVOPS_CACHE_KEEPALIVE_MAX_REFRESHES, DEFAULT_MAX_REFRESHES);
  const maxSessions = options.maxSessions ?? DEFAULT_MAX_SESSIONS;
  /** @type {Map<string, { request: object, body: string, tools: Set<string>, refreshes: number, timer: any }>} */
  const sessions = new Map();

  function stop(sessionID) {
    const entry = sessions.get(sessionID);
    if (entry?.timer) clearTimer?.(entry.timer);
    sessions.delete(sessionID);
  }

  function arm(sessionID, entry) {
    entry.timer = setTimer(() => {
      entry.timer = null;
      void refresh(sessionID, entry);
    }, intervalMs);
    entry.timer?.unref?.();
  }

  async function refresh(sessionID, entry) {
    if (sessions.get(sessionID) !== entry) return;
    if (!enabled() || entry.tools.size === 0 || entry.refreshes >= maxRefreshes) {
      stop(sessionID);
      return;
    }
    entry.refreshes += 1;
    try {
      const response = await send(entry.request, entry.body);
      let usage = null;
      try {
        usage = (await response.json())?.usage ?? null;
      } catch {
        // Usage is diagnostics only.
      }
      log(`[aidevops] cache-keepalive: session=${sessionID} refresh=${entry.refreshes}/${maxRefreshes} status=${response.status} cache_read=${usage?.cache_read_input_tokens ?? "?"} cache_write=${usage?.cache_creation_input_tokens ?? "?"} running_tools=${entry.tools.size}`);
      if (!response.ok) {
        stop(sessionID);
        return;
      }
    } catch (err) {
      log(`[aidevops] cache-keepalive: session=${sessionID} refresh failed: ${err?.message ?? err}`);
      stop(sessionID);
      return;
    }
    if (sessions.get(sessionID) === entry) arm(sessionID, entry);
  }

  return {
    /**
     * Record a completed agent request. Replaces any earlier gap state: a new
     * LLM request means the previous step's tools have finished.
     * @param {string|undefined} sessionID
     * @param {object} request opaque send() context (url, init, headers)
     * @param {string} rawBody host body before plugin transforms
     * @param {number} status response status
     */
    recordRequest(sessionID, request, rawBody, status) {
      try {
        if (!sessionID) return;
        stop(sessionID);
        if (!enabled() || status < 200 || status >= 300) return;
        const body = buildKeepaliveBody(rawBody);
        if (!body) return;
        const entry = { request, body, tools: new Set(), refreshes: 0, timer: null };
        sessions.set(sessionID, entry);
        while (sessions.size > maxSessions) stop(sessions.keys().next().value);
        arm(sessionID, entry);
      } catch {
        // fail open
      }
    },
    toolStarted(sessionID, callID) {
      const entry = sessionID ? sessions.get(sessionID) : null;
      if (entry) entry.tools.add(String(callID ?? "tool"));
    },
    toolFinished(sessionID, callID) {
      const entry = sessionID ? sessions.get(sessionID) : null;
      if (entry) entry.tools.delete(String(callID ?? "tool"));
    },
    /** Test/diagnostic view. */
    state(sessionID) {
      const entry = sessions.get(sessionID);
      return entry ? { tools: entry.tools.size, refreshes: entry.refreshes, armed: Boolean(entry.timer) } : null;
    },
  };
}
