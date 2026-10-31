// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { scalar } from "./bounded-operation-values.mjs";
export { applySupervisorMessage, disposeOperations } from "./bounded-operation-termination.mjs";

const MAX_CAPTURE_BYTES = 1024 * 1024;
const MAX_PROGRESS_REMAINDER_BYTES = 4096;
const RECEIPT_SCHEMA = "aidevops.interactive-operation/v1";

export function appendCapture(operation, chunk) {
  const value = Buffer.from(chunk);
  const remaining = MAX_CAPTURE_BYTES - operation.outputBytes;
  if (remaining <= 0) {
    operation.outputTruncated = true;
    return;
  }
  operation.output.push(value.subarray(0, remaining));
  operation.outputBytes += Math.min(value.length, remaining);
  if (value.length > remaining) operation.outputTruncated = true;
}

export function observeProgress(operation, chunk, now) {
  const text = `${operation.progressRemainder}${String(chunk)}`;
  const lines = text.split(/\r?\n/);
  let observed = false;
  operation.progressRemainder = lines.pop() || "";
  if (Buffer.byteLength(operation.progressRemainder) > MAX_PROGRESS_REMAINDER_BYTES) {
    operation.progressRemainder = operation.progressRemainder.slice(-MAX_PROGRESS_REMAINDER_BYTES);
  }
  for (const line of lines) {
    if (/^AIDEVOPS_PROGRESS:\s*\S/.test(line)) {
      operation.lastMeaningfulProgressAt = now();
      operation.progressEvents += 1;
      observed = true;
    }
  }
  return observed;
}

export function signalSupervisor(child, signal, cause) {
  if (!child?.connected || child.exitCode !== null || child.signalCode !== null) return false;
  try {
    child.send({ action: "terminate", cause });
    return true;
  } catch {
    return false;
  }
}

export function trimTerminalOperations(operations, maximum) {
  if (operations.size < maximum) return;
  for (const [id, operation] of operations) {
    if (!operation.child && !operation.restorationChild) operations.delete(id);
    if (operations.size < maximum) return;
  }
  throw new Error("too many active bounded operations");
}

// The supervisor reports whether helper-created process groups were tracked
// (GH#33514). Unverifiable attribution is reported, never upgraded to owned.
function operationContainment(operation) {
  if (operation.attributionComplete === false) return "incomplete";
  return operation.nestedProcessGroups > 0 ? "owned_process_tree" : "owned_process_group";
}

export function operationReceipt(operation, now) {
  const elapsedMs = Math.max(0, now - operation.startedAt);
  const lastProgressAgeMs = operation.lastMeaningfulProgressAt === null
    ? null
    : Math.max(0, now - operation.lastMeaningfulProgressAt);
  return {
    schema: RECEIPT_SCHEMA,
    operation_id: operation.id,
    containment: operationContainment(operation),
    nested_process_groups: operation.nestedProcessGroups || 0,
    // GH#34047: exit 0 is not liveness evidence for anything the command
    // launched; true means command exit triggered descendant termination.
    post_exit_descendants_terminated: operation.postExitDescendantsTerminated === true,
    state: operation.state,
    elapsed_ms: elapsedMs,
    budget_ms: operation.budgetMs,
    remaining_ms: Math.max(0, operation.budgetMs - elapsedMs),
    progress_interval_ms: operation.progressIntervalMs,
    progress_events: operation.progressEvents,
    last_meaningful_progress_age_ms: lastProgressAgeMs,
    progress_overdue: elapsedMs >= operation.progressIntervalMs
      && (lastProgressAgeMs === null || lastProgressAgeMs >= operation.progressIntervalMs),
    process_exit: operation.processExit,
    process_signal: operation.processSignal || null,
    termination_cause: operation.terminationCause || null,
    kill_grace_ms: operation.killGraceMs,
    command_execution: operation.state === "starting" || operation.state === "running"
      ? "pending"
      : (operation.commandStarted ? "observed" : "missing"),
    supervisor_runtime: operation.supervisorRuntime || null,
    restoration_state: operation.restorationState,
    restoration_exit: operation.restorationExit,
    restoration_termination_cause: operation.restorationTerminationCause || null,
    restoration_signal: operation.restorationSignal || null,
    output_id: operation.outputID || null,
    evidence_state: operation.state === "finalizing" ? "pending" : (operation.outputID ? "recorded" : "unavailable"),
    output_truncated: operation.outputTruncated,
  };
}

export async function runOperationRestoration(manager, operation) {
  operation.state = "restoring";
  operation.restorationState = "running";
  manager.notifyStatusWaiters(operation);
  await new Promise((resolve) => {
    let settled = false;
    const finish = (state, code = null) => {
      if (settled) return;
      settled = true;
      if (operation.restorationTimer) manager.clearTimer(operation.restorationTimer);
      operation.restorationChild = null;
      operation.restorationExit = Number.isInteger(code) ? code : null;
      operation.restorationState = state;
      manager.notifyStatusWaiters(operation);
      resolve();
    };
    const child = manager.spawnOwned(operation, operation.restorationCommand, "restoration");
    operation.restorationChild = child;
    operation.restorationChildExited = false;
    child.once("exit", () => { operation.restorationChildExited = true; });
    operation.restorationTimer = manager.setTimer(() => {
      operation.restorationTerminationCause ||= "budget";
      if (operation.restorationDisposition === "running") operation.restorationDisposition = "timed_out";
      operation.restorationState = "timing_out";
      manager.notifyStatusWaiters(operation);
      if (!operation.restorationChildExited && child.exitCode === null && child.signalCode === null) {
        manager.kill(child, "SIGTERM", operation.restorationTerminationCause);
      }
    }, operation.restorationBudgetMs);
    child.once("error", () => finish("failed"));
    child.once("close", (code, signal) => {
      operation.restorationSignal = scalar(signal);
      if (signal || !operation.restorationCommandStarted) operation.restorationTerminationCause ||= "supervisor_exit";
      const cause = operation.restorationTerminationCause;
      const disposition = operation.restorationDisposition;
      const succeeded = (!cause || cause === "post_exit_cleanup") && code === 0 && operation.restorationCommandStarted;
      finish(disposition !== "running" ? disposition : (succeeded ? "succeeded" : "failed"), code);
    });
  });
}
