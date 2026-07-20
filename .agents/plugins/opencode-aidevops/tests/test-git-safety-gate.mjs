// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  checkCanonicalGitSafetyGate,
  checkCanonicalWriteSafetyGate,
  checkCommandSafetyGate,
  isDirectFileMutationTool,
} from "../quality-hooks-git-safety.mjs";

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

test("classifies built-in and namespaced direct file mutation tools", () => {
  for (const tool of ["Write", "write_file", "edit", "edit_file", "write", "functions.apply_patch", "namespace/Edit", "tools::apply-patch"]) {
    assert.equal(isDirectFileMutationTool(tool), true, tool);
  }
  for (const tool of ["Bash", "read", "functions.read", "glob"]) {
    assert.equal(isDirectFileMutationTool(tool), false, tool);
  }
});

test("classifies every apply-patch target instead of trusting linked cwd", () => {
  const { root, repo, linked } = setupRepo();
  try {
    const linkedPatch = "*** Begin Patch\n*** Add File: linked-only.md\n+safe\n*** End Patch\n";
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, linkedPatch),
    );
    const absoluteLinkedPatch = `*** Begin Patch\n*** Add File: ${join(linked, "absolute-linked.md")}\n+safe\n*** End Patch\n`;
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, absoluteLinkedPatch),
      "an absolute linked-worktree target must not inherit the canonical workspace classification",
    );
    const canonicalPatch = `*** Begin Patch\n*** Update File: ${join(repo, "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, canonicalPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    const traversalPatch = `*** Begin Patch\n*** Update File: ${join(linked, "..", "repo", "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, traversalPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    symlinkSync(repo, join(linked, "canonical-link"));
    const symlinkPatch = `*** Begin Patch\n*** Update File: ${join(linked, "canonical-link", "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, symlinkPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, ""),
      /targets could not be classified/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, { invalid: true }),
      /targets could not be classified/,
    );

    const outsideTarget = join(root, "aidevops-issue-body.md");
    const outsidePatch = `*** Begin Patch\n*** Add File: ${outsideTarget}\n+safe\n*** End Patch\n`;
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, outsidePatch),
    );
    const mixedPatch = `*** Begin Patch\n*** Add File: ${outsideTarget}\n+safe\n*** Update File: ${join(repo, "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, mixedPatch),
      /canonical write policy.*read-only session mirrors/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when canonical policy returns a non-object payload", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-canonical-policy-"));
  const isolatedScripts = join(root, "scripts");
  mkdirSync(isolatedScripts);
  try {
    writeFileSync(
      join(isolatedScripts, "canonical-write-policy-helper.py"),
      "print('null')\n",
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("README.md", isolatedScripts),
      /malformed output/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("blocks every canonical direct write and preserves linked-worktree writes", () => {
  const { root, repo, linked } = setupRepo();
  try {
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(repo, "README.md"), scriptsDir, repo),
      /canonical write policy.*read-only session mirrors/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo),
      /canonical write policy/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(repo, "new-file.md"), scriptsDir, linked),
      /canonical write policy/,
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "README.md"), scriptsDir, linked),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "README.md"), scriptsDir, repo),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("new-file.md", scriptsDir, linked),
    );
    const bodyDir = join(root, ".aidevops", ".agent-workspace", "tmp");
    mkdirSync(bodyDir, { recursive: true });
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(bodyDir, "issue-body.md"), scriptsDir, repo),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "from-canonical.md"), scriptsDir, repo),
    );

    const canonicalAlias = join(root, "canonical-alias");
    symlinkSync(repo, canonicalAlias, "dir");
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(canonicalAlias, "README.md"), scriptsDir, repo),
      /canonical write policy.*read-only session mirrors/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

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
  const activeScriptsDir = join(root, "active", "agents", "scripts");
  try {
    mkdirSync(join(repo, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(repo, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.throws(
      () => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, repo),
      /canonical worktree mutation/,
    );

    mkdirSync(join(linked, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(linked, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    mkdirSync(dirname(activeScriptsDir), { recursive: true });
    symlinkSync(scriptsDir, activeScriptsDir, "dir");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, linked));
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      "./.agents/scripts/full-loop-helper.sh commit-and-pr --issue 123 --testing 'git tests pass'",
      scriptsDir,
      linked,
    ));
    const repositoryWrapper = join(linked, ".agents", "scripts", "full-loop-helper.sh");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      `${repositoryWrapper} commit-and-pr --issue 123`,
      scriptsDir,
      linked,
    ));
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${join(repo, ".agents", "scripts", "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        repo,
      ),
      /canonical worktree mutation/,
    );
    const activeWrapper = join(activeScriptsDir, "full-loop-helper.sh");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      `PR_NUMBER=$(${activeWrapper} commit-and-pr --issue 123 --message 'fix: example')`,
      scriptsDir,
      linked,
      { activeScriptsDir },
    ));
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${activeWrapper} commit-and-pr --issue 123`,
        scriptsDir,
        repo,
        { activeScriptsDir },
      ),
      /canonical worktree mutation/,
    );
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      `${join(scriptsDir, "full-loop-helper.sh")} commit-and-pr --issue 123 --testing 'git tests pass'`,
      scriptsDir,
      linked,
    ));
    const homeRelativeScripts = scriptsDir.startsWith(`${process.env.HOME}/`)
      ? `~/${scriptsDir.slice(process.env.HOME.length + 1)}`
      : null;
    if (homeRelativeScripts) {
      assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
        `${homeRelativeScripts}/full-loop-helper.sh commit-and-pr --issue 123`,
        scriptsDir,
        linked,
      ));
    }
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
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        "$HOME/.aidevops/agents/scripts/full-loop-helper.sh commit-and-pr --issue 123",
        scriptsDir,
        linked,
      ),
      /unclassified nested Git invocation/,
    );
    const unrelatedScripts = join(root, "unrelated", "scripts");
    mkdirSync(unrelatedScripts, { recursive: true });
    writeFileSync(join(unrelatedScripts, "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${join(unrelatedScripts, "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        linked,
        { activeScriptsDir: unrelatedScripts },
      ),
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

test("blocks account mutations unless inherited authorization matches exactly", () => {
  const cwd = process.cwd();
  const helper = join(scriptsDir, "command-policy-helper.py");
  const command = "gh repo fork owner/source --clone=false";
  const previousAuthorization = process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
  const authorization = execFileSync(
    "python3",
    [helper, "authorization-digest", "--cwd", cwd, "--command", command],
    { encoding: "utf8" },
  ).trim();
  try {
    delete process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, cwd),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate(
        "bash -lc 'gh repo fork owner/source --clone=false'",
        scriptsDir,
        cwd,
      ),
      /github\.account-mutation/,
    );
    assert.doesNotThrow(() => checkCommandSafetyGate("gh repo view owner/source", scriptsDir, cwd));

    process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = authorization;
    assert.doesNotThrow(() => checkCommandSafetyGate(command, scriptsDir, cwd));
    assert.throws(
      () => checkCommandSafetyGate(
        "sudo -n gh repo fork owner/source --clone=false",
        scriptsDir,
        cwd,
      ),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate("gh repo fork owner/different --clone=false", scriptsDir, cwd),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate("gh repo create owner/new-repo --public", scriptsDir, cwd),
      /github\.account-mutation/,
    );
  } finally {
    if (previousAuthorization === undefined) {
      delete process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
    } else {
      process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = previousAuthorization;
    }
  }
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
    for (const moduleName of readdirSync(scriptsDir).filter((name) => /^command_policy_.*\.py$/.test(name))) {
      copyFileSync(join(scriptsDir, moduleName), join(isolatedScripts, moduleName));
    }
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

test("fails closed when command policy exits nonzero with an allow payload", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-command-policy-exit-"));
  const isolatedScripts = join(root, "scripts");
  mkdirSync(isolatedScripts);
  try {
    writeFileSync(
      join(isolatedScripts, "command-policy-helper.py"),
      "import sys\nprint('{\"decision\":\"allow\"}')\nsys.exit(1)\n",
    );
    assert.throws(
      () => checkCommandSafetyGate("printf safe", isolatedScripts, process.cwd()),
      /shared command policy \(allow/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
