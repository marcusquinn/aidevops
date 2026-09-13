// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  cleanWorkerBlockerIssueNumber,
  normalizeWorkerBlockerRepoSlug,
  normalizeWorkerBlockerRequestId,
  normalizeWorkerBlockerSessionKey,
} from "./worker-blocker-log.mjs";
import {
  activeWorkerBlockerEventsMatching,
  reconcileWorkerBlockers,
} from "./worker-blocker-reconcile-common.mjs";

function workerBlockerSessionScope(input, options) {
  const issueNumber = cleanWorkerBlockerIssueNumber(input.issue_number);
  const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
  const sessionKey = normalizeWorkerBlockerSessionKey(input.session_key, options);
  const requestId = normalizeWorkerBlockerRequestId(input.request_id, options);
  if (!repoSlug.includes("/") || !sessionKey) throw new Error("Invalid worker blocker session scope");
  return { issueNumber, repoSlug, sessionKey, requestId };
}

function sessionEventMatchesScope(event, scope) {
  const eventRepo = String(event.repo_slug || "").toLowerCase();
  const eventIssue = cleanWorkerBlockerIssueNumber(event.issue_number);
  const eventSession = typeof event.session_key === "string" ? event.session_key : "";
  const eventRequest = event.request_id === null || event.request_id === undefined
    ? ""
    : String(event.request_id);
  return eventRepo === scope.repoSlug
    && eventIssue === scope.issueNumber
    && eventSession === scope.sessionKey
    && (!scope.requestId || eventRequest === scope.requestId);
}

function activeWorkerBlockerSessionEvents(logPath, scope) {
  return activeWorkerBlockerEventsMatching(
    logPath,
    (event) => sessionEventMatchesScope(event, scope),
  );
}

function terminalSessionWorkerBlockerEvents(active, input) {
  return active.map((event) => ({
    event: input.event || "session_terminal_reconciled",
    status: input.status || "resolved",
    reason: input.reason || "session_terminal",
    blocking: false,
    source: input.source || "worker-blocker-log",
    issue_number: event.issue_number ?? null,
    repo_slug: event.repo_slug || "",
    session_key: event.session_key || "",
    request_id: event.request_id ?? "",
    permission: event.permission || "",
    tool: event.tool || "",
    risk_level: event.risk_level || "",
    grantable: typeof event.grantable === "boolean" ? event.grantable : null,
    detail: input.detail || "",
  }));
}

function staleSupervisorSessionScope(input, options) {
  const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
  const sessionKey = normalizeWorkerBlockerSessionKey(input.session_key, options);
  const staleBefore = Number(input.stale_before);
  if (repoSlug || sessionKey !== "supervisor-pulse" || !Number.isSafeInteger(staleBefore) || staleBefore <= 0) {
    throw new Error("Invalid stale supervisor blocker scope");
  }
  return { staleBefore };
}

function activeStaleSupervisorSessionEvents(logPath, scope) {
  return activeWorkerBlockerEventsMatching(logPath, (event) => (
    event.repo_slug === ""
    && event.session_key === "supervisor-pulse"
    && String(event.source || "").includes("supervisor-pulse")
    && (event.event === "stale_supervisor_session_terminal_reconciled"
      || (Number.isFinite(Number(event.ts)) && Number(event.ts) <= scope.staleBefore))
  ));
}

function terminalStaleSupervisorSessionEvents(active) {
  return active.map((event) => ({
    event: "stale_supervisor_session_terminal_reconciled",
    status: "resolved",
    reason: "verified_stale_supervisor_session",
    blocking: false,
    source: "worker-blocker-stale-supervisor-pulse-reconcile",
    issue_number: event.issue_number ?? null,
    // Preserve the unscoped identity without falling back to the worker's repository environment.
    repo_slug: " ",
    session_key: "supervisor-pulse",
    request_id: event.request_id ?? "",
    permission: event.permission || "",
    tool: event.tool || "",
    risk_level: event.risk_level || "",
    grantable: typeof event.grantable === "boolean" ? event.grantable : null,
    detail: "Reconciled after explicit stale cutoff; original blocker evidence retained.",
  }));
}

const SESSION_RECONCILIATION_CONTRACT = {
  resolveScope: workerBlockerSessionScope,
  activeEvents: activeWorkerBlockerSessionEvents,
  terminalEvents: terminalSessionWorkerBlockerEvents,
};

const STALE_SUPERVISOR_SESSION_RECONCILIATION_CONTRACT = {
  resolveScope: staleSupervisorSessionScope,
  activeEvents: activeStaleSupervisorSessionEvents,
  terminalEvents: terminalStaleSupervisorSessionEvents,
};

export function resolveWorkerBlockersForSession(input = {}, options = {}) {
  return reconcileWorkerBlockers(input, options, SESSION_RECONCILIATION_CONTRACT);
}

export function resolveStaleSupervisorWorkerBlockers(input = {}, options = {}) {
  return reconcileWorkerBlockers(input, options, STALE_SUPERVISOR_SESSION_RECONCILIATION_CONTRACT);
}
