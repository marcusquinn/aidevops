// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

const MAX_TASKS = 20;
const MAX_TEXT_LENGTH = 240;

export function boundedText(value) {
  return String(value ?? "")
    .replace(/(?:sk-|gh[pousr]_|github_pat_|glpat-|xox[baprs]-)[A-Za-z0-9_.-]{8,}/gi, "[redacted]")
    .replace(/\b(?:password|secret|token|api[_-]?key)\s*[:=]\s*\S+/gi, "credential=[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_TEXT_LENGTH);
}

function normalizedShape(value, key = "") {
  let normalized = null;
  if (/intent|password|secret|token|authorization|api.?key/i.test(key)) {
    normalized = "[redacted]";
  } else if (Array.isArray(value)) {
    normalized = value.slice(0, 20).map((item) => normalizedShape(item));
  } else if (value && typeof value === "object") {
    normalized = Object.fromEntries(
      Object.keys(value)
        .sort()
        .slice(0, 40)
        .map((childKey) => [childKey, normalizedShape(value[childKey], childKey)]),
    );
  } else if (typeof value === "string") {
    normalized = boundedText(value);
  } else if (["number", "boolean"].includes(typeof value)) {
    normalized = value;
  }
  return normalized;
}

export function operationFingerprint(toolName, args) {
  const shape = JSON.stringify({ tool: String(toolName || "unknown").toLowerCase(), args: normalizedShape(args || {}) });
  return createHash("sha256").update(shape).digest("hex");
}

export function classifyToolOutcome(output) {
  const text = String(output?.output || "").trim();
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  const failedStatuses = [
    "aborted", "blocked", "cancelled", "canceled", "denied", "error", "failed",
    "rejected", "timed_out", "timeout",
  ];
  const exitCode = [output?.metadata?.exit, output?.metadata?.exitCode, output?.metadata?.exit_code]
    .find((value) => Number.isInteger(value));

  let outcome = "success";
  if (/^BLOCKED by shared command policy\b/i.test(text)) {
    outcome = "policy_block";
  } else if (failedStatuses.includes(status) || output?.error || output?.metadata?.error) {
    outcome = "tool_error";
  } else if (exitCode !== undefined) {
    outcome = exitCode === 0 ? "success" : "command_failure";
  } else if (["completed", "success", "succeeded"].includes(status)) {
    outcome = "success";
  } else if (/^(?:error|failed|aborted|cancelled|canceled|tool execution aborted|operation timed out)\b/i.test(text)) {
    outcome = "tool_error";
  }
  return outcome;
}

export function toolOutcomeFailed(output) {
  return classifyToolOutcome(output) !== "success";
}

export function isExplicitCompletionClaim(text) {
  const normalized = String(text || "").replace(/`[^`]*`/g, " ");
  if (/\b(?:not|isn't|is not|aren't|are not)\s+(?:done|complete|completed|finished)\b/i.test(normalized)) return false;
  return /(?:^|[.!?]\s+)(?:FULL_LOOP_COMPLETE\b|(?:the\s+)?(?:task|work|implementation|objective|issue|request)\s+(?:is|has been)\s+(?:now\s+)?(?:done|complete|completed|finished)|(?:all|everything)\s+(?:is|has been)\s+(?:done|complete|completed|finished))/im.test(normalized);
}

// Ported from .agents/hooks/session_continuation_stop.py; keep both in sync.
// A path blocker pauses one route; a human dependency, a question, or a
// What next ask hands the whole turn back to the user.
const HUMAN_DEPENDENCY_RE = /\b(?:need|needs|require|requires|waiting (?:for|on)) (?:your|user|human|maintainer)\b/i;
const PATH_BLOCKER_RE = /\bBLOCKED\b|\bblocker\b|\bblocked (?:on|by)\b|\b(?:cannot|can't|unable to) (?:continue|proceed)\b/i;
// GH#34123: "no blocker", "not blocked", "without blockers" state the opposite.
const NEGATED_BLOCKER_RE = /\b(?:no|not|never|without|nothing)\s+(?:\w+\s+){0,2}?(?:blockers?|blocked)\b/gi;
// GH#34123: the What next field (reference/session.md) that lists user asks.
const NEEDED_FROM_YOU_RE = /Needed from you:[*_\s]*([^\n]*)/gi;
const NO_ASK_RE = /^(?:none|nothing|n\/a)\b/i;

function withoutCode(text) {
  return String(text || "").replace(/```[\s\S]*?```/g, " ").replace(/`[^`]*`/g, " ");
}

// GH#34123: a What next block whose "Needed from you" field holds anything
// but None lists numbered asks, so the turn is a deliberate handback.
function hasWhatNextAsk(normalized) {
  const values = [...normalized.matchAll(NEEDED_FROM_YOU_RE)].map((match) => match[1].trim());
  const last = values.at(-1);
  return Boolean(last) && !NO_ASK_RE.test(last);
}

function handsBackToUser(normalized) {
  const lines = normalized.split("\n").map((line) => line.trim().replace(/[*_` ]+$/, "")).filter(Boolean);
  if (lines.slice(-3).some((line) => line.endsWith("?"))) return true;
  return HUMAN_DEPENDENCY_RE.test(normalized) || hasWhatNextAsk(normalized);
}

export function reportsBlocker(text) {
  return PATH_BLOCKER_RE.test(withoutCode(text).replace(NEGATED_BLOCKER_RE, " "));
}

// GH#33888: true when the text reports a blocker without asking the user a
// question, naming a human dependency, or listing a What next ask, so other
// active todos may continue.
export function isPathBlockerYield(text) {
  const normalized = withoutCode(text);
  if (handsBackToUser(normalized)) return false;
  return reportsBlocker(normalized);
}

export function sessionId(input) {
  return String(input?.sessionID || input?.sessionId || input?.session?.id || "unknown-session");
}

function terminalTodoStatus(status) {
  return ["completed", "cancelled", "canceled"].includes(String(status || "").toLowerCase());
}

export function activeTodos(todos) {
  if (!Array.isArray(todos)) return [];
  return todos
    .filter((todo) => !terminalTodoStatus(todo?.status))
    .slice(0, MAX_TASKS)
    .map((todo) => boundedText(todo?.content || todo?.title || "Unresolved task"));
}

export function capMap(map, maxEntries) {
  while (map.size > maxEntries) map.delete(map.keys().next().value);
}
