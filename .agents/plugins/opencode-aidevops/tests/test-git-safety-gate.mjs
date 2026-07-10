import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { checkCanonicalGitSafetyGate } from "../quality-hooks-git-safety.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const scriptsDir = join(here, "..", "..", "..", "scripts");

function setupRepo() {
  const root = mkdtempSync(join(tmpdir(), "aidevops-git-gate-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  mkdirSync(repo);
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: repo });
  execFileSync("git", ["config", "user.email", "test@example.invalid"], { cwd: repo });
  execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: repo });
  writeFileSync(join(repo, "README.md"), "seed\n");
  execFileSync("git", ["add", "README.md"], { cwd: repo });
  execFileSync("git", ["commit", "-q", "-m", "seed"], { cwd: repo });
  execFileSync("git", ["worktree", "add", "-q", "-b", "feature/test", linked], { cwd: repo });
  return { root, repo, linked };
}

test("blocks canonical branch mutation before execution", () => {
  const { root, repo } = setupRepo();
  try {
    assert.throws(
      () => checkCanonicalGitSafetyGate("git branch -m main safety/example", scriptsDir, repo),
      /canonical worktree mutation/,
    );
    assert.equal(execFileSync("git", ["symbolic-ref", "--short", "HEAD"], { cwd: repo, encoding: "utf8" }).trim(), "main");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allows read-only canonical commands and linked-worktree mutation", () => {
  const { root, repo, linked } = setupRepo();
  try {
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate("git status --short", scriptsDir, repo));
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate("git switch -c feature/child", scriptsDir, linked));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when policy engine is missing", () => {
  assert.throws(
    () => checkCanonicalGitSafetyGate("git status", "/missing/aidevops/scripts", process.cwd()),
    /guard is missing/,
  );
});
