// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { boundedInteger, scalar } from "./bounded-operation-values.mjs";

const TERMINATION_DISPOSITIONS = new Map([
  ["budget", "timed_out"], ["cancel", "cancelled"], ["dispose", "cancelled"],
  ["session_deleted", "cancelled"], ["signal_sigterm", "failed"],
  ["signal_sigint", "failed"], ["parent_disconnect", "failed"], ["spawn_error", "failed"],
]);

function applyTerminationMessage(operation, message) {
  operation.terminationCause ||= scalar(message.cause);
  if (operation.disposition !== "running") return;
  const disposition = TERMINATION_DISPOSITIONS.get(message.cause);
  if (!disposition) return;
  operation.disposition = disposition;
  operation.state = disposition === "timed_out" ? "timing_out" : "cancelling";
}

function applyRestorationMessage(operation, message) {
  if (message.event === "command_started") operation.restorationCommandStarted = true;
  if (message.event !== "termination") return;
  operation.restorationTerminationCause ||= scalar(message.cause);
  const disposition = TERMINATION_DISPOSITIONS.get(message.cause);
  if (!disposition || operation.restorationDisposition !== "running") return;
  operation.restorationDisposition = disposition;
  operation.restorationState = disposition === "timed_out" ? "timing_out" : "cancelling";
}

// Supervisor budget reports can precede manager timers. Keep restoration
// evidence independent; containment is reported only for the main command.
export function applySupervisorMessage(operation, stage, message) {
  if (message?.type !== "aidevops.operation" || message.operationID !== operation.id) return;
  if (stage !== "main") return applyRestorationMessage(operation, message);
  switch (message.event) {
    case "termination":
      applyTerminationMessage(operation, message);
      break;
    case "containment":
      operation.nestedProcessGroups = boundedInteger(message.nestedProcessGroups, 0, 0, 1_000_000);
      operation.attributionComplete = message.attributionComplete === true;
      operation.postExitDescendantsTerminated = message.postExitDescendantsTerminated === true;
      break;
    case "command_started":
      operation.commandStarted = true;
      operation.supervisorRuntime = scalar(message.runtime);
      break;
  }
}

function liveChild(child, exited) {
  return child && !exited && child.exitCode === null && child.signalCode === null;
}

function disposeMain(operation, kill) {
  if (!liveChild(operation.child, operation.childExited)) return;
  operation.terminationCause ||= "dispose";
  if (operation.disposition === "running") {
    operation.disposition = "cancelled";
    operation.state = "cancelling";
  }
  kill(operation.child, "SIGTERM", operation.terminationCause);
}

function disposeRestoration(operation, kill) {
  if (!liveChild(operation.restorationChild, operation.restorationChildExited)) return;
  operation.restorationTerminationCause ||= "dispose";
  if (operation.restorationDisposition === "running") operation.restorationDisposition = "cancelled";
  operation.restorationState = "cancelling";
  kill(operation.restorationChild, "SIGTERM", operation.restorationTerminationCause);
}

export function disposeOperations(operations, kill, clearTimer) {
  for (const operation of operations.values()) {
    disposeMain(operation, kill);
    disposeRestoration(operation, kill);
    for (const timer of [operation.budgetTimer, operation.killTimer, operation.restorationTimer]) {
      if (timer) clearTimer(timer);
    }
  }
}
