// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#35968: repeated-operation detection for the session continuation guard.
// A bounded per-scope window of operation fingerprints detects cycles of
// period 1-4 (A,A,A / A,B,A,B / ...), whether the calls fail or succeed.
// Only evidence of progress (a new edit, a changed todo set) clears it.

import { createHash } from "node:crypto";
import { boundedText, editedPaths, operationFingerprint } from "./session-continuation-utils.mjs";

export const MAX_LOOP_PERIOD = 4;
// Successful calls repeat legitimately more often than failing ones (status
// reads, re-checks), so an all-success cycle needs extra repetitions and an
// identical output on every repetition before it counts as non-progress.
export const SUCCESS_EXTRA_REPEATS = 2;
const MIN_WINDOW = 20;
const MAX_SEEN_EDITS = 20;
const POLL_ACTIONS = new Set(["status", "output"]);

export function loopWindowSize(threshold) {
  return Math.max(MIN_WINDOW, (threshold + SUCCESS_EXTRA_REPEATS) * MAX_LOOP_PERIOD);
}

// Designed polling: the bounded-operation tool's status/output actions are
// the documented way to wait on a long-running command.
export function isDesignedPoll(tool, args) {
  return /(?:^|[_.:/])aidevops_bounded_operation$/.test(String(tool || ""))
    && POLL_ACTIONS.has(String(args?.action || "").toLowerCase());
}

function outputDigest(output) {
  return createHash("sha256").update(String(output?.output ?? "")).digest("hex").slice(0, 16);
}

export function loopEntry(call, output, failed) {
  return {
    fp: operationFingerprint(call.tool, call.args),
    tool: String(call.tool || "unknown"),
    failed,
    out: outputDigest(output),
  };
}

export function emptyLoopState() {
  return { window: [], seenEdits: [], signaled: new Set(), todos: null };
}

function todoDigest(todos) {
  if (!Array.isArray(todos)) return "";
  return todos.map((todo) => `${String(todo?.content ?? "")}\u0000${String(todo?.status ?? "")}`).join("\n");
}

// A successful edit with arguments not seen before in this scope, or a
// TodoWrite that changes any task or status, is evidence of progress.
export function isProgress(loop, call, entry) {
  if (entry.failed) return false;
  if (String(call.tool || "").toLowerCase() === "todowrite") {
    const digest = todoDigest(call.args?.todos);
    const changed = digest !== loop.todos;
    loop.todos = digest;
    return changed;
  }
  if (editedPaths(call.tool, call.args).length === 0) return false;
  if (loop.seenEdits.includes(entry.fp)) return false;
  loop.seenEdits.push(entry.fp);
  if (loop.seenEdits.length > MAX_SEEN_EDITS) loop.seenEdits.shift();
  return true;
}

export function recordLoopEntry(loop, entry, progress, threshold) {
  if (progress) {
    loop.window = [];
    loop.signaled.clear();
  }
  loop.window.push(entry);
  const size = loopWindowSize(threshold);
  if (loop.window.length > size) loop.window.splice(0, loop.window.length - size);
}

function sameStep(a, b, matchOutput) {
  return a.fp === b.fp && a.failed === b.failed && (!matchOutput || a.out === b.out);
}

function repeatsWithPeriod(window, period, length, matchOutput) {
  if (window.length < length) return false;
  for (let i = window.length - length + period; i < window.length; i += 1) {
    if (!sameStep(window[i], window[i - period], matchOutput)) return false;
  }
  return true;
}

// Returns the shortest repeating trailing cycle, or null. The signature is
// rotation-independent so one loop is signalled once, not once per phase.
export function detectLoop(window, threshold) {
  for (let period = 1; period <= Math.min(MAX_LOOP_PERIOD, window.length); period += 1) {
    const cycle = window.slice(-period);
    const failing = cycle.some((entry) => entry.failed);
    const repeats = failing ? threshold : threshold + SUCCESS_EXTRA_REPEATS;
    if (!repeatsWithPeriod(window, period, repeats * period, !failing)) continue;
    const tools = cycle.map((entry) => entry.tool);
    return {
      period,
      repeats,
      kind: failing ? "failure" : "success",
      description: failing ? "failing" : "non-progressing",
      tools,
      label: boundedText(tools.join(" -> ")),
      signature: cycle.map((entry) => `${entry.fp}:${entry.failed ? 1 : 0}`).sort().join("|"),
    };
  }
  return null;
}
