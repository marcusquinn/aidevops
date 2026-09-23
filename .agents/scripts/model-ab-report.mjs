// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { observeIssue } from "./model-ab-observe.mjs";

function accumulate(arm, issue, outcome) {
  arm.observations.push({ issue, ...outcome });
  if (outcome.delivery === "verified") arm.verified += 1;
  else if (outcome.delivery === "pending") arm.pending += 1;
  else arm.unknown += 1;
  arm.escalations += outcome.escalations;
  arm.fallbacks += outcome.fallbacks;
  arm.retries += outcome.retries;
  arm.failed_attempts += outcome.failed_attempts || 0;
  arm.request_errors += outcome.request_errors || 0;
  arm.delegations += outcome.delegation_count || 0;
  arm.accepted_subagents += outcome.accepted_subagents || 0;
  arm.parent_interventions += outcome.parent_interventions || 0;
  if (!outcome.route_observed || outcome.accepted_subagents === null) arm.incomplete_evidence += 1;
}

export function aggregateObserved(assignments, observe = observeIssue) {
  for (const arm of Object.values(assignments.arms)) {
    Object.assign(arm, { verified: 0, pending: 0, unknown: 0, escalations: 0,
      fallbacks: 0, retries: 0, failed_attempts: 0, request_errors: 0,
      delegations: 0, accepted_subagents: 0, parent_interventions: 0,
      incomplete_evidence: 0, observations: [] });
    for (const { issue, assigned_at: assignedAt } of arm.assignments
      || arm.issues.map((number) => ({ issue: number, assigned_at: null }))) {
      const outcome = observe(assignments.repo, issue, assignedAt);
      accumulate(arm, issue, outcome);
    }
  }
  assignments.result = "observational: no automatic winner; compare verified delivery per assigned issue, escalation, fallbacks, retries and parent acceptance only when coverage and cohorts support it";
  return assignments;
}
