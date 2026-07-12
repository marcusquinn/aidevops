// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  gpt56ContextCapEnabled,
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

test("GPT-5.6 cap defaults on and applies 300K without losing model fields", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { name: "Sol" } } } },
  };
  assert.equal(gpt56ContextCapEnabled(), true);
  assert.equal(registerGpt56ContextLimits(config), 4);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].name, "Sol");
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.output, 128000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.output, 128000);
});

test("GPT-5.6 cap preserves an explicit output limit", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { limit: { output: 64000 } } } } },
  };
  registerGpt56ContextLimits(config);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"].limit, {
    output: 64000,
    context: 300000,
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
