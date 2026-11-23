// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#39048: OpenCode 1.19 raises `doom_loop` only when the last three parts of
// the current assistant message are identical tool calls, i.e. one response
// emitting three identical calls in parallel; sequential polls across turns
// never trigger it. Workers sometimes fan out identical bounded-operation
// `status` / `output` polls in one response. Those are read-only and bounded
// by the response, so the duplicate is waste, not a loop, but rejecting it
// ended the whole worker session and lost its progress. Only these polls
// pass; start/cancel and every other tool's doom loop keep their gate.

import { createHash } from "crypto";
import { recordPermissionBlocker } from "./permission-broker-blocker-log.mjs";
import { isDesignedPoll } from "./session-continuation-loops.mjs";

function doomLoopTool(request) {
  const tool = request?.metadata?.tool;
  if (typeof tool === "string" && tool.length > 0) return tool;
  const patterns = Array.isArray(request?.patterns) ? request.patterns : [request?.pattern];
  return patterns.length === 1 && typeof patterns[0] === "string" ? patterns[0] : "";
}

export function isDesignedPollDoomLoop(request) {
  const permission = request?.permission || request?.type || "";
  if (permission !== "doom_loop") return false;
  return isDesignedPoll(doomLoopTool(request), request?.metadata?.input);
}

// One non-blocking audit event per polled operation, not per poll. The caller
// passes its sanitizer so this module does not import the broker back.
export function recordDesignedPollAllow(context, raw, sanitize) {
  const input = raw?.metadata?.input || {};
  const tool = sanitize(raw?.metadata?.tool || "", { home: context.home, maxLength: 100 });
  const operation = sanitize(String(input.operation_id || ""), { home: context.home, maxLength: 100 });
  const key = `${raw?.sessionID || ""}\n${tool}\n${operation}`;
  recordPermissionBlocker({
    loggedEvents: context.loggedEvents,
    home: context.home,
    blockerLogPath: context.blockerLogPath,
    capture: null,
    request: {
      request_id: `designed-poll-${createHash("sha256").update(key).digest("hex").slice(0, 16)}`,
      permission: "doom_loop",
      tool,
      risk: { level: "low", grantable: true },
    },
    event: "permission_designed_poll_allowed",
    reason: "designed_poll",
    detail: `Auto-allowed repeated read-only ${String(input.action || "").slice(0, 20)} poll of ${operation || "a bounded operation"}`,
    status: "allowed",
    blocking: false,
  });
}
