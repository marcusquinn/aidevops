// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createTools } from "../tools.mjs";

const testDir = dirname(fileURLToPath(import.meta.url));
const scriptsDir = resolve(testDir, "../../../scripts");

function git(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

test("caller context preserves its live runtime PID and fences other sessions", async () => {
  const root = mkdtempSync(join(tmpdir(), "gh36057-pre-edit-owner-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  const runtime = spawn("sleep", ["120"]);
  const overrides = {
    WORKTREE_REGISTRY_DIR: join(root, "registry"),
    WORKTREE_REGISTRY_DB: join(root, "registry", "owners.db"),
    OPENCODE: "1",
    OPENCODE_PID: String(runtime.pid),
    OPENCODE_SESSION_ID: "ses_caller_fixture",
    AIDEVOPS_OPENCODE_SESSION_ID: "ses_caller_fixture",
    FULL_LOOP_HEADLESS: "false",
  };
  const saved = Object.fromEntries(Object.keys(overrides).map((key) => [key, process.env[key]]));
  Object.assign(process.env, overrides);
  try {
    mkdirSync(repo);
    git(repo, ["init", "--initial-branch=main"]);
    git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"]);
    git(repo, ["worktree", "add", "-b", "bugfix/caller-fixture", linked]);
    const bashResult = execFileSync("bash", [join(scriptsDir, "pre-edit-check.sh")], {
      cwd: linked, encoding: "utf8", env: process.env,
    });
    assert.match(bashResult, /OK.*In linked worktree/);
    const tool = createTools(scriptsDir, () => "").aidevops_pre_edit_check;
    const result = await tool.execute({ workdir: linked }, { sessionID: "ses_caller_fixture" });
    assert.match(result, /Pre-edit check PASSED/);
    assert.doesNotMatch(result, /transaction unavailable|WORKTREE_OWNERSHIP_CONFLICT/);
    const owner = () => execFileSync("sqlite3", [overrides.WORKTREE_REGISTRY_DB,
      "SELECT owner_pid || '|' || owner_session FROM worktree_owners;"], { encoding: "utf8" }).trim();
    assert.equal(owner(), `${runtime.pid}|ses_caller_fixture`, "tool and Bash must retain the same runtime owner");

    // Tool arguments cannot impersonate the caller; context is authoritative.
    const rejected = await tool.execute({ workdir: linked, sessionID: "ses_caller_fixture",
      OPENCODE_PID: String(runtime.pid) }, { sessionID: "ses_other_fixture" });
    assert.match(rejected, /WORKTREE_OWNERSHIP_CONFLICT=true/);
    assert.equal(owner(), `${runtime.pid}|ses_caller_fixture`);

    // Multiple sessions can share one OpenCode server process. Equal PID alone
    // must not let another session rewrite the existing session stamp.
    const sharedPidResult = (() => {
      try {
        return execFileSync("bash", [join(scriptsDir, "pre-edit-check.sh")], {
          cwd: linked, encoding: "utf8", env: { ...process.env, OPENCODE_SESSION_ID: "ses_other_fixture" },
        });
      } catch (error) {
        return String(error.stdout) + String(error.stderr);
      }
    })();
    assert.match(sharedPidResult, /WORKTREE_OWNERSHIP_CONFLICT=true/);
    assert.equal(owner(), `${runtime.pid}|ses_caller_fixture`);

    // A transaction error must fail closed without asserting another live owner
    // or inviting the same session to create a duplicate worktree.
    execFileSync("sqlite3", [overrides.WORKTREE_REGISTRY_DB,
      "CREATE TRIGGER reject_write BEFORE UPDATE ON worktree_owners BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"]);
    const unavailable = await tool.execute({ workdir: linked }, { sessionID: "ses_caller_fixture" });
    assert.match(unavailable, /WORKTREE_OWNERSHIP_UNAVAILABLE=true/);
    assert.match(unavailable, /WORKTREE_OWNERSHIP_ERROR_STAGE=write/);
    assert.doesNotMatch(unavailable, /WORKTREE_OWNERSHIP_CONFLICT=true|fixture failure/);
    assert.equal(owner(), `${runtime.pid}|ses_caller_fixture`);
  } finally {
    runtime.kill();
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(root, { recursive: true, force: true });
  }
});

test("pre-edit tool validates the explicitly targeted Git worktree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t27909-pre-edit-tool-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  const otherLinked = join(root, "other-linked");
  const nonGit = join(root, "not-git");
  const injectionMarker = join(root, "injected");

  try {
    mkdirSync(repo);
    mkdirSync(nonGit);
    git(repo, ["init", "--initial-branch=main"]);
    git(repo, ["config", "user.email", "test@example.invalid"]);
    git(repo, ["config", "user.name", "Test"]);
    git(repo, ["config", "commit.gpgsign", "false"]);
    writeFileSync(join(repo, "README.md"), "fixture\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "--no-gpg-sign", "-m", "init"]);
    git(repo, ["worktree", "add", "-b", "bugfix/fixture", linked]);
    git(repo, ["worktree", "add", "-b", "bugfix/other-fixture", otherLinked]);

    const preEditTool = createTools(scriptsDir, () => "").aidevops_pre_edit_check;
    const canonicalResult = await preEditTool.execute({ workdir: repo });
    assert.match(canonicalResult, /Pre-edit check exit [12]:/);
    assert.match(canonicalResult, /create a worktree/i);

    const linkedResult = await preEditTool.execute({
      workdir: linked,
      task: `fix fixture '; touch ${injectionMarker}`,
    });
    assert.match(linkedResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.equal(existsSync(injectionMarker), false, "task text must remain one argv value");

    const otherLinkedResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(otherLinked, "README.md")],
    });
    assert.match(otherLinkedResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.match(otherLinkedResult, /bugfix\/other-fixture/);
    assert.doesNotMatch(otherLinkedResult, /bugfix\/fixture[^-]/);

    const multipleWorktreesResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(linked, "README.md"), join(otherLinked, "README.md")],
    });
    assert.match(multipleWorktreesResult, /explicit repository targets span multiple worktrees/);
    assert.doesNotMatch(multipleWorktreesResult, /Pre-edit check PASSED/);

    const invalidResult = await preEditTool.execute({ workdir: nonGit, task: "fix fixture" });
    assert.match(invalidResult, /target workdir must resolve to an existing Git worktree/);

    const worktreesBefore = git(repo, ["worktree", "list", "--porcelain"]);
    const externalResult = await preEditTool.execute({
      workdir: repo,
      task: "update personal configuration",
      targetPaths: [join(nonGit, "custom.sh"), join(root, "LaunchAgents", "fixture.plist")],
    });
    assert.match(externalResult, /Git isolation not applicable/);
    assert.match(externalResult, /does not authorize file writes/);
    assert.equal(git(repo, ["worktree", "list", "--porcelain"]), worktreesBefore);

    const repositoryResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(repo, "nested", "..", "README.md")],
    });
    assert.match(repositoryResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(repositoryResult, /Git isolation not applicable/);

    const mixedResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(nonGit, "custom.sh"), join(repo, "README.md")],
    });
    assert.match(mixedResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(mixedResult, /Git isolation not applicable/);

    const linkedToCanonicalResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(repo, "README.md")],
    });
    assert.match(linkedToCanonicalResult, /failed closed/);
    assert.doesNotMatch(linkedToCanonicalResult, /Pre-edit check PASSED/);

    const symlinkEscape = join(repo, "external-link");
    symlinkSync(nonGit, symlinkEscape);
    const symlinkResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(symlinkEscape, "custom.sh")],
    });
    assert.match(symlinkResult, /failed closed/);
    assert.doesNotMatch(symlinkResult, /Git isolation not applicable/);

    const traversalResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: ["../not-git/custom.sh"],
    });
    assert.match(traversalResult, /parent traversal.*ambiguous/);
    assert.doesNotMatch(traversalResult, /Git isolation not applicable/);

    const repositoryLink = join(nonGit, "repository-link");
    symlinkSync(repo, repositoryLink);
    const repositorySymlinkResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(repositoryLink, "README.md")],
    });
    assert.match(repositorySymlinkResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(repositorySymlinkResult, /Git isolation not applicable/);

    const malformedResult = await preEditTool.execute({ workdir: repo, targetPaths: [""] });
    assert.match(malformedResult, /failed closed/);
    const malformedArrayResult = await preEditTool.execute({ workdir: repo, targetPaths: {} });
    assert.match(malformedArrayResult, /targetPaths must be an array/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("slow loop-mode creation is reported exactly once beyond the former timeout", { timeout: 30000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), "t28080-pre-edit-slow-"));
  const repo = join(root, "repo");
  const linked = join(root, "slow-linked");
  const fixtureScripts = join(root, "scripts");

  try {
    mkdirSync(repo);
    mkdirSync(fixtureScripts);
    git(repo, ["init", "--initial-branch=main"]);
    git(repo, ["config", "user.email", "test@example.invalid"]);
    git(repo, ["config", "user.name", "Test"]);
    git(repo, ["config", "commit.gpgsign", "false"]);
    writeFileSync(join(repo, "README.md"), "fixture\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "--no-gpg-sign", "-m", "init"]);
    writeFileSync(join(fixtureScripts, "pre-edit-check.sh"), `#!/usr/bin/env bash
set -eu
[[ "\${OPENCODE_SESSION_ID:-}" == "ses_pre_edit_fixture" ]] || exit 9
[[ "\${OPENCODE_PID:-}" =~ ^[0-9]+$ ]] || exit 10
linked=${JSON.stringify(linked)}
if ! git -C "$PWD" show-ref --verify --quiet refs/heads/bugfix/slow-fixture; then
  sleep 10.1
  git -C "$PWD" worktree add -q -b bugfix/slow-fixture "$linked"
fi
printf 'LOOP_DECISION=worktree_created\\nWORKTREE_PATH=%s\\nNEXT_STEP: cd to the worktree path and continue implementation there.\\n' "$linked"
`);

    const preEditTool = createTools(fixtureScripts, () => "").aidevops_pre_edit_check;
    const context = { sessionID: "ses_pre_edit_fixture" };
    const firstResult = await preEditTool.execute({ workdir: repo, task: "fix slow fixture" }, context);
    const secondResult = await preEditTool.execute({ workdir: repo, task: "fix slow fixture" }, context);

    assert.match(firstResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.match(firstResult, new RegExp(`WORKTREE_PATH=${linked.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    assert.match(secondResult, /Pre-edit check PASSED \(exit 0\)/);
    const worktreeList = git(repo, ["worktree", "list", "--porcelain"]);
    assert.equal(worktreeList.split("branch refs/heads/bugfix/slow-fixture").length - 1, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("timeout is explicit and terminates the complete fixture process tree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t28080-pre-edit-timeout-"));
  const repo = join(root, "repo");
  const fixtureScripts = join(root, "scripts");
  const lateMarker = join(root, "late-side-effect");

  try {
    mkdirSync(repo);
    mkdirSync(fixtureScripts);
    git(repo, ["init", "--initial-branch=main"]);
    writeFileSync(join(fixtureScripts, "pre-edit-check.sh"), `#!/usr/bin/env bash
sleep 0.2
touch ${JSON.stringify(lateMarker)}
`);
    const preEditTool = createTools(fixtureScripts, () => "", { preEditTimeoutMs: 25 }).aidevops_pre_edit_check;
    const result = await preEditTool.execute({ workdir: repo, task: "fix timeout fixture" });

    assert.match(result, /Pre-edit check TIMED OUT after 25ms/);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 300));
    assert.equal(existsSync(lateMarker), false, "timed-out descendants must not complete side effects");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
