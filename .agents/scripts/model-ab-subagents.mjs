// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolveRuntimeEventsDbPath } from "./runtime-events-store.mjs";

function observedRows(db, sql) {
  return JSON.parse(execFileSync("sqlite3", ["-readonly", "-json", db, sql],
    { encoding: "utf8", timeout: 10000 }) || "[]");
}

function collectChildRequests(experiment, db, arms) {
  // Keep SQL predicates independent of private-config strings.
  const rows = observedRows(db,
    "SELECT session_id, ab_experiment, ab_arm, tokens_total, cost FROM llm_requests WHERE ab_arm IS NOT NULL AND routing_population='interactive_child';");
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
  return sessions;
}

function collectParentReceipts(db, sessions, arms) {
  const receipts = observedRows(db,
    "SELECT subject_id, payload_json FROM runtime_events WHERE event_type='subagent.acceptance' ORDER BY id DESC;");
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
}

export function reportSubagents(experiment, db = resolveRuntimeEventsDbPath()) {
  const arms = Object.fromEntries(experiment.arms.map((arm) => [arm.name, {
    delegations: 0, accepted_unchanged: 0, accepted_repaired: 0,
    rejected: 0, interventions: 0, tokens: 0, cost: 0,
  }]));
  if (!existsSync(db)) return { experiment: experiment.id, arms, result: "no observed routes" };
  const sessions = collectChildRequests(experiment, db, arms);
  collectParentReceipts(db, sessions, arms);
  return { experiment: experiment.id, arms,
    result: "observed child routes and explicit parent receipts only; unreviewed completion is not acceptance" };
}
