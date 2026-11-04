// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#36608: direct worker pushes target only the dispatched repository's
// non-default branches; same-name forks keep the external-PR flow working.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { assertWorkerGitTargets } from "../worker-write-fence.mjs";
import { resolveTrustedExecutable } from "../../../scripts/trusted-executable.mjs";

const realGit = resolveTrustedExecutable("git");
// Every signal isHeadless() (proxy-lifecycle.mjs) reads. GITHUB_ACTIONS is set
// on CI runners, so clearing only AIDEVOPS_HEADLESS leaves CI headless (GH#36694).
const HEADLESS_SIGNALS = ["FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS", "GITHUB_ACTIONS"];

test("headless workers push only task branches to their own repository", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-push-fence-"));
  const repo = join(root, "repo");
  mkdirSync(repo);
  const env = {
    AIDEVOPS_HEADLESS: "1",
    WORKER_WORKTREE_PATH: repo,
    WORKER_REPO_SLUG: "owner/repo",
    AIDEVOPS_TEMP_DIR: join(root, "managed-tmp"),
  };
  const previousSignals = Object.fromEntries(HEADLESS_SIGNALS.map((name) => [name, process.env[name]]));
  try {
    execFileSync(realGit, ["init", "-q", "-b", "feature/test"], { cwd: repo });
    execFileSync(realGit, ["remote", "add", "origin", "https://github.com/owner/repo.git"], { cwd: repo });
    execFileSync(realGit, ["remote", "add", "other", "git@github.com:other/tool.git"], { cwd: repo });
    execFileSync(realGit, ["remote", "add", "fork", "git@github.com:me/repo.git"], { cwd: repo });
    // isHeadless() reads the process environment, not the injected env.
    process.env.AIDEVOPS_HEADLESS = "1";
    const check = (command) => assertWorkerGitTargets(command, repo, env);
    const blocked = /Workers push only their task branch to their own repository/;

    assert.doesNotThrow(() => check("git push -u origin feature/test"));
    assert.doesNotThrow(() => check("git push"));
    assert.doesNotThrow(() => check("git push fork main"));
    assert.throws(() => check("git push origin HEAD:main"), blocked);
    assert.throws(() => check("git push origin +feature/test:refs/heads/master"), blocked);
    assert.throws(() => check("git push --mirror origin"), blocked);
    assert.throws(() => check("git push other HEAD:fix"), /targets other\/tool/);
    assert.throws(() => check("git push https://github.com/other/tool.git HEAD:fix"), blocked);
    assert.throws(() => check("git push missing HEAD:fix"), blocked);
    assert.throws(() => check(`cd ${repo} && git push other HEAD:fix`), blocked);

    for (const name of HEADLESS_SIGNALS) delete process.env[name];
    assert.doesNotThrow(() => check("git push other HEAD:fix"));
  } finally {
    for (const [name, value] of Object.entries(previousSignals)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    rmSync(root, { recursive: true, force: true });
  }
});
