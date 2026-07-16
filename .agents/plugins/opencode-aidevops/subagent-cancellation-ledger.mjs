// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { toolOutcomeFailed } from "./session-continuation-guard.mjs";
import { classifySideEffect, safeToolName } from "./subagent-side-effect-classifier.mjs";
import { eventSessionID } from "./subagent-lifecycle-tracker.mjs";

const MAX_SESSION_STATES = 64;

function capMap(map, maximum = MAX_SESSION_STATES) {
  while (map.size > maximum) map.delete(map.keys().next().value);
}

export function shortSessionHash(value) {
  return createHash("sha256").update(String(value || "unknown")).digest("hex").slice(0, 12);
}

export class SubagentCancellationLedger {
  constructor(maxEntries, qualityLog, lifecycle) {
    this.maxEntries = maxEntries;
    this.qualityLog = qualityLog;
    this.lifecycle = lifecycle;
    this.activity = new Map();
    this.sequence = 0;
    this.trackingFailed = false;
  }

  safeLog(level, message) {
    try {
      this.qualityLog?.(level, message);
    } catch {
      this.trackingFailed = true;
    }
  }

  sessionActivity(sessionID) {
    if (!this.activity.has(sessionID)) {
      if (this.activity.size >= MAX_SESSION_STATES) this.trackingFailed = true;
      this.activity.set(sessionID, { events: [], inflight: new Map(), keys: new Set(), truncated: false });
      capMap(this.activity);
    }
    return this.activity.get(sessionID);
  }

  addLedgerEvent(sessionID, callID, effect, status) {
    if (!sessionID || !effect) return;
    const state = this.sessionActivity(sessionID);
    const call = `sha256:${shortSessionHash(callID)}`;
    const key = `${call}:${effect.kind}:${effect.operation}:${status}`;
    if (state.keys.has(key)) return;
    state.keys.add(key);
    if (state.events.length >= this.maxEntries) {
      state.truncated = true;
    } else {
      state.events.push({ call, kind: effect.kind, operation: effect.operation, status, tool: effect.tool });
    }
  }

  beforeTool(input, output) {
    const tool = safeToolName(input?.tool);
    const callID = String(input?.callID || `event-${++this.sequence}`);
    const sessionID = String(input?.sessionID || "");
    if (tool === "task" || tool === "mcp_task") {
      this.lifecycle.beforeTask(callID, sessionID);
    } else {
      const effect = classifySideEffect(tool, output?.args || input?.args || {});
      if (effect && sessionID) {
        const state = this.sessionActivity(sessionID);
        state.inflight.set(callID, effect);
        this.addLedgerEvent(sessionID, callID, effect, "attempted");
      }
    }
  }

  afterSideEffect(input, output) {
    const sessionID = String(input?.sessionID || "");
    const callID = String(input?.callID || "");
    const state = this.activity.get(sessionID);
    const effect = state?.inflight.get(callID);
    if (effect) {
      state.inflight.delete(callID);
      this.addLedgerEvent(sessionID, callID, effect, toolOutcomeFailed(output) ? "failed" : "completed");
    }
  }

  observeRuntimeToolPart(part) {
    const sessionID = String(part?.sessionID || "");
    const callID = String(part?.callID || "");
    const status = String(part?.state?.status || "").toLowerCase();
    if (!sessionID || !callID || part?.type !== "tool") return;
    if (["pending", "running"].includes(status)) {
      this.beforeTool({ tool: part.tool, sessionID, callID }, { args: part.state?.input || {} });
    } else if (["completed", "error", "failed", "aborted", "cancelled", "canceled"].includes(status)) {
      this.afterSideEffect({ tool: part.tool, sessionID, callID }, { status, error: part.state?.error });
    }
  }

  routeEvent(event) {
    const sessionID = eventSessionID(event);
    this.lifecycle.handleEvent(event);
    if (["message.part.updated", "message.part.delta"].includes(event.type)) {
      this.observeRuntimeToolPart(event.properties?.part);
    } else if (event.type === "file.edited") {
      this.addLedgerEvent(sessionID, event?.id || `file-event-${++this.sequence}`, {
        kind: "file", operation: "write", tool: "runtime-event",
      }, "completed");
    }
  }

  handleEvent(input) {
    try {
      this.routeEvent(input?.event || input || {});
    } catch (error) {
      this.trackingFailed = true;
      this.safeLog("WARN", `[subagent-cancellation] lifecycle event tracking failed: ${error?.name || "Error"}`);
    }
  }

  ledgerFor(childID) {
    const state = this.activity.get(childID) || { events: [], inflight: new Map(), truncated: false };
    const ledger = [...state.events];
    for (const [callID, effect] of state.inflight) {
      if (ledger.length >= this.maxEntries) break;
      ledger.push({
        call: `sha256:${shortSessionHash(callID)}`,
        kind: effect.kind,
        operation: effect.operation,
        status: "unknown",
        tool: effect.tool,
      });
    }
    return {
      ledger,
      truncated: state.truncated || state.events.length + state.inflight.size > this.maxEntries,
      unknown: state.inflight.size > 0,
    };
  }
}
