// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for t3538: interactive OpenCode shells must stamp
// AIDEVOPS_SESSION_ORIGIN=interactive even when a stale worker-origin value is
// inherited by the shell environment. Without this, gh_create_issue labels
// maintainer-created issues as origin:worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createShellEnvHook } from "../shell-env.mjs";

function makeHook() {
  return createShellEnvHook({
    agentsDir: "/tmp/aidevops-agents",
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
  });
}

function withTempAgentsDir(fn) {
  const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-"));
  const dir = join(root, "agents");
  mkdirSync(dir);
  try {
    return fn(dir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function makeHookForAgentsDir(agentsDir) {
  return createShellEnvHook({
    agentsDir,
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
  });
}

function makeHookForAgentsDirAndVersion(agentsDir, version) {
  return createShellEnvHook({
    agentsDir,
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
    version,
  });
}

async function withCleanHeadlessProcessEnv(fn) {
  const keys = ["FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS", "GITHUB_ACTIONS"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    for (const key of keys) delete process.env[key];
    await fn();
  } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

test("interactive OpenCode shell overrides stale worker origin", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const hook = makeHook();
    const output = {
      env: {
        PATH: "/usr/bin:/bin",
        AIDEVOPS_SESSION_ORIGIN: "worker",
      },
    };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "interactive");
  });
});

test("headless OpenCode shell stamps worker origin", async () => {
  const hook = makeHook();
  const output = {
    env: {
      PATH: "/usr/bin:/bin",
      OPENCODE_HEADLESS: "true",
      AIDEVOPS_SESSION_ORIGIN: "interactive",
    },
  };

  await hook({ sessionID: "worker-session" }, output);

  assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "worker");
});

test("shell env version prefers deployed agents VERSION over legacy version", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
    writeFileSync(join(agentsDir, "..", "version"), "2.44.2\n");

    const hook = makeHookForAgentsDir(agentsDir);
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_VERSION, "3.20.102");
  });
});

test("shell env version uses precomputed dependency before filesystem fallbacks", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");

    const hook = makeHookForAgentsDirAndVersion(agentsDir, "3.21.0\n");
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_VERSION, "3.21.0");
  });
});

test("shell env hook tolerates missing dependency object", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const hook = createShellEnvHook();
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "interactive");
  });
});

test("shell env hook without agentsDir does not read VERSION from process cwd", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-cwd-"));
    const previousCwd = process.cwd();
    try {
      writeFileSync(join(root, "VERSION"), "9.9.9-cwd\n");
      process.chdir(root);

      const hook = createShellEnvHook();
      const output = { env: { PATH: "/usr/bin:/bin" } };

      await hook({ sessionID: "interactive-session" }, output);

      assert.equal(output.env.AIDEVOPS_VERSION, undefined);
    } finally {
      process.chdir(previousCwd);
      rmSync(root, { recursive: true, force: true });
    }
  });
});

test("shell env hook with blank agentsDir does not read VERSION from process cwd", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-blank-cwd-"));
    const previousCwd = process.cwd();
    try {
      writeFileSync(join(root, "VERSION"), "9.9.9-cwd\n");
      process.chdir(root);

      const hook = makeHookForAgentsDir("   ");
      const output = { env: { PATH: "/usr/bin:/bin" } };

      await hook({ sessionID: "interactive-session" }, output);

      assert.equal(output.env.AIDEVOPS_VERSION, undefined);
    } finally {
      process.chdir(previousCwd);
      rmSync(root, { recursive: true, force: true });
    }
  });
});
