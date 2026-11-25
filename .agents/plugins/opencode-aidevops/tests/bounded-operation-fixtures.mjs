// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after } from "node:test";
import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";

// The lifecycle registry requires a canonical state parent (macOS /var is a symlink).
export const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-bounded-operation-")));
export const owner = { sessionID: "ses_owner" };
export const recorded = [];
const managers = [];

// Real supervisors use a disposable registry, never the operator's installation.
const lifecycleKeys = ["AIDEVOPS_LIFECYCLE_STATE_DIR", "AIDEVOPS_PRIVATE_WORKLOAD", "AIDEVOPS_LIFECYCLE_DISABLED"];
const priorLifecycleEnvironment = Object.fromEntries(lifecycleKeys.map((key) => [key, process.env[key]]));
for (const key of lifecycleKeys) delete process.env[key];
process.env.AIDEVOPS_LIFECYCLE_STATE_DIR = join(root, "lifecycle-state");

after(() => {
  for (const instance of managers) instance.dispose();
  for (const key of lifecycleKeys) {
    if (priorLifecycleEnvironment[key] === undefined) delete process.env[key];
    else process.env[key] = priorLifecycleEnvironment[key];
  }
  rmSync(root, { recursive: true, force: true });
});

export function manager(options = {}) {
  const instance = new BoundedInteractiveOperationManager({
    projectRoot: root,
    killGraceMs: 10,
    recordOutput: async (content, evidence) => {
      recorded.push({ content: String(content), evidence });
      return `out_fixture_${recorded.length}`;
    },
    readOutput: async (outputID, bounds) => ({
      output: `${bounds.offset}: output for ${outputID}\n`, redacted: false, truncated: false,
    }),
    ...options,
  });
  managers.push(instance);
  return instance;
}

export function launcher({ started = false } = {}) {
  return (runtime) => {
    const child = new EventEmitter();
    child.stdin = { end() {} };
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.connected = false;
    child.exitCode = null;
    child.signalCode = null;
    queueMicrotask(() => {
      child.emit("spawn");
      if (started) child.emit("message", {
        type: "aidevops.operation", event: "command_started", operationID: "op_fixture", runtime: "node v22.23.1",
      });
      child.exitCode = 0;
      child.emit("exit", 0, null);
      child.emit("close", 0, null);
    });
    assert.equal(runtime, "node");
    return child;
  };
}

// Startup on loaded hosts is not a timeout/latency assertion.
export const SUCCESS_BUDGET_MS = 30_000;

// Include both supervisor phases and their grace, plus scheduling/drain slack.
// Long-budget tests deliberately use 24-hour budgets and 300-second grace;
// cap the test-only wait, not the operation or any final-state assertion.
export function operationWaitMs(instance, operationID) {
  const operation = instance.operations.get(operationID);
  const main = operation.budgetMs + operation.killGraceMs;
  const restoration = operation.restorationCommand
    ? operation.restorationBudgetMs + operation.killGraceMs : 0;
  return Math.min(120_000, main + restoration + 15_000);
}

export function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

const zombie = (pid) => {
  try {
    return execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim().startsWith("Z");
  } catch {
    return false; // exited between the probes
  }
};

// GH#40309: SIGKILL delivery and reaping by an orphan's new parent are
// asynchronous, so on a loaded host a receipt can precede the kernel's removal;
// a zombie has already been contained. A real survivor of a long sleep stays
// alive far past this bound.
export async function contained(pid, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (alive(pid) && !zombie(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return !alive(pid) || zombie(pid);
}

// Waits on wait-aware status until the running command reports progress, so a
// test can act after startup without racing it under load.
export async function progressed(instance, operationID, context = owner) {
  while (!instance.status(operationID, context).progress_events) {
    await instance.status(operationID, context, { waitMs: 1000 });
    assert.equal(instance.status(operationID, context).state, "running");
  }
}

export async function terminal(instance, operationID, context = owner, timeoutMs = operationWaitMs(instance, operationID)) {
  const deadline = Date.now() + timeoutMs;
  let receipt;
  do {
    receipt = instance.status(operationID, context);
    if (!["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"].includes(receipt.state)) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(`operation ${operationID} did not reach a terminal state: ${receipt?.state} after ${timeoutMs} ms (budget ${receipt?.budget_ms} ms, grace ${receipt?.kill_grace_ms} ms)`);
}
