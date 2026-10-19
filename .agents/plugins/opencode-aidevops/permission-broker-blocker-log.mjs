// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { appendWorkerBlockerEvent } from "../../scripts/worker-blocker-log.mjs";

export function recordPermissionBlocker({ loggedEvents, home, blockerLogPath, capture, request, event, reason, detail, status = "blocked", blocking = true }) {
  const dedupeKey = `${event}:${request?.request_id || "unknown"}`;
  if (loggedEvents.has(dedupeKey)) return;
  loggedEvents.add(dedupeKey);
  while (loggedEvents.size > 100) loggedEvents.delete(loggedEvents.values().next().value);
  appendWorkerBlockerEvent({
    event,
    status,
    reason,
    blocking,
    source: "opencode-permission-broker",
    issue_number: capture?.issue || process.env.WORKER_ISSUE_NUMBER || "",
    repo_slug: capture?.repo || process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "",
    session_key: capture?.worker_session || process.env.WORKER_SESSION_KEY || "",
    request_id: request?.request_id || "",
    permission: request?.permission || "",
    tool: request?.tool || "",
    risk_level: request?.risk?.level || "",
    grantable: request?.risk?.grantable,
    detail,
  }, { home, logPath: blockerLogPath });
}
