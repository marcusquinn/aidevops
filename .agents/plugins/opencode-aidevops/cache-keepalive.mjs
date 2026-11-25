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
  const parsed = parseJsonObject(rawBody);
  if (!isRefreshableAgentRequest(parsed)) return null;
  parsed.max_tokens = 1;
  parsed.stream = false;
  return JSON.stringify(parsed);
}

function parseJsonObject(rawBody) {
  if (typeof rawBody !== "string" || rawBody.length === 0) return null;
  try {
    return JSON.parse(rawBody);
  } catch {
    return null;
  }
}

function nonEmptyArray(value) {
  return Array.isArray(value) && value.length > 0;
}

/** Streamed, tool-bearing agent request without a fixed thinking budget. */
function isRefreshableAgentRequest(parsed) {
  return Boolean(parsed)
    && nonEmptyArray(parsed.tools)
    && nonEmptyArray(parsed.messages)
    && parsed.stream === true
    && parsed.thinking?.type !== "enabled";
}

/**
 * Resolve scheduler settings. globalThis lookups keep module creation safe in
 * isolated VM contexts (oauth-pool-rotation-probe.mjs) without timers/process.
 */
function resolveSettings(options) {
  const env = globalThis.process?.env ?? {};
  const setTimer = options.setTimer ?? globalThis.setTimeout;
  return {
    send: options.send,
    setTimer,
    clearTimer: options.clearTimer ?? globalThis.clearTimeout,
    enabled: options.enabled ?? (() => env.AIDEVOPS_CACHE_KEEPALIVE !== "0" && typeof setTimer === "function"),
    log: options.log ?? ((line) => globalThis.console?.error(line)),
    intervalMs: options.intervalMs ?? positiveInt(env.AIDEVOPS_CACHE_KEEPALIVE_INTERVAL_MS, DEFAULT_INTERVAL_MS),
    maxRefreshes: options.maxRefreshes ?? positiveInt(env.AIDEVOPS_CACHE_KEEPALIVE_MAX_REFRESHES, DEFAULT_MAX_REFRESHES),
    maxSessions: options.maxSessions ?? DEFAULT_MAX_SESSIONS,
  };
}

async function readUsage(response) {
  try {
    return (await response.json())?.usage ?? null;
  } catch {
    return null; // Usage is diagnostics only.
  }
}

/**
 * Send one refresh. Returns true when keep-warm may continue for this gap.
 */
async function sendRefresh(settings, sessionID, entry) {
  try {
    const response = await settings.send(entry.request, entry.body);
    const usage = await readUsage(response);
    settings.log(`[aidevops] cache-keepalive: session=${sessionID} refresh=${entry.refreshes}/${settings.maxRefreshes} status=${response.status} cache_read=${usage?.cache_read_input_tokens ?? "?"} cache_write=${usage?.cache_creation_input_tokens ?? "?"} running_tools=${entry.tools.size}`);
    return response.ok;
  } catch (err) {
    settings.log(`[aidevops] cache-keepalive: session=${sessionID} refresh failed: ${err?.message ?? err}`);
    return false;
  }
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
  const settings = resolveSettings(options);
  /** @type {Map<string, { request: object, body: string, tools: Set<string>, refreshes: number, timer: any }>} */
  const sessions = new Map();

  function stop(sessionID) {
    const entry = sessions.get(sessionID);
    if (entry?.timer) settings.clearTimer?.(entry.timer);
    sessions.delete(sessionID);
  }

  function arm(sessionID, entry) {
    entry.timer = settings.setTimer(() => {
      entry.timer = null;
      void refresh(sessionID, entry);
    }, settings.intervalMs);
    entry.timer?.unref?.();
  }

  function shouldRefresh(entry) {
    return settings.enabled() && entry.tools.size > 0 && entry.refreshes < settings.maxRefreshes;
  }

  async function refresh(sessionID, entry) {
    if (sessions.get(sessionID) !== entry) return;
    if (!shouldRefresh(entry)) {
      stop(sessionID);
      return;
    }
    entry.refreshes += 1;
    const ok = await sendRefresh(settings, sessionID, entry);
    if (!ok) stop(sessionID);
    else if (sessions.get(sessionID) === entry) arm(sessionID, entry);
  }

  function entryFor(sessionID) {
    return sessionID ? sessions.get(sessionID) : null;
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
        const ok = status >= 200 && status < 300 && settings.enabled();
        const body = ok ? buildKeepaliveBody(rawBody) : null;
        if (!body) return;
        const entry = { request, body, tools: new Set(), refreshes: 0, timer: null };
        sessions.set(sessionID, entry);
        while (sessions.size > settings.maxSessions) stop(sessions.keys().next().value);
        arm(sessionID, entry);
      } catch {
        // fail open
      }
    },
    toolStarted(sessionID, callID) {
      entryFor(sessionID)?.tools.add(String(callID ?? "tool"));
    },
    toolFinished(sessionID, callID) {
      entryFor(sessionID)?.tools.delete(String(callID ?? "tool"));
    },
    /** Test/diagnostic view. */
    state(sessionID) {
      const entry = sessions.get(sessionID);
      return entry ? { tools: entry.tools.size, refreshes: entry.refreshes, armed: Boolean(entry.timer) } : null;
    },
  };
}
