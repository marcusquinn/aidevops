// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { adaptToolDefinition, LEGACY_PARENT_GUIDANCE, BOUNDED_PARENT_GUIDANCE } from "../tool-definition.mjs";

test("only the known Bash directory paragraph changes, preserving parameters and safety text", async () => {
  const suffix = '\n\n2. Command Execution:\n   - Always quote file paths that contain spaces with double quotes';
  const parameters = { command: { type: "string" } };
  const output = { description: `Preamble\n${LEGACY_PARENT_GUIDANCE}${suffix}`, parameters };
  await adaptToolDefinition({ toolID: "bash" }, output);
  assert.equal(output.description, `Preamble\n${BOUNDED_PARENT_GUIDANCE}${suffix}`);
  assert.equal(output.parameters, parameters);
  await adaptToolDefinition({ toolID: "bash" }, output);
  assert.equal(output.description, `Preamble\n${BOUNDED_PARENT_GUIDANCE}${suffix}`);
  assert.match(output.description, /child names are materially needed/);
  assert.match(output.description, /pre-edit Git checks/);
});

test("other tools and unknown upstream descriptions remain untouched", async () => {
  for (const [toolID, description] of [["read", LEGACY_PARENT_GUIDANCE], ["bash", "New upstream guidance"]]) {
    const output = { description };
    await adaptToolDefinition({ toolID }, output);
    assert.equal(output.description, description);
  }
});

test("apply_patch exposes an optional workdir without replacing an upstream definition", async () => {
  const properties = { patchText: { type: "string" } };
  const output = { parameters: { type: "object", properties } };
  await adaptToolDefinition({ toolID: "apply_patch" }, output);
  assert.equal(output.parameters.properties, properties);
  assert.deepEqual(properties.workdir, {
    type: "string",
    description: "Optional verified linked-worktree directory for applying the patch. Use absolute patch paths when targeting a different worktree.",
  });
  await adaptToolDefinition({ toolID: "apply_patch" }, output);
  assert.equal(Object.keys(properties).filter((key) => key === "workdir").length, 1);

  const upstreamWorkdir = { type: "string", description: "Upstream context" };
  const upstream = { parameters: { properties: { workdir: upstreamWorkdir } } };
  await adaptToolDefinition({ toolID: "apply_patch" }, upstream);
  assert.equal(upstream.parameters.properties.workdir, upstreamWorkdir);
});

test("both plugin modes register the definition adapter", () => {
  const entry = readFileSync(new URL("../index.mjs", import.meta.url), "utf8");
  assert.equal(entry.split('"tool.definition": adaptToolDefinition').length - 1, 2);
  const v2 = readFileSync(new URL("../v2.mjs", import.meta.url), "utf8");
  assert.match(v2, /editor\.update\("apply_patch", \(definition\) => adaptToolDefinition\(\{ toolID: "apply_patch" \}, definition\)\)/);
});

test("bounded check accepts a high-cardinality parent with spaces without output, and rejects non-directories", () => {
  const root = mkdtempSync(join(tmpdir(), "parent-verification-"));
  try {
    const parent = join(root, "parent with spaces");
    mkdirSync(parent);
    for (let i = 0; i < 3000; i++) writeFileSync(join(parent, `child-${i}`), "");
    for (const [path, status] of [[parent, 0], [join(root, "missing"), 1], [join(parent, "child-0"), 1]]) {
      const result = spawnSync("test", ["-d", path], { encoding: "utf8" });
      assert.equal(result.status, status);
      assert.equal(result.stdout, "");
      assert.equal(result.stderr, "");
    }
    const helper = fileURLToPath(new URL("../../../scripts/command-policy-helper.py", import.meta.url));
    const result = spawnSync("python3", [helper, "check-command", "--command", `test -d "${parent}"`], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).decision, "allow");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
