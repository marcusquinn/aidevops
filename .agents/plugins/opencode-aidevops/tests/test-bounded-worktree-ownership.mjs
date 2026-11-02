// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { runtimeOwner } from "../runtime-owner.mjs";
import { processStartIdentity } from "../process-start-identity.mjs";

const scripts = fileURLToPath(new URL("../../../scripts/", import.meta.url));
const registry = join(scripts, "../worker-lifecycle/worker-registry.py");
const managerURL = new URL("../bounded-interactive-operation.mjs", import.meta.url).href;
const preEditURL = new URL("../pre-edit-check-tool.mjs", import.meta.url).href;
const admissionURL = new URL("../lifecycle-admission.mjs", import.meta.url).href;

function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "bounded-ownership-")));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, "repo");
  const target = join(root, "tree");
  const state = join(root, "state");
  const env = { ...process.env,
    AIDEVOPS_LIFECYCLE_STATE_DIR: state,
    WORKTREE_REGISTRY_DIR: join(root, "legacy"),
    WORKTREE_REGISTRY_DB: join(root, "legacy", "registry.db"),
    AIDEVOPS_PRIVATE_WORKLOAD: "0", AIDEVOPS_LIFECYCLE_DISABLED: "0",
    FULL_LOOP_HEADLESS: "false", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1",
  };
  for (const key of Object.keys(env)) {
    if (["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"].includes(key)) continue;
    const runtimePrefixes = ["OPENCODE", "WORKER_", "GIT_", "AIDEVOPS_LIFECYCLE_RUNTIME"];
    if (runtimePrefixes.some(prefix => key.startsWith(prefix))) delete env[key];
    if (key === "AIDEVOPS_LIFECYCLE_SESSION_ID") delete env[key];
  }
  const git = (args) => execFileSync("git", args, { env, encoding: "utf8", stdio: "pipe" });
  git(["init", "-q", "--initial-branch=main", repo]);
  git(["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "commit", "-q", "--allow-empty", "-m", "fixture"]);
  const command = ["bash", "-c", 'source "$1"; worktree_create_registered "$2" "$3" HEAD -b bugfix/session',
    "fixture", join(scripts, "shared-worktree-create.sh"), repo, target];
  const prepare = () => JSON.parse(execFileSync("python3", ["-E", "-s", "-B", registry,
    "--state-dir", state, "prepare-cleanup", "--path", target], { env, encoding: "utf8" }));
  return { root, repo, target, state, env, command, prepare };
}

test("bounded creation retains the actual interactive runtime until it exits", { timeout: 180000 }, async (t) => {
  const f = fixture(t);
  const program = `
    import { execFileSync } from 'node:child_process';
    import { BoundedInteractiveOperationManager } from ${JSON.stringify(managerURL)};
    import { createPreEditCheckTool } from ${JSON.stringify(preEditURL)};
    import { admitToolOwner } from ${JSON.stringify(admissionURL)};
    import { processStartIdentity } from ${JSON.stringify(new URL("../process-start-identity.mjs", import.meta.url).href)};
    const context = { sessionID: 'ses_interactive_fixture' };
    process.env.OPENCODE_PID = String(process.pid);
    process.env.OPENCODE_PID_START_IDENTITY = processStartIdentity(process.pid);
    process.env.OPENCODE_SESSION_ID = context.sessionID;
    const manager = new BoundedInteractiveOperationManager({ projectRoot: ${JSON.stringify(f.repo)},
      recordOutput: async content => { process.stderr.write(content); return 'fixture'; } });
    const start = await manager.start({ command: ${JSON.stringify(f.command)}, budgetMs: 120000 }, context);
    let result;
    do { result = await manager.status(start.operation_id, context, { waitMs: 1000 }); }
    while (['starting', 'running', 'timing_out', 'finalizing'].includes(result.state));
    if (result.state !== 'succeeded') throw new Error(JSON.stringify(result));
    // The command and supervisor have ended, but the interactive runtime continues.
    // Check BEFORE a subsequent tool admission can mask incorrect creation ownership.
    const initial = JSON.parse(execFileSync('python3', ['-E', '-s', '-B', ${JSON.stringify(registry)},
      '--state-dir', ${JSON.stringify(f.state)}, 'prepare-cleanup', '--path', ${JSON.stringify(f.target)}], { encoding: 'utf8' }));
    if (initial.status !== 'waiting-for-runs' || !initial.creation_verified)
      throw new Error('creation ownership lost: ' + JSON.stringify(initial));
    admitToolOwner({ scriptsDir: ${JSON.stringify(scripts)}, input: { tool: 'bash', ...context },
      output: { args: { workdir: ${JSON.stringify(f.target)}, command: 'git status --short' } }, bash: true });
    const schema = { optional() { return this; }, describe() { return this; } };
    const tool = createPreEditCheckTool(x => x, { string: () => schema, array: () => schema }, ${JSON.stringify(scripts)});
    const checked = await tool.execute({ workdir: ${JSON.stringify(f.target)} }, context);
    if (!checked.includes('PASSED')) throw new Error(checked);
    console.log('READY');
    process.stdin.resume();
    process.stdin.on('end', () => { manager.dispose(); });
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", program], { env: f.env });
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });
  let output = "";
  let errors = "";
  child.stderr.on("data", chunk => { errors += chunk; });
  child.stdout.on("data", chunk => { output += chunk; });
  const exited = once(child, "exit");
  await new Promise((resolve, reject) => {
    child.stdout.on("data", () => { if (output.includes("READY")) resolve(); });
    child.once("exit", code => reject(new Error(`runtime exited ${code}: ${errors}`)));
  });
  const active = f.prepare();
  assert.equal(active.creation_verified, true);
  assert.equal(active.status, "waiting-for-runs");
  assert.equal(active.admission, "open");
  assert.equal(active.cleanup_authorized, false);
  assert.ok(existsSync(f.target));
  child.stdin.end();
  assert.equal((await exited)[0], 0, errors);
  const ended = f.prepare();
  assert.equal(ended.status, "registered-runs-ended");
  assert.equal(ended.admission, "closed");
  assert.equal(ended.creation_verified, true);
  // Preparation still cannot authorize deletion without preservation verification.
  assert.equal(ended.cleanup_authorized, false);
});

test("undeclared creation remains a coverage gap instead of adopting the producer", (t) => {
  const f = fixture(t);
  execFileSync(f.command[0], f.command.slice(1), { env: f.env, cwd: f.repo, stdio: "pipe" });
  const result = f.prepare();
  assert.equal(result.status, "coverage-gap");
  assert.equal(result.creation_verified, false);
  assert.equal(result.admission, "open");
});

test("runtime owner requires matching session and original native generation proof", async () => {
  const child = spawn("sleep", ["30"]);
  const keys = ["OPENCODE_PID", "OPENCODE_PID_START_IDENTITY", "OPENCODE_SESSION_ID"];
  const saved = keys.map(key => process.env[key]);
  try {
    process.env.OPENCODE_PID = String(child.pid);
    process.env.OPENCODE_PID_START_IDENTITY = processStartIdentity(child.pid);
    process.env.OPENCODE_SESSION_ID = "ses_fixture";
    assert.equal(runtimeOwner("ses_fixture").pid, String(child.pid));
    // Without matching inherited proof, the plugin's own runtime owns the
    // session (GH#36430); a foreign or stale identity is never adopted.
    const self = { pid: String(process.pid), identity: processStartIdentity(process.pid) };
    assert.deepEqual(runtimeOwner("ses_other"), self);
    process.env.OPENCODE_PID_START_IDENTITY = "stale-generation";
    assert.deepEqual(runtimeOwner("ses_fixture"), self);
    delete process.env.OPENCODE_PID_START_IDENTITY;
    assert.deepEqual(runtimeOwner("ses_fixture"), self);
    for (const key of keys) delete process.env[key];
    assert.deepEqual(runtimeOwner("ses_fixture"), self);
  } finally {
    child.kill();
    await once(child, "exit");
    keys.forEach((key, index) => {
      if (saved[index] === undefined) delete process.env[key];
      else process.env[key] = saved[index];
    });
  }
});
