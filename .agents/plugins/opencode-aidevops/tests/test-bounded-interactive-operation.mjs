// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { EventEmitter, once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";
import { createOutputSandboxReader, createOutputSandboxRecorder } from "../bounded-operation-output.mjs";
import {
  parseProcessSnapshot,
  recordOwnedDescendants,
  verifiedNestedTargets,
} from "../bounded-operation-process-tree.mjs";
import { createBoundedInteractiveOperationTool } from "../bounded-operation-tool.mjs";
import { resolveGptImageProjectRoot, resolveSessionOwnedWorktreeRoot } from "../gpt-image-worktree.mjs";

const root = mkdtempSync(join(tmpdir(), "aidevops-bounded-operation-"));
const owner = { sessionID: "ses_owner" };
const recorded = [];
const managers = [];

after(() => {
  for (const manager of managers) manager.dispose();
  rmSync(root, { recursive: true, force: true });
});

function manager(options = {}) {
  const instance = new BoundedInteractiveOperationManager({
    projectRoot: root,
    killGraceMs: 10,
    recordOutput: async (content, evidence) => {
      recorded.push({ content: String(content), evidence });
      return `out_fixture_${recorded.length}`;
    },
    readOutput: async (outputID, bounds) => ({
      output: `${bounds.offset}: output for ${outputID}\n`,
      redacted: false,
      truncated: false,
    }),
    ...options,
  });
  managers.push(instance);
  return instance;
}

function launcher({ started = false } = {}) {
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
      if (started) {
        child.emit("message", {
          type: "aidevops.operation",
          event: "command_started",
          operationID: "op_fixture",
          runtime: "node v22.23.1",
        });
      }
      child.exitCode = 0;
      child.emit("exit", 0, null);
      child.emit("close", 0, null);
    });
    assert.equal(runtime, "node");
    return child;
  };
}

async function terminal(instance, operationID, context = owner, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  let receipt;
  do {
    receipt = instance.status(operationID, context);
    if (!["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"].includes(receipt.state)) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(`operation ${operationID} did not reach a terminal state: ${receipt?.state}`);
}

describe("bounded interactive operations", () => {
  test("start returns control and explicit progress reaches a private terminal receipt", async () => {
    const instance = manager();
    const before = Date.now();
    const started = await instance.start({
      command: [process.execPath, "-e", "console.log('AIDEVOPS_PROGRESS: phase-one'); setTimeout(() => process.exit(0), 80)"],
      cwd: root,
      budgetMs: 1000,
      progressIntervalMs: 30,
    }, owner);

    assert.equal(started.state, "running");
    assert.ok(Date.now() - before < 500, "start waited for command completion");
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.state, "succeeded");
    assert.equal(result.process_exit, 0);
    assert.equal(result.progress_events, 1);
    assert.equal(result.output_id, "out_fixture_1");
    assert.equal(result.evidence_state, "recorded");
    assert.equal(result.restoration_state, "not_required");
    assert.equal(result.command_execution, "observed");
    assert.match(result.supervisor_runtime, /^node v\d+\./);
    assert.equal(JSON.stringify(result).includes("phase-one"), false);
  });

  test("wait-aware status returns on progress, terminal state, or its bound", async () => {
    const instance = manager();
    const progressing = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => console.log('AIDEVOPS_PROGRESS: ready'), 40); setTimeout(() => process.exit(0), 250)"],
      budgetMs: 5000,
      progressIntervalMs: 500,
    }, owner);
    const progressStarted = Date.now();
    const progress = await instance.status(progressing.operation_id, owner, { waitMs: 500 });
    assert.equal(progress.state, "running");
    assert.equal(progress.progress_events, 1);
    assert.ok(Date.now() - progressStarted < 400, "progress did not wake status promptly");
    // Terminal containment scans the process inventory; its latency on shared
    // runners must not be confused with the progress-wakeup latency above.
    const completed = await instance.status(progressing.operation_id, owner, { waitMs: 3000 });
    assert.ok(["finalizing", "succeeded"].includes(completed.state));
    assert.equal((await terminal(instance, progressing.operation_id)).state, "succeeded");

    const quiet = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => process.exit(0), 500)"],
      budgetMs: 1000,
    }, owner);
    const boundStarted = Date.now();
    const bounded = await instance.status(quiet.operation_id, owner, { waitMs: 30 });
    assert.equal(bounded.state, "running");
    assert.ok(Date.now() - boundStarted >= 20, "status returned before its wait bound");
    instance.cancel(quiet.operation_id, owner);
    await terminal(instance, quiet.operation_id);
  });

  test("wait-aware status preserves immediate, ownership, cancellation, and tool behavior", async () => {
    const instance = manager();
    const started = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 1000,
    }, owner);
    assert.equal(instance.status(started.operation_id, owner).state, "running");
    assert.throws(() => instance.status(started.operation_id, owner, { waitMs: 60001 }), /0 to 60000/);
    assert.throws(() => instance.status(started.operation_id, { sessionID: "ses_other" }, { waitMs: 20 }), /owner mismatch/);

    const waiting = instance.status(started.operation_id, owner, { waitMs: 500 });
    instance.cancel(started.operation_id, owner);
    assert.equal((await waiting).state, "cancelling");

    const schemaNode = { optional() { return this; } };
    const z = { enum: () => schemaNode, string: () => schemaNode, number: () => schemaNode, array: () => schemaNode };
    const tool = createBoundedInteractiveOperationTool((definition) => definition, z, instance);
    const toolResult = JSON.parse(await tool.execute({
      action: "status",
      operation_id: started.operation_id,
      wait_seconds: 1,
    }, owner));
    assert.ok(["cancelling", "finalizing", "cancelled"].includes(toolResult.state), JSON.stringify(toolResult));
    assert.equal(toolResult.schema, "aidevops.interactive-operation/v1");
    await terminal(instance, started.operation_id);
  });

  test("an outside cwd requires a session-owned worktree resolution before spawn", async () => {
    const linked = mkdtempSync(join(tmpdir(), "aidevops-bounded-linked-"));
    let resolution;
    const instance = manager({
      resolveWorktreeRoot: async (requested, projectRoot, context, options) => {
        resolution = { requested, projectRoot, context, options };
        return { root: linked, linked: true };
      },
    });
    const started = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      cwd: linked,
      budgetMs: 1000,
    }, owner);
    assert.equal((await terminal(instance, started.operation_id)).state, "succeeded");
    assert.equal(realpathSync(resolution.requested), realpathSync(linked));
    assert.equal(resolution.projectRoot, realpathSync(root));
    assert.equal(resolution.context, owner);
    assert.equal(resolution.options.subject, "Operation");
    assert.equal(resolution.options.allowStartupRoot, true);
    rmSync(linked, { recursive: true, force: true });
  });

  test("non-Git parent accepts owned child worktree but rejects unrelated, canonical and symlink paths", async () => {
    const parent = mkdtempSync(join(tmpdir(), "aidevops-org-parent-"));
    const repo = join(parent, "child");
    const linked = join(tmpdir(), `aidevops-linked-${process.pid}-${Date.now()}`);
    const unrelated = join(tmpdir(), `aidevops-unrelated-${process.pid}-${Date.now()}`);
    const unrelatedLinked = `${unrelated}-linked`;
    const alias = join(parent, "alias");
    const previousRepos = process.env.AIDEVOPS_REPOS_JSON;
    let verified = 0;
    const options = {
      subject: "Operation",
      verifyWorktreeOwnership: async () => { verified++; },
    };
    try {
      mkdirSync(repo);
      execFileSync("git", ["init", "-q", repo]);
      execFileSync("git", ["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"]);
      execFileSync("git", ["-C", repo, "worktree", "add", "-q", "--detach", linked]);
      mkdirSync(unrelated);
      execFileSync("git", ["init", "-q", unrelated]);
      execFileSync("git", ["-C", unrelated, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"]);
      execFileSync("git", ["-C", unrelated, "worktree", "add", "-q", "--detach", unrelatedLinked]);
      symlinkSync(linked, alias);
      assert.deepEqual(await resolveSessionOwnedWorktreeRoot(linked, parent, owner, options), { root: realpathSync(linked), linked: true });
      assert.equal(verified, 1);
      await assert.rejects(resolveSessionOwnedWorktreeRoot(unrelatedLinked, parent, owner, options), /unrelated Git repository/);
      assert.deepEqual(await resolveGptImageProjectRoot(linked, parent, owner, options), { root: realpathSync(linked), linked: true });
      await assert.rejects(resolveGptImageProjectRoot(unrelatedLinked, parent, owner, options), /Image workdir belongs to an unrelated Git repository/);
      await assert.rejects(resolveGptImageProjectRoot(repo, parent, owner, options), /linked Git worktree/);
      await assert.rejects(resolveGptImageProjectRoot(alias, parent, owner, options), /unsafe/);
      const reposFile = join(parent, "repos.json");
      writeFileSync(reposFile, JSON.stringify({ initialized_repos: [{ path: unrelated }] }));
      process.env.AIDEVOPS_REPOS_JSON = reposFile;
      assert.deepEqual(await resolveSessionOwnedWorktreeRoot(unrelatedLinked, parent, owner, options), { root: realpathSync(unrelatedLinked), linked: true });
      delete process.env.AIDEVOPS_REPOS_JSON;
      await assert.rejects(resolveSessionOwnedWorktreeRoot(repo, parent, owner, options), /linked Git worktree/);
      await assert.rejects(resolveSessionOwnedWorktreeRoot(alias, parent, owner, options), /unsafe/);
      const instance = manager({ projectRoot: parent, resolveWorktreeRoot: (cwd, project, context) =>
        resolveSessionOwnedWorktreeRoot(cwd, project, context, options) });
      const started = await instance.start({ command: [process.execPath, "-e", "process.exit(0)"], cwd: linked, budgetMs: 1000 }, owner);
      assert.equal((await terminal(instance, started.operation_id)).state, "succeeded");
      await assert.rejects(instance.start({ command: [process.execPath], cwd: alias }, owner), /unsafe/);
      await assert.rejects(instance.start({ command: [process.execPath], cwd: repo }, owner), /linked Git worktree/);
      assert.equal(verified, 4, "rejected paths must not reach ownership verification");
    } finally {
      if (previousRepos === undefined) delete process.env.AIDEVOPS_REPOS_JSON;
      else process.env.AIDEVOPS_REPOS_JSON = previousRepos;
      execFileSync("git", ["-C", repo, "worktree", "remove", "--force", linked]);
      execFileSync("git", ["-C", unrelated, "worktree", "remove", "--force", unrelatedLinked]);
      rmSync(unrelated, { recursive: true, force: true });
      rmSync(parent, { recursive: true, force: true });
    }
  });

  test("explicit audited adoption enables a previous session worktree without taking a live owner", async () => {
    const fixture = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-adopt-")));
    const repo = join(fixture, "repo");
    const linked = join(fixture, "linked");
    const scriptsDir = fileURLToPath(new URL("../../../scripts/", import.meta.url));
    const helper = join(scriptsDir, "worktree-helper.sh");
    const env = { ...process.env, WORKTREE_REGISTRY_DIR: fixture,
      WORKTREE_REGISTRY_DB: join(fixture, "registry.db"), AUDIT_LOG_FILE: join(fixture, "audit.jsonl"),
      OPENCODE_SESSION_ID: owner.sessionID, OPENCODE_PID: String(process.pid) };
    const previousOwner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    try {
      execFileSync("git", ["init", "-q", repo]);
      execFileSync("git", ["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"]);
      execFileSync("git", ["-C", repo, "worktree", "add", "-q", "-b", "feature/adopt", linked]);
      execFileSync("bash", ["-c", 'source "$1"; register_worktree "$2" feature/adopt --owner-pid "$3" --session ses_previous --task 33228',
        "fixture", join(scriptsDir, "shared-constants.sh"), linked, String(previousOwner.pid)], { env });
      const invoke = (path = linked, task = "33228", overrides = {}) => execFileSync(helper,
        ["adopt", path, owner.sessionID, task], { env: { ...env, ...overrides }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      assert.throws(() => invoke(), "live owner must not be displaced");
      const exited = once(previousOwner, "exit");
      previousOwner.kill();
      await exited;
      assert.throws(() => invoke(linked, "other-task"));
      assert.throws(() => invoke(linked, "33228", { OPENCODE_SESSION_ID: "ses_other" }));
      assert.throws(() => invoke(repo));
      const alias = join(fixture, "alias");
      symlinkSync(linked, alias);
      assert.throws(() => invoke(alias));
      assert.equal(invoke().trim(), "ADOPTED");
      assert.equal(execFileSync(helper, ["registry", "verify-owner", linked, owner.sessionID], { env, encoding: "utf8" }).trim(), "VERIFIED");
      assert.throws(() => invoke(), "a now-live owner must not be re-adopted");
      const audit = readFileSync(env.AUDIT_LOG_FILE, "utf8");
      assert.match(audit, /Explicit worktree adoption requested/);
      assert.match(audit, /Worktree adoption verified/);
      const instance = manager({ projectRoot: fixture, scriptsDir });
      // The normal resolver uses the isolated registry, with no verification stub.
      const environmentKeys = ["WORKTREE_REGISTRY_DB", "AIDEVOPS_FULL_LOOP_CLEANUP_DIR",
        "AIDEVOPS_SESSION_ID", "OPENCODE_SESSION_ID", "OPENCODE_PID"];
      const priorEnvironment = Object.fromEntries(environmentKeys.map((key) => [key, process.env[key]]));
      process.env.WORKTREE_REGISTRY_DB = env.WORKTREE_REGISTRY_DB;
      process.env.AIDEVOPS_FULL_LOOP_CLEANUP_DIR = join(fixture, "cleanup-receipts");
      process.env.AIDEVOPS_SESSION_ID = "";
      process.env.OPENCODE_SESSION_ID = "ses_stale_host_environment";
      process.env.OPENCODE_PID = String(process.pid);
      try {
        const handoff = await instance.start({
          command: ["bash", "-c", 'SCRIPT_DIR="$1"; source "$SCRIPT_DIR/shared-constants.sh"; source "$SCRIPT_DIR/full-loop-helper-state.sh"; source "$SCRIPT_DIR/full-loop-helper-merge.sh"; _merge_record_deferred_cleanup_owner 123 example/repo "$2"',
            "fixture", scriptsDir, `${linked}\tfeature/adopt\t0`],
          cwd: linked, budgetMs: 15000,
        }, owner);
        assert.equal((await terminal(instance, handoff.operation_id, owner, 17000)).state, "succeeded");
        const receipt = JSON.parse(readFileSync(join(process.env.AIDEVOPS_FULL_LOOP_CLEANUP_DIR, "example_repo-123.json"), "utf8"));
        assert.equal(receipt.owner.session, owner.sessionID);
        assert.equal(receipt.owner.pid, process.pid);
        assert.equal(receipt.resource_cleanup_state, "CLEANUP_DEFERRED");
        assert.ok(receipt.owner.process_identity, "the live owner start identity is retained");
        assert.equal(execFileSync(helper, ["registry", "verify-owner", linked, owner.sessionID], { env, encoding: "utf8" }).trim(), "VERIFIED");
        assert.throws(() => invoke(), "cleanup deferral must not enable live-owner adoption");
        await assert.rejects(instance.start({ command: [process.execPath], cwd: linked }, { sessionID: "ses_other" }), /not owned/);
        const resumed = await instance.start({ command: [process.execPath, "-e", "process.exit(0)"], cwd: linked, budgetMs: 5000 }, owner);
        assert.equal((await terminal(instance, resumed.operation_id, owner, 7000)).state, "succeeded");
      } finally {
        for (const key of environmentKeys) {
          if (priorEnvironment[key] === undefined) delete process.env[key];
          else process.env[key] = priorEnvironment[key];
        }
      }
    } finally {
      previousOwner.kill();
      rmSync(fixture, { recursive: true, force: true });
    }
  });

  test("failure, timeout, and scoped cancellation cannot appear as success", async () => {
    const instance = manager();
    const failed = await instance.start({
      command: [process.execPath, "-e", "process.exit(7)"],
      budgetMs: 1000,
      progressIntervalMs: 20,
    }, owner);
    assert.equal((await terminal(instance, failed.operation_id)).state, "failed");

    const timed = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 30,
      progressIntervalMs: 10,
    }, owner);
    const timedResult = await terminal(instance, timed.operation_id);
    assert.equal(timedResult.state, "timed_out");
    assert.notEqual(timedResult.process_signal, null);

    const forked = await instance.start({
      command: [process.execPath, "-e", "const {spawn}=require('node:child_process'); const c=spawn(process.execPath,['-e','setTimeout(()=>{},1000)'],{stdio:['ignore','inherit','inherit']}); c.unref()"],
      budgetMs: 60,
      progressIntervalMs: 20,
    }, owner);
    assert.equal((await terminal(instance, forked.operation_id)).state, "timed_out");

    const cancellable = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 1000,
      progressIntervalMs: 20,
    }, owner);
    assert.throws(() => instance.cancel(cancellable.operation_id, { sessionID: "ses_other" }), /owner mismatch/);
    assert.equal(instance.status(cancellable.operation_id, owner).state, "running");
    assert.equal(instance.cancel(cancellable.operation_id, owner).state, "cancelling");
    assert.equal((await terminal(instance, cancellable.operation_id)).state, "cancelled");

    const spawnFailure = await instance.start({
      command: [join(root, "missing-executable")],
      restorationCommand: [process.execPath, "-e", "process.exit(0)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const spawnFailureResult = await terminal(instance, spawnFailure.operation_id);
    assert.equal(spawnFailureResult.state, "failed");
    assert.equal(spawnFailureResult.restoration_state, "succeeded");
  });

  test("helper-created process groups are contained on timeout and cancellation (GH#33514)", async () => {
    const alive = (pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    const nestedPid = (recordedBefore) => {
      const match = recorded.slice(recordedBefore).map((entry) => entry.content).join("\n").match(/nested:(\d+)/);
      assert.ok(match, "nested child PID was not reported");
      return Number(match[1]);
    };
    // An unrelated process group outside every operation must survive.
    const unrelated = spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
    unrelated.unref();
    try {
      const instance = manager();
      // `set -m` mirrors timeout_sec's fallback; GNU timeout also calls setpgid.
      const nestedCommand = ["bash", "-c", "set -m; sleep 30 & echo nested:$!; wait"];
      let recordedBefore = recorded.length;
      const timed = await instance.start({ command: nestedCommand, budgetMs: 400 }, owner);
      const timedResult = await terminal(instance, timed.operation_id, owner, 5000);
      assert.equal(timedResult.state, "timed_out");
      assert.equal(timedResult.containment, "owned_process_tree");
      assert.equal(timedResult.nested_process_groups, 1);
      assert.equal(alive(nestedPid(recordedBefore)), false, "nested process group survived the deadline");

      recordedBefore = recorded.length;
      const cancelled = await instance.start({ command: nestedCommand, budgetMs: 10_000 }, owner);
      await new Promise((resolve) => setTimeout(resolve, 400));
      instance.cancel(cancelled.operation_id, owner);
      const cancelledResult = await terminal(instance, cancelled.operation_id, owner, 5000);
      assert.equal(cancelledResult.state, "cancelled");
      assert.equal(alive(nestedPid(recordedBefore)), false, "nested process group survived cancellation");

      const timeoutBinary = ["timeout", "gtimeout"].find((name) => {
        try {
          execFileSync("sh", ["-c", `command -v ${name}`], { stdio: "ignore" });
          return true;
        } catch {
          return false;
        }
      });
      if (timeoutBinary) {
        const gnu = await instance.start({ command: [timeoutBinary, "30", "sleep", "30"], budgetMs: 400 }, owner);
        const gnuResult = await terminal(instance, gnu.operation_id, owner, 5000);
        assert.equal(gnuResult.state, "timed_out");
        assert.equal(gnuResult.containment, "owned_process_tree");
      }
      assert.equal(alive(unrelated.pid), true, "an unrelated process group was signalled");
    } finally {
      unrelated.kill("SIGKILL");
    }
  });

  test("detached test servers are drained on completion, cancellation and expiry (GH#33747)", async () => {
    const instance = manager({ killGraceMs: 50 });
    for (const mode of ["completion", "cancel", "expiry"]) {
      const pidFile = join(root, `escaped-${mode}.json`);
      const server = `const net=require('node:net'); process.on('SIGTERM',()=>{}); net.createServer().listen(0,'127.0.0.1',()=>require('node:fs').writeFileSync(${JSON.stringify(pidFile)},JSON.stringify({pid:process.pid})))`;
      const script = `const {spawn}=require('node:child_process'); const c=spawn(process.execPath,['-e',${JSON.stringify(server)}],{detached:true,stdio:'ignore'}); c.unref(); ${mode === "completion" ? `const t=setInterval(()=>{if(require('node:fs').existsSync(${JSON.stringify(pidFile)})){clearInterval(t);process.exit(0)}},10)` : "setInterval(()=>{},1000)"}`;
      const started = await instance.start({ command: [process.execPath, "-e", script], budgetMs: mode === "expiry" ? 1000 : 5000 }, owner);
      let pid;
      try {
        const deadline = Date.now() + 3000;
        while (Date.now() < deadline) {
          try { pid = JSON.parse(readFileSync(pidFile, "utf8")).pid; break; } catch { /* wait for listener */ }
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
        assert.ok(pid, "escaped server never listened");
        if (mode === "cancel") instance.cancel(started.operation_id, owner);
        const result = await terminal(instance, started.operation_id, owner, 5000);
        assert.equal(result.state, { completion: "succeeded", cancel: "cancelled", expiry: "timed_out" }[mode]);
        let running = false;
        try {
          process.kill(pid, 0);
          // PID 1 may retain a dead zombie on Linux containers.
          running = process.platform !== "linux" || !readFileSync(`/proc/${pid}/stat`, "utf8").includes(") Z ");
        } catch { /* process is gone */ }
        assert.equal(running, false, `${mode}: detached server survived cleanup`);
      } finally {
        if (pid) { try { process.kill(pid, "SIGKILL"); } catch { /* already drained */ } }
      }
    }
  });

  test("descendant attribution requires a matching process start identity", () => {
    const snapshot = parseProcessSnapshot([
      "100 1 100 Sun Oct  4 03:00:00 2026",
      "101 100 100 Sun Oct  4 03:00:01 2026",
      "102 101 102 Sun Oct  4 03:00:02 2026",
      "103 1 102 Sun Oct  4 03:00:02 2026",
      "200 1 200 Sun Oct  4 03:00:03 2026",
      "garbage",
    ].join("\n"));
    assert.equal(snapshot.length, 5);
    const owned = new Map();
    recordOwnedDescendants(snapshot, 100, owned);
    assert.deepEqual([...owned.keys()].sort(), [101, 102]);
    // 102 exited and its PID was reused by an unrelated process; 103 is a
    // reparented member only attributable through a verified recorded parent.
    const later = parseProcessSnapshot([
      "100 1 100 Sun Oct  4 03:00:00 2026",
      "102 1 102 Sun Oct  4 03:09:59 2026",
      "103 1 102 Sun Oct  4 03:00:02 2026",
      "200 1 200 Sun Oct  4 03:00:03 2026",
    ].join("\n"));
    recordOwnedDescendants(later, 100, owned);
    assert.deepEqual(verifiedNestedTargets(later, owned, 100), [], "a reused PID must never be signalled");
    const reparented = parseProcessSnapshot([
      "100 1 100 Sun Oct  4 03:00:00 2026",
      "102 1 102 Sun Oct  4 03:00:02 2026",
      "104 102 102 Sun Oct  4 03:00:05 2026",
      "200 1 200 Sun Oct  4 03:00:03 2026",
    ].join("\n"));
    const tracked = new Map(owned);
    tracked.set(102, { pgid: 102, started: "Sun Oct  4 03:00:02 2026" });
    recordOwnedDescendants(reparented, 100, tracked);
    assert.deepEqual(verifiedNestedTargets(reparented, tracked, 100).sort(), [102, 104]);
  });

  test("a launcher cannot report success without supervisor command evidence", async () => {
    const missingEvidence = manager({
      makeID: () => "op_fixture",
      spawn: launcher(),
    });
    const missingStarted = await missingEvidence.start({
      command: ["git", "--version"],
      budgetMs: 1000,
    }, owner);
    const missingResult = await terminal(missingEvidence, missingStarted.operation_id);
    assert.equal(missingResult.state, "failed");
    assert.equal(missingResult.process_exit, 0);
    assert.equal(missingResult.command_execution, "missing");

    const verifiedEvidence = manager({
      makeID: () => "op_fixture",
      spawn: launcher({ started: true }),
    });
    const verifiedStarted = await verifiedEvidence.start({
      command: ["git", "--version"],
      budgetMs: 1000,
    }, owner);
    const verifiedResult = await terminal(verifiedEvidence, verifiedStarted.operation_id);
    assert.equal(verifiedResult.state, "succeeded");
    assert.equal(verifiedResult.command_execution, "observed");
    assert.equal(verifiedResult.supervisor_runtime, "node v22.23.1");
  });

  test("restoration runs after success and remains visible when it fails", async () => {
    const instance = manager();
    const restored = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.exit(0)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const restoredResult = await terminal(instance, restored.operation_id);
    assert.equal(restoredResult.state, "succeeded");
    assert.equal(restoredResult.restoration_state, "succeeded");
    assert.equal(restoredResult.restoration_exit, 0);

    const brokenRestore = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.exit(9)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const brokenResult = await terminal(instance, brokenRestore.operation_id);
    assert.equal(brokenResult.state, "restoration_failed");
    assert.equal(brokenResult.restoration_state, "failed");
    assert.equal(brokenResult.restoration_exit, 9);

    const timedRestore = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "const {spawn}=require('node:child_process'); const c=spawn(process.execPath,['-e','setTimeout(()=>{},1000)'],{stdio:['ignore','inherit','inherit']}); c.unref()"],
      budgetMs: 1000,
      restorationBudgetMs: 30,
    }, owner);
    const timedRestoreResult = await terminal(instance, timedRestore.operation_id);
    assert.equal(timedRestoreResult.state, "restoration_failed");
    assert.equal(timedRestoreResult.restoration_state, "timed_out");
  });

  test("wait-aware status wakes when restoration reaches its timeout", async () => {
    const instance = manager({ kill: () => false });
    const started = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "setTimeout(() => process.exit(0), 200)"],
      budgetMs: 1000,
      restorationBudgetMs: 30,
    }, owner);
    const deadline = Date.now() + 1000;
    while (instance.status(started.operation_id, owner).state !== "restoring" && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    const result = await instance.status(started.operation_id, owner, { waitMs: 500 });
    assert.equal(result.state, "restoring");
    assert.equal(result.restoration_state, "timing_out");
    assert.equal((await terminal(instance, started.operation_id)).state, "restoration_failed");
  });

  test("expired generations and private command data stay isolated", async () => {
    const instance = manager();
    assert.throws(() => instance.status("op_stale_generation", owner), /expired generation/);
    const privateValue = `${root}/private-token-value`;
    const started = await instance.start({
      command: [process.execPath, "-e", `console.log(${JSON.stringify(privateValue)})`],
      budgetMs: 1000,
    }, owner);
    const result = await terminal(instance, started.operation_id);
    const serialized = JSON.stringify(result);
    assert.equal(serialized.includes(root), false);
    assert.equal(serialized.includes("private-token-value"), false);
    assert.match(result.output_id, /^out_fixture_/);

    const newlineFree = await instance.start({
      command: [process.execPath, "-e", "process.stdout.write('x'.repeat(20000))"],
      budgetMs: 1000,
    }, owner);
    await terminal(instance, newlineFree.operation_id);
    assert.ok(instance.operations.get(newlineFree.operation_id).progressRemainder.length <= 4096);
  });

  test("terminal output retrieval is bounded and session-owned", async () => {
    const instance = manager();
    const started = await instance.start({
      command: [process.execPath, "-e", "console.log('retrieval-proof')"],
      budgetMs: 1000,
    }, owner);
    await assert.rejects(instance.output(started.operation_id, owner), /only after.*terminal/i);
    await terminal(instance, started.operation_id);

    const result = await instance.output(started.operation_id, owner, { offset: 2, limit: 10 });
    assert.equal(result.schema, "aidevops.interactive-operation-output/v1");
    assert.equal(result.output, `2: output for ${result.output_id}\n`);
    assert.equal(result.offset, 2);
    assert.equal(result.limit, 10);
    await assert.rejects(instance.output(started.operation_id, { sessionID: "ses_other" }), /owner mismatch/);
    await assert.rejects(instance.output(started.operation_id, owner, { offset: 0 }), /positive integer/);
    await assert.rejects(instance.output(started.operation_id, owner, { limit: 501 }), /1 to 500/);

    const schemaNode = { optional() { return this; } };
    const z = { enum: () => schemaNode, string: () => schemaNode, number: () => schemaNode, array: () => schemaNode };
    const tool = createBoundedInteractiveOperationTool((definition) => definition, z, instance);
    const toolResult = JSON.parse(await tool.execute({
      action: "output",
      operation_id: started.operation_id,
      output_offset: 3,
      output_limit: 4,
    }, owner));
    assert.equal(toolResult.output, `3: output for ${toolResult.output_id}\n`);
  });

  test("the sandbox adapter retrieves stored output without exposing its path", async () => {
    const helper = fileURLToPath(new URL("../../../scripts/output-sandbox-helper.sh", import.meta.url));
    const previousDirectory = process.env.AIDEVOPS_OUTPUT_SANDBOX_DIR;
    process.env.AIDEVOPS_OUTPUT_SANDBOX_DIR = join(root, "output-sandbox");
    const recorder = createOutputSandboxRecorder(helper);
    const reader = createOutputSandboxReader(helper);
    try {
      const outputID = await recorder(Buffer.from("first\nsecond\n"), { exitCode: 0 });
      assert.match(outputID, /^out_/);
      const result = await reader(outputID, { offset: 2, limit: 1 });
      assert.equal(result.output, "2: second\n");
      assert.equal(result.redacted, false);
      assert.equal(result.output.includes(process.env.AIDEVOPS_OUTPUT_SANDBOX_DIR), false);
      await assert.rejects(reader("out_missing", { offset: 1, limit: 1 }), /output not found/);
    } finally {
      recorder.dispose();
      reader.dispose();
      if (previousDirectory === undefined) delete process.env.AIDEVOPS_OUTPUT_SANDBOX_DIR;
      else process.env.AIDEVOPS_OUTPUT_SANDBOX_DIR = previousDirectory;
    }
  });

  test("session deletion cancels only operations owned by that session", async () => {
    const instance = manager();
    const first = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 1000,
    }, owner);
    const secondOwner = { sessionID: "ses_second" };
    const second = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => process.exit(0), 100)"],
      budgetMs: 1000,
    }, secondOwner);
    instance.handleEvent({ event: { type: "session.deleted", properties: { info: { id: owner.sessionID } } } });
    const deadline = Date.now() + 2000;
    while (instance.operations.has(first.operation_id) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(instance.operations.has(first.operation_id), false);
    assert.equal((await terminal(instance, second.operation_id, secondOwner)).state, "succeeded");
  });
});
