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
