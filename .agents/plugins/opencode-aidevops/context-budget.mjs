// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { capResolvedModel, customizedModelLimits, preserveFamilyPreference, preserveOpusOverride,
  restoreCustomLimit, validWindow } from "./context-budget-policy.mjs";

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
      customized = customizedModelLimits(config);
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
        restoreCustomLimit(existing, limit);
      }
    },
    apply(input) {
      const model = input?.model;
      if (!auto || !validWindow(model)) return false;
      const limit = model.limit;
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
      if (preserveFamilyPreference(model, settings) || preserveOpusOverride(model)) return false;
      const reserve = reserved ?? Math.min(DEFAULT_RESERVE, limit.output);
      return capResolvedModel(model, reserve);
    },
  };
}
