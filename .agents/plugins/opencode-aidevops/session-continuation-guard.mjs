// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { addEditedPaths, captureCheck, defaultDirtyEdits } from "./session-continuation-capture.mjs";
import {
  detectLoop,
  emptyLoopState,
  isDesignedPoll,
  isProgress,
  loopEntry,
  recordLoopEntry,
} from "./session-continuation-loops.mjs";
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

// GH#35121: remember which files this session's edit tools changed.
function recordEdits(state, call) {
  const edits = addEditedPaths(state.edits.get(call.scope), call.tool, call.args, state.repository);
  if (!edits) return;
  state.edits.set(call.scope, edits);
  capMap(state.edits, state.maxScopes);
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

  if (!failed) recordEdits(state, call);

  if (!failed && call.tool.toLowerCase() === "todowrite") {
    const active = activeTodos(call.args?.todos);
    state.tasks.set(call.scope, active);
    capMap(state.tasks, state.maxScopes);
    const recovery = loadRecovery(state, call.scope);
    if (active.length === 0 && recovery?.unresolved) {
      resolveScope(state, call.scope, "All tracked session tasks reached a terminal state.");
    }
  }

  // GH#35968: designed polling is neither progress nor repetition.
  if (isDesignedPoll(call.tool, call.args)) return { failed, replan: false };

  const loop = state.loops.get(call.scope) || emptyLoopState();
  state.loops.delete(call.scope);
  state.loops.set(call.scope, loop);
  capMap(state.loops, state.maxScopes);
  const entry = loopEntry(call, output, failed);
  recordLoopEntry(loop, entry, isProgress(loop, call, entry), state.threshold);

  const detected = detectLoop(loop.window, state.threshold);
  if (!detected || loop.signaled.has(detected.signature)) return { failed, replan: false };
  loop.signaled.add(detected.signature);
  return signalLoop(state, input, output, call, detected);
}

function failureRecovery(state, input, call, detected) {
  const sessionHash = sessionHashFor(input);
  const single = detected.period === 1;
  const tool = boundedText(call.tool);
  return {
    status: "recovering",
    unresolved: true,
    session: `sha256:${sessionHash}`,
    objective: "Continue the active session objective without discarding unresolved work.",
    directions: "Preserve active todos and do not rerun an unsafe command under unchanged conditions.",
    trigger: single
      ? `${state.threshold} identical ${tool} operations failed or aborted under unchanged conditions.`
      : `${state.threshold} repetitions of the ${detected.label} tool-call cycle included failures under unchanged conditions.`,
    completed: "No additional acceptance criterion was verified by the failed operation.",
    remaining: remainingFor(state, call.scope),
    unsafeRoute: single
      ? `Repeat the same ${tool} operation without changed conditions.`
      : `Repeat the ${detected.label} cycle without changed conditions.`,
    nextSafeRoute: "Change the operation arguments or execution conditions, then resume the first unresolved criterion.",
    resumeCondition: "A materially changed operation succeeds and all remaining criteria reach a terminal state.",
    owner: `session:${sessionHash}`,
  };
}

function loopCorrection(state, call, detected) {
  if (detected.kind === "success") {
    return `[AIDevOps recovery guard] The ${detected.label} tool-call cycle repeated ${detected.repeats} times with identical results and no edit or task progress. If you are waiting on external state, use one bounded wait (aidevops_bounded_operation status with wait_seconds, or the owning helper's wait command); otherwise change the approach before calling these tools again.`;
  }
  if (detected.period === 1) {
    return `[AIDevOps recovery guard] ${state.threshold} identical ${boundedText(call.tool)} failures detected. Do not repeat this operation unchanged. Continue by changing its arguments or conditions and preserving the unresolved criteria in the recovery checkpoint.`;
  }
  return `[AIDevOps recovery guard] The ${detected.label} tool-call cycle repeated ${state.threshold} times with failures. Do not repeat this cycle unchanged. Continue by changing its arguments or conditions and preserving the unresolved criteria in the recovery checkpoint.`;
}

// Failing cycles checkpoint recovery; all-success cycles only steer, so a
// false positive can never block a later legitimate completion claim.
function signalLoop(state, input, output, call, detected) {
  const failed = toolOutcomeFailed(output);
  const correction = loopCorrection(state, call, detected);
  output.output = `${String(output.output || "").trim()}\n\n${correction}`.trim();
  const result = { failed, replan: true, count: detected.repeats, loop: { kind: detected.kind, description: detected.description, period: detected.period, tools: detected.tools }, correction };
  if (detected.kind === "success") {
    state.qualityLog?.("WARN", `[session-continuation] non-progressing ${detected.label} cycle steered for session ${sessionHashFor(input)}`);
    return result;
  }
  const recovery = failureRecovery(state, input, call, detected);
  state.recoveries.set(call.scope, recovery);
  state.loadedScopes.add(call.scope);
  capMap(state.recoveries, state.maxScopes);
  state.adapter.save?.(recovery);
  state.qualityLog?.("WARN", `[session-continuation] repeated ${detected.label} failure cycle checkpointed for session ${sessionHashFor(input)}`);
  return result;
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

// GH#35121: a closeout that asks the user for nothing must not leave files
// this session edited uncommitted. Steer once per distinct dirty set toward
// the Capture Check: commit with authority, otherwise ask for bounded
// commit/PR approval and keep Close at Not yet. Never commits anything itself.
function correctUncapturedCloseout(state, input, output) {
  const scope = scopeFor(state, input);
  const check = captureCheck(state.edits.get(scope), output?.text, state.dirtyEdits, state.captureSteered.get(scope));
  if (check.error) state.qualityLog?.("WARN", `[session-continuation] capture check failed: ${boundedText(check.error?.message)}`);
  if (!check.steering) return { corrected: false };
  state.captureSteered.set(scope, check.fingerprint);
  capMap(state.captureSteered, state.maxScopes);
  queueSteering(state, input, "capture", check.steering);
  state.qualityLog?.("WARN", `[session-continuation] queued uncommitted-edit capture steering for session ${sessionHashFor(input)}`);
  return { corrected: true, capture: true, dirty: check.dirty };
}

function completeText(state, input, output) {
  const result = correctTodoYield(state, input, output);
  if (result.corrected) return result;
  return correctUncapturedCloseout(state, input, output);
}

function correctTodoYield(state, input, output) {
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
// model request (the same channel TTSR corrections use).
function deliverSteering(state, input, output) {
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

// Fail-open: a steering failure must never block the model request.
function injectSteering(state, input, output) {
  try {
    return deliverSteering(state, input, output);
  } catch (error) {
    state.qualityLog?.("WARN", `[session-continuation] steering injection failed: ${boundedText(error?.message)}`);
    return { injected: false };
  }
}

function resolveGuard(state, input, evidence) {
  resolveScope(state, scopeFor(state, input), evidence || "Objective explicitly reached a terminal condition.");
}

function getState(state, input) {
  const scope = scopeFor(state, input);
  const loop = state.loops.get(scope);
  return {
    loop: loop ? { window: loop.window.map(({ tool, failed }) => ({ tool, failed })) } : null,
    tasks: state.tasks.get(scope) || [],
    recovery: loadRecovery(state, scope),
  };
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
    loops: new Map(),
    tasks: new Map(),
    recoveries: new Map(),
    loadedScopes: new Set(),
    steering: new Map(),
    edits: new Map(),
    captureSteered: new Map(),
    dirtyEdits: options.dirtyEdits || defaultDirtyEdits,
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
