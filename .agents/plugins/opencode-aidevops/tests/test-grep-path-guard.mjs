// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { checkGrepPathScope, GREP_PATH_DESCRIPTION_NOTE } from "../grep-path-guard.mjs";
import { adaptToolDefinition } from "../tool-definition.mjs";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "aidevops-grep-path-"));
  writeFileSync(join(root, "first.txt"), "shared-marker\n");
  writeFileSync(join(root, "second.txt"), "shared-marker\n");
  return root;
}

test("rejects a regular-file path instead of searching its siblings", () => {
  const root = fixture();
  try {
    assert.throws(() => checkGrepPathScope("grep", { pattern: "shared-marker", path: join(root, "first.txt") }),
      /must be a directory/);
    assert.throws(() => checkGrepPathScope("grep", { pattern: "shared-marker", path: "first.txt" }, root),
      /rg -n -- <pattern> <file>/);
    symlinkSync(join(root, "first.txt"), join(root, "link.txt"));
    assert.throws(() => checkGrepPathScope("grep", { path: join(root, "link.txt") }), /must be a directory/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("keeps directory, missing, and omitted paths unchanged", () => {
  const root = fixture();
  try {
    assert.doesNotThrow(() => checkGrepPathScope("grep", { pattern: "shared-marker", path: root }));
    assert.doesNotThrow(() => checkGrepPathScope("grep", { pattern: "shared-marker", path: "." }, root));
    assert.doesNotThrow(() => checkGrepPathScope("grep", { path: join(root, "missing.txt") }));
    assert.doesNotThrow(() => checkGrepPathScope("grep", { pattern: "shared-marker" }));
    assert.doesNotThrow(() => checkGrepPathScope("read", { filePath: join(root, "first.txt"), path: join(root, "first.txt") }));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("grep definition states the directory contract once", async () => {
  const output = { description: "Fast content search tool.\n" };
  await adaptToolDefinition({ toolID: "grep" }, output);
  await adaptToolDefinition({ toolID: "grep" }, output);
  assert.equal(output.description, `Fast content search tool.\n\n${GREP_PATH_DESCRIPTION_NOTE}`);
});

test("the shared quality hook runs the guard and V2 adapts the grep definition", () => {
  const hooks = readFileSync(new URL("../quality-hooks.mjs", import.meta.url), "utf8");
  assert.match(hooks, /checkGrepPathScope\(input\.tool, output\.args \|\| \{\}, ctx\.repositoryDir\)/);
  const v2 = readFileSync(new URL("../v2.mjs", import.meta.url), "utf8");
  assert.match(v2, /editor\.update\("grep", \(definition\) => adaptToolDefinition\(\{ toolID: "grep" \}, definition\)\)/);
});
