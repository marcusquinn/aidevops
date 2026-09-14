// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { appendRuntimeEventSync } from "../../scripts/runtime-events.mjs";

function digest(value) {
  return createHash("sha256").update(String(value || "unknown")).digest("hex").slice(0, 24);
}

/** Own bounded OpenCode objective identities and explicit parent receipts. */
export function createObjectiveEvidenceAdapter({ isReady = () => true, onEvent = () => {} } = {}) {
  const contexts = new Map();
  const pendingRequests = new Map();
  const started = new Set();

  function emit(input) {
    const envelope = appendRuntimeEventSync(input);
    onEvent(envelope);
    return envelope;
  }

  function environmentContext(sessionID) {
    const issue = String(process.env.WORKER_ISSUE_NUMBER || "").trim();
    const configured = String(process.env.AIDEVOPS_OBJECTIVE_ID || "").trim();
    const run = String(process.env.AIDEVOPS_RUN_ID || "").trim();
    if (!configured && !issue && !run) return null;
    return {
      objectiveID: configured || `issue:${issue || digest(run)}`,
      runID: `run:${digest(run || sessionID)}`,
    };
  }

  function contextForSession(sessionID) {
    const known = contexts.get(String(sessionID || ""));
    if (known) return known;
    return environmentContext(sessionID) ? begin(sessionID, sessionID) : null;
  }

  function attach(sessionID, requestID, context = contexts.get(sessionID)) {
    if (!context) {
      const pending = pendingRequests.get(sessionID) || [];
      pending.push(requestID);
      pendingRequests.set(sessionID, pending.slice(-128));
      return null;
    }
    const requestRef = `opencode-message:${digest(requestID)}`;
    return emit({
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

  function flush(sessionID, context) {
    const pending = pendingRequests.get(sessionID) || [];
    pendingRequests.delete(sessionID);
    for (const requestID of pending) attach(sessionID, requestID, context);
  }

  function begin(sessionID, boundaryID) {
    const context = environmentContext(sessionID) || {
      objectiveID: `objective:opencode:${digest(`${sessionID}:${boundaryID}`)}`,
      runID: `run:opencode:${digest(sessionID)}`,
    };
    contexts.set(sessionID, context);
    while (contexts.size > 1000) contexts.delete(contexts.keys().next().value);
    if (!started.has(context.objectiveID)) {
      started.add(context.objectiveID);
      while (started.size > 2000) started.delete(started.values().next().value);
      emit({
        eventType: "objective.started", subjectId: context.objectiveID,
        sessionId: sessionID, correlationId: context.runID,
        payload: { objective_version: 1, objective_id: context.objectiveID, run_id: context.runID },
      });
    }
    flush(sessionID, context);
    return context;
  }

  function inherit(sessionID, parentSessionID) {
    const context = contextForSession(parentSessionID);
    if (context && sessionID) {
      contexts.set(sessionID, context);
      flush(sessionID, context);
    }
    return context;
  }

  function recordAcceptance(evidence = {}) {
    if (!isReady()) return null;
    return emit({
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

  function recordDecision(evidence = {}) {
    if (!isReady()) return { recorded: false, reason: "observability unavailable" };
    const context = evidence.objectiveID && evidence.runID
      ? { objectiveID: evidence.objectiveID, runID: evidence.runID }
      : contextForSession(evidence.parentSessionID);
    if (!context) return { recorded: false, reason: "objective context unavailable" };
    const acceptance = evidence.contributionID
      ? recordAcceptance({ ...evidence, objectiveID: context.objectiveID, runID: context.runID })
      : null;
    let outcome = null;
    if (evidence.objectiveOutcome) {
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
      outcome = emit({
        eventType: "objective.outcome", subjectId: context.objectiveID,
        sessionId: evidence.parentSessionID || null, correlationId: context.runID, payload,
      });
    }
    return {
      recorded: Boolean(acceptance || outcome),
      acceptanceEventID: acceptance?.eventId || null,
      outcomeEventID: outcome?.eventId || null,
      ...context,
    };
  }

  return { attach, begin, contextForSession, inherit, recordAcceptance, recordDecision };
}
