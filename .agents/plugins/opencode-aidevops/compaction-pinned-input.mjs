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
// recent inline images, in front of the compaction anchor message. Collection:
// compaction-replay-collect.mjs. Budget and part building:
// compaction-replay-budget.mjs. Media token estimates, the context-window cap
// and the compaction-loop backstop (GH#39958): compaction-replay-sizing.mjs.
// ---------------------------------------------------------------------------

import { collectHiddenUserInput, findCompactionAnchor } from "./compaction-replay-collect.mjs";
import {
  buildReplayParts,
  DEFAULT_MIN_EXCERPT_CHARS,
  droppedMediaReason,
  PIN_METADATA_KEY,
  planReplay,
  selectWithinBudget,
} from "./compaction-replay-budget.mjs";
import { DEFAULT_MAX_MEDIA_TOKENS, postCompactionPressure, replayWindowTokens } from "./compaction-replay-sizing.mjs";

export { collectHiddenUserInput, findCompactionAnchor, buildReplayParts, selectWithinBudget };

const DEFAULT_MAX_TEXT_CHARS = 64_000;
const DEFAULT_MAX_MEDIA = 4;
const DEFAULT_MAX_CONTEXT_PERCENT = 15;
// Drop replayed media when the request after the previous compaction already
// used this share of the window (compaction-loop backstop).
const DEFAULT_PRESSURE_PERCENT = 80;
const DEFAULT_FETCH_TIMEOUT_MS = 10_000;
const MAX_CACHED_SESSIONS = 32;
// Hidden helper agents run on other models; their windows are not the session's.
const AUXILIARY_AGENTS = new Set(["compaction", "title", "summary"]);
const ENABLED_VALUES = ["1", "true", "on"];

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
 * Resolve replay limits. Env overrides keep the feature tunable without code;
 * they are read per request, so a running process picks up changes.
 * @param {object} [overrides]
 * @returns {{ enabled: boolean, maxTextChars: number, minExcerptChars: number, maxMedia: number,
 *   maxMediaTokens: number, maxContextPercent: number, pressurePercent: number, replayPdfs: boolean,
 *   fetchTimeoutMs: number }}
 */
export function resolveReplayLimits(overrides = {}) {
  const disabled = ["0", "false", "off"].includes(String(process.env.AIDEVOPS_COMPACTION_REPLAY || "").toLowerCase());
  return {
    enabled: !disabled,
    maxTextChars: envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_CHARS", DEFAULT_MAX_TEXT_CHARS),
    minExcerptChars: DEFAULT_MIN_EXCERPT_CHARS,
    maxMedia: envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_IMAGES", DEFAULT_MAX_MEDIA),
    maxMediaTokens: envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_MEDIA_TOKENS", DEFAULT_MAX_MEDIA_TOKENS),
    // 0 would cap replayed text at nothing and drop every hidden user turn.
    maxContextPercent: Math.min(100, envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_CONTEXT_PERCENT", DEFAULT_MAX_CONTEXT_PERCENT) || DEFAULT_MAX_CONTEXT_PERCENT),
    pressurePercent: DEFAULT_PRESSURE_PERCENT,
    replayPdfs: ENABLED_VALUES.includes(String(process.env.AIDEVOPS_COMPACTION_REPLAY_PDFS || "").toLowerCase()),
    fetchTimeoutMs: DEFAULT_FETCH_TIMEOUT_MS,
    ...overrides,
  };
}

function boundedSet(map, key, value) {
  map.delete(key);
  map.set(key, value);
  while (map.size > MAX_CACHED_SESSIONS) map.delete(map.keys().next().value);
}

/**
 * Remember the session model's input window from chat.params, after the
 * context budget has applied its cap.
 * @param {{ windows: Map<string, number> }} state
 * @param {object} input - chat.params input
 */
function rememberWindow(state, input) {
  const agent = typeof input?.agent === "string" ? input.agent : input?.agent?.name;
  const sessionID = String(input?.sessionID || "");
  const windowTokens = replayWindowTokens(input?.model?.limit);
  if (sessionID && windowTokens > 0 && !AUXILIARY_AGENTS.has(agent)) boundedSet(state.windows, sessionID, windowTokens);
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
 * Loop backstop: withhold media when the request after the previous
 * compaction already used `pressurePercent` of the window.
 * @returns {string} label reason, or "" to replay media normally
 */
function droppedMedia(state, history, request, limits, windowTokens) {
  const percent = postCompactionPressure(history, request.anchor.summaryID, windowTokens);
  if (percent === null || percent < limits.pressurePercent) return "";
  state.qualityLog?.("INFO", `[compaction-replay] media dropped: post-compaction context ${percent}%`);
  return droppedMediaReason(percent);
}

/**
 * Compute replay parts for one compaction from the stored history.
 * @returns {Promise<{ parts: Array<object>, summary: string }>}
 */
async function prepareReplay(state, request, limits, windowTokens) {
  const { sessionID, anchor, messages } = request;
  const history = await fetchHistory(state.client, sessionID, limits.fetchTimeoutMs);
  const visible = new Set(messages.map((msg) => msg?.info?.id).filter(Boolean));
  const { selection, maxMediaTokens, totalTokens } = planReplay(collectHiddenUserInput(history, visible), limits, windowTokens);
  if (selection.selected.length === 0) return { parts: [], summary: "no hidden user turns" };
  const built = buildReplayParts(selection, {
    sessionID,
    anchorID: anchor.anchorID,
    overflow: anchor.overflow,
    maxMedia: limits.maxMedia,
    maxMediaTokens,
    replayPdfs: limits.replayPdfs,
    dropped: droppedMedia(state, history, request, limits, windowTokens),
  });
  const cap = totalTokens === null ? "no context cap (window unknown)" : `context cap ${totalTokens} tokens`;
  return {
    parts: built.parts,
    summary: `${built.messages} user turn(s), ${built.media} attachment(s), ${selection.excerpted} excerpted, ${selection.omitted} elided, ~${built.mediaTokens} media tokens, ${cap}`,
  };
}

/**
 * Cached per compaction and window: history is fetched once and the prompt
 * prefix stays byte-stable across turns (prompt caching). After a restart the
 * first transform runs before chat.params reports the window, so the replay is
 * rebuilt once under the context cap when the window becomes known.
 */
function partsFor(state, request, limits) {
  const { sessionID, anchor } = request;
  const windowTokens = state.windows.get(sessionID) || 0;
  const cached = state.cache.get(sessionID);
  if (cached?.summaryID === anchor.summaryID && cached.windowTokens === windowTokens) return Promise.resolve(cached.parts);
  const key = `${sessionID}:${anchor.summaryID}:${windowTokens}`;
  if (!state.inflight.has(key)) {
    const pending = prepareReplay(state, request, limits, windowTokens).then(({ parts, summary }) => {
      boundedSet(state.cache, sessionID, { summaryID: anchor.summaryID, windowTokens, parts });
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
 * Create the replay hook for experimental.chat.messages.transform. Call
 * `chatParams` from chat.params so the replay knows each session's window.
 * @param {object} client - OpenCode SDK client
 * @param {{ qualityLog?: Function, limits?: object }} [options]
 * @returns {{ inject: Function, chatParams: Function }}
 */
export function createCompactionInputReplay(client, options = {}) {
  const state = {
    client,
    qualityLog: options.qualityLog,
    limits: options.limits,
    cache: new Map(),
    inflight: new Map(),
    windows: new Map(),
  };
  return {
    inject: (_input, output) => injectReplay(state, output),
    chatParams: (input) => {
      try {
        rememberWindow(state, input);
      } catch {
        // Fail open: without a window the configured caps still apply.
      }
    },
  };
}
