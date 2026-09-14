// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { appendRuntimeEventSync } from "../../scripts/runtime-events.mjs";

function digest(value) {
  return createHash("sha256").update(String(value || "unknown")).digest("hex").slice(0, 24);
}

class ObjectiveEvidenceAdapter {
  constructor({ isReady = () => true, onEvent = () => {} } = {}) {
    this.isReady = isReady;
    this.onEvent = onEvent;
    this.contexts = new Map();
    this.pendingRequests = new Map();
    this.started = new Set();
  }

  emit(input) {
    const envelope = appendRuntimeEventSync(input);
    this.onEvent(envelope);
    return envelope;
  }

  environmentContext(sessionID) {
    const issue = String(process.env.WORKER_ISSUE_NUMBER || "").trim();
    const configured = String(process.env.AIDEVOPS_OBJECTIVE_ID || "").trim();
    const run = String(process.env.AIDEVOPS_RUN_ID || "").trim();
    if (!configured && !issue && !run) return null;
    return {
      objectiveID: configured || `issue:${issue || digest(run)}`,
      runID: `run:${digest(run || sessionID)}`,
    };
  }

  contextForSession(sessionID) {
    const known = this.contexts.get(String(sessionID || ""));
    if (known) return known;
    return this.environmentContext(sessionID) ? this.begin(sessionID, sessionID) : null;
  }

  attach(sessionID, requestID, context = this.contexts.get(sessionID)) {
    if (!context) {
      const pending = this.pendingRequests.get(sessionID) || [];
      pending.push(requestID);
      this.pendingRequests.set(sessionID, pending.slice(-128));
      return null;
    }
    const requestRef = `opencode-message:${digest(requestID)}`;
    return this.emit({
      eventType: "objective.session.attached",
      subjectId: requestRef,
      sessionId: sessionID,
      correlationId: context.runID,
      payload: {
        objective_version: 1, objective_id: context.objectiveID, run_id: context.runID,
        contribution_id: requestRef, request_ids: [requestRef],
        boundary: "completed_assistant_message", allocation: "unique",
      },
    });
  }

  flush(sessionID, context) {
    const pending = this.pendingRequests.get(sessionID) || [];
    this.pendingRequests.delete(sessionID);
    for (const requestID of pending) this.attach(sessionID, requestID, context);
  }

  begin(sessionID, boundaryID) {
    const context = this.environmentContext(sessionID) || {
      objectiveID: `objective:opencode:${digest(`${sessionID}:${boundaryID}`)}`,
      runID: `run:opencode:${digest(sessionID)}`,
    };
    this.contexts.set(sessionID, context);
    while (this.contexts.size > 1000) this.contexts.delete(this.contexts.keys().next().value);
    if (!this.started.has(context.objectiveID)) {
      this.started.add(context.objectiveID);
      while (this.started.size > 2000) this.started.delete(this.started.values().next().value);
      this.emit({
        eventType: "objective.started", subjectId: context.objectiveID,
        sessionId: sessionID, correlationId: context.runID,
        payload: { objective_version: 1, objective_id: context.objectiveID, run_id: context.runID },
      });
    }
    this.flush(sessionID, context);
    return context;
  }

  inherit(sessionID, parentSessionID) {
    const context = this.contextForSession(parentSessionID);
    if (context && sessionID) {
      this.contexts.set(sessionID, context);
      this.flush(sessionID, context);
    }
    return context;
  }

  recordAcceptance(evidence = {}) {
    if (!this.isReady()) return null;
    return this.emit({
      eventType: "subagent.acceptance",
      subjectId: evidence.contributionID || evidence.childSessionID || "unknown-contribution",
      sessionId: evidence.parentSessionID || null,
      correlationId: evidence.parentSessionID || evidence.runID || "subagent-acceptance",
      causationId: evidence.callID || undefined,
      payload: {
        attempt_id: evidence.attemptID,
        contribution_id: evidence.contributionID,
        contribution_outcome: evidence.outcome,
        intervention_count: Number.isSafeInteger(evidence.interventionCount) ? evidence.interventionCount : 0,
        objective_id: evidence.objectiveID,
        objective_version: 1,
        observed_at: evidence.observedAt || new Date().toISOString(),
        policy_version: evidence.policyVersion || "unknown",
        repair_contribution_id: evidence.repairContributionID,
        run_id: evidence.runID,
        source: evidence.source || "parent_assertion",
      },
    });
  }

  recordDecision(evidence = {}) {
    if (!this.isReady()) return { recorded: false, reason: "observability unavailable" };
    const context = evidence.objectiveID && evidence.runID
      ? { objectiveID: evidence.objectiveID, runID: evidence.runID }
      : this.contextForSession(evidence.parentSessionID);
    if (!context) return { recorded: false, reason: "objective context unavailable" };
    const acceptance = evidence.contributionID
      ? this.recordAcceptance({ ...evidence, objectiveID: context.objectiveID, runID: context.runID })
      : null;
    const outcome = evidence.objectiveOutcome ? this.recordOutcome(evidence, context) : null;
    return {
      recorded: Boolean(acceptance || outcome),
      acceptanceEventID: acceptance?.eventId || null,
      outcomeEventID: outcome?.eventId || null,
      ...context,
    };
  }

  recordOutcome(evidence, context) {
    const payload = {
      objective_version: 1, objective_id: context.objectiveID, run_id: context.runID,
      outcome: evidence.objectiveOutcome, source: evidence.source || "parent_decision",
      observed_at: evidence.observedAt || new Date().toISOString(),
      policy_version: evidence.policyVersion || "v1",
    };
    if (evidence.objectiveOutcome === "verified") Object.assign(payload, {
      evidence_kind: evidence.evidenceKind,
      evidence_fingerprint: evidence.evidenceFingerprint,
      observer: evidence.observer,
    });
    return this.emit({
      eventType: "objective.outcome", subjectId: context.objectiveID,
      sessionId: evidence.parentSessionID || null, correlationId: context.runID, payload,
    });
  }
}

export function createObjectiveEvidenceAdapter(options) {
  return new ObjectiveEvidenceAdapter(options);
}
