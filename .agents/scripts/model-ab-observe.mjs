// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolveRuntimeEventsDbPath } from "./runtime-events-store.mjs";

const feedback = fileURLToPath(new URL("./routing-feedback.mjs", import.meta.url));

function command(executable, args) {
  return execFileSync(executable, args, {
    encoding: "utf8", timeout: 10000, stdio: ["ignore", "pipe", "ignore"],
  });
}

function acceptanceEvents(session) {
  if (!/^ses_[a-zA-Z0-9]+$/.test(session)) throw new Error("invalid session identity");
  const db = resolveRuntimeEventsDbPath();
  if (!existsSync(db)) throw new Error("runtime event store unavailable");
  const rows = command("sqlite3", ["-readonly", "-json", db,
    `SELECT occurred_at, payload_json FROM runtime_events WHERE event_type='subagent.acceptance' AND session_id='${session}' ORDER BY id DESC LIMIT 1000;`]);
  return rows.trim() ? JSON.parse(rows) : [];
}

function linkedMerge(repo, issue, assignedAt) {
  try {
    const entry = JSON.parse(command("gh", ["issue", "view", String(issue), "--repo", repo,
      "--json", "state,closedByPullRequestsReferences"]));
    if (entry.state !== "CLOSED") return "pending";
    for (const pr of entry.closedByPullRequestsReferences || []) {
      const detail = JSON.parse(command("gh", ["pr", "view", String(pr.number), "--repo", repo,
        "--json", "state,mergedAt"]));
      if (detail.state === "MERGED" && detail.mergedAt && assignedAt
        && Date.parse(detail.mergedAt) >= Date.parse(assignedAt)) return "verified";
    }
    return "unverified_closure";
  } catch {
    return "unknown";
  }
}

function consumeAcceptance(events, assignedAt, seen, accepted) {
  let interventions = 0;
  for (const event of events) {
    if (!assignedAt || Date.parse(event.occurred_at) < Date.parse(assignedAt)) continue;
    const payload = JSON.parse(event.payload_json);
    if (!payload.contribution_id || seen.has(payload.contribution_id)) continue;
    seen.add(payload.contribution_id);
    if (["accepted_unchanged", "accepted_repaired"].includes(payload.contribution_outcome)) {
      accepted.add(payload.contribution_id);
      interventions += Number(payload.intervention_count) || 0;
    }
  }
  return interventions;
}

function parentAcceptance(metrics, assignedAt) {
  const accepted = new Set();
  const seen = new Set();
  let interventions = 0;
  let available = Boolean(metrics?.sessionIDs?.some((session) => session.startsWith("ses_")));
  for (const session of metrics?.sessionIDs || []) {
    if (!session.startsWith("ses_")) continue;
    try {
      interventions += consumeAcceptance(acceptanceEvents(session), assignedAt, seen, accepted);
    } catch { available = false; }
  }
  return { accepted_subagents: available ? accepted.size : null,
    parent_interventions: available ? interventions : null };
}

export function observeIssue(repo, issue, assignedAt) {
  let metrics;
  try {
    metrics = JSON.parse(command(process.execPath, [feedback, "--repo", repo,
      "--issue", String(issue), "--format", "json"]));
  } catch { metrics = null; }
  return {
    delivery: linkedMerge(repo, issue, assignedAt),
    route_observed: Boolean(metrics?.hasData),
    models: metrics?.models || [], model_variants: metrics?.modelVariants || [],
    escalations: metrics?.escalationCount || 0, fallbacks: metrics?.candidateFallbackCount || 0,
    retries: metrics?.retryCount || 0, request_errors: metrics?.requestErrorCount || 0,
    failed_attempts: metrics?.failedAttemptCount || 0,
    delegation_count: metrics?.delegationCount || 0,
    ...parentAcceptance(metrics, assignedAt),
  };
}
