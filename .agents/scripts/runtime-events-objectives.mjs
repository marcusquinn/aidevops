// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/** Validation for optional, append-only objective and contribution evidence. */

const OBJECTIVE_EVENT_TYPES = new Set([
  "objective.started",
  "objective.session.attached",
  "objective.outcome",
  "subagent.acceptance",
]);
const OBJECTIVE_OUTCOMES = new Set([
  "verified", "accepted_unverified", "failed", "cancelled", "incomplete", "unknown",
]);
const CONTRIBUTION_OUTCOMES = new Set([
  "accepted_unchanged", "accepted_repaired", "rejected", "reused", "unknown",
]);

function opaqueId(value, name, { required = true } = {}) {
  if ((value === undefined || value === null || value === "") && !required) return;
  if (typeof value !== "string" || value.length > 256 || !/^[A-Za-z0-9:_-]+$/.test(value)) {
    throw new TypeError(`${name} must be a bounded opaque identifier`);
  }
}

function requiredValue(value, name) {
  if (typeof value !== "string" || value.length < 1 || value.length > 128) {
    throw new TypeError(`${name} is required`);
  }
}

function requireObjectiveIdentity(payload, { contribution = false } = {}) {
  opaqueId(payload.objective_id, "objective_id");
  opaqueId(payload.run_id, "run_id");
  opaqueId(payload.attempt_id, "attempt_id", { required: false });
  if (contribution) opaqueId(payload.contribution_id, "contribution_id");
}

function validateAttachment(payload) {
  requireObjectiveIdentity(payload, { contribution: true });
  const requestIds = payload.request_ids;
  if (!Array.isArray(requestIds) || requestIds.length < 1 || requestIds.length > 128) {
    throw new TypeError("objective attachment requires bounded request_ids");
  }
  for (const requestId of requestIds) opaqueId(requestId, "request_id");
  requiredValue(payload.boundary, "boundary");
  if (!["unique", "unallocated"].includes(payload.allocation)) {
    throw new TypeError("objective attachment allocation must be unique or unallocated");
  }
}

function validateOutcome(payload) {
  requireObjectiveIdentity(payload);
  if (!OBJECTIVE_OUTCOMES.has(payload.outcome)) throw new TypeError("unknown objective outcome");
  requiredValue(payload.source, "source");
  requiredValue(payload.observed_at, "observed_at");
  requiredValue(payload.policy_version, "policy_version");
  if (payload.outcome !== "verified") return;
  requiredValue(payload.evidence_kind, "evidence_kind");
  requiredValue(payload.evidence_fingerprint, "evidence_fingerprint");
  requiredValue(payload.observer, "observer");
  if (["caller", "self", "unknown"].includes(payload.observer)) {
    throw new TypeError("verified outcome requires an independent observer");
  }
}

function validateAcceptance(payload) {
  requireObjectiveIdentity(payload, { contribution: true });
  if (!CONTRIBUTION_OUTCOMES.has(payload.contribution_outcome)) {
    throw new TypeError("unknown contribution outcome");
  }
  requiredValue(payload.source, "source");
  requiredValue(payload.observed_at, "observed_at");
  requiredValue(payload.policy_version, "policy_version");
  const interventions = payload.intervention_count;
  if (!Number.isSafeInteger(interventions) || interventions < 0 || interventions > 1000) {
    throw new TypeError("intervention_count must be a bounded non-negative integer");
  }
  opaqueId(payload.repair_contribution_id, "repair_contribution_id", { required: false });
}

const OBJECTIVE_VALIDATORS = Object.freeze({
  "objective.outcome": validateOutcome,
  "objective.session.attached": validateAttachment,
  "objective.started": requireObjectiveIdentity,
  "subagent.acceptance": validateAcceptance,
});

/** Reject malformed objective evidence before it can be silently recorded. */
export function validateObjectiveRuntimeEvent(eventType, payload = {}) {
  if (!OBJECTIVE_EVENT_TYPES.has(eventType)) return;
  if (payload.objective_version !== 1) throw new TypeError("objective evidence requires objective_version 1");
  OBJECTIVE_VALIDATORS[eventType](payload);
}

export function isObjectiveRuntimeEvent(eventType) {
  return OBJECTIVE_EVENT_TYPES.has(eventType);
}
