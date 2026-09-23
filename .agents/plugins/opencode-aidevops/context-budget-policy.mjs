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
  return (id?.startsWith("gpt-5.6-") && settings.gpt56_context_cap === false) ||
    (astra && (settings.astra_context_cap === false || settings.astra_compaction_target === 400000)) ||
    (gpt6 && settings.gpt6_context_cap === false);
}

export function preserveOpusOverride(model) {
  const value = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  return model.providerID === "anthropic" && model.id === "claude-opus-4-7" &&
    value !== undefined && Number.isFinite(Number(value)) && Number(value) > 0;
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

export function capResolvedModel(model, reserve) {
  const limit = model.limit;
  const usable = limit.input !== undefined ? limit.input - reserve : limit.context - limit.output;
  const physicalInput = limit.context - limit.output;
  if (!Number.isFinite(usable) || usable <= 240000 || physicalInput <= 0) return false;
  limit.input = Math.min(240000 + reserve, physicalInput);
  limit.context = Math.min(limit.context, limit.input + limit.output);
  return true;
}
