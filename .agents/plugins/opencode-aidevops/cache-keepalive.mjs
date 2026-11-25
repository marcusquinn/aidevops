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

/** Every check a body must pass before a refresh can reuse its cache prefix. */
const REFRESHABLE_CHECKS = [
  (parsed) => nonEmptyArray(parsed.tools),
  (parsed) => nonEmptyArray(parsed.messages),
  (parsed) => parsed.stream === true,
  (parsed) => parsed.thinking?.type !== "enabled",
];

/** Streamed, tool-bearing agent request without a fixed thinking budget. */
function isRefreshableAgentRequest(parsed) {
  if (!parsed) return false;
  return REFRESHABLE_CHECKS.every((check) => check(parsed));
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
  return new CacheKeepalive(resolveSettings(options));
}

function isSuccessStatus(status) {
  return status >= 200 && status < 300;
}

function toolKey(callID) {
  return String(callID ?? "tool");
}

/** Per-session keep-warm scheduler. Every public method fails open. */
class CacheKeepalive {
  constructor(settings) {
    this.settings = settings;
    /** @type {Map<string, { request: object, body: string, tools: Set<string>, refreshes: number, timer: any }>} */
    this.sessions = new Map();
  }

  stop(sessionID) {
    const entry = this.sessions.get(sessionID);
    if (entry?.timer) this.settings.clearTimer?.(entry.timer);
    this.sessions.delete(sessionID);
  }

  /** Release this host instance's timers without changing other instances. */
  dispose() {
    for (const sessionID of this.sessions.keys()) this.stop(sessionID);
  }

  arm(sessionID, entry) {
    entry.timer = this.settings.setTimer(() => {
      entry.timer = null;
      void this.refresh(sessionID, entry);
    }, this.settings.intervalMs);
    entry.timer?.unref?.();
  }

  isCurrent(sessionID, entry) {
    return this.sessions.get(sessionID) === entry;
  }

  shouldRefresh(entry) {
    if (!this.settings.enabled()) return false;
    return entry.tools.size > 0 && entry.refreshes < this.settings.maxRefreshes;
  }

  async refresh(sessionID, entry) {
    if (!this.isCurrent(sessionID, entry)) return;
    if (!this.shouldRefresh(entry)) {
      this.stop(sessionID);
      return;
    }
    entry.refreshes += 1;
    const ok = await sendRefresh(this.settings, sessionID, entry);
    if (!ok) {
      this.stop(sessionID);
      return;
    }
    if (this.isCurrent(sessionID, entry)) this.arm(sessionID, entry);
  }

  entryFor(sessionID) {
    return sessionID ? this.sessions.get(sessionID) : null;
  }

  evictOverflow() {
    while (this.sessions.size > this.settings.maxSessions) {
      this.stop(this.sessions.keys().next().value);
    }
  }

  bodyFor(rawBody, status) {
    if (!isSuccessStatus(status) || !this.settings.enabled()) return null;
    return buildKeepaliveBody(rawBody);
  }

  /**
   * Record a completed agent request. Replaces any earlier gap state: a new
   * LLM request means the previous step's tools have finished.
   * @param {string|undefined} sessionID
   * @param {object} request opaque send() context (url, init, headers)
   * @param {string} rawBody host body before plugin transforms
   * @param {number} status response status
   */
  recordRequest(sessionID, request, rawBody, status) {
    if (!sessionID) return;
    try {
      this.stop(sessionID);
      const body = this.bodyFor(rawBody, status);
      if (!body) return;
      const entry = { request, body, tools: new Set(), refreshes: 0, timer: null };
      this.sessions.set(sessionID, entry);
      this.evictOverflow();
      this.arm(sessionID, entry);
    } catch {
      // fail open
    }
  }

  toolStarted(sessionID, callID) {
    this.entryFor(sessionID)?.tools.add(toolKey(callID));
  }

  toolFinished(sessionID, callID) {
    this.entryFor(sessionID)?.tools.delete(toolKey(callID));
  }

  /** Test/diagnostic view. */
  state(sessionID) {
    const entry = this.sessions.get(sessionID);
    if (!entry) return null;
    return { tools: entry.tools.size, refreshes: entry.refreshes, armed: Boolean(entry.timer) };
  }
}
