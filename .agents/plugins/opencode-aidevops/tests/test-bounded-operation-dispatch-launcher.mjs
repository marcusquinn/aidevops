// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// GH#34047: known detaching pulse dispatch launchers must be rejected before
// spawn, while foreground subcommands and lookalike arguments stay allowed.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";

import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";
import { createBoundedInteractiveOperationTool } from "../bounded-operation-tool.mjs";

const root = mkdtempSync(join(tmpdir(), "aidevops-bounded-dispatch-"));
const owner = { sessionID: "ses_owner" };
const managers = [];
const SUCCESS_BUDGET_MS = 10_000;
const NON_TERMINAL = new Set(["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"]);

after(() => {
  for (const instance of managers) instance.dispose();
  rmSync(root, { recursive: true, force: true });
});

function fixtureChild() {
  const child = new EventEmitter();
  child.stdin = { end() {} };
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.connected = false;
  child.exitCode = null;
  child.signalCode = null;
  queueMicrotask(() => {
    child.emit("spawn");
    child.emit("message", {
      type: "aidevops.operation",
      event: "command_started",
      operationID: "op_fixture",
      runtime: "node v22.23.1",
    });
    child.exitCode = 0;
    child.emit("exit", 0, null);
    child.emit("close", 0, null);
  });
  return child;
}

function countingManager() {
  const counter = { spawns: 0 };
  const instance = new BoundedInteractiveOperationManager({
    projectRoot: root,
    killGraceMs: 10,
    makeID: () => "op_fixture",
    spawn: () => {
      counter.spawns += 1;
      return fixtureChild();
    },
    recordOutput: async () => "out_fixture",
    readOutput: async () => ({ output: "", redacted: false, truncated: false }),
  });
  managers.push(instance);
  return { instance, counter };
}

async function terminalState(instance, operationID) {
  const deadline = Date.now() + 15_000;
  let receipt;
  do {
    receipt = instance.status(operationID, owner);
    if (!NON_TERMINAL.has(receipt.state)) return receipt.state;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(`operation ${operationID} did not reach a terminal state: ${receipt?.state}`);
}

const wrapper = "/installed/scripts/pulse-wrapper.sh";
const dispatchArgs = ["--command", "dispatch", "123", "owner/repo", "title", "issue title", "login", "/repo", "prompt"];

describe("bounded operation dispatch launcher guard (GH#34047)", () => {
  test("known detaching dispatch launchers are rejected before spawn", async () => {
    const { instance, counter } = countingManager();
    const rejected = [
      [wrapper, ...dispatchArgs],
      ["env", "PATH=/governed/bin:/usr/bin", wrapper, ...dispatchArgs],
      ["/usr/bin/env", "-i", "-u", "HOME", "PATH=/usr/bin", "--", wrapper, ...dispatchArgs],
      ["bash", wrapper, "--command", "dispatch-foss", "owner/repo"],
      ["env", "PATH=/usr/bin", "bash", "pulse-wrapper.sh", "--command", "dispatch"],
    ];
    for (const command of rejected) {
      await assert.rejects(instance.start({ command, budgetMs: 1000 }, owner),
        /launches a detached worker.*exact-attempt worker status/, JSON.stringify(command));
    }
    await assert.rejects(instance.start({
      command: ["git", "--version"],
      restorationCommand: ["env", "PATH=/usr/bin", wrapper, ...dispatchArgs],
      budgetMs: 1000,
    }, owner), /launches a detached worker/);
    assert.equal(counter.spawns, 0, "a rejected launcher reached spawn");
  });

  test("foreground subcommands and lookalike arguments stay allowed", async () => {
    const { instance, counter } = countingManager();
    for (const command of [
      [wrapper, "--command", "list-candidates"],
      ["env", "PATH=/usr/bin", wrapper, "--command", "capacity"],
      ["/tmp/other-wrapper.sh", "--command", "dispatch"],
      ["bash", "-c", "echo pulse-wrapper.sh --command dispatch"],
    ]) {
      const started = await instance.start({ command, budgetMs: SUCCESS_BUDGET_MS }, owner);
      assert.equal(await terminalState(instance, started.operation_id), "succeeded", JSON.stringify(command));
    }
    assert.equal(counter.spawns, 4);
  });

  test("tool surface reports the rejection and documents it", async () => {
    const { instance, counter } = countingManager();
    const schemaNode = { optional() { return this; } };
    const z = { enum: () => schemaNode, string: () => schemaNode, number: () => schemaNode, array: () => schemaNode };
    const tool = createBoundedInteractiveOperationTool((definition) => definition, z, instance);
    const response = JSON.parse(await tool.execute({ action: "start", command: [wrapper, ...dispatchArgs] }, owner));
    assert.match(response.error, /normal shell tool/);
    assert.match(tool.description, /rejected before spawn/);
    assert.equal(counter.spawns, 0);
  });
});
