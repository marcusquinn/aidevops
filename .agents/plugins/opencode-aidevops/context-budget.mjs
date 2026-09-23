// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const TARGET = 240000;
const DEFAULT_RESERVE = 20000;

/**
 * OpenCode's request hook receives the same mutable provider model used by its
 * subsequent overflow check. Cap resolved models there so the policy also covers
 * built-in models absent from config.provider.models and future model IDs.
 * Explicit user limits are captured before aidevops registers its own models.
 */
export function createContextBudget() {
  let customized = new Map();
  let settings = {};
  let reserved;
  let auto = true;

  return {
    capture(config) {
      customized = new Map();
      for (const [provider, definition] of Object.entries(config.provider ?? {})) {
        for (const [id, model] of Object.entries(definition.models ?? {})) {
          if (model?.limit?.context !== undefined || model?.limit?.input !== undefined) {
            customized.set(`${provider}/${id}`, {
              ...(model.limit.context !== undefined ? { context: model.limit.context } : {}),
              ...(model.limit.input !== undefined ? { input: model.limit.input } : {}),
            });
          }
        }
      }
      reserved = config.compaction?.reserved;
      auto = config.compaction?.auto !== false;
      const file = process.env.AIDEVOPS_SETTINGS_FILE || join(homedir(), ".config", "aidevops", "settings.json");
      try {
        settings = existsSync(file) ? JSON.parse(readFileSync(file, "utf8"))?.runtime?.opencode ?? {} : {};
      } catch {
        settings = {};
      }
    },
    restore(config) {
      // Family-specific registrars may have replaced the user's model metadata.
      for (const [key, limit] of customized) {
        // Explicit CLI enable is a deliberate override of GPT-6 model limits.
        if (settings.gpt6_context_cap === true &&
            /^openai\/gpt-6-(sol|luna)(-fast)?$/.test(key)) continue;
        const slash = key.indexOf("/");
        const existing = config.provider?.[key.slice(0, slash)]?.models?.[key.slice(slash + 1)];
        if (!existing?.limit) continue;
        existing.limit = { ...existing.limit, ...limit };
        if (limit.context !== undefined && limit.input === undefined && Number.isFinite(existing.limit.output)) {
          // Do not retain an aidevops-generated input cap under a custom context.
          existing.limit.input = Math.max(0, limit.context - existing.limit.output);
        } else if (limit.input !== undefined && limit.context === undefined &&
                   Number.isFinite(existing.limit.context) && Number.isFinite(existing.limit.output)) {
          // The generated context must not invalidate a user's larger input budget.
          existing.limit.context = Math.max(existing.limit.context, limit.input + existing.limit.output);
        }
      }
    },
    apply(input) {
      const model = input?.model;
      const limit = model?.limit;
      if (!auto || !limit || !Number.isFinite(limit.context) || limit.context <= 0 ||
          !Number.isFinite(limit.output) || limit.output <= 0) return false;
      const id = `${model.providerID}/${model.id}`;
      const custom = customized.get(id);
      if (custom) {
        // The provider merge can reintroduce a native input larger than a user's
        // context-only override. Keep their context, but enforce its physical input.
        if (custom.context !== undefined && custom.input === undefined &&
            limit.input > limit.context - limit.output && limit.context > limit.output) {
          limit.input = limit.context - limit.output;
        }
        return false;
      }
      if (model.providerID === "anthropic" && model.id === "claude-opus-4-7" &&
          process.env.AIDEVOPS_OPUS_47_CONTEXT &&
          Number.isFinite(Number(process.env.AIDEVOPS_OPUS_47_CONTEXT)) &&
          Number(process.env.AIDEVOPS_OPUS_47_CONTEXT) > 0) return false;
      if (model.providerID === "openai") {
        if (model.id?.startsWith("gpt-5.6-") && settings.gpt56_context_cap === false) return false;
        if (model.id === "gpt-6-astra" || model.id?.startsWith("gpt-6-astra-")) {
          if (settings.astra_context_cap === false || settings.astra_compaction_target === 400000) return false;
        }
        if (/^gpt-6-(sol|luna)(-fast)?$/.test(model.id) && settings.gpt6_context_cap === false) return false;
      }
      const reserve = reserved ?? Math.min(DEFAULT_RESERVE, limit.output);
      const usable = limit.input !== undefined ? limit.input - reserve : limit.context - limit.output;
      if (!Number.isFinite(usable) || usable <= TARGET) return false;
      const physicalInput = limit.context - limit.output;
      if (physicalInput <= 0) return false;
      limit.input = Math.min(TARGET + reserve, physicalInput);
      // Never advertise a larger provider context or change the response limit.
      limit.context = Math.min(limit.context, limit.input + limit.output);
      return true;
    },
  };
}
