// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for t3538: interactive OpenCode shells must stamp
// AIDEVOPS_SESSION_ORIGIN=interactive even when a stale worker-origin value is
// inherited by the shell environment. Without this, gh_create_issue labels
// maintainer-created issues as origin:worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createShellEnvHook } from "../shell-env.mjs";

function makeHook() {
  return createShellEnvHook({
    agentsDir: "/tmp/aidevops-agents",
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
  });
}

test("interactive OpenCode shell overrides stale worker origin", async () => {
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
