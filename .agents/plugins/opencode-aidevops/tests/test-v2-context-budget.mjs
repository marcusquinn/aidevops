// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { applyV2ContextBudget, readV2ContextBudget } from "../v2-context-budget.mjs";

test("V2 240K policy is disabled without an exact explicit setting", () => {
  const root = mkdtempSync(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "v2-budget-"));
  try {
    const file = join(root, "settings.json");
    assert.equal(readV2ContextBudget(file), null);
    for (const value of ["240000", 0, false, 500000]) {
      writeFileSync(file, JSON.stringify({ runtime: { opencode: { v2_compaction_target: value } } }));
      assert.equal(readV2ContextBudget(file), null);
    }
    writeFileSync(file, JSON.stringify({ runtime: { opencode: {
      v2_compaction_target: 240000, v2_compaction_buffer: -1,
    } } }));
    assert.equal(readV2ContextBudget(file), null);
    writeFileSync(file, JSON.stringify({ runtime: { opencode: { v2_compaction_target: 240000 } } }));
    assert.deepEqual(readV2ContextBudget(file), { target: 240000, buffer: 20000 });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("V2 catalog cap yields 240K local compaction threshold without changing native context", () => {
  const models = new Map([
    ["opus", { id: "opus", name: "Native Opus", limit: { context: 1000000, input: 890000, output: 128000 } }],
    ["haiku", { id: "haiku", limit: { context: 200000, output: 32000 } }],
    ["short", { id: "short", limit: { context: 300000, input: 190000, output: 32000 } }],
    ["unknown", { id: "unknown", limit: { context: 0, output: 32000 } }],
  ]);
  const editor = {
    provider: { list: () => [{ provider: { id: "anthropic" }, models }] },
    model: { update(providerID, id, change) {
      assert.equal(providerID, "anthropic");
      change(models.get(id));
    } },
  };
  const before = structuredClone(models.get("opus"));
  assert.equal(applyV2ContextBudget(editor, null), 0);
  assert.equal(applyV2ContextBudget(editor, { target: 240000, buffer: 20000 }), 1);
  assert.equal(models.get("opus").limit.input, 260000);
  assert.equal(models.get("opus").limit.input - 20000, 240000);
  assert.equal(models.get("opus").limit.context, before.limit.context);
  assert.equal(models.get("opus").limit.output, before.limit.output);
  assert.equal(models.get("opus").name, before.name);
  assert.deepEqual(models.get("haiku").limit, { context: 200000, output: 32000 });
  assert.equal(models.get("short").limit.input, 190000);
  assert.equal(applyV2ContextBudget(editor, { target: 240000, buffer: 20000 }), 0);
});
