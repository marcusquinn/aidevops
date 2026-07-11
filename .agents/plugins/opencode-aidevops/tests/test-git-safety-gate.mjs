// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { checkCommandSafetyGate } from "../quality-hooks-git-safety.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const scriptsDir = join(here, "..", "..", "..", "scripts");
const realGit = "/usr/bin/git";

function setupRepo() {
  const root = mkdtempSync(join(tmpdir(), "aidevops-git-gate-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  mkdirSync(repo);
  execFileSync(realGit, ["init", "-q", "-b", "main"], { cwd: repo });
  execFileSync(realGit, ["config", "user.name", "Test"], { cwd: repo });
  execFileSync(realGit, ["config", "user.email", "test@example.invalid"], { cwd: repo });
  execFileSync(realGit, ["config", "commit.gpgsign", "false"], { cwd: repo });
  writeFileSync(join(repo, "README.md"), "seed\n");
  execFileSync(realGit, ["add", "README.md"], { cwd: repo });
  execFileSync(realGit, ["commit", "-q", "-m", "seed"], { cwd: repo });
  execFileSync(realGit, ["worktree", "add", "-q", "-b", "feature/test", linked], { cwd: repo });
  return { root, repo, linked };
}

test("blocks canonical branch mutation before execution", () => {
  const { root, repo } = setupRepo();
  try {
    assert.throws(
      () => checkCommandSafetyGate("git branch -m main safety/example", scriptsDir, repo),
      /canonical worktree mutation/,
    );
    assert.equal(execFileSync(realGit, ["symbolic-ref", "--short", "HEAD"], { cwd: repo, encoding: "utf8" }).trim(), "main");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allows read-only canonical commands and linked-worktree mutation", () => {
  const { root, repo, linked } = setupRepo();
  try {
    assert.doesNotThrow(() => checkCommandSafetyGate("git status --short", scriptsDir, repo));
    assert.doesNotThrow(() => checkCommandSafetyGate("git switch -c feature/child", scriptsDir, linked));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allows the repository full-loop commit-and-pr wrapper only from a linked worktree", () => {
  const { root, repo, linked } = setupRepo();
  const wrapperCommand = "PR_NUMBER=$(full-loop-helper.sh commit-and-pr --issue 123 --testing 'git tests pass')";
  try {
    mkdirSync(join(repo, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(repo, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.throws(
      () => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, repo),
      /canonical worktree mutation/,
    );

    mkdirSync(join(linked, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(linked, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, linked));
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      "./.agents/scripts/full-loop-helper.sh commit-and-pr --issue 123 --testing 'git tests pass'",
      scriptsDir,
      linked,
    ));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("does not trust similarly named full-loop wrappers", () => {
  const { root, linked } = setupRepo();
  try {
    assert.throws(
      () => checkCanonicalGitSafetyGate("./tmp/full-loop-helper.sh commit-and-pr --testing 'git tests pass'", scriptsDir, linked),
      /unclassified nested Git invocation/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when policy engine is missing", () => {
  assert.throws(
    () => checkCommandSafetyGate("printf safe", "/missing/aidevops/scripts", process.cwd()),
    /policy helper is missing/,
  );
});

test("blocks generic destructive commands through shared policy", () => {
  assert.throws(
    () => checkCommandSafetyGate("rm -rf ./build-output", scriptsDir, process.cwd()),
    /forbid, filesystem\.rm-recursive-force/,
  );
});

test("rejects ambiguous shell syntax before execution", () => {
  assert.throws(
    () => checkCommandSafetyGate("printf one\nprintf two", scriptsDir, process.cwd()),
    /command\.parse-error.*multiline/,
  );
  assert.throws(
    () => checkCommandSafetyGate("curl https:\/\/\$\(printf example\.com\)", scriptsDir, process.cwd()),
    /command\.parse-error.*dynamic shell expansion/,
  );
});

test("enforces network policy in OpenCode worker tool adapter", () => {
  assert.throws(
    () => checkCommandSafetyGate(
      "curl --url HTTPS://requestbin.com/collect",
      scriptsDir,
      process.cwd(),
      { worker: true, workerId: "node-test" },
    ),
    /network\.worker-policy/,
  );
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "printf '%s' 'curl https://requestbin.com/collect'",
    scriptsDir,
    process.cwd(),
    { worker: true, workerId: "node-test" },
  ));
});

test("fails closed when required policy is malformed", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-command-policy-"));
  const isolatedScripts = join(root, "scripts");
  const isolatedConfigs = join(root, "configs");
  mkdirSync(isolatedScripts);
  mkdirSync(isolatedConfigs);
  try {
    copyFileSync(join(scriptsDir, "command-policy-helper.py"), join(isolatedScripts, "command-policy-helper.py"));
    copyFileSync(join(scriptsDir, "canonical-git-command-guard.py"), join(isolatedScripts, "canonical-git-command-guard.py"));
    writeFileSync(join(isolatedConfigs, "command-policy.json"), "{not-json\n");
    assert.throws(
      () => checkCommandSafetyGate("printf safe", isolatedScripts, process.cwd()),
      /policy\.invalid.*malformed/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
