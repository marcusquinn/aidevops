// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const ACTIVE_STATES = ["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"];
const MAX_OUTPUT_LINES = 500;
const MAX_STATUS_WAIT_MS = 60 * 1000;

export function operationStatus(manager, id, context = {}, requested = {}) {
  const operation = manager.ownedOperation(id, context);
  const waitMs = Number(requested.waitMs ?? 0);
  if (!Number.isSafeInteger(waitMs) || waitMs < 0 || waitMs > MAX_STATUS_WAIT_MS) {
    throw new Error("status wait must be an integer from 0 to 60000 milliseconds");
  }
  if (waitMs === 0 || !ACTIVE_STATES.includes(operation.state)) return manager.receipt(operation);
  return new Promise((resolve) => {
    const waiter = {
      version: manager.statusVersion(operation),
      finish: () => {
        if (!operation.statusWaiters.delete(waiter)) return;
        manager.clearTimer(waiter.timer);
        resolve(manager.receipt(operation));
      },
      timer: null,
    };
    operation.statusWaiters.add(waiter);
    waiter.timer = manager.setTimer(waiter.finish, waitMs);
  });
}

export async function operationOutput(manager, id, context = {}, requested = {}) {
  const operation = manager.ownedOperation(id, context);
  if (ACTIVE_STATES.includes(operation.state)) {
    throw new Error("stored output is available only after the operation reaches a terminal state");
  }
  if (!operation.outputID) throw new Error("stored output is unavailable");
  const offset = Number(requested.offset ?? 1);
  const limit = Number(requested.limit ?? 120);
  if (!Number.isSafeInteger(offset) || offset < 1) throw new Error("output offset must be a positive integer");
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_OUTPUT_LINES) {
    throw new Error(`output limit must be an integer from 1 to ${MAX_OUTPUT_LINES}`);
  }
  const result = await manager.readOutput(operation.outputID, { offset, limit });
  return {
    schema: "aidevops.interactive-operation-output/v1",
    operation_id: operation.id,
    state: operation.state,
    output_id: operation.outputID,
    offset,
    limit,
    output: result.output,
    output_redacted: Boolean(result.redacted),
    output_truncated: Boolean(result.truncated),
  };
}

export function cancelOperation(manager, id, context = {}) {
  const operation = manager.ownedOperation(id, context);
  if (!["running", "starting"].includes(operation.state)) return manager.receipt(operation);
  if (!manager.requestTermination(operation, "cancelled")) {
    throw new Error("owned process could not be signalled");
  }
  return manager.receipt(operation);
}
