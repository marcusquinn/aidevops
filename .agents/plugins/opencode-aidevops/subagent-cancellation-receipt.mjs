// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { SubagentCancellationLedger, shortSessionHash } from "./subagent-cancellation-ledger.mjs";
import { SubagentLifecycleTracker, scalarSessionID } from "./subagent-lifecycle-tracker.mjs";
import { classifySideEffect, safeToolName } from "./subagent-side-effect-classifier.mjs";

export { classifySideEffect };
export const MAX_CANCELLATION_LEDGER_ENTRIES = 24;
export const MAX_CANCELLATION_RECEIPT_BYTES = 8 * 1024;
export const CANCELLATION_RECEIPT_MARKER = "[AIDevOps cancellation receipt]";
const INTERRUPTED_TASK_ERROR = "Tool execution aborted";
const MAX_INTERRUPTED_TASKS = 64;

function capMap(map, maximum) {
  while (map.size > maximum) map.delete(map.keys().next().value);
}

function isTaskTool(tool) {
  const name = safeToolName(tool);
  return name === "task" || name === "mcp_task";
}

// GH#35529: OpenCode abort cleanup marks an in-flight Task part
// `status:"error"`, `error:"Tool execution aborted"`, `metadata.interrupted`
// without producing a Task result, so tool.execute.after never runs for it.
function interruptedTaskPart(part) {
  if (part?.type !== "tool" || !isTaskTool(part?.tool)) return false;
  const state = part?.state || {};
  if (String(state.status || "").toLowerCase() !== "error") return false;
  return state.metadata?.interrupted === true
    || part?.metadata?.interrupted === true
    || String(state.error || "").trim() === INTERRUPTED_TASK_ERROR;
}

function recoveryGuidance(childID) {
  const child = childID || "unknown (no unique child identity)";
  const inspect = childID
    ? ` Inspect it read-only: \`session-introspect-helper.sh recent 30 --session ${childID}\` (tool calls) and \`opencode export ${childID}\` (final assistant text).`
    : "";
  return `[AIDevOps interrupted Task recovery] Child session: ${child}.${inspect} Before re-delegating, reuse its verified units, treat its claims as unverified until they match evidence, and never replay a side effect listed above.`;
}

function taskWasCancelled(output) {
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  return ["aborted", "cancelled", "canceled"].includes(status)
    || /\b(?:abort(?:ed)?|cancel(?:led|ed)?)\b/i.test(`${output?.title || ""} ${output?.output || ""}`);
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

function boundedReceipt(receipt) {
  const bounded = { ...receipt, ledger: [...receipt.ledger] };
  let json = JSON.stringify(bounded);
  while (Buffer.byteLength(json, "utf8") > MAX_CANCELLATION_RECEIPT_BYTES && bounded.ledger.length > 0) {
    bounded.ledger.pop();
    bounded.truncated = true;
    bounded.complete = false;
    if (!bounded.incomplete_reasons.includes("receipt_size_limit")) {
      bounded.incomplete_reasons.push("receipt_size_limit");
    }
    json = JSON.stringify(bounded);
  }
  return { receipt: bounded, json };
}

class SubagentCancellationReceipt {
  constructor(client, options) {
    this.client = client;
    this.maxWaitMs = options.maxWaitMs ?? 3000;
    this.pollMs = options.pollMs ?? 25;
    this.sleep = options.sleep || ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.recordReceipt = options.recordReceipt;
    this.lifecycle = new SubagentLifecycleTracker();
    this.ledger = new SubagentCancellationLedger(
      options.maxEntries || MAX_CANCELLATION_LEDGER_ENTRIES,
      options.qualityLog,
      this.lifecycle,
    );
    // callID -> interrupted Task awaiting its parent-facing receipt (GH#35529).
    this.interrupted = new Map();
    // callIDs whose receipt already travels in the stored Task result.
    this.resultReceipts = new Map();
  }

  async waitForTerminal(childID) {
    const deadline = Date.now() + this.maxWaitMs;
    let evidence = this.lifecycle.terminalEvidence(childID);
    while (!evidence && Date.now() < deadline) {
      await this.sleep(this.pollMs);
      evidence = this.lifecycle.terminalEvidence(childID);
    }
    return evidence;
  }

  async terminateAndConfirm(childID) {
    const result = { abortRequested: false, evidence: "", reason: "child_identity_missing" };
    if (childID && typeof this.client?.session?.abort === "function") {
      result.reason = "abort_api_failed";
      try {
        const response = await this.client.session.abort({ path: { id: childID } });
        if (!responseError(response)) {
          result.abortRequested = true;
          result.reason = "termination_unconfirmed";
          result.evidence = await this.waitForTerminal(childID);
          if (result.evidence) result.reason = "";
        }
      } catch (error) {
        this.ledger.safeLog(
          "WARN",
          `[subagent-cancellation] session abort failed: ${error?.message || error?.name || "Error"}`,
        );
        result.reason = "abort_api_failed";
      }
    } else if (childID) {
      result.reason = "abort_api_unavailable";
      result.evidence = this.lifecycle.terminalEvidence(childID);
    }
    return result;
  }

  incompleteReasons(termination, observedSession, ledgerState) {
    const reasons = [];
    if (!termination.abortRequested) reasons.push(termination.reason || "abort_not_requested");
    if (!termination.evidence) reasons.push("termination_unconfirmed");
    if (!observedSession) reasons.push("lifecycle_events_missing");
    if (ledgerState.unknown) reasons.push("side_effect_outcome_unknown");
    if (ledgerState.truncated) reasons.push("ledger_truncated");
    if (this.ledger.trackingFailed || this.lifecycle.trackingFailed) reasons.push("event_tracking_failed");
    return [...new Set(reasons)];
  }

  buildReceipt(identity, termination) {
    const observedSession = this.lifecycle.observedSession(identity.childID);
    const ledgerState = this.ledger.ledgerFor(identity.childID);
    if ((!identity.childID || !observedSession) && ledgerState.ledger.length === 0) {
      ledgerState.ledger.push({
        call: `sha256:${shortSessionHash(identity.callID)}`,
        kind: "subagent",
        operation: "activity",
        status: "unknown",
        tool: "task",
      });
    }
    const incompleteReasons = this.incompleteReasons(termination, observedSession, ledgerState);
    return {
      version: 1,
      child: `sha256:${shortSessionHash(identity.childID)}`,
      complete: incompleteReasons.length === 0,
      incomplete_reasons: incompleteReasons,
      ledger: ledgerState.ledger.slice(0, MAX_CANCELLATION_LEDGER_ENTRIES),
      reaped: Boolean(termination.abortRequested && termination.evidence),
      telemetry: "pending",
      termination: termination.evidence ? "confirmed" : "unconfirmed",
      termination_evidence: termination.evidence || "none",
      truncated: ledgerState.truncated,
    };
  }

  persistReceipt(receipt, input, childID) {
    let recorded = false;
    try {
      recorded = Boolean(this.recordReceipt?.(receipt, {
        childSessionID: childID,
        parentSessionID: scalarSessionID(input?.sessionID),
      }));
    } catch (error) {
      this.ledger.safeLog(
        "WARN",
        `[subagent-cancellation] receipt persistence failed: ${error?.message || error?.name || "Error"}`,
      );
      recorded = false;
    }
    receipt.telemetry = recorded ? "recorded" : "unavailable";
    if (!recorded) {
      receipt.complete = false;
      receipt.incomplete_reasons.push("telemetry_unavailable");
    }
  }

  logReceipt(receipt, source) {
    this.ledger.safeLog(
      receipt.complete ? "INFO" : "WARN",
      `[subagent-cancellation] child ${receipt.child} source=${source} termination=${receipt.termination} receipt=${receipt.complete ? "complete" : "incomplete"}`,
    );
  }

  appendReceipt(output, receipt) {
    const bounded = boundedReceipt(receipt);
    output.output = `${String(output.output || "").trim()}\n\n${CANCELLATION_RECEIPT_MARKER}\n${bounded.json}`.trim();
    output.metadata = { ...output.metadata, aidevopsCancellationReceipt: bounded.receipt };
    this.logReceipt(bounded.receipt, "task_result");
    return bounded.receipt;
  }

  async cancelledTaskReceipt(input, output) {
    const identity = this.lifecycle.takeChildIdentity(input, output);
    const termination = await this.terminateAndConfirm(identity.childID);
    const receipt = this.buildReceipt(identity, termination);
    this.persistReceipt(receipt, input, identity.childID);
    return this.appendReceipt(output, receipt);
  }

  async afterTool(input, output) {
    const tool = safeToolName(input?.tool);
    let receipt = null;
    if (isTaskTool(tool)) {
      const callID = String(input?.callID || "");
      if (taskWasCancelled(output)) {
        // The stored Task result carries this receipt; never inject a second.
        this.interrupted.delete(callID);
        this.resultReceipts.set(callID, true);
        capMap(this.resultReceipts, MAX_INTERRUPTED_TASKS);
        receipt = await this.cancelledTaskReceipt(input, output);
      } else {
        this.lifecycle.takeChildIdentity(input, output);
      }
    } else {
      this.ledger.afterSideEffect(input, output);
    }
    return receipt;
  }

  observeInterruptedTask(event) {
    if (event?.type !== "message.part.updated") return;
    const part = event.properties?.part;
    if (!interruptedTaskPart(part)) return;
    const callID = scalarSessionID(part.callID);
    if (!callID || this.interrupted.has(callID) || this.resultReceipts.has(callID)) return;
    const parentID = scalarSessionID(part.sessionID);
    const identity = this.lifecycle.takeChildIdentity(
      { callID, sessionID: parentID },
      { error: part.state?.error, metadata: { ...part.metadata, ...part.state?.metadata } },
    );
    this.interrupted.set(callID, { identity, parentID, text: "", finalizing: null });
    capMap(this.interrupted, MAX_INTERRUPTED_TASKS);
  }

  handleEvent(input) {
    this.ledger.handleEvent(input);
    try {
      this.observeInterruptedTask(input?.event || input || {});
    } catch (error) {
      this.ledger.trackingFailed = true;
      this.ledger.safeLog("WARN", `[subagent-cancellation] interrupted Task tracking failed: ${error?.name || "Error"}`);
    }
  }

  // OpenCode has already aborted the child; prefer its lifecycle evidence and
  // request an abort only when termination is still unconfirmed.
  async interruptedTermination(identity) {
    if (!identity.childID) return { abortRequested: false, evidence: "", reason: identity.reason || "child_identity_missing" };
    const evidence = await this.waitForTerminal(identity.childID);
    if (evidence) return { abortRequested: true, evidence, reason: "" };
    return this.terminateAndConfirm(identity.childID);
  }

  async finalizeInterrupted(entry) {
    const termination = await this.interruptedTermination(entry.identity);
    const receipt = this.buildReceipt(entry.identity, termination);
    this.persistReceipt(receipt, { sessionID: entry.parentID }, entry.identity.childID);
    const bounded = boundedReceipt(receipt);
    this.logReceipt(bounded.receipt, "interrupted_part");
    entry.text = `${CANCELLATION_RECEIPT_MARKER}\n${bounded.json}\n${recoveryGuidance(entry.identity.childID)}`;
    return entry.text;
  }

  interruptedReceiptText(entry) {
    if (entry.text) return Promise.resolve(entry.text);
    entry.finalizing ||= this.finalizeInterrupted(entry);
    return entry.finalizing;
  }

  // Stored history stays unchanged: the receipt is re-applied to the same
  // interrupted Task result in each outgoing request, once per request, so
  // the parent's context stays stable across turns.
  async injectReceipts(_input, output) {
    const messages = output?.messages;
    if (!Array.isArray(messages) || this.interrupted.size === 0) return 0;
    let injected = 0;
    for (const message of messages) {
      const parts = Array.isArray(message?.parts) ? message.parts : [];
      for (let index = 0; index < parts.length; index += 1) {
        const part = parts[index];
        const entry = this.interrupted.get(scalarSessionID(part?.callID));
        if (!entry || !interruptedTaskPart(part)) continue;
        if (entry.parentID && scalarSessionID(part.sessionID) !== entry.parentID) continue;
        const error = String(part.state?.error || "").trim();
        if (error.includes(CANCELLATION_RECEIPT_MARKER)) continue;
        const text = await this.interruptedReceiptText(entry);
        parts[index] = { ...part, state: { ...part.state, error: `${error}\n\n${text}`.trim() } };
        injected += 1;
      }
    }
    return injected;
  }

  async safeInjectReceipts(input, output) {
    try {
      return await this.injectReceipts(input, output);
    } catch (error) {
      this.ledger.safeLog("WARN", `[subagent-cancellation] interrupted receipt injection failed: ${error?.name || "Error"}`);
      return 0;
    }
  }
}

/** Delay a cancelled Task result until child termination is confirmed. */
export function createSubagentCancellationReceipt(client, options = {}) {
  const handler = new SubagentCancellationReceipt(client, options);
  return {
    afterTool: handler.afterTool.bind(handler),
    beforeTool: handler.ledger.beforeTool.bind(handler.ledger),
    handleEvent: handler.handleEvent.bind(handler),
    injectReceipts: handler.safeInjectReceipts.bind(handler),
  };
}
