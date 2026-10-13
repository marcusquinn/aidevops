// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { applyV2ContextBudget, readV2ContextBudget } from "../v2-context-budget.mjs";

test("V2 240K policy is on by default and any other explicit target opts out (GH#32807)", () => {
  const root = mkdtempSync(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "v2-budget-"));
  try {
    const file = join(root, "settings.json");
    assert.deepEqual(readV2ContextBudget(file), { target: 240000, buffer: 20000 });
    writeFileSync(file, JSON.stringify({ runtime: { opencode: { astra_context_cap: true } } }));
    assert.deepEqual(readV2ContextBudget(file), { target: 240000, buffer: 20000 });
    writeFileSync(file, "{not json");
    assert.deepEqual(readV2ContextBudget(file), { target: 240000, buffer: 20000 });
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

test("V2 caps xAI Grok at 190K usable input, below the 200K price band (GH#34538)", () => {
  // Grok 4.5+ catalogues advertise output equal to context (500K/500K).
  const xai = new Map([
    ["grok-4.6", { id: "grok-4.6", limit: { context: 500000, output: 500000 } }],
  ]);
  const router = new Map([
    ["x-ai/grok-4.7", { id: "x-ai/grok-4.7", limit: { context: 500000, output: 500000 } }],
    ["other", { id: "other", limit: { context: 1000000, output: 128000 } }],
    ["kimi-k2.6", { id: "kimi-k2.6", limit: { context: 262144, output: 262144 } }],
  ]);
  const records = [{ provider: { id: "xai" }, models: xai }, { provider: { id: "openrouter" }, models: router }];
  const editor = {
    provider: { list: () => records },
    model: { update(providerID, id, change) {
      change(records.find((record) => record.provider.id === providerID).models.get(id));
    } },
  };
  assert.equal(applyV2ContextBudget(editor, { target: 240000, buffer: 20000 }), 3);
  assert.equal(xai.get("grok-4.6").limit.input - 20000, 190000);
  assert.equal(router.get("x-ai/grok-4.7").limit.input - 20000, 190000);
  assert.equal(router.get("other").limit.input - 20000, 240000);
  assert.equal(xai.get("grok-4.6").limit.context, 500000);
  assert.deepEqual(router.get("kimi-k2.6").limit, { context: 262144, output: 262144 });
  assert.equal(applyV2ContextBudget(editor, { target: 240000, buffer: 20000 }), 0);
});
