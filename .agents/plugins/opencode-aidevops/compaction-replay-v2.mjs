// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Verbatim user-input replay after compaction — OpenCode 2 adapter (GH#35189)
//
// OpenCode 2.0.3 local compaction replaces everything before the checkpoint
// with one `<conversation-checkpoint>` user message (summary plus a serialized
// recent tail, attachments only as "[Attached …]" markers). The plugin API
// cannot list earlier session messages, so this adapter records each user
// prompt durably from the `session.prompt` hook, captures the host-normalized
// image/PDF parts from the `session.context` hook, and prepends every hidden
// turn to the checkpoint message. Budget and replay text are shared with the
// OpenCode 1 implementation (compaction-replay-budget.mjs); the store lives in
// compaction-replay-v2-store.mjs.
//
// Provider-native checkpoints are untouched: OpenCode 2 already keeps recent
// whole user messages for those (compaction.ts retainUsers()).
// ---------------------------------------------------------------------------

import { buildReplayParts, PIN_METADATA_KEY, selectWithinBudget } from "./compaction-replay-budget.mjs";
import { resolveReplayLimits } from "./compaction-pinned-input.mjs";
import {
  messageMedia,
  promptEntry,
  pruneMedia,
  pruneStores,
  readStore,
  writeStore,
} from "./compaction-replay-v2-store.mjs";
import { initialMediaShape, observeMediaShape, toV2Part } from "./compaction-replay-v2-media.mjs";
import { quotedIDs } from "./compaction-replay-v2-quotes.mjs";

export const CHECKPOINT_PREFIX = "<conversation-checkpoint>";
const MAX_CACHED_SESSIONS = 32;

const contentParts = (message) => (Array.isArray(message?.content) ? message.content : []);
const isCheckpointText = (text) => typeof text === "string" && text.trimStart().startsWith(CHECKPOINT_PREFIX);
const errorText = (error) => String(error?.message ?? error).slice(0, 200);

function boundedSet(map, key, value) {
  map.set(key, value);
  while (map.size > MAX_CACHED_SESSIONS) map.delete(map.keys().next().value);
}

/**
 * Plain text of a V2 LLM message whose content is a string or a part list.
 * @param {object} message
 * @returns {string}
 */
export function messageText(message) {
  if (typeof message?.content === "string") return message.content;
  return contentParts(message).filter((part) => part?.type === "text").map((part) => String(part.text || "")).join("\n");
}

/**
 * Index of the local compaction checkpoint message, or -1.
 * @param {Array<object>} messages
 * @returns {number}
 */
export function findCheckpointIndex(messages) {
  if (!Array.isArray(messages)) return -1;
  return messages.findIndex((message) => message?.role === "user" && (isCheckpointText(message.content)
    || contentParts(message).some((part) => part?.type === "text" && isCheckpointText(part.text))));
}

/**
 * Hidden replay entries for this request: recorded prompts no longer in the
 * request. Text-only turns already quoted verbatim in the checkpoint's
 * recent tail are skipped.
 */
function hiddenEntries(store, messages, checkpointText) {
  const visible = new Set(messages.map((message) => message?.id).filter(Boolean));
  const candidates = store.prompts.filter((entry) => !visible.has(entry.id));
  const quoted = quotedIDs(candidates, checkpointText);
  return candidates.filter((entry) => !quoted.has(entry.id)).map((entry) => ({
    id: entry.id,
    created: entry.created,
    text: entry.text,
    notes: [...entry.notes, ...(entry.mediaCaptured ? [] : entry.inlineNotes || [])],
    media: [...entry.media],
  }));
}

function sessionStore(state, sessionID) {
  const cached = state.stores.get(sessionID);
  if (cached) return cached;
  const store = readStore(state.storeDir, sessionID);
  boundedSet(state.stores, sessionID, store);
  return store;
}

function log(state, level, message) {
  try {
    state.qualityLog?.(level, `[compaction-replay-v2] ${message}`);
  } catch {
    // Logging must never break the host hook.
  }
}

function persist(state, store) {
  state.revision++;
  try {
    writeStore(state.storeDir, store);
  } catch (error) {
    log(state, "WARN", `store write failed: ${errorText(error)}`);
  }
}

/** Record host-normalized media for recorded prompts still visible in context. */
function captureMedia(state, store, messages, maxMedia) {
  const byID = new Map(store.prompts.map((entry) => [entry.id, entry]));
  const fresh = messages
    .map((message) => (message?.role === "user" ? [message, byID.get(message.id)] : []))
    .filter(([, entry]) => entry && !entry.mediaCaptured);
  for (const [message, entry] of fresh) {
    entry.media = messageMedia(message);
    entry.mediaCaptured = true;
  }
  if (fresh.length === 0) return;
  pruneMedia(store.prompts, maxMedia);
  persist(state, store);
}

/** Track the host's media part shape; a change invalidates cached parts. */
function updateMediaShape(state, messages) {
  const next = observeMediaShape(state.media, messages);
  if (next.shape === state.media.shape && next.Asset === state.media.Asset) return;
  state.media = next;
  state.revision++;
}

function replayParts(state, store, request, limits) {
  const { sessionID, messages, index } = request;
  const checkpoint = messages[index];
  const anchorID = checkpoint.id || "checkpoint";
  const key = `${anchorID}:${state.revision}`;
  const cached = state.cache.get(sessionID);
  if (cached?.key === key) return cached.parts;
  const entries = hiddenEntries(store, messages, messageText(checkpoint));
  const selection = selectWithinBudget(entries, limits.maxTextChars, limits.minExcerptChars);
  const built = selection.selected.length > 0
    ? buildReplayParts(selection, { sessionID, anchorID, overflow: false, maxMedia: limits.maxMedia })
    : { parts: [], messages: 0, media: 0 };
  const parts = built.parts.map((part) => toV2Part(part, state.media));
  boundedSet(state.cache, sessionID, { key, parts });
  log(state, "INFO", `prepared ${built.messages} user turn(s), ${built.media} attachment(s), ${selection.excerpted} excerpted, ${selection.omitted} elided`);
  return parts;
}

const alreadyInjected = (message) => contentParts(message).some((part) => part?.metadata?.[PIN_METADATA_KEY]);

/** Validate the request; returns either a skip reason or the session context. */
function injectionTarget(state, event, limits) {
  const sessionID = String(event?.sessionID || "");
  const messages = Array.isArray(event?.messages) ? event.messages : null;
  if (!limits.enabled || !sessionID || !messages) return { reason: limits.enabled ? "no_session" : "disabled" };
  const store = sessionStore(state, sessionID);
  captureMedia(state, store, messages, limits.maxMedia);
  updateMediaShape(state, messages);
  const index = findCheckpointIndex(messages);
  let reason = "";
  if (index < 0) reason = "no_compaction";
  else if (alreadyInjected(messages[index])) reason = "already_injected";
  return reason ? { reason } : { target: { sessionID, messages, index, store } };
}

/**
 * Prepend replay parts to the checkpoint message. Mutates event.messages.
 * @returns {{ injected: boolean, parts?: number, reason?: string }}
 */
function injectReplay(state, event) {
  const limits = resolveReplayLimits(state.limits);
  const { target, reason } = injectionTarget(state, event, limits);
  if (!target) return { injected: false, reason };
  const parts = replayParts(state, target.store, target, limits);
  if (parts.length > 0) {
    const checkpoint = target.messages[target.index];
    const original = typeof checkpoint.content === "string" ? [{ type: "text", text: checkpoint.content }] : contentParts(checkpoint);
    target.messages[target.index] = { ...checkpoint, content: [...parts, ...original] };
  }
  return parts.length > 0 ? { injected: true, parts: parts.length } : { injected: false, reason: "nothing_hidden" };
}

function recordPrompt(state, event) {
  const limits = resolveReplayLimits(state.limits);
  const sessionID = String(event?.sessionID || "");
  const entry = limits.enabled && sessionID ? promptEntry(event) : null;
  const store = entry ? sessionStore(state, sessionID) : null;
  if (!entry || store.prompts.some((existing) => existing.id === entry.id)) return { recorded: false };
  store.prompts.push(entry);
  persist(state, store);
  return { recorded: true };
}

/**
 * Create the OpenCode 2 replay adapter. Both entry points fail open.
 * @param {{ storeDir: string, hostVersion?: string, qualityLog?: Function, limits?: object }} options
 * @returns {{ recordPrompt: Function, inject: Function }}
 */
export function createV2CompactionReplay(options) {
  const state = {
    storeDir: options.storeDir,
    qualityLog: options.qualityLog,
    limits: options.limits,
    media: initialMediaShape(options.hostVersion),
    stores: new Map(),
    cache: new Map(),
    revision: 0,
  };
  pruneStores(state.storeDir);
  const guarded = (label, fn, fallback) => (event) => {
    try {
      return fn(state, event);
    } catch (error) {
      log(state, "WARN", `${label} skipped: ${errorText(error)}`);
      return fallback;
    }
  };
  return {
    recordPrompt: guarded("record", recordPrompt, { recorded: false }),
    inject: guarded("inject", injectReplay, { injected: false, reason: "error" }),
  };
}
