// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const DEFAULT_FAILURE_THRESHOLD = 3;
const DEFAULT_MAX_SCOPES = 32;
const MAX_TASKS = 20;
const MAX_TEXT_LENGTH = 240;
const COMPLETION_CORRECTION_MARKER = "<!-- SESSION_CONTINUATION_GUARD -->";

function boundedText(value) {
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

export function toolOutcomeFailed(output) {
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  if (["error", "failed", "aborted", "cancelled", "canceled", "timeout", "timed_out"].includes(status)) return true;
  if (output?.error || output?.metadata?.error) return true;
  if (Number.isInteger(output?.metadata?.exitCode) && output.metadata.exitCode !== 0) return true;
  const text = String(output?.output || "").trim();
  return /^(?:error|failed|aborted|cancelled|canceled|tool execution aborted|operation timed out)\b/i.test(text);
}

export function isExplicitCompletionClaim(text) {
  const normalized = String(text || "").replace(/`[^`]*`/g, " ");
  if (/\b(?:not|isn't|is not|aren't|are not)\s+(?:done|complete|completed|finished)\b/i.test(normalized)) return false;
  return /(?:^|[.!?]\s+)(?:FULL_LOOP_COMPLETE\b|(?:the\s+)?(?:task|work|implementation|objective|issue|request)\s+(?:is|has been)\s+(?:now\s+)?(?:done|complete|completed|finished)|(?:all|everything)\s+(?:is|has been)\s+(?:done|complete|completed|finished))/im.test(normalized);
}

function sessionId(input) {
  return String(input?.sessionID || input?.sessionId || input?.session?.id || "unknown-session");
}

function terminalTodoStatus(status) {
  return ["completed", "cancelled", "canceled"].includes(String(status || "").toLowerCase());
}

function activeTodos(todos) {
  if (!Array.isArray(todos)) return [];
  return todos
    .filter((todo) => !terminalTodoStatus(todo?.status))
    .slice(0, MAX_TASKS)
    .map((todo) => boundedText(todo?.content || todo?.title || "Unresolved task"));
}

function capMap(map, maxEntries) {
  while (map.size > maxEntries) map.delete(map.keys().next().value);
}

function defaultCheckpointAdapter(checkpointHelper, repository, qualityLog) {
  const helperPath = checkpointHelper ? resolve(checkpointHelper) : "";

  function run(args, capture = false) {
    if (!helperPath) return "";
    try {
      return execFileSync("bash", [helperPath, ...args], {
        cwd: repository,
        encoding: "utf8",
        stdio: capture ? ["ignore", "pipe", "ignore"] : "ignore",
        timeout: 5000,
      }) || "";
    } catch (error) {
      qualityLog?.("WARN", `[session-continuation] checkpoint command failed: ${boundedText(error?.message)}`);
      return "";
    }
  }

  return {
    load() {
      const raw = run(["recovery-status", "--json"], true);
      if (!raw) return null;
      try {
        return JSON.parse(raw);
      } catch {
        return null;
      }
    },
    save(recovery) {
      run([
        "recovery-save",
        "--session", recovery.session,
        "--objective", recovery.objective,
        "--directions", recovery.directions,
        "--trigger", recovery.trigger,
        "--completed", recovery.completed,
        "--remaining", recovery.remaining,
        "--unsafe-route", recovery.unsafeRoute,
        "--next-safe-route", recovery.nextSafeRoute,
        "--resume-condition", recovery.resumeCondition,
        "--owner", recovery.owner,
        "--status", recovery.status,
      ]);
    },
    resolve(evidence) {
      run(["recovery-resolve", "--evidence", boundedText(evidence)]);
    },
  };
}

export function createSessionContinuationGuard(options = {}) {
  const repository = String(options.repository || process.cwd());
  const threshold = options.failureThreshold || DEFAULT_FAILURE_THRESHOLD;
  const maxScopes = options.maxScopes || DEFAULT_MAX_SCOPES;
  const qualityLog = options.qualityLog;
  const adapter = options.checkpointAdapter || defaultCheckpointAdapter(options.checkpointHelper, repository, qualityLog);
  const calls = new Map();
  const failures = new Map();
  const tasks = new Map();
  const recoveries = new Map();
  const loadedScopes = new Set();

  function scopeFor(input) {
    return `${repository}\u0000${sessionId(input)}`;
  }

  function loadRecovery(scope) {
    if (loadedScopes.has(scope)) return recoveries.get(scope) || null;
    loadedScopes.add(scope);
    const loaded = adapter.load?.();
    if (loaded?.status && loaded.status !== "none") recoveries.set(scope, loaded);
    capMap(recoveries, maxScopes);
    return recoveries.get(scope) || null;
  }

  function remainingFor(scope, recovery = null) {
    const active = tasks.get(scope) || [];
    if (active.length > 0) return active.join("; ");
    return boundedText(recovery?.remaining || "Replan the failed operation and verify the original objective");
  }

  function resolveScope(scope, evidence) {
    const recovery = loadRecovery(scope);
    tasks.set(scope, []);
    if (recovery?.unresolved || ["recovering", "blocked"].includes(recovery?.status)) {
      adapter.resolve?.(evidence);
      recoveries.set(scope, { ...recovery, status: "resolved", unresolved: false, resolutionEvidence: boundedText(evidence) });
    }
  }

  function beforeTool(input, output) {
    const callID = String(input?.callID || "");
    if (!callID) return;
    calls.set(callID, {
      scope: scopeFor(input),
      tool: String(input?.tool || "unknown"),
      args: output?.args || {},
    });
    capMap(calls, maxScopes * 4);
  }

  function afterTool(input, output) {
    const callID = String(input?.callID || "");
    const call = calls.get(callID) || {
      scope: scopeFor(input),
      tool: String(input?.tool || "unknown"),
      args: input?.args || {},
    };
    calls.delete(callID);
    const failed = toolOutcomeFailed(output);

    if (!failed && call.tool.toLowerCase() === "todowrite") {
      const active = activeTodos(call.args?.todos);
      tasks.set(call.scope, active);
      capMap(tasks, maxScopes);
      const recovery = loadRecovery(call.scope);
      if (active.length === 0 && recovery?.unresolved) {
        resolveScope(call.scope, "All tracked session tasks reached a terminal state.");
      }
    }

    if (!failed) {
      failures.delete(call.scope);
      return { failed: false, replan: false };
    }

    const fingerprint = operationFingerprint(call.tool, call.args);
    const previous = failures.get(call.scope);
    const failure = previous?.fingerprint === fingerprint
      ? { ...previous, count: previous.count + 1 }
      : { fingerprint, count: 1, signaled: false, tool: call.tool };
    failures.set(call.scope, failure);
    capMap(failures, maxScopes);

    if (failure.count < threshold || failure.signaled) return { failed: true, replan: false, count: failure.count };
    failure.signaled = true;
    const sessionHash = createHash("sha256").update(sessionId(input)).digest("hex").slice(0, 12);
    const recovery = {
      status: "recovering",
      unresolved: true,
      session: `sha256:${sessionHash}`,
      objective: "Continue the active session objective without discarding unresolved work.",
      directions: "Preserve active todos and do not rerun an unsafe command under unchanged conditions.",
      trigger: `${threshold} identical ${boundedText(call.tool)} operations failed or aborted under unchanged conditions.`,
      completed: "No additional acceptance criterion was verified by the failed operation.",
      remaining: remainingFor(call.scope),
      unsafeRoute: `Repeat the same ${boundedText(call.tool)} operation without changed conditions.`,
      nextSafeRoute: "Change the operation arguments or execution conditions, then resume the first unresolved criterion.",
      resumeCondition: "A materially changed operation succeeds and all remaining criteria reach a terminal state.",
      owner: `session:${sessionHash}`,
    };
    recoveries.set(call.scope, recovery);
    loadedScopes.add(call.scope);
    capMap(recoveries, maxScopes);
    adapter.save?.(recovery);

    const correction = `[AIDevOps recovery guard] ${threshold} identical ${boundedText(call.tool)} failures detected. Do not repeat this operation unchanged. Continue by changing its arguments or conditions and preserving the unresolved criteria in the recovery checkpoint.`;
    output.output = `${String(output.output || "").trim()}\n\n${correction}`.trim();
    qualityLog?.("WARN", `[session-continuation] repeated ${boundedText(call.tool)} failure checkpointed for session ${sessionHash}`);
    return { failed: true, replan: true, count: failure.count, correction };
  }

  function completeText(input, output) {
    if (!isExplicitCompletionClaim(output?.text)) return { corrected: false };
    const scope = scopeFor(input);
    const recovery = loadRecovery(scope);
    const active = tasks.get(scope) || [];
    const unresolvedRecovery = recovery?.unresolved || ["recovering", "blocked"].includes(recovery?.status);
    if (active.length === 0 && !unresolvedRecovery) return { corrected: false };
    if (String(output.text).includes(COMPLETION_CORRECTION_MARKER)) return { corrected: true };

    const remaining = remainingFor(scope, recovery);
    const nextAction = boundedText(recovery?.nextSafeRoute || `Continue the first active task: ${active[0] || remaining}`);
    output.text = `${output.text}\n\n${COMPLETION_CORRECTION_MARKER}\nCompletion is not yet valid. Remaining criteria: ${remaining}. Continue with: ${nextAction}.`;
    qualityLog?.("WARN", `[session-continuation] corrected premature completion claim for session ${createHash("sha256").update(sessionId(input)).digest("hex").slice(0, 12)}`);
    return { corrected: true, remaining, nextAction };
  }

  return {
    beforeTool,
    afterTool,
    completeText,
    resolve(input, evidence) {
      resolveScope(scopeFor(input), evidence || "Objective explicitly reached a terminal condition.");
    },
    getState(input) {
      const scope = scopeFor(input);
      return { failure: failures.get(scope) || null, tasks: tasks.get(scope) || [], recovery: loadRecovery(scope) };
    },
  };
}

export { COMPLETION_CORRECTION_MARKER };
