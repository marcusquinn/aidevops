// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ---------------------------------------------------------------------------
// GH#37997: stop compaction summaries that loop on repeated text (OpenCode 1).
//
// Stream: `message.part.delta` text of compaction summaries is checked at the
// tail. On a loop, interactive sessions are aborted and compaction is rerun
// (compaction-loop-recovery.mjs). Headless runs are never aborted: `opencode
// run` would exit, so the output cap ends the stream and text.complete
// collapses the loop instead.
// Model input: messages.transform drops failed summaries and repairs a
// misanchored boundary (compaction-history-repair.mjs).
// ---------------------------------------------------------------------------

import { collapseRepetitions, LOOP_DEFAULTS, repetitionAtTail } from "./compaction-loop-detect.mjs";
import { isCompactionSummary, repairCompactedHistory } from "./compaction-history-repair.mjs";
import {
  abortLoopingCompaction,
  continuationPolicy,
  RecoveryLedger,
  rerunCompaction,
  sessionHash,
} from "./compaction-loop-recovery.mjs";

const CHECK_EVERY_CHARS = 512;
const MAX_TRACKED = 64;

function capMap(map) {
  while (map.size > MAX_TRACKED) map.delete(map.keys().next().value);
}

function idleEvent(event) {
  return event.type === "session.idle"
    || (event.type === "session.status" && event.properties?.status?.type === "idle");
}

function eventSessionID(event) {
  const props = event.properties || {};
  return String(props.sessionID || props.info?.sessionID || props.part?.sessionID || "");
}

function agentName(input) {
  return typeof input?.agent === "string" ? input.agent : input?.agent?.name;
}

class CompactionLoopGuard {
  constructor({ client, isHeadless, qualityLog, shouldContinue, continuation, now, detectOptions }) {
    this.client = client;
    this.isHeadless = isHeadless || (() => false);
    this.log = qualityLog || (() => {});
    this.shouldContinue = shouldContinue || continuationPolicy(continuation);
    this.now = now || Date.now;
    this.detectOptions = { ...LOOP_DEFAULTS, ...detectOptions };
    this.summaries = new Map(); // assistant messageID -> { sessionID, looped }
    this.compactionParts = new Map(); // user messageID -> { auto, overflow }
    this.streams = new Map(); // partID -> { messageID, sessionID, tail, length, checkedAt }
    this.requests = new Map(); // sessionID -> parent request identity
    this.recoveries = new RecoveryLedger(this.now, MAX_TRACKED);
  }

  // The compaction request's `message` is its parent user message: the
  // session's agent, model and variant to continue with.
  chatParams(input) {
    const message = input?.message;
    if (agentName(input) !== "compaction" || !input?.sessionID || !message?.model) return;
    const { providerID, modelID, variant } = message.model;
    this.requests.set(input.sessionID, { parentID: message.id, agent: message.agent, providerID, modelID, variant });
    capMap(this.requests);
  }

  trackMessage(info) {
    if (isCompactionSummary(info) && info.id && !this.summaries.has(info.id)) {
      this.summaries.set(info.id, { sessionID: info.sessionID, looped: false });
      capMap(this.summaries);
    }
    this.recoveries.observe(info);
  }

  trackCompactionPart(part) {
    this.compactionParts.set(part.messageID, { auto: part.auto === true, overflow: part.overflow === true });
    capMap(this.compactionParts);
  }

  // A delta appends; a full part update (text) replaces it.
  trackText({ id, messageID, sessionID, delta }, text) {
    const stream = this.streams.get(id) || { messageID, sessionID, tail: "", length: 0, checkedAt: 0 };
    const next = text === undefined ? stream.tail + delta : text;
    stream.length = text === undefined ? stream.length + delta.length : text.length;
    stream.tail = next.slice(-this.detectOptions.window);
    this.streams.set(id, stream);
    capMap(this.streams);
    this.check(stream);
  }

  trackPart(part, text) {
    if (part?.type === "compaction" && part.messageID) return this.trackCompactionPart(part);
    if (!part?.id || !this.summaries.has(part.messageID)) return undefined;
    if (part.type !== "text" && part.type !== "reasoning") return undefined;
    return this.trackText({ ...part, delta: String(part.delta || "") }, text);
  }

  check(stream) {
    if (stream.length - stream.checkedAt < CHECK_EVERY_CHARS) return;
    stream.checkedAt = stream.length;
    const summary = this.summaries.get(stream.messageID);
    if (!summary || summary.looped) return;
    const loop = repetitionAtTail(stream.tail, this.detectOptions);
    if (!loop) return;
    summary.looped = true;
    this.onLoop(stream, loop);
  }

  // The looping compaction's parent identity and { auto, overflow } part.
  origin(sessionID) {
    const request = this.requests.get(sessionID);
    return { request, part: this.compactionParts.get(request?.parentID) };
  }

  onLoop(stream, loop) {
    const { sessionID, messageID } = stream;
    const detail = `session sha256:${sessionHash(sessionID)} period=${loop.period} repeats=${loop.repeats} chars=${stream.length}`;
    if (this.isHeadless()) {
      this.log("WARN", `[compaction-loop-guard] repetition loop in compaction summary (${detail}); headless: output cap ends it, text is collapsed on completion`);
      return;
    }
    const retry = this.recoveries.reserve(sessionID, messageID, this.origin(sessionID));
    this.log("WARN", `[compaction-loop-guard] repetition loop in compaction summary (${detail}); aborting${retry ? " and rerunning compaction" : "; retry limit reached"}`);
    void abortLoopingCompaction({ client: this.client, log: this.log, sessionID, retry }).then((aborted) => {
      if (!aborted) this.recoveries.cancel(sessionID);
    });
  }

  maybeRecover(sessionID) {
    const origin = this.recoveries.take(sessionID);
    if (!origin) return;
    rerunCompaction({
      client: this.client,
      log: this.log,
      sessionID,
      request: origin.request,
      part: origin.part,
      shouldContinue: this.shouldContinue,
    }).catch((error) => {
      this.log("WARN", `[compaction-loop-guard] rerun failed: ${String(error?.message ?? error).slice(0, 200)}`);
    });
  }

  handleEvent(input) {
    const event = input?.event ?? input;
    const props = event?.properties || {};
    if (event?.type === "message.updated") this.trackMessage(props.info);
    else if (event?.type === "message.part.updated") this.trackPart(props.part, String(props.part?.text ?? ""));
    else if (event?.type === "message.part.delta" && props.field === "text") {
      // Text and reasoning parts both stream `text` deltas; both can loop.
      this.trackPart({ id: props.partID, messageID: props.messageID, sessionID: props.sessionID, type: "text", delta: props.delta });
    } else if (event?.type === "session.deleted") this.forget(String(props.info?.id || ""));
    if (idleEvent(event)) this.maybeRecover(eventSessionID(event));
  }

  forget(sessionID) {
    this.requests.delete(sessionID);
    this.recoveries.forget(sessionID);
  }

  transformMessages(output) {
    const { dropped, trimmed } = repairCompactedHistory(output?.messages);
    if (dropped || trimmed) {
      this.log("INFO", `[compaction-loop-guard] model input repaired: dropped ${dropped} failed summary message(s), trimmed ${trimmed} message(s) before a misanchored summary`);
    }
  }

  completeText(input, output) {
    if (!this.summaries.has(input?.messageID) || typeof output?.text !== "string") return;
    const collapsed = collapseRepetitions(output.text, this.detectOptions);
    if (!collapsed.runs) return;
    output.text = collapsed.text;
    this.log("WARN", `[compaction-loop-guard] collapsed ${collapsed.runs} repeated run(s), ${collapsed.removed} chars, in a compaction summary`);
  }
}

const DISABLED_GUARD = Object.freeze({
  chatParams: () => {},
  handleEvent: () => {},
  transformMessages: () => {},
  completeText: () => {},
});

// Every hook is fail-open: a guard error is logged and never blocks the host.
function failOpen(log, hook, run) {
  return (...args) => {
    try {
      run(...args);
    } catch (error) {
      log("WARN", `[compaction-loop-guard] ${hook} skipped: ${String(error?.message ?? error).slice(0, 200)}`);
    }
  };
}

/**
 * @param {object} options - `client`, `isHeadless()`, `qualityLog(level, msg)`,
 *   `continuation` (compaction autocontinue guard) or `shouldContinue(sessionID)`,
 *   `now()`, `detectOptions`,
 *   `env` (defaults to process.env; `AIDEVOPS_COMPACTION_LOOP_GUARD=0` disables)
 * @returns {{ chatParams: Function, handleEvent: Function, transformMessages: Function, completeText: Function }}
 */
export function createCompactionLoopGuard(options = {}) {
  const env = options.env || process.env;
  if (String(env.AIDEVOPS_COMPACTION_LOOP_GUARD ?? "").trim() === "0") return DISABLED_GUARD;
  const guard = new CompactionLoopGuard(options);
  return {
    chatParams: failOpen(guard.log, "chat.params", (input) => guard.chatParams(input)),
    handleEvent: failOpen(guard.log, "event", (input) => guard.handleEvent(input)),
    transformMessages: failOpen(guard.log, "transform", (_input, output) => guard.transformMessages(output)),
    completeText: failOpen(guard.log, "collapse", (input, output) => guard.completeText(input, output)),
  };
}
