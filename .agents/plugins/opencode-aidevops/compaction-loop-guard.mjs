// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ---------------------------------------------------------------------------
// GH#37997: stop compaction summaries that loop on repeated text (OpenCode 1).
//
// Stream: `message.part.delta` text of compaction summaries is checked at the
// tail. On a loop, interactive sessions are aborted, compaction is rerun via
// `session.summarize` (a fresh, correctly anchored compaction part), and an
// automatic compaction continues with the original agent, model and variant.
// Headless runs are never aborted: `opencode run` would exit, so the output
// cap ends the stream and text.complete collapses the loop instead.
// Model input: messages.transform drops failed summaries and repairs a
// misanchored boundary (compaction-loop-detect.mjs).
// ---------------------------------------------------------------------------

import { createHash } from "node:crypto";
import {
  collapseRepetitions,
  isCompactionSummary,
  LOOP_DEFAULTS,
  repairCompactedHistory,
  repetitionAtTail,
} from "./compaction-loop-detect.mjs";

// Same text as OpenCode's own post-compaction continuation (compaction.ts).
export const CONTINUE_TEXT = "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.";
const CHECK_EVERY_CHARS = 512;
const MAX_TRACKED = 64;
const MAX_RECOVERIES = 2;
const RECOVERY_WINDOW_MS = 30 * 60 * 1000;

function capMap(map) {
  while (map.size > MAX_TRACKED) map.delete(map.keys().next().value);
}

function sessionHash(sessionID) {
  return createHash("sha256").update(String(sessionID || "unknown-session")).digest("hex").slice(0, 12);
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

function idleEvent(event) {
  return event.type === "session.idle"
    || (event.type === "session.status" && event.properties?.status?.type === "idle");
}

function eventSessionID(event) {
  const props = event.properties || {};
  return String(props.sessionID || props.info?.sessionID || props.part?.sessionID || "");
}

class CompactionLoopGuard {
  constructor({ client, isHeadless, qualityLog, shouldContinue, now, detectOptions }) {
    this.client = client;
    this.isHeadless = isHeadless || (() => false);
    this.log = qualityLog || (() => {});
    this.shouldContinue = shouldContinue;
    this.now = now || Date.now;
    this.detectOptions = { ...LOOP_DEFAULTS, ...(detectOptions || {}) };
    this.summaries = new Map(); // assistant messageID -> { sessionID, looped }
    this.compactionParts = new Map(); // user messageID -> { auto, overflow }
    this.streams = new Map(); // partID -> { messageID, sessionID, tail, checkedAt }
    this.requests = new Map(); // sessionID -> parent request identity
    this.recoveries = new Map(); // sessionID -> { attempts, pending }
  }

  // The compaction request's `message` is its parent user message: the
  // session's agent, model and variant to continue with.
  chatParams(input) {
    const agent = typeof input?.agent === "string" ? input.agent : input?.agent?.name;
    const message = input?.message;
    if (agent !== "compaction" || !input?.sessionID || !message?.model) return;
    this.requests.set(input.sessionID, {
      parentID: message.id,
      agent: message.agent,
      providerID: message.model.providerID,
      modelID: message.model.modelID,
      variant: message.model.variant,
    });
    capMap(this.requests);
  }

  trackMessage(info) {
    if (isCompactionSummary(info) && info.id) {
      if (!this.summaries.has(info.id)) this.summaries.set(info.id, { sessionID: info.sessionID, looped: false });
      capMap(this.summaries);
    }
    const recovery = this.recoveries.get(info?.sessionID);
    if (recovery?.pending?.messageID === info?.id && (info.error || info.time?.completed)) {
      recovery.pending.ended = true;
    }
  }

  trackPart(part, text) {
    if (part?.type === "compaction" && part.messageID) {
      this.compactionParts.set(part.messageID, { auto: part.auto === true, overflow: part.overflow === true });
      capMap(this.compactionParts);
      return;
    }
    if (!part?.id || !this.summaries.has(part.messageID)) return;
    if (part.type !== "text" && part.type !== "reasoning") return;
    const stream = this.streams.get(part.id)
      || { messageID: part.messageID, sessionID: part.sessionID, tail: "", length: 0, checkedAt: 0 };
    // A delta appends; a full part update replaces (text-start and text-end).
    const delta = String(part.delta || "");
    stream.tail = (text === undefined ? stream.tail + delta : text).slice(-this.detectOptions.window);
    stream.length = text === undefined ? stream.length + delta.length : text.length;
    this.streams.set(part.id, stream);
    capMap(this.streams);
    this.check(stream);
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

  onLoop(stream, loop) {
    const { sessionID, messageID } = stream;
    const detail = `session sha256:${sessionHash(sessionID)} period=${loop.period} repeats=${loop.repeats} chars=${stream.length}`;
    if (this.isHeadless()) {
      this.log("WARN", `[compaction-loop-guard] repetition loop in compaction summary (${detail}); headless: output cap ends it, text is collapsed on completion`);
      return;
    }
    const recovery = this.recoveries.get(sessionID) || { attempts: [], pending: null };
    recovery.attempts = recovery.attempts.filter((at) => this.now() - at < RECOVERY_WINDOW_MS);
    const retry = recovery.attempts.length < MAX_RECOVERIES;
    if (retry) {
      recovery.attempts.push(this.now());
      recovery.pending = { messageID, ended: false, request: this.requests.get(sessionID) };
    }
    this.recoveries.set(sessionID, recovery);
    capMap(this.recoveries);
    this.log("WARN", `[compaction-loop-guard] repetition loop in compaction summary (${detail}); aborting${retry ? " and rerunning compaction" : "; retry limit reached"}`);
    void this.abort(sessionID, retry);
  }

  async abort(sessionID, retry) {
    try {
      const response = await this.client?.session?.abort?.({ path: { id: sessionID } });
      if (responseError(response)) throw new Error(String(responseError(response)?.message || "abort failed"));
    } catch (error) {
      const recovery = this.recoveries.get(sessionID);
      if (recovery) recovery.pending = null;
      this.log("WARN", `[compaction-loop-guard] abort failed: ${String(error?.message ?? error).slice(0, 200)}`);
      return;
    }
    await this.toast(retry
      ? "The compaction summary started repeating text. It was stopped and compaction is running again."
      : "The compaction summary repeated text again and was stopped. Send /compact to retry, or pin agent.compaction.model to another model.",
    retry ? "warning" : "error");
  }

  async toast(message, variant) {
    try {
      await this.client?.tui?.showToast?.({ body: { title: "Compaction loop stopped", message, variant } });
    } catch {
      // Toasts are advisory; the log line above is the durable record.
    }
  }

  async recover(sessionID, pending) {
    const request = pending.request;
    if (!request?.providerID || !request?.modelID || typeof this.client?.session?.summarize !== "function") {
      this.log("WARN", "[compaction-loop-guard] rerun skipped: compaction request identity unavailable");
      return;
    }
    const part = this.compactionParts.get(request.parentID) || { auto: false, overflow: false };
    const summarized = await this.client.session.summarize({
      path: { id: sessionID },
      body: { providerID: request.providerID, modelID: request.modelID, auto: false },
    });
    if (responseError(summarized)) throw new Error("summarize failed");
    this.log("INFO", `[compaction-loop-guard] compaction rerun completed for session sha256:${sessionHash(sessionID)}`);
    if (!part.auto || part.overflow) return;
    if (this.shouldContinue && !(await this.shouldContinue(sessionID))) return;
    if (typeof this.client.session.promptAsync !== "function") return;
    const prompted = await this.client.session.promptAsync({
      path: { id: sessionID },
      body: {
        agent: request.agent,
        model: { providerID: request.providerID, modelID: request.modelID },
        ...(request.variant ? { variant: request.variant } : {}),
        parts: [{ type: "text", text: CONTINUE_TEXT, synthetic: true }],
      },
    });
    if (responseError(prompted)) throw new Error("continuation prompt failed");
  }

  // Only the idle after the aborted summary has ended proves the run is torn
  // down; an earlier idle would join the failing run.
  maybeRecover(sessionID) {
    const recovery = this.recoveries.get(sessionID);
    const pending = recovery?.pending;
    if (!pending?.ended) return;
    recovery.pending = null;
    this.recover(sessionID, pending).catch((error) => {
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
    this.recoveries.delete(sessionID);
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

/**
 * @param {object} options - `client`, `isHeadless()`, `qualityLog(level, msg)`,
 *   `shouldContinue(sessionID)` (autocontinue policy), `now()`, `detectOptions`,
 *   `env` (defaults to process.env; `AIDEVOPS_COMPACTION_LOOP_GUARD=0` disables)
 * @returns {{ chatParams: Function, handleEvent: Function, transformMessages: Function, completeText: Function }}
 */
export function createCompactionLoopGuard(options = {}) {
  const env = options.env || process.env;
  if (String(env.AIDEVOPS_COMPACTION_LOOP_GUARD ?? "").trim() === "0") return DISABLED_GUARD;
  const guard = new CompactionLoopGuard(options);
  return {
    chatParams: (input) => guard.chatParams(input),
    handleEvent: (input) => guard.handleEvent(input),
    transformMessages: (_input, output) => guard.transformMessages(output),
    completeText: (input, output) => guard.completeText(input, output),
  };
}
