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
  for (const [provider, id] of [["openai", "gpt-6-sol"], ["anthropic", "claude-opus-5-4"],
    ["anthropic", "claude-sonnet-4-6"], ["google", "gemini-future"], ["custom", "unlisted"]]) {
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

test("uses the 240K usable-input target for every large Anthropic model (GH#32807)", () => {
  const budget = setup();
  budget.capture({});
  for (const id of ["claude-opus-5-5", "claude-opus-5-6-20260926", "claude-opus-6",
    "claude-fable-5-1", "claude-fable-5-2", "claude-sonnet-5", "claude-sonnet-5-1",
    "claude-opus-5-4", "claude-fable-5", "claude-sonnet-4-6", "claude-haiku-5"]) {
    const resolved = model("anthropic", id);
    assert.equal(budget.apply({ model: resolved }), true, id);
    assert.equal(resolved.limit.input - 20000, 240000, id);
    assert.equal(resolved.limit.context, 388000, id);
    assert.equal(resolved.limit.output, 128000, id);
    assert.equal(budget.apply({ model: resolved }), false, id);
  }
  const customProvider = model("custom", "claude-opus-5-5");
  assert.equal(budget.apply({ model: customProvider }), true);
  assert.equal(customProvider.limit.input - 20000, 240000);
  // OpenCode compacts at context minus its 32K request-output clamp when no
  // input limit is set: 250K - 32K = 218K stays native; 300K - 32K = 268K is capped.
  const smallerNative = model("anthropic", "claude-opus-5-5", { context: 250000, output: 64000 });
  assert.equal(budget.apply({ model: smallerNative }), false);
  assert.deepEqual(smallerNative.limit, { context: 250000, output: 64000 });
  const hostThreshold = model("anthropic", "claude-opus-5-5", { context: 300000, output: 64000 });
  assert.equal(budget.apply({ model: hostThreshold }), true);
  assert.deepEqual(hostThreshold.limit, { context: 300000, output: 64000, input: 260000 });
  assert.equal(budget.apply({ model: hostThreshold }), false);
});

test("targets 190K usable input for xAI Grok below the 200K price band (GH#34538)", () => {
  const budget = setup();
  budget.capture({});
  // Native catalogue windows: Grok 4.5-4.7 advertise output equal to context.
  for (const [provider, id, limit] of [
    ["xai", "grok-4.6", { context: 500000, output: 500000 }],
    ["xai", "grok-4.7", { context: 500000, output: 500000 }],
    ["xai", "grok-4.5", { context: 500000, output: 500000 }],
    ["xai", "grok-4.20-0309-reasoning", { context: 1000000, output: 30000 }],
    ["openrouter", "x-ai/grok-4.6", { context: 500000, output: 450000 }],
    ["nano-gpt", "x-ai/grok-4.7", { context: 500000, input: 500000, output: 500000 }],
    ["amazon-bedrock", "us.xai.grok-4.6", { context: 500000, output: 500000 }],
    ["llmgateway", "grok-4-6", { context: 500000, output: 500000 }],
  ]) {
    const resolved = model(provider, id, limit);
    assert.equal(budget.apply({ model: resolved }), true, `${provider}/${id}`);
    assert.equal(resolved.limit.input - 20000, 190000, `${provider}/${id}`);
    assert.equal(resolved.limit.context, Math.min(limit.context, resolved.limit.input + limit.output),
      `${provider}/${id}`);
    assert.equal(resolved.limit.output, limit.output, `${provider}/${id}`);
    assert.equal(budget.apply({ model: resolved }), false, `${provider}/${id}`);
  }
  for (const [provider, id] of [["openai", "gpt-6.1-sol"], ["anthropic", "claude-opus-5-5"]]) {
    const resolved = model(provider, id);
    assert.equal(budget.apply({ model: resolved }), true, id);
    assert.equal(resolved.limit.input - 20000, 240000, id);
  }
  const custom = setup();
  custom.capture({ provider: { xai: { models: { "grok-4.6": { limit: { input: 300000 } } } } } });
  const chosen = model("xai", "grok-4.6", { context: 2000000, input: 300000, output: 64000 });
  assert.equal(custom.apply({ model: chosen }), false);
  assert.equal(chosen.limit.input, 300000);
});

test("windows advertising output equal to context use the host output clamp (GH#34538)", () => {
  const previous = process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX;
  try {
    delete process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX;
    const budget = setup();
    budget.capture({});
    const large = model("moonshotai", "kimi-k3", { context: 1048576, output: 1048576 });
    assert.equal(budget.apply({ model: large }), true);
    assert.equal(large.limit.input - 20000, 240000);
    assert.equal(large.limit.context, 1048576);
    // 262144 - 32000 = 230144 usable is already below the target: stay native.
    const near = model("moonshotai", "kimi-k2.6", { context: 262144, output: 262144 });
    assert.equal(budget.apply({ model: near }), false);
    assert.deepEqual(near.limit, { context: 262144, output: 262144 });
    process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX = "300000";
    const clamped = model("xai", "grok-4.6", { context: 500000, output: 500000 });
    assert.equal(budget.apply({ model: clamped }), true);
    assert.equal(clamped.limit.input, 200000);
  } finally {
    if (previous === undefined) delete process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX;
    else process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX = previous;
  }
});

test("caps Haiku 4.5 at native 200K, targeting 180K without reducing output headroom", () => {
  const budget = setup();
  budget.capture({});
  const shortOutput = model("anthropic", "claude-haiku-4-5", { context: 200000, output: 8000 });
  assert.equal(budget.apply({ model: shortOutput }), true);
  assert.equal(shortOutput.limit.input - 8000, 180000);
  assert.equal(shortOutput.limit.context, 196000);
  const fullOutput = model("anthropic", "claude-haiku-4-5", { context: 200000, output: 32000 });
  assert.equal(budget.apply({ model: fullOutput }), false);
  assert.equal(fullOutput.limit.context - fullOutput.limit.output, 168000);
  const overstated = model("anthropic", "claude-haiku-4-5");
  assert.equal(budget.apply({ model: overstated }), true);
  assert.equal(overstated.limit.context, 200000);
  assert.equal(overstated.limit.input, 72000);
  const custom = setup();
  custom.capture({ provider: { anthropic: { models: { "claude-haiku-4-5": {
    limit: { context: 300000 },
  } } } } });
  const chosen = model("anthropic", "claude-haiku-4-5");
  assert.equal(custom.apply({ model: chosen }), false);
  assert.equal(chosen.limit.context, 1050000);
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
  assert.equal(disabled.apply({ model: model("anthropic", "claude-opus-5-5") }), false);
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

test("retains the 200K usable-input reliability boundary for native Opus 4.7", () => {
  const previous = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  try {
    delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
    const budget = setup();
    budget.capture({});
    const resolved = model("anthropic", "claude-opus-4-7", { context: 1000000, output: 64000 });
    assert.equal(budget.apply({ model: resolved }), true);
    assert.equal(resolved.limit.input - 20000, 200000);
    assert.equal(resolved.limit.context, resolved.limit.input + resolved.limit.output);
  } finally {
    if (previous === undefined) delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
    else process.env.AIDEVOPS_OPUS_47_CONTEXT = previous;
  }
});

test("preserves an explicit Opus 4.7 environment override without picker injection", () => {
  const previous = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  try {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "500000";
    const budget = setup();
    budget.capture({});
    const resolved = model("anthropic", "claude-opus-4-7");
    assert.equal(budget.apply({ model: resolved }), true);
    assert.equal(resolved.limit.input - 20000, 400000);
    assert.equal(resolved.limit.output, 128000);
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
