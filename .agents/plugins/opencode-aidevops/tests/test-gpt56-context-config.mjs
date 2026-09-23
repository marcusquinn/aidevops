// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  getAstraContextHealth,
  getGpt6ContextHealth,
  gpt56ContextCapEnabled,
  registerAstraContextLimits,
  registerGpt6ContextLimits,
  registerGpt56ContextLimits,
} from "../config-hook.mjs";

const originalSettingsFile = process.env.AIDEVOPS_SETTINGS_FILE;
const tempDirs = [];

afterEach(() => {
  if (originalSettingsFile === undefined) {
    delete process.env.AIDEVOPS_SETTINGS_FILE;
  } else {
    process.env.AIDEVOPS_SETTINGS_FILE = originalSettingsFile;
  }
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function settingsFile(value) {
  const dir = mkdtempSync(join(tmpdir(), "aidevops-gpt56-"));
  tempDirs.push(dir);
  const file = join(dir, "settings.json");
  if (value !== undefined) writeFileSync(file, JSON.stringify(value));
  process.env.AIDEVOPS_SETTINGS_FILE = file;
  return file;
}

test("GPT-5.6 cap defaults on and applies a 240K compaction threshold without losing model fields", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { name: "Sol" } } } },
  };
  assert.equal(gpt56ContextCapEnabled(), true);
  assert.equal(registerGpt56ContextLimits(config), 4);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].name, "Sol");
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.input, 260000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.output, 128000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.input, 260000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.output, 128000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.input - 20000, 240000);
});

test("GPT-5.6 cap preserves an explicit output limit but owns context and input budgets", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { limit: { context: 400000, input: 380000, output: 64000 } } } } },
  };
  registerGpt56ContextLimits(config);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"].limit, {
    output: 64000,
    context: 300000,
    input: 260000,
  });
});

test("GPT-5.6 cap opt-out leaves OpenAI model metadata untouched", () => {
  settingsFile({ runtime: { opencode: { gpt56_context_cap: false } } });
  const config = { provider: { openai: { models: {} } } };
  assert.equal(gpt56ContextCapEnabled(), false);
  assert.equal(registerGpt56ContextLimits(config), 0);
  assert.deepEqual(config.provider.openai.models, {});
});

test("malformed settings fail open to the cost-aware default", () => {
  const file = settingsFile({});
  writeFileSync(file, "not-json");
  assert.equal(gpt56ContextCapEnabled(), true);
});

test("Astra defaults to the same 240K compaction target as GPT-5.6", () => {
  settingsFile(undefined);
  for (const reserve of [undefined, 0, 35000]) {
    const config = { compaction: reserve === undefined ? {} : { reserved: reserve } };
    assert.equal(registerAstraContextLimits(config), 1);
    const limits = config.provider.openai.models["gpt-6-astra"].limit;
    assert.equal(limits.input - (reserve ?? 20000), 240000);
    assert.equal(limits.context, limits.input + limits.output);
    assert.equal(limits.output, 128000);
    assert.equal(config.compaction.reserved, reserve);
  }
});

test("Astra retains model fields and explicit output limits, independently of GPT-5.6", () => {
  settingsFile({ runtime: { opencode: { gpt56_context_cap: false } } });
  const config = { provider: { openai: { models: {
    "gpt-6-astra": { name: "Astra", limit: { context: 1000000, output: 4000 } },
    "gpt-5.6-sol": { name: "untouched" },
  } } } };
  registerAstraContextLimits(config);
  assert.equal(config.provider.openai.models["gpt-6-astra"].name, "Astra");
  assert.equal(config.provider.openai.models["gpt-6-astra"].limit.input - 4000, 240000);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"], { name: "untouched" });
});

test("Astra opt-out leaves metadata untouched", () => {
  settingsFile({ runtime: { opencode: { astra_context_cap: false } } });
  const config = {};
  assert.equal(registerAstraContextLimits(config), 0);
  assert.deepEqual(config, {});
});

test("Astra lower budget honours reserves/output and preserves all other models", () => {
  settingsFile({ runtime: { opencode: { astra_compaction_target: 240000 } } });
  for (const reserved of [undefined, 0, 35000]) {
    for (const output of [128000, 4000]) {
      const config = { compaction: { reserved }, provider: { openai: { models: {
        "gpt-6-astra": { name: "custom", limit: { context: 1000000, output } },
        "gpt-5.6-sol": { name: "Sol" }, "unrelated": { limit: { input: 123 } },
      } } } };
      registerGpt56ContextLimits(config);
      const before = structuredClone(config);
      registerAstraContextLimits(config);
      const reserve = reserved ?? Math.min(20000, output);
      const limits = config.provider.openai.models["gpt-6-astra"].limit;
      assert.equal(limits.input - reserve, 240000);
      assert.equal(limits.context, limits.input + output);
      assert.equal(config.provider.openai.models["gpt-6-astra"].name, "custom");
      assert.deepEqual(getAstraContextHealth(config), { managed: true, target: 240000, auto: true, reserve, limits });
      delete before.provider.openai.models["gpt-6-astra"];
      delete config.provider.openai.models["gpt-6-astra"];
      assert.deepEqual(config, before);
    }
  }
});

test("Astra invalid selections fall back to 240K without changing GPT-5.6", () => {
  for (const target of [undefined, null, "240000", 0, -1, 300000, {}, true]) {
    settingsFile({ runtime: { opencode: { astra_compaction_target: target } } });
    const config = {};
    registerAstraContextLimits(config);
    assert.equal(getAstraContextHealth(config).target, 240000);
  }
  const file = settingsFile({});
  writeFileSync(file, "not-json");
  const config = {};
  registerAstraContextLimits(config);
  assert.equal(getAstraContextHealth(config).target, 240000);
});

test("Astra opt-out overrides a saved low target; receipts reflect the consumed settings", () => {
  const file = settingsFile({ runtime: { opencode: { astra_context_cap: false, astra_compaction_target: 240000 } } });
  const config = { compaction: { auto: false } };
  assert.equal(getAstraContextHealth(config), null);
  assert.equal(registerAstraContextLimits(config), 0);
  writeFileSync(file, "{}");
  assert.deepEqual(config, { compaction: { auto: false } });
  assert.deepEqual(getAstraContextHealth(config), { managed: false, target: 240000, auto: false });
});

test("GPT-6 Sol/Luna default to 240K usable input", () => {
  settingsFile(undefined);
  const config = {};
  assert.equal(registerGpt6ContextLimits(config), 4);
  assert.equal(config.provider.openai.models["gpt-6-sol"].limit.input - 20000, 240000);
  assert.deepEqual(getGpt6ContextHealth(config).customized, []);
});

test("GPT-6 default preserves explicit model limits; enable forces the cap", () => {
  const file = settingsFile(undefined);
  const config = { provider: { openai: { models: {
    "gpt-6-sol": { name: "custom", limit: { context: 1050000, input: 922000, output: 128000 } },
  } } } };
  const original = structuredClone(config.provider.openai.models["gpt-6-sol"]);
  assert.equal(registerGpt6ContextLimits(config), 3);
  assert.deepEqual(config.provider.openai.models["gpt-6-sol"], original);
  assert.deepEqual(getGpt6ContextHealth(config).customized, ["gpt-6-sol"]);
  writeFileSync(file, JSON.stringify({ runtime: { opencode: { gpt6_context_cap: true } } }));
  assert.equal(registerGpt6ContextLimits(config), 4);
  assert.equal(config.provider.openai.models["gpt-6-sol"].limit.input - 20000, 240000);
});

test("GPT-6 opt-out leaves provider metadata untouched", () => {
  settingsFile({ runtime: { opencode: { gpt6_context_cap: false } } });
  const config = {};
  assert.equal(registerGpt6ContextLimits(config), 0);
  assert.deepEqual(config, {});
  assert.deepEqual(getGpt6ContextHealth(config), { managed: false, target: 240000, auto: true });
});

test("GPT-6 Sol/Luna cap covers normal and Fast variants while preserving model fields", () => {
  settingsFile({ runtime: { opencode: { gpt6_context_cap: true } } });
  for (const reserved of [undefined, 0, 35000]) {
    const config = {
      compaction: reserved === undefined ? {} : { reserved },
      provider: { openai: { models: {
        "gpt-6-sol": {
          name: "Sol custom",
          variants: { high: { reasoningEffort: "high" } },
          limit: { context: 1050000, input: 922000, output: 4000 },
        },
        "gpt-6-sol-fast": { options: { serviceTier: "priority" } },
        "gpt-6-luna-fast": { options: { serviceTier: "priority" }, limit: { output: 64000 } },
        unrelated: { limit: { input: 123 } },
      } } },
    };
    assert.equal(registerGpt6ContextLimits(config), 4);
    for (const id of ["gpt-6-sol", "gpt-6-sol-fast", "gpt-6-luna", "gpt-6-luna-fast"]) {
      const limits = config.provider.openai.models[id].limit;
      const reserve = reserved ?? Math.min(20000, limits.output);
      assert.equal(limits.input - reserve, 240000);
      assert.equal(limits.context, limits.input + limits.output);
    }
    assert.equal(config.provider.openai.models["gpt-6-sol"].name, "Sol custom");
    assert.deepEqual(config.provider.openai.models["gpt-6-sol"].variants, { high: { reasoningEffort: "high" } });
    assert.deepEqual(config.provider.openai.models["gpt-6-sol-fast"].options, { serviceTier: "priority" });
    assert.deepEqual(config.provider.openai.models["gpt-6-luna-fast"].options, { serviceTier: "priority" });
    assert.deepEqual(config.provider.openai.models.unrelated, { limit: { input: 123 } });
    assert.equal(getGpt6ContextHealth(config).managed, true);
    assert.equal(Object.keys(getGpt6ContextHealth(config).models).length, 4);
  }
});

test("GPT-6 Sol/Luna cap defaults on for missing or malformed settings", () => {
  for (const value of [{}, { runtime: { opencode: { gpt6_context_cap: "true" } } }]) {
    settingsFile(value);
    const config = {};
    assert.equal(registerGpt6ContextLimits(config), 4);
  }
  const file = settingsFile({});
  writeFileSync(file, "not-json");
  const config = {};
  assert.equal(registerGpt6ContextLimits(config), 4);
});

test("GPT-6 Sol/Luna cap leaves GPT-5.6 and Astra behavior independent", () => {
  settingsFile({ runtime: { opencode: { gpt6_context_cap: true, gpt56_context_cap: false, astra_context_cap: false } } });
  const config = { provider: { openai: { models: {
    "gpt-5.6-sol": { name: "untouched GPT-5.6" },
    "gpt-6-astra": { name: "untouched Astra" },
  } } } };
  registerGpt6ContextLimits(config);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"], { name: "untouched GPT-5.6" });
  assert.deepEqual(config.provider.openai.models["gpt-6-astra"], { name: "untouched Astra" });
});
