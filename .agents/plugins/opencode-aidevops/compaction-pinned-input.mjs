// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Verbatim user-input replay after compaction (GH#35186)
//
// OpenCode 1.x compaction loses three kinds of user input:
// - images: compaction.ts serialize() gives the summarizer only an
//   "[Attached image/png: …]" marker, and filterCompacted() stops sending the
//   original user messages once a summary exists;
// - turn aims: each user turn survives only as the summarizer's paraphrase,
//   re-summarized on every compaction. A small retained tail rarely helps,
//   because splitTurn() keeps a large turn only from turn.start + 1 and so
//   drops that turn's user message;
// - authorisations and standing instructions: same paraphrase, in assistant
//   voice, which aidevops rules rightly do not treat as authority.
//
// The session store still holds the original user messages. This hook reads
// them once per compaction and puts every hidden user turn, in full, with its
// recent inline media, in front of the compaction anchor message. Collection:
// compaction-replay-collect.mjs. Budget and part building:
// compaction-replay-budget.mjs.
// ---------------------------------------------------------------------------

import { collectHiddenUserInput, findCompactionAnchor } from "./compaction-replay-collect.mjs";
import {
  buildReplayParts,
  DEFAULT_MIN_EXCERPT_CHARS,
  PIN_METADATA_KEY,
  selectWithinBudget,
} from "./compaction-replay-budget.mjs";

export { collectHiddenUserInput, findCompactionAnchor, buildReplayParts, selectWithinBudget };

const DEFAULT_MAX_TEXT_CHARS = 64_000;
const DEFAULT_MAX_MEDIA = 4;
const DEFAULT_FETCH_TIMEOUT_MS = 10_000;
const MAX_CACHED_SESSIONS = 32;

/**
 * Read a non-negative integer from the environment.
 * @param {string} name
 * @param {number} fallback
 * @returns {number}
 */
function envInt(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

/**
 * Resolve replay limits. Env overrides keep the feature tunable without code.
 * @param {object} [overrides]
 * @returns {{ enabled: boolean, maxTextChars: number, minExcerptChars: number, maxMedia: number, fetchTimeoutMs: number }}
 */
export function resolveReplayLimits(overrides = {}) {
  const disabled = ["0", "false", "off"].includes(String(process.env.AIDEVOPS_COMPACTION_REPLAY || "").toLowerCase());
  return {
    enabled: !disabled,
    maxTextChars: envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_CHARS", DEFAULT_MAX_TEXT_CHARS),
    minExcerptChars: DEFAULT_MIN_EXCERPT_CHARS,
    maxMedia: envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_IMAGES", DEFAULT_MAX_MEDIA),
    fetchTimeoutMs: DEFAULT_FETCH_TIMEOUT_MS,
    ...overrides,
  };
}

async function fetchHistory(client, sessionID, timeoutMs) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`session history fetch exceeded ${timeoutMs}ms`)), timeoutMs);
  });
  try {
    const response = await Promise.race([client.session.messages({ path: { id: sessionID } }), timeout]);
    const history = response?.data ?? response;
    if (!Array.isArray(history)) throw new Error("session history response was not an array");
    return history;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Compute replay parts for one compaction from the stored history.
 * @returns {Promise<{ parts: Array<object>, summary: string }>}
 */
async function prepareReplay(client, request, limits) {
  const { sessionID, anchor, messages } = request;
  const history = await fetchHistory(client, sessionID, limits.fetchTimeoutMs);
  const visible = new Set(messages.map((msg) => msg?.info?.id).filter(Boolean));
  const selection = selectWithinBudget(collectHiddenUserInput(history, visible), limits.maxTextChars, limits.minExcerptChars);
  if (selection.selected.length === 0) return { parts: [], summary: "no hidden user turns" };
  const built = buildReplayParts(selection, { sessionID, anchorID: anchor.anchorID, overflow: anchor.overflow, maxMedia: limits.maxMedia });
  return {
    parts: built.parts,
    summary: `${built.messages} user turn(s), ${built.media} attachment(s), ${selection.excerpted} excerpted, ${selection.omitted} elided`,
  };
}

/**
 * Cached per compaction: history is fetched once and the prompt prefix stays
 * byte-stable across turns (prompt caching).
 */
function partsFor(state, request, limits) {
  const { sessionID, anchor } = request;
  const cached = state.cache.get(sessionID);
  if (cached?.summaryID === anchor.summaryID) return Promise.resolve(cached.parts);
  const key = `${sessionID}:${anchor.summaryID}`;
  if (!state.inflight.has(key)) {
    const pending = prepareReplay(state.client, request, limits).then(({ parts, summary }) => {
      state.cache.set(sessionID, { summaryID: anchor.summaryID, parts });
      while (state.cache.size > MAX_CACHED_SESSIONS) state.cache.delete(state.cache.keys().next().value);
      state.qualityLog?.("INFO", `[compaction-replay] prepared ${summary}`);
      return parts;
    });
    state.inflight.set(key, pending.finally(() => state.inflight.delete(key)));
  }
  return state.inflight.get(key);
}

/**
 * Decide whether this request needs a replay; returns the request or a skip reason.
 * @returns {{ request?: object, reason?: string }}
 */
function replayRequest(state, output, limits) {
  if (!limits.enabled) return { reason: "disabled" };
  const messages = output?.messages;
  const anchor = findCompactionAnchor(messages);
  const anchorMessage = anchor ? messages[anchor.anchorIndex] : null;
  const sessionID = String(anchorMessage?.info?.sessionID || "");
  let reason = "";
  if (!anchorMessage) reason = "no_compaction";
  else if (anchorMessage.parts.some((part) => part?.metadata?.[PIN_METADATA_KEY])) reason = "already_injected";
  else if (!sessionID || !state.client?.session?.messages) reason = "no_session";
  return reason ? { reason } : { request: { sessionID, anchor, messages, anchorMessage } };
}

/**
 * Fail-open: any error leaves the request unchanged.
 * @returns {Promise<{ injected: boolean, parts?: number, reason?: string }>}
 */
async function injectReplay(state, output) {
  const limits = resolveReplayLimits(state.limits);
  const { request, reason } = replayRequest(state, output, limits);
  if (!request) return { injected: false, reason };
  try {
    const parts = await partsFor(state, request, limits);
    if (parts.length > 0) {
      const { anchor, anchorMessage, messages } = request;
      messages[anchor.anchorIndex] = { ...anchorMessage, parts: [...parts, ...anchorMessage.parts] };
    }
    return parts.length > 0 ? { injected: true, parts: parts.length } : { injected: false, reason: "nothing_hidden" };
  } catch (error) {
    state.qualityLog?.("WARN", `[compaction-replay] skipped: ${String(error?.message ?? error).slice(0, 200)}`);
    return { injected: false, reason: "error" };
  }
}

/**
 * Create the replay hook for experimental.chat.messages.transform.
 * @param {object} client - OpenCode SDK client
 * @param {{ qualityLog?: Function, limits?: object }} [options]
 */
export function createCompactionInputReplay(client, options = {}) {
  const state = {
    client,
    qualityLog: options.qualityLog,
    limits: options.limits,
    cache: new Map(),
    inflight: new Map(),
  };
  return { inject: (_input, output) => injectReplay(state, output) };
}
