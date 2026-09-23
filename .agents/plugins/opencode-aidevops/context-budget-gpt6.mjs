// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { preserveGpt6Limit } from "./context-budget-policy.mjs";
import { GPT6_COMPACTION_TARGET, GPT6_MODEL_IDS, GPT6_OUTPUT_DEFAULT } from "./model-limits.mjs";

// Receipts describe the settings actually consumed, not a later settings read.
const healthByConfig = new WeakMap();

export function getGpt6ContextHealth(config) {
  return healthByConfig.get(config) ?? null;
}

/** Default GPT-6 Sol/Luna to ~240K usable input unless explicitly customized. */
export function registerGpt6Budget(config, settings) {
  const managed = settings.gpt6_context_cap !== false;
  const health = { managed, target: GPT6_COMPACTION_TARGET, auto: config.compaction?.auto !== false };
  healthByConfig.set(config, health);
  if (!managed) return 0;

  config.provider ??= {};
  config.provider.openai ??= {};
  config.provider.openai.models ??= {};
  const models = config.provider.openai.models;
  const applied = {};
  const customized = [];
  for (const id of GPT6_MODEL_IDS) {
    const existing = models[id] || {};
    if (preserveGpt6Limit(settings, existing)) {
      customized.push(id);
      continue;
    }
    const output = existing.limit?.output ?? GPT6_OUTPUT_DEFAULT;
    const reserve = config.compaction?.reserved ?? Math.min(20000, output);
    const input = GPT6_COMPACTION_TARGET + reserve;
    models[id] = {
      ...existing,
      limit: { ...existing.limit, context: input + output, input, output },
    };
    applied[id] = { reserve, limits: { ...models[id].limit } };
  }
  health.models = applied;
  health.customized = customized;
  return Object.keys(applied).length;
}
