// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { safeToolName } from "./subagent-side-effect-classifier.mjs";
import { scalarSessionID } from "./subagent-task-identity.mjs";

export const CANCELLATION_RECEIPT_MARKER = "[AIDevOps cancellation receipt]";
const INTERRUPTED_TASK_ERROR = "Tool execution aborted";
const MAX_INTERRUPTED_TASKS = 64;
// Only a well-formed runtime session ID is embedded in suggested commands.
const SAFE_SESSION_ID = /^[A-Za-z0-9_-]{1,80}$/;

function capMap(map) {
  while (map.size > MAX_INTERRUPTED_TASKS) map.delete(map.keys().next().value);
}

export function isTaskTool(tool) {
  const name = safeToolName(tool);
  return name === "task" || name === "mcp_task";
}

function interruptedMetadata(part) {
  return part?.state?.metadata?.interrupted === true || part?.metadata?.interrupted === true;
}

// GH#35529: OpenCode abort cleanup marks an in-flight Task part
// `status:"error"`, `error:"Tool execution aborted"`, `metadata.interrupted`
// without producing a Task result, so tool.execute.after never runs for it.
export function interruptedTaskPart(part) {
  if (part?.type !== "tool" || !isTaskTool(part?.tool)) return false;
  if (String(part?.state?.status || "").toLowerCase() !== "error") return false;
  return interruptedMetadata(part) || String(part.state.error || "").trim() === INTERRUPTED_TASK_ERROR;
}

function recoveryGuidance(rawChildID) {
  const childID = SAFE_SESSION_ID.test(rawChildID || "") ? rawChildID : "";
  const child = childID || "unknown (no unique, well-formed child identity)";
  const inspect = childID
    ? ` Inspect it read-only: \`session-introspect-helper.sh recent 30 --session ${childID}\` (tool calls) and \`opencode export ${childID}\` (final assistant text).`
    : "";
  return `[AIDevOps interrupted Task recovery] Child session: ${child}.${inspect} Before re-delegating, reuse its verified units, treat its claims as unverified until they match evidence, and never replay a side effect listed above.`;
}

/** Parent-facing text: the bounded receipt JSON plus one recovery pointer. */
export function interruptedReceiptText(receiptJson, childID) {
  return `${CANCELLATION_RECEIPT_MARKER}\n${receiptJson}\n${recoveryGuidance(childID)}`;
}

function* messageParts(messages) {
  for (const message of messages) {
    const parts = Array.isArray(message?.parts) ? message.parts : [];
    for (let index = 0; index < parts.length; index += 1) yield { parts, index, part: parts[index] };
  }
}

/**
 * Queue interrupted Task parts and attach their receipt to the matching tool
 * result in outgoing requests. Stored history stays unchanged, so the receipt
 * is re-applied once per request and the parent's context stays stable.
 */
export class InterruptedTaskReceipts {
  constructor(finalize) {
    this.finalize = finalize;
    this.pending = new Map();
    // callIDs whose receipt already travels in the stored Task result.
    this.resultReceipts = new Map();
  }

  markResultReceipt(callID) {
    this.pending.delete(callID);
    this.resultReceipts.set(callID, true);
    capMap(this.resultReceipts);
  }

  observe(event, takeIdentity) {
    if (event?.type !== "message.part.updated") return;
    const part = event.properties?.part;
    if (!interruptedTaskPart(part)) return;
    const callID = scalarSessionID(part.callID);
    if (!callID || this.pending.has(callID) || this.resultReceipts.has(callID)) return;
    const parentID = scalarSessionID(part.sessionID);
    const identity = takeIdentity(
      { callID, sessionID: parentID },
      { error: part.state?.error, metadata: { ...part.metadata, ...part.state?.metadata } },
    );
    this.pending.set(callID, { identity, parentID, text: "", finalizing: null });
    capMap(this.pending);
  }

  receiptText(entry) {
    if (entry.text) return Promise.resolve(entry.text);
    entry.finalizing ||= this.finalize(entry)
      .then((text) => {
        entry.text = text;
        return text;
      })
      .catch((error) => {
        entry.finalizing = null;
        throw error;
      });
    return entry.finalizing;
  }

  targetEntry(part) {
    const entry = this.pending.get(scalarSessionID(part?.callID));
    if (!entry || !interruptedTaskPart(part)) return null;
    if (entry.parentID && scalarSessionID(part.sessionID) !== entry.parentID) return null;
    return String(part.state?.error || "").includes(CANCELLATION_RECEIPT_MARKER) ? null : entry;
  }

  async inject(output) {
    const messages = output?.messages;
    if (!Array.isArray(messages) || this.pending.size === 0) return 0;
    let injected = 0;
    for (const { parts, index, part } of messageParts(messages)) {
      const entry = this.targetEntry(part);
      if (!entry) continue;
      const text = await this.receiptText(entry);
      const error = String(part.state?.error || "").trim();
      parts[index] = { ...part, state: { ...part.state, error: `${error}\n\n${text}`.trim() } };
      injected += 1;
    }
    return injected;
  }
}
