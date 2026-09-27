// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { eligibleCreationDate } from "./model-ab-enrollment.mjs";
import { observeIssue } from "./model-ab-observe.mjs";
import { armModels, assignedIssueNumbers, assignmentPaths } from "./model-ab-store.mjs";
import { resolveRuntimeEventsDbPath } from "./runtime-events-store.mjs";

export function reportSubagents(experiment, db = resolveRuntimeEventsDbPath()) {
  const arms = Object.fromEntries(experiment.arms.map((arm) => [arm.name, {
    delegations: 0, accepted_unchanged: 0, accepted_repaired: 0,
    rejected: 0, interventions: 0, tokens: 0, cost: 0,
  }]));
  if (!existsSync(db)) return { experiment: experiment.id, arms, result: "no observed routes" };
  // The experiment ID is validated before entry. Keep SQL predicates independent
  // of user-controlled strings even when the CLI receives a private config file.
  const rows = JSON.parse(execFileSync("sqlite3", ["-readonly", "-json", db,
    "SELECT session_id, ab_experiment, ab_arm, tokens_total, cost FROM llm_requests WHERE ab_arm IS NOT NULL AND routing_population='interactive_child';"],
  { encoding: "utf8", timeout: 10000 }) || "[]");
  const sessions = new Map();
  for (const row of rows) {
    if (row.ab_experiment !== experiment.id || !Object.hasOwn(arms, row.ab_arm)) continue;
    if (!sessions.has(row.session_id)) {
      sessions.set(row.session_id, row.ab_arm);
      arms[row.ab_arm].delegations += 1;
    }
    if (sessions.get(row.session_id) !== row.ab_arm) continue;
    arms[row.ab_arm].tokens += Number(row.tokens_total) || 0;
    arms[row.ab_arm].cost += Number(row.cost) || 0;
  }
  const receipts = JSON.parse(execFileSync("sqlite3", ["-readonly", "-json", db,
    "SELECT subject_id, payload_json FROM runtime_events WHERE event_type='subagent.acceptance' ORDER BY id DESC;"],
  { encoding: "utf8", timeout: 10000 }) || "[]");
  const seen = new Set();
  for (const receipt of receipts) {
    const payload = JSON.parse(receipt.payload_json);
    const contribution = payload.contribution_id || receipt.subject_id;
    if (seen.has(contribution)) continue;
    seen.add(contribution);
    if (!contribution.startsWith("opencode-child:")) continue;
    const arm = sessions.get(contribution.slice("opencode-child:".length));
    if (!arm || !["accepted_unchanged", "accepted_repaired", "rejected"].includes(payload.contribution_outcome)) continue;
    arms[arm][payload.contribution_outcome] += 1;
    arms[arm].interventions += Number(payload.intervention_count) || 0;
  }
  return { experiment: experiment.id, arms,
    result: "observed child routes and explicit parent receipts only; unreviewed completion is not acceptance" };
}

function verifyAssignment(experiment, issue, item, fingerprint, assignedArm) {
  if (item.fingerprint !== fingerprint || item.arm !== assignedArm(experiment, experiment.repo, issue).name) {
    throw new Error("model A/B report refused changed assignment evidence");
  }
  if (!Number.isFinite(Date.parse(item.assigned_at))) {
    throw new Error("model A/B report refused changed assignment evidence");
  }
  if (experiment.enrollment && !eligibleCreationDate(experiment, item.created_at)) {
    throw new Error("model A/B report refused ineligible prospective assignment");
  }
}

export function snapshotAssignments(experiment, directory, assignedArm) {
  const fingerprint = createHash("sha256").update(JSON.stringify(experiment)).digest("hex");
  const arms = Object.fromEntries(experiment.arms.map((arm) => [arm.name,
    { assigned: 0, issues: [], assignments: [], models: armModels(arm) }]));
  const excluded = [];
  const issues = experiment.issues || assignedIssueNumbers(experiment.repo, directory);
  for (const issue of issues) {
    const { receipt } = assignmentPaths(experiment, experiment.repo, issue, directory);
    if (!existsSync(receipt)) { excluded.push(issue); continue; }
    const item = JSON.parse(readFileSync(receipt, "utf8"));
    if (experiment.enrollment && item.experiment !== experiment.id) continue;
    verifyAssignment(experiment, issue, item, fingerprint, assignedArm);
    arms[item.arm].assigned += 1;
    arms[item.arm].issues.push(issue);
    arms[item.arm].assignments.push({ issue, assigned_at: item.assigned_at });
  }
  return { experiment: experiment.id, repo: experiment.repo, arms, excluded,
    result: "assignment-only: join observed requests, escalations, merged-PR evidence and parent acceptance before comparing outcomes" };
}

// Observed models outside the arm's routes: availability fallbacks to another
// provider, legacy-arm tier escalations, or unexplained crossovers.
function withOffArmModels(arm, outcome) {
  const known = Array.isArray(arm.models) ? arm.models : null;
  const offArm = known ? (outcome.models || []).filter((model) => !known.includes(model)) : [];
  if (offArm.length > 0) arm.off_arm_issues += 1;
  return { ...outcome, off_arm_models: offArm };
}

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
      incomplete_evidence: 0, off_arm_issues: 0, observations: [] });
    for (const { issue, assigned_at: assignedAt } of arm.assignments
      || arm.issues.map((number) => ({ issue: number, assigned_at: null }))) {
      accumulate(arm, issue, withOffArmModels(arm, observe(assignments.repo, issue, assignedAt)));
    }
  }
  assignments.result = "observational: no automatic winner; compare verified delivery per assigned issue, escalation, fallbacks, retries, off-arm routes and parent acceptance only when coverage and cohorts support it";
  return assignments;
}
