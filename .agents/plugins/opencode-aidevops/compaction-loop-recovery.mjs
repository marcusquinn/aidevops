// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ---------------------------------------------------------------------------
// GH#37997: host actions for a looping compaction summary (OpenCode 1 SDK).
// Abort the looping run, then rerun compaction through `session.summarize`
// (a fresh, correctly anchored compaction part) and continue an automatic
// compaction with the original agent, model and variant.
// ---------------------------------------------------------------------------

import { createHash } from "node:crypto";
import { isCompactionSummary } from "./compaction-history-repair.mjs";

// Same text as OpenCode's own post-compaction continuation (compaction.ts).
export const CONTINUE_TEXT = "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.";

const MAX_RECOVERIES = 2;
const RECOVERY_WINDOW_MS = 30 * 60 * 1000;

/**
 * Per-session rerun budget (MAX_RECOVERIES per RECOVERY_WINDOW_MS) and the
 * chain origin: the first looping compaction's request and part ({ auto,
 * overflow }). A rerun is a manual compaction whose parent has no variant, so
 * a loop in a rerun must recover with the original identity. A clean summary
 * or an expired window ends the chain.
 */
export class RecoveryLedger {
  constructor(now, maxTracked) {
    this.now = now;
    this.maxTracked = maxTracked;
    this.sessions = new Map(); // sessionID -> { attempts, pending, origin }
  }

  /** @returns {boolean} true when a rerun is reserved */
  reserve(sessionID, messageID, origin) {
    const entry = this.sessions.get(sessionID) || { attempts: [], pending: null, origin: null };
    entry.attempts = entry.attempts.filter((at) => this.now() - at < RECOVERY_WINDOW_MS);
    if (entry.attempts.length === 0) entry.origin = null;
    entry.origin = entry.origin || origin;
    const retry = entry.attempts.length < MAX_RECOVERIES;
    if (retry) {
      entry.attempts.push(this.now());
      entry.pending = { messageID, ended: false };
    }
    this.sessions.set(sessionID, entry);
    while (this.sessions.size > this.maxTracked) this.sessions.delete(this.sessions.keys().next().value);
    return retry;
  }

  /** Track message.updated: the aborted summary ending, or a clean summary. */
  observe(info) {
    const entry = this.sessions.get(info?.sessionID);
    if (!entry) return;
    if (entry.pending?.messageID === info.id) {
      if (info.error || info.time?.completed) entry.pending.ended = true;
    } else if (!entry.pending && isCompactionSummary(info) && info.finish && !info.error) {
      entry.origin = null;
    }
  }

  /**
   * Only the idle after the aborted summary has ended proves the run is torn
   * down; an earlier idle would join the failing run.
   * @returns {object|null} the chain origin when a rerun is due
   */
  take(sessionID) {
    const entry = this.sessions.get(sessionID);
    if (!entry?.pending?.ended) return null;
    entry.pending = null;
    return entry.origin || {};
  }

  cancel(sessionID) {
    const entry = this.sessions.get(sessionID);
    if (entry) entry.pending = null;
  }

  forget(sessionID) {
    this.sessions.delete(sessionID);
  }
}

export function sessionHash(sessionID) {
  return createHash("sha256").update(String(sessionID || "unknown-session")).digest("hex").slice(0, 12);
}

/**
 * Adapt the plugin's compaction autocontinue guard (compaction-lifecycle.mjs)
 * so a rerun continues under the same policy as OpenCode's own continuation.
 * @returns {Function|undefined} async (sessionID) => boolean
 */
export function continuationPolicy(continuation) {
  if (typeof continuation?.autoContinue !== "function") return undefined;
  return async (sessionID) => {
    const decision = { enabled: true };
    await continuation.autoContinue({ sessionID }, decision);
    return decision.enabled;
  };
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

async function toast(client, message, variant) {
  try {
    await client?.tui?.showToast?.({ body: { title: "Compaction loop stopped", message, variant } });
  } catch {
    // Toasts are advisory; the quality log line is the durable record.
  }
}

/**
 * Abort the looping run and tell the user what happens next.
 * @returns {Promise<boolean>} true when the abort was accepted
 */
export async function abortLoopingCompaction({ client, log, sessionID, retry }) {
  try {
    const response = await client?.session?.abort?.({ path: { id: sessionID } });
    if (responseError(response)) throw new Error(String(responseError(response)?.message || "abort failed"));
  } catch (error) {
    log("WARN", `[compaction-loop-guard] abort failed: ${String(error?.message ?? error).slice(0, 200)}`);
    return false;
  }
  await toast(client, retry
    ? "The compaction summary started repeating text. It was stopped and compaction is running again."
    : "The compaction summary repeated text again and was stopped. Send /compact to retry, or pin agent.compaction.model to another model.",
  retry ? "warning" : "error");
  return true;
}

async function continueSession(client, sessionID, request) {
  if (typeof client.session.promptAsync !== "function") return;
  const prompted = await client.session.promptAsync({
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

/**
 * Rerun compaction after the aborted run is torn down. Only an automatic,
 * non-overflow compaction is continued, and only when policy allows it.
 * @param {object} input - `client`, `log`, `sessionID`, `request` (parent
 *   agent/model/variant), `part` ({ auto, overflow }), `shouldContinue`
 */
export async function rerunCompaction({ client, log, sessionID, request, part, shouldContinue }) {
  if (!request?.providerID || !request?.modelID || typeof client?.session?.summarize !== "function") {
    log("WARN", "[compaction-loop-guard] rerun skipped: compaction request identity unavailable");
    return;
  }
  const summarized = await client.session.summarize({
    path: { id: sessionID },
    body: { providerID: request.providerID, modelID: request.modelID, auto: false },
  });
  if (responseError(summarized)) throw new Error("summarize failed");
  log("INFO", `[compaction-loop-guard] compaction rerun completed for session sha256:${sessionHash(sessionID)}`);
  if (!part?.auto || part.overflow) return;
  if (shouldContinue && !(await shouldContinue(sessionID))) return;
  await continueSession(client, sessionID, request);
}
