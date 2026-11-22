// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { createBoundedInteractiveOperationTool } from "../bounded-operation-tool.mjs";
import { createProcessTreeTracker } from "../bounded-operation-process-tree.mjs";
import { root, owner, recorded, manager, launcher, SUCCESS_BUDGET_MS, terminal } from "./bounded-operation-fixtures.mjs";

// Registered inside the existing lifecycle suite, using its shared fixture and
// unchanged node --test entrypoint rather than a new runner.
export function terminationCases() {
  test("same-group escalation rejects reused and unattributed process identities", () => {
    let entries = [
      { pid: 100, ppid: 1, pgid: 100, started: "root" },
      { pid: 101, ppid: 100, pgid: 100, started: "owned" },
      { pid: 900, ppid: 100, pgid: 100, started: "ps" },
    ];
    const tracker = createProcessTreeTracker(100, () => ({ entries, psPid: 900 }));
    assert.deepEqual(tracker.ownGroupTargets(tracker.track()), [101]);
    entries = [
      { pid: 100, ppid: 1, pgid: 100, started: "root" },
      { pid: 101, ppid: 1, pgid: 100, started: "reused" },
      { pid: 102, ppid: 1, pgid: 100, started: "unattributed" },
      { pid: 900, ppid: 100, pgid: 100, started: "ps" },
    ];
    assert.deepEqual(tracker.ownGroupTargets(tracker.track()), []);
  });

  test("failure, timeout, and scoped cancellation cannot appear as success", async () => {
    const instance = manager();
    const failed = await instance.start({ command: [process.execPath, "-e", "process.exit(7)"], budgetMs: SUCCESS_BUDGET_MS }, owner);
    assert.equal((await terminal(instance, failed.operation_id)).state, "failed");
    const timed = await instance.start({ command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"], budgetMs: 30 }, owner);
    const timedResult = await terminal(instance, timed.operation_id);
    assert.equal(timedResult.state, "timed_out");
    assert.equal(timedResult.termination_cause, "budget");
    // The supervisor can handle budget termination and exit normally, leaving
    // process_signal null. State and cause, not signal delivery, prove timeout.
    const forkedInstance = manager({ killGraceMs: 5000 });
    const before = recorded.length;
    const forked = await forkedInstance.start({ command: [process.execPath, "-e", `
      const {spawn} = require('node:child_process');
      const child = spawn(process.execPath, ['-e', "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000); process.send('ready');"], {stdio:['ignore','inherit','inherit','ipc']});
      child.once('message', (message) => {
        if (message !== 'ready') process.exit(1);
        console.log('forked-descendant-ready'); child.disconnect(); child.unref();
      });
    `], budgetMs: SUCCESS_BUDGET_MS }, owner);
    const forkedResult = await terminal(forkedInstance, forked.operation_id);
    assert.equal(forkedResult.state, "succeeded");
    assert.equal(forkedResult.termination_cause, "post_exit_cleanup");
    assert.equal(forkedResult.post_exit_descendants_terminated, true);
    assert.match(recorded.slice(before).map((entry) => entry.content).join("\n"), /forked-descendant-ready/);
    const cancellable = await instance.start({ command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"], budgetMs: 1000 }, owner);
    assert.throws(() => instance.cancel(cancellable.operation_id, { sessionID: "ses_other" }), /owner mismatch/);
    assert.equal(instance.status(cancellable.operation_id, owner).state, "running");
    assert.equal(instance.cancel(cancellable.operation_id, owner).state, "cancelling");
    assert.equal((await terminal(instance, cancellable.operation_id)).state, "cancelled");
    const missing = await instance.start({ command: [join(root, "missing-executable")], restorationCommand: [process.execPath, "-e", "process.exit(0)"],
      budgetMs: SUCCESS_BUDGET_MS, restorationBudgetMs: SUCCESS_BUDGET_MS }, owner);
    const missingResult = await terminal(instance, missing.operation_id);
    assert.equal(missingResult.state, "failed");
    assert.equal(missingResult.termination_cause, "spawn_error");
    assert.equal(missingResult.restoration_state, "succeeded");
  });

  test("TERM handler keeps per-operation grace and cancellation remains the first cause", async () => {
    const instance = manager();
    const started = await instance.start({ command: [process.execPath, "-e", `
      process.on('SIGTERM', () => setTimeout(() => { console.log('cleanup-lock-released'); process.exit(0); }, 350));
      console.log('AIDEVOPS_PROGRESS: handler-ready'); setInterval(()=>{},1000);
    `], budgetMs: SUCCESS_BUDGET_MS, killGraceMs: 1500, progressIntervalMs: 10 }, owner);
    while (!instance.status(started.operation_id, owner).progress_events) {
      await instance.status(started.operation_id, owner, { waitMs: 1000 });
      assert.equal(instance.status(started.operation_id, owner).state, "running");
    }
    const before = recorded.length;
    assert.equal(instance.cancel(started.operation_id, owner).termination_cause, "cancel");
    instance.dispose();
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.termination_cause, "cancel");
    assert.equal(result.kill_grace_ms, 1500);
    assert.equal(result.state, "cancelled");
    assert.equal(result.process_exit, 0);
    assert.equal(result.process_signal, null);
    assert.match(recorded.slice(before).map((entry) => entry.content).join("\n"), /cleanup-lock-released/);
  });

  test("supervisor budget expiry cannot succeed when the manager timer is delayed", async () => {
    const instance = manager({ setTimer: () => null });
    const started = await instance.start({ command: [process.execPath, "-e", `
      process.on('SIGTERM', () => setTimeout(() => process.exit(0),150));
      console.log('AIDEVOPS_PROGRESS: ready'); setInterval(()=>{},1000);
    `], budgetMs: 1200, killGraceMs: 1500 }, owner);
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.process_exit, 0);
    assert.equal(result.state, "timed_out");
    assert.equal(result.termination_cause, "budget");
  });

  test("dispose, session deletion, external signals and supervisor loss have distinct causes", async () => {
    for (const cause of ["dispose", "session_deleted", "signal_sigterm", "signal_sigint", "supervisor_exit"]) {
      const instance = manager();
      const started = await instance.start({ command: [process.execPath, "-e", "process.on('SIGTERM',()=>process.exit(0)); console.log('AIDEVOPS_PROGRESS: ready'); setInterval(()=>{},1000)"],
        budgetMs: SUCCESS_BUDGET_MS, killGraceMs: 1500 }, owner);
      while (!instance.status(started.operation_id, owner).progress_events) {
        await new Promise((resolve) => setTimeout(resolve, 10));
        assert.equal(instance.status(started.operation_id, owner).state, "running");
      }
      const operation = instance.operations.get(started.operation_id);
      const actions = {
        dispose: () => instance.dispose(),
        session_deleted: () => instance.handleEvent({ type: "session.deleted", properties: { sessionID: owner.sessionID } }),
        signal_sigterm: () => process.kill(operation.child.pid, "SIGTERM"),
        signal_sigint: () => process.kill(operation.child.pid, "SIGINT"),
        supervisor_exit: () => process.kill(-operation.child.pid, "SIGKILL"),
      };
      actions[cause]();
      const deadline = Date.now() + 15_000;
      while (!["failed", "cancelled"].includes(operation.state) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
      assert.ok(["failed", "cancelled"].includes(operation.state));
      assert.equal(instance.receipt(operation).termination_cause, cause);
      if (cause !== "supervisor_exit") assert.equal(operation.processExit, 0);
    }
  });

  test("tool passes bounded grace without changing the default and overdue progress is diagnostic", async () => {
    const instance = manager({ killGraceMs: 500 });
    const schemaNode = { optional() { return this; } };
    const z = { enum: () => schemaNode, string: () => schemaNode, number: () => schemaNode, array: () => schemaNode };
    const tool = createBoundedInteractiveOperationTool((definition) => definition, z, instance);
    for (const [requested, expected] of [[undefined, 500], [90, 90_000], [999, 300_000], [-1, 10]]) {
      const started = JSON.parse(await tool.execute({ action: "start", command: [process.execPath, "-e", "setTimeout(() => process.exit(0),80)"],
        budget_seconds: 10, progress_interval_seconds: 0.01, kill_grace_seconds: requested }, owner));
      const result = await terminal(instance, started.operation_id);
      assert.equal(result.kill_grace_ms, expected);
      assert.equal(result.state, "succeeded");
      assert.equal(result.progress_events, 0);
      assert.equal(result.progress_overdue, true);
      assert.equal(result.termination_cause, null);
    }
  });

  test("manager fallback grace is clamped before receipt and supervisor configuration", async () => {
    for (const [fallback, expected] of [[900_000, 300_000], [-50, 10], [NaN, 500]]) {
      let configuration;
      const fixture = launcher({ started: true });
      const instance = manager({ killGraceMs: fallback, makeID: () => "op_fixture", spawn: (runtime) => {
        const child = fixture(runtime);
        child.stdin.end = (value) => { configuration = JSON.parse(value); };
        return child;
      } });
      const started = await instance.start({ command: ["fixture"] }, owner);
      assert.equal((await terminal(instance, started.operation_id)).kill_grace_ms, expected);
      assert.equal(configuration.killGraceMs, expected);
    }
  });

  restorationTerminationCases();
  sameGroupSurvivorCases();
  longBudgetCases();
}

function longBudgetCases() {
  test("24-hour tool budgets remain running past the reported two-hour point without progress", async () => {
    for (const requested of [86_400, 172_800]) {
      let now = 0;
      const timers = [];
      const instance = manager({ now: () => now, setTimer: (callback, milliseconds) => {
        timers.push(milliseconds);
        return setTimeout(callback, milliseconds);
      } });
      const schemaNode = { optional() { return this; } };
      const z = { enum: () => schemaNode, string: () => schemaNode, number: () => schemaNode, array: () => schemaNode };
      const tool = createBoundedInteractiveOperationTool((definition) => definition, z, instance);
      assert.match(tool.description, /86400 seconds/);
      const started = JSON.parse(await tool.execute({ action: "start", budget_seconds: requested,
        command: [process.execPath, "-e", "console.log('ordinary output'); setTimeout(()=>process.exit(0),80)"] }, owner));
      assert.equal(started.budget_ms, 86_400_000);
      assert.deepEqual(timers, [86_400_000]);
      // Advance only the existing manager clock: no claim of a real two-hour soak.
      now = 7_216_000;
      const status = JSON.parse(await tool.execute({ action: "status", operation_id: started.operation_id }, owner));
      assert.equal(status.state, "running");
      assert.equal(status.remaining_ms, 79_184_000);
      assert.equal(status.progress_events, 0);
      assert.equal(status.progress_overdue, true);
      assert.equal(status.termination_cause, null);
      const result = await terminal(instance, started.operation_id);
      assert.equal(result.state, "succeeded");
      assert.equal(result.progress_events, 0);
      assert.equal(result.termination_cause, null);
    }
  });
}

function restorationTerminationCases() {
  test("restoration stop disposition survives an earlier post-exit cleanup cause", async () => {
    for (const cause of ["budget", "dispose"]) {
      let launches = 0;
      let restorationTimeout;
      const fixture = launcher({ started: true });
      const instance = manager({ makeID: () => "op_fixture", setTimer: (callback, milliseconds) => {
        if (milliseconds === 4321) restorationTimeout = callback;
        return null;
      }, spawn: (runtime) => {
        const child = fixture(runtime);
        if (++launches === 2) child.once("spawn", () => {
          child.emit("message", { type: "aidevops.operation", operationID: "op_fixture", event: "termination", cause: "post_exit_cleanup" });
          if (cause === "budget") restorationTimeout();
          else instance.dispose();
        });
        return child;
      } });
      const started = await instance.start({ command: ["fixture"], restorationCommand: ["restore"], restorationBudgetMs: 4321 }, owner);
      const result = await terminal(instance, started.operation_id);
      assert.equal(result.state, "restoration_failed");
      assert.equal(result.restoration_exit, 0);
      assert.equal(result.restoration_termination_cause, "post_exit_cleanup");
      assert.equal(result.restoration_state, cause === "budget" ? "timed_out" : "cancelled");
    }
  });

  test("restoration supervisor budget retains timeout even with exit-zero cleanup", async () => {
    const instance = manager({ setTimer: () => null });
    const started = await instance.start({ command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.on('SIGTERM',()=>setTimeout(()=>process.exit(0),100)); setInterval(()=>{},1000)"],
      budgetMs: SUCCESS_BUDGET_MS, restorationBudgetMs: 1200, killGraceMs: 1500 }, owner);
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.state, "restoration_failed");
    assert.equal(result.termination_cause, null);
    assert.equal(result.restoration_state, "timed_out");
    assert.equal(result.restoration_exit, 0);
    assert.equal(result.restoration_termination_cause, "budget");
  });

  test("restoration disposal cannot become success after exit-zero TERM cleanup", async () => {
    const instance = manager();
    const started = await instance.start({ command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.on('SIGTERM',()=>setTimeout(()=>process.exit(0),100)); console.log('AIDEVOPS_PROGRESS: restoration-ready'); setInterval(()=>{},1000)"],
      budgetMs: SUCCESS_BUDGET_MS, restorationBudgetMs: SUCCESS_BUDGET_MS, killGraceMs: 1500 }, owner);
    const deadline = Date.now() + 5000;
    while (!instance.status(started.operation_id, owner).progress_events && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(instance.status(started.operation_id, owner).progress_events, 1);
    instance.dispose();
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.state, "restoration_failed");
    assert.equal(result.termination_cause, null);
    assert.equal(result.restoration_state, "cancelled");
    assert.equal(result.restoration_exit, 0);
    assert.equal(result.restoration_termination_cause, "dispose");
  });
}

function sameGroupSurvivorCases() {
  test("same-group survivors drain promptly but keep grace while main remains alive", async () => {
    for (const cancel of [false, true]) {
      const instance = manager();
      const before = recorded.length;
      const started = await instance.start({ command: [process.execPath, "-e", `
        const {spawn} = require('node:child_process');
        const child = spawn(process.execPath, ['-e', "process.on('SIGTERM',()=>{}); console.log('child-ready'); setInterval(()=>{},1000)"], {stdio:['ignore','pipe','inherit']});
        child.stdout.once('data', () => {
          console.log('AIDEVOPS_PROGRESS: child-ready');
          ${cancel ? "process.on('SIGTERM',()=>setTimeout(()=>{console.log('main-cleanup-complete'); process.exit(0);},400));" : "process.exit(0);"}
        });
      `], budgetMs: SUCCESS_BUDGET_MS, killGraceMs: 300_000 }, owner);
      if (cancel) {
        const deadline = Date.now() + 5000;
        while (!instance.status(started.operation_id, owner).progress_events && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
        assert.equal(instance.status(started.operation_id, owner).progress_events, 1);
        instance.cancel(started.operation_id, owner);
      }
      const result = await terminal(instance, started.operation_id, owner, 5000);
      assert.equal(result.state, cancel ? "cancelled" : "succeeded");
      assert.equal(result.process_exit, 0);
      assert.equal(result.termination_cause, cancel ? "cancel" : "post_exit_cleanup");
      assert.equal(result.post_exit_descendants_terminated, !cancel);
      if (cancel) assert.match(recorded.slice(before).map((entry) => entry.content).join("\n"), /main-cleanup-complete/);
    }
  });
}
