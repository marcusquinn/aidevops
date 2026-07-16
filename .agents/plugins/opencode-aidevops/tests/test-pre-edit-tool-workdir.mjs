// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createTools } from "../tools.mjs";

const testDir = dirname(fileURLToPath(import.meta.url));
const scriptsDir = resolve(testDir, "../../../scripts");

function git(cwd, args) {
  return execFileSync("/usr/bin/git", args, {
    cwd,
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

test("pre-edit tool validates the explicitly targeted Git worktree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t27909-pre-edit-tool-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
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

    const invalidResult = await preEditTool.execute({ workdir: nonGit, task: "fix fixture" });
    assert.match(invalidResult, /target workdir must resolve to an existing Git worktree/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
