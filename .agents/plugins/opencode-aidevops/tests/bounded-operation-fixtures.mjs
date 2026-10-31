// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after } from "node:test";
import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";

export const root = mkdtempSync(join(tmpdir(), "aidevops-bounded-operation-"));
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
export const SUCCESS_BUDGET_MS = 10_000;

export async function terminal(instance, operationID, context = owner, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let receipt;
  do {
    receipt = instance.status(operationID, context);
    if (!["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"].includes(receipt.state)) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(`operation ${operationID} did not reach a terminal state: ${receipt?.state}`);
}
