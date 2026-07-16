// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { registerResearchOnlyAgent } from "../config-hook.mjs";

test("research-only profile overrides permissive config and fails closed", () => {
  const agentsDir = mkdtempSync(join(tmpdir(), "aidevops-research-only-"));
  const sourceDir = join(agentsDir, "tools", "ai-assistants");
  mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, "research-only.md"), "---\nmode: subagent\n---\n\nCanonical research prompt.\n");

  try {
    const config = {
      tools: { "playwriter_*": true },
      agent: {
        "research-only": {
          tools: { bash: true, task: true },
          permission: "allow",
        },
      },
    };

    assert.equal(registerResearchOnlyAgent(config, agentsDir), 1);
    const profile = config.agent["research-only"];

    assert.equal(profile.mode, "subagent");
    assert.equal(profile.prompt, "Canonical research prompt.");
    assert.deepEqual(profile.tools, {
      "*": false,
      read: true,
      grep: true,
      glob: true,
      webfetch: true,
      websearch: true,
      write: false,
      edit: false,
      apply_patch: false,
      bash: false,
      task: false,
      todowrite: false,
      skill: false,
    });
    assert.equal(profile.permission["*"], "deny");
    assert.equal(profile.permission.bash, "deny");
    assert.equal(profile.permission.task, "deny");
    assert.equal(profile.permission.edit, "deny");
    assert.equal(profile.permission.write, "deny");
    assert.equal(profile.permission.apply_patch, "deny");
    assert.equal(profile.permission.external_directory, "deny");
    assert.equal(profile.permission.read["*"], "allow");
    assert.equal(profile.permission.read["*.env"], "deny");
    assert.equal(profile.permission.webfetch, "allow");
    assert.equal(config.tools["playwriter_*"], true);
  } finally {
    rmSync(agentsDir, { recursive: true, force: true });
  }
});
