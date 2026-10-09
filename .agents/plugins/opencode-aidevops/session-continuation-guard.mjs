// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import {
  activeTodos,
  boundedText,
  capMap,
  classifyToolOutcome,
  isExplicitCompletionClaim,
  isPathBlockerYield,
  operationFingerprint,
  sessionId,
  toolOutcomeFailed,
} from "./session-continuation-utils.mjs";

const DEFAULT_FAILURE_THRESHOLD = 3;
const DEFAULT_MAX_SCOPES = 32;
const STEERING_PREFIX = "[aidevops continuation guard]";

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

function scopeFor(state, input) {
  return `${state.repository}\u0000${sessionId(input)}`;
}

function loadRecovery(state, scope) {
  if (state.loadedScopes.has(scope)) return state.recoveries.get(scope) || null;
  state.loadedScopes.add(scope);
  const loaded = state.adapter.load?.();
  const isObject = loaded !== null && typeof loaded === "object";
  const isRecord = isObject && !Array.isArray(loaded);
  const status = isRecord && typeof loaded.status === "string" ? loaded.status : null;
  if (status && status !== "none") {
    state.recoveries.set(scope, loaded);
  }
  capMap(state.recoveries, state.maxScopes);
  return state.recoveries.get(scope) || null;
}

function remainingFor(state, scope, recovery = null) {
  const active = state.tasks.get(scope) || [];
  if (active.length > 0) return active.join("; ");
  return boundedText(recovery?.remaining || "Replan the failed operation and verify the original objective");
}

function resolveScope(state, scope, evidence) {
  const recovery = loadRecovery(state, scope);
  state.tasks.set(scope, []);
  if (recovery?.unresolved || ["recovering", "blocked"].includes(recovery?.status)) {
    state.adapter.resolve?.(evidence);
    state.recoveries.set(scope, { ...recovery, status: "resolved", unresolved: false, resolutionEvidence: boundedText(evidence) });
  }
}

function beforeTool(state, input, output) {
  // GH#34123: a later tool call means the text was not the turn's yield, so
  // steering queued from it is stale.
  state.steering.delete(sessionId(input));
  const callID = String(input?.callID || "");
  if (!callID) return;
  state.calls.set(callID, {
    scope: scopeFor(state, input),
    tool: String(input?.tool || "unknown"),
    args: output?.args || {},
  });
  capMap(state.calls, state.maxScopes * 4);
}

function afterTool(state, input, output) {
  const callID = String(input?.callID || "");
  const call = state.calls.get(callID) || {
    scope: scopeFor(state, input),
    tool: String(input?.tool || "unknown"),
    args: input?.args || {},
  };
  state.calls.delete(callID);
  const failed = toolOutcomeFailed(output);

  if (!failed && call.tool.toLowerCase() === "todowrite") {
    const active = activeTodos(call.args?.todos);
    state.tasks.set(call.scope, active);
    capMap(state.tasks, state.maxScopes);
    const recovery = loadRecovery(state, call.scope);
    if (active.length === 0 && recovery?.unresolved) {
      resolveScope(state, call.scope, "All tracked session tasks reached a terminal state.");
    }
  }

  if (!failed) {
    state.failures.delete(call.scope);
    return { failed: false, replan: false };
  }

  const fingerprint = operationFingerprint(call.tool, call.args);
  const previous = state.failures.get(call.scope);
  const failure = previous?.fingerprint === fingerprint
    ? { ...previous, count: previous.count + 1 }
    : { fingerprint, count: 1, signaled: false, tool: call.tool };
  state.failures.set(call.scope, failure);
  capMap(state.failures, state.maxScopes);

  if (failure.count < state.threshold || failure.signaled) return { failed: true, replan: false, count: failure.count };
  failure.signaled = true;
  const sessionHash = createHash("sha256").update(sessionId(input)).digest("hex").slice(0, 12);
  const recovery = {
    status: "recovering",
    unresolved: true,
    session: `sha256:${sessionHash}`,
    objective: "Continue the active session objective without discarding unresolved work.",
    directions: "Preserve active todos and do not rerun an unsafe command under unchanged conditions.",
    trigger: `${state.threshold} identical ${boundedText(call.tool)} operations failed or aborted under unchanged conditions.`,
    completed: "No additional acceptance criterion was verified by the failed operation.",
    remaining: remainingFor(state, call.scope),
    unsafeRoute: `Repeat the same ${boundedText(call.tool)} operation without changed conditions.`,
    nextSafeRoute: "Change the operation arguments or execution conditions, then resume the first unresolved criterion.",
    resumeCondition: "A materially changed operation succeeds and all remaining criteria reach a terminal state.",
    owner: `session:${sessionHash}`,
  };
  state.recoveries.set(call.scope, recovery);
  state.loadedScopes.add(call.scope);
  capMap(state.recoveries, state.maxScopes);
  state.adapter.save?.(recovery);

  const correction = `[AIDevOps recovery guard] ${state.threshold} identical ${boundedText(call.tool)} failures detected. Do not repeat this operation unchanged. Continue by changing its arguments or conditions and preserving the unresolved criteria in the recovery checkpoint.`;
  output.output = `${String(output.output || "").trim()}\n\n${correction}`.trim();
  state.qualityLog?.("WARN", `[session-continuation] repeated ${boundedText(call.tool)} failure checkpointed for session ${sessionHash}`);
  return { failed: true, replan: true, count: failure.count, correction };
}

function sessionHashFor(input) {
  return createHash("sha256").update(sessionId(input)).digest("hex").slice(0, 12);
}

// GH#34123: steering is model-only. text.complete output is the rendered,
// persisted assistant message, so corrections are queued per session and
// delivered once as a synthetic message by injectSteering() on the next model
// call. The user-visible text is never modified.
function queueSteering(state, input, kind, text) {
  const key = sessionId(input);
  state.steering.set(key, { kind, text: `${STEERING_PREFIX} ${text}` });
  capMap(state.steering, state.maxScopes);
}

// GH#33888: a reported blocker pauses only its own path. When another active
// todo remains, steer the next model call to continue the unblocked work.
// Steering only: no auto-continuation, no todo state changes.
function correctBlockerYield(state, input) {
  const scope = scopeFor(state, input);
  const active = state.tasks.get(scope) || [];
  if (active.length <= 1) return { corrected: false };

  const remaining = active.join("; ");
  queueSteering(state, input, "blocker", `Your last message reported a blocker while ${active.length} todos remain active: ${remaining}. A blocker pauses only its own path; unless the latest user message redirects the session, continue the next unblocked safe todo or record that todo's own blocker.`);
  state.qualityLog?.("WARN", `[session-continuation] queued path-blocker steering with ${active.length} active todos for session ${sessionHashFor(input)}`);
  return { corrected: true, remaining, blocker: true };
}

function completeText(state, input, output) {
  if (!isExplicitCompletionClaim(output?.text)) {
    if (isPathBlockerYield(output?.text)) return correctBlockerYield(state, input);
    return { corrected: false };
  }
  const scope = scopeFor(state, input);
  const recovery = loadRecovery(state, scope);
  const active = state.tasks.get(scope) || [];
  const unresolvedRecovery = recovery?.unresolved || ["recovering", "blocked"].includes(recovery?.status);
  if (active.length === 0 && !unresolvedRecovery) return { corrected: false };

  const remaining = remainingFor(state, scope, recovery);
  const nextAction = boundedText(recovery?.nextSafeRoute || `Continue the first active task: ${active[0] || remaining}`);
  queueSteering(state, input, "completion", `Your last message claimed completion, but it is not yet valid. Remaining criteria: ${remaining}. Unless the latest user message redirects the session, continue with: ${nextAction}.`);
  state.qualityLog?.("WARN", `[session-continuation] queued premature-completion steering for session ${sessionHashFor(input)}`);
  return { corrected: true, remaining, nextAction };
}

// Deliver queued steering once, as a synthetic user message appended to the
// model request (the same channel TTSR corrections use). Fail-open.
function injectSteering(state, input, output) {
  const messages = output?.messages;
  if (!Array.isArray(messages) || messages.length === 0) return { injected: false };
  const key = String(input?.sessionID || messages.at(-1)?.info?.sessionID || messages[0]?.info?.sessionID || "");
  const pending = key ? state.steering.get(key) : null;
  if (!pending) return { injected: false };
  state.steering.delete(key);
  const id = `continuation-steering-${Date.now()}`;
  messages.push({
    info: { id, sessionID: key, role: "user", time: { created: Date.now() }, parentID: "" },
    parts: [{ id: `${id}-part`, sessionID: key, messageID: id, type: "text", text: pending.text, synthetic: true }],
  });
  return { injected: true, kind: pending.kind, text: pending.text };
}

function resolveGuard(state, input, evidence) {
  resolveScope(state, scopeFor(state, input), evidence || "Objective explicitly reached a terminal condition.");
}

function getState(state, input) {
  const scope = scopeFor(state, input);
  return { failure: state.failures.get(scope) || null, tasks: state.tasks.get(scope) || [], recovery: loadRecovery(state, scope) };
}

export function createSessionContinuationGuard(options = {}) {
  const repository = String(options.repository || process.cwd());
  const qualityLog = options.qualityLog;
  const state = {
    repository,
    threshold: options.failureThreshold || DEFAULT_FAILURE_THRESHOLD,
    maxScopes: options.maxScopes || DEFAULT_MAX_SCOPES,
    qualityLog,
    adapter: options.checkpointAdapter || defaultCheckpointAdapter(options.checkpointHelper, repository, qualityLog),
    calls: new Map(),
    failures: new Map(),
    tasks: new Map(),
    recoveries: new Map(),
    loadedScopes: new Set(),
    steering: new Map(),
  };

  return {
    beforeTool: beforeTool.bind(null, state),
    afterTool: afterTool.bind(null, state),
    completeText: completeText.bind(null, state),
    injectSteering: injectSteering.bind(null, state),
    resolve: resolveGuard.bind(null, state),
    getState: getState.bind(null, state),
  };
}

export {
  STEERING_PREFIX,
  classifyToolOutcome,
  isExplicitCompletionClaim,
  isPathBlockerYield,
  operationFingerprint,
  toolOutcomeFailed,
};
