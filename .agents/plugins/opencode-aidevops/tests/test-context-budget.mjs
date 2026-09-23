// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createContextBudget } from "../context-budget.mjs";

const original = process.env.AIDEVOPS_SETTINGS_FILE;
const dirs = [];
afterEach(() => {
  if (original === undefined) delete process.env.AIDEVOPS_SETTINGS_FILE;
  else process.env.AIDEVOPS_SETTINGS_FILE = original;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function setup(settings = {}) {
  const dir = mkdtempSync(join(tmpdir(), "aidevops-context-budget-"));
  dirs.push(dir);
  process.env.AIDEVOPS_SETTINGS_FILE = join(dir, "settings.json");
  writeFileSync(process.env.AIDEVOPS_SETTINGS_FILE, JSON.stringify({ runtime: { opencode: settings } }));
  return createContextBudget();
}

function model(providerID, id, limit = { context: 1050000, input: 922000, output: 128000 }) {
  return { providerID, id, limit: { ...limit }, options: { serviceTier: "priority" } };
}

test("caps any resolved large model on first request without changing provider metadata beyond limits", () => {
  const budget = setup();
  budget.capture({});
  for (const [provider, id] of [["openai", "gpt-6-sol"], ["anthropic", "claude-opus-5"],
    ["google", "gemini-future"], ["custom", "unlisted"]]) {
    const resolved = model(provider, id);
    const registry = { [id]: resolved };
    assert.equal(budget.apply({ model: resolved }), true);
    assert.equal(registry[id].limit.input, 260000);
    assert.equal(registry[id].limit.context, 388000);
    assert.equal(resolved.limit.output, 128000);
    assert.equal(resolved.options.serviceTier, "priority");
    assert.equal(budget.apply({ model: resolved }), false);
  }
});

test("preserves explicit model context/input overrides and smaller native windows", () => {
  const budget = setup();
  budget.capture({ provider: { openai: { models: {
    "gpt-6-sol": { limit: { context: 600000 } },
    "gpt-6-luna": { limit: { input: 500000 } },
    "gpt-6-astra": { limit: { output: 4000 } },
  } } } });
  const registered = { provider: { openai: { models: {
    "gpt-6-sol": { limit: { context: 388000, input: 260000, output: 128000 } },
    "gpt-6-luna": { limit: { context: 388000, input: 260000, output: 128000 } },
  } } } };
  budget.restore(registered);
  assert.equal(registered.provider.openai.models["gpt-6-sol"].limit.context, 600000);
  assert.equal(registered.provider.openai.models["gpt-6-sol"].limit.input, 472000);
  assert.equal(registered.provider.openai.models["gpt-6-luna"].limit.input, 500000);
  assert.equal(registered.provider.openai.models["gpt-6-luna"].limit.context, 628000);
  assert.equal(budget.apply({ model: model("openai", "gpt-6-sol") }), false);
  assert.equal(budget.apply({ model: model("openai", "gpt-6-luna") }), false);
  const nativeMerged = model("openai", "gpt-6-sol", { context: 600000, input: 922000, output: 128000 });
  assert.equal(budget.apply({ model: nativeMerged }), false);
  assert.equal(nativeMerged.limit.input, 472000);
  const unregistered = { provider: { openai: { models: { "gpt-6-sol": { limit: { context: 600000 } } } } } };
  budget.restore(unregistered);
  assert.deepEqual(unregistered.provider.openai.models["gpt-6-sol"].limit, { context: 600000 });
  const outputOnly = model("openai", "gpt-6-astra", { context: 1000000, input: 500000, output: 4000 });
  assert.equal(budget.apply({ model: outputOnly }), true);
  assert.equal(outputOnly.limit.input, 244000);
  assert.equal(outputOnly.limit.output, 4000);
  const small = model("openai", "small", { context: 128000, input: 100000, output: 32000 });
  assert.equal(budget.apply({ model: small }), false);
  assert.equal(small.limit.context, 128000);
});

test("respects reserve, output and existing model-family preferences", () => {
  const budget = setup({ gpt56_context_cap: false, gpt6_context_cap: false,
    astra_compaction_target: 400000 });
  budget.capture({ compaction: { reserved: 35000 } });
  for (const id of ["gpt-5.6-sol", "gpt-6-sol", "gpt-6-astra"]) {
    assert.equal(budget.apply({ model: model("openai", id) }), false);
  }
  const other = model("anthropic", "claude-fable-5", { context: 1000000, output: 64000 });
  assert.equal(budget.apply({ model: other }), true);
  assert.equal(other.limit.input - 35000, 240000);
  assert.equal(other.limit.context, 339000);
});

test("disabled automatic compaction and unknown windows are untouched", () => {
  const disabled = setup();
  disabled.capture({ compaction: { auto: false } });
  assert.equal(disabled.apply({ model: model("openai", "gpt-5.4") }), false);
  const enabled = setup();
  enabled.capture({});
  assert.equal(enabled.apply({ model: model("custom", "unknown", { context: 0, output: 1000 }) }), false);
});

test("never advertises input greater than context minus output for inconsistent native metadata", () => {
  const budget = setup();
  budget.capture({});
  const resolved = model("custom", "inconsistent", { context: 220000, input: 500000, output: 64000 });
  assert.equal(budget.apply({ model: resolved }), true);
  assert.equal(resolved.limit.input, 156000);
  assert.equal(resolved.limit.context, 220000);
  assert.equal(resolved.limit.input + resolved.limit.output, resolved.limit.context);
});

test("preserves an explicit Opus 4.7 environment override", () => {
  const previous = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  try {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "500000";
    const budget = setup();
    budget.capture({});
    assert.equal(budget.apply({ model: model("anthropic", "claude-opus-4-7") }), false);
  } finally {
    if (previous === undefined) delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
    else process.env.AIDEVOPS_OPUS_47_CONTEXT = previous;
  }
});

test("explicit GPT-6 enable overrides a per-model limit", () => {
  const budget = setup({ gpt6_context_cap: true });
  budget.capture({ provider: { openai: { models: {
    "gpt-6-sol": { limit: { context: 600000, input: 500000 } },
  } } } });
  const config = { provider: { openai: { models: {
    "gpt-6-sol": { limit: { context: 388000, input: 260000, output: 128000 } },
  } } } };
  budget.restore(config);
  assert.equal(config.provider.openai.models["gpt-6-sol"].limit.input, 260000);
});
