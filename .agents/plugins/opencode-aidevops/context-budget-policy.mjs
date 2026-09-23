// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

export function preserveGpt6Limit(settings, model) {
  const explicit = model.limit?.context !== undefined || model.limit?.input !== undefined;
  return settings.gpt6_context_cap !== true && explicit;
}

export function customizedModelLimits(config) {
  const limits = new Map();
  for (const [provider, definition] of Object.entries(config.provider ?? {})) {
    for (const [id, model] of Object.entries(definition.models ?? {})) {
      const context = model?.limit?.context;
      const input = model?.limit?.input;
      if (context === undefined && input === undefined) continue;
      limits.set(`${provider}/${id}`, {
        ...(context !== undefined ? { context } : {}),
        ...(input !== undefined ? { input } : {}),
      });
    }
  }
  return limits;
}

export function preserveFamilyPreference(model, settings) {
  if (model.providerID !== "openai") return false;
  const id = model.id;
  const astra = id === "gpt-6-astra" || id?.startsWith("gpt-6-astra-");
  const gpt6 = /^gpt-6-(sol|luna)(-fast)?$/.test(id);
  if (astra && settings.astra_context_cap === false) return true;
  if (astra && settings.astra_compaction_target === 400000) return true;
  if (gpt6 && settings.gpt6_context_cap === false) return true;
  return id?.startsWith("gpt-5.6-") && settings.gpt56_context_cap === false;
}

export function preserveOpusOverride(model) {
  if (model.providerID !== "anthropic" || model.id !== "claude-opus-4-7") return false;
  const value = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  return value !== undefined && Number.isFinite(Number(value)) && Number(value) > 0;
}

export function validWindow(model) {
  const limit = model?.limit;
  return Number.isFinite(limit?.context) && limit.context > 0 &&
    Number.isFinite(limit.output) && limit.output > 0;
}

export function restoreCustomLimit(existing, limit) {
  existing.limit = { ...existing.limit, ...limit };
  const output = existing.limit.output;
  if (!Number.isFinite(output)) return;
  if (limit.context !== undefined && limit.input === undefined) {
    existing.limit.input = Math.max(0, limit.context - output);
  }
  if (limit.input !== undefined && limit.context === undefined && Number.isFinite(existing.limit.context)) {
    existing.limit.context = Math.max(existing.limit.context, limit.input + output);
  }
}

export function restoreConfiguredLimits(config, customized, settings) {
  for (const [key, limit] of customized) {
    // Explicit CLI enable is a deliberate override of GPT-6 model limits.
    if (settings.gpt6_context_cap === true &&
        /^openai\/gpt-6-(sol|luna)(-fast)?$/.test(key)) continue;
    const slash = key.indexOf("/");
    const existing = config.provider?.[key.slice(0, slash)]?.models?.[key.slice(slash + 1)];
    if (existing?.limit) restoreCustomLimit(existing, limit);
  }
}

export function preserveCustomWindow(model, custom) {
  const limit = model.limit;
  // The provider merge can reintroduce a native input larger than a user's
  // context-only override. Keep their context, but enforce its physical input.
  if (custom.context !== undefined && custom.input === undefined &&
      limit.input > limit.context - limit.output && limit.context > limit.output) {
    limit.input = limit.context - limit.output;
  }
}

export function capResolvedModel(model, reserve) {
  const limit = model.limit;
  const usable = limit.input !== undefined ? limit.input - reserve : limit.context - limit.output;
  const physicalInput = limit.context - limit.output;
  if (!Number.isFinite(usable) || usable <= 240000 || physicalInput <= 0) return false;
  limit.input = Math.min(240000 + reserve, physicalInput);
  limit.context = Math.min(limit.context, limit.input + limit.output);
  return true;
}
