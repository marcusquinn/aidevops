// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  applyTitleAgentSuffix,
  isTitleAgentCompletion,
  readAidevopsVersion,
  withAidevopsTitleSuffix,
} from "../session-title-suffix.mjs";

function withTempAgentsDir(fn) {
  const root = mkdtempSync(join(tmpdir(), "aidevops-title-suffix-"));
  const dir = join(root, "agents");
  mkdirSync(dir);
  try {
    return fn(dir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function withoutEnvVersion(fn) {
  const saved = process.env.AIDEVOPS_VERSION;
  try {
    delete process.env.AIDEVOPS_VERSION;
    return fn();
  } finally {
    if (saved === undefined) delete process.env.AIDEVOPS_VERSION;
    else process.env.AIDEVOPS_VERSION = saved;
  }
}

test("title suffix appends and replaces idempotently", () => {
  assert.equal(
    withAidevopsTitleSuffix("Investigate title path", "3.20.102"),
    "Investigate title path · AIDevOps 3.20.102",
  );
  assert.equal(
    withAidevopsTitleSuffix("Investigate title path · AIDevOps 3.20.101", "3.20.102"),
    "Investigate title path · AIDevOps 3.20.102",
  );
});

test("version reader prefers deployed agents VERSION", () => {
  withoutEnvVersion(() =>
    withTempAgentsDir((agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
      writeFileSync(join(agentsDir, "..", "version"), "2.44.2\n");

      assert.equal(readAidevopsVersion(agentsDir), "3.20.102");
    }),
  );
});

test("title agent completion gets version suffix", () => {
  withoutEnvVersion(() =>
    withTempAgentsDir((agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
      const output = { text: "Check live title capability" };

      applyTitleAgentSuffix({ agent: "title" }, output, agentsDir);

      assert.equal(output.text, "Check live title capability · AIDevOps 3.20.102");
    }),
  );
});

test("non-title completions are untouched", () => {
  withTempAgentsDir((agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
    const output = { text: "Normal assistant output" };

    applyTitleAgentSuffix({ agent: "build" }, output, agentsDir);

    assert.equal(output.text, "Normal assistant output");
  });
});

test("title agent detection accepts known hook shapes", () => {
  assert.equal(isTitleAgentCompletion({ agent: "title" }), true);
  assert.equal(isTitleAgentCompletion({ agentID: "title" }), true);
  assert.equal(isTitleAgentCompletion({ agent: { id: "title" } }), true);
  assert.equal(isTitleAgentCompletion({ agent: { name: "title" } }), true);
  assert.equal(isTitleAgentCompletion({ agent: "build" }), false);
});
