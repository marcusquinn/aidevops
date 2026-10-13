// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { isXaiGrokModel, physicalInputLimit, XAI_GROK_COMPACTION_TARGET } from "./model-limits.mjs";

const V2_DEFAULT_BUFFER = 20_000; // OpenCode 2.0.3 local compaction default.
const V2_TARGET = 240000;

function readOpenCodeSettings(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"))?.runtime?.opencode ?? {};
  } catch {
    // Missing or unreadable settings keep the cost-saving default.
    return {};
  }
}

/**
 * V2 has no mutable per-request model limit, so the budget caps catalogue input
 * limits. It is on by default at 240K (GH#32807); any explicit
 * `v2_compaction_target` other than 240000 (for example `false`) opts out.
 */
export function readV2ContextBudget(file = process.env.AIDEVOPS_SETTINGS_FILE ||
  join(homedir(), ".config", "aidevops", "settings.json")) {
  const options = readOpenCodeSettings(file);
  if (options === null || typeof options !== "object") return { target: V2_TARGET, buffer: V2_DEFAULT_BUFFER };
  if (options.v2_compaction_target !== undefined && options.v2_compaction_target !== V2_TARGET) return null;
  const buffer = options.v2_compaction_buffer ?? V2_DEFAULT_BUFFER;
  if (!Number.isSafeInteger(buffer) || buffer < 0 || buffer > 100000) return null;
  return { target: V2_TARGET, buffer };
}

function hasUsableWindow(limit) {
  return Number.isSafeInteger(limit?.context) && Number.isSafeInteger(limit.output) &&
    limit.output > 0 && limit.context > 0;
}

// V2's request-output clamp is not yet qualified, so only windows that
// advertise output >= context (no input space under the old rule) use the
// host clamp; capping them can only lower input.
function v2PhysicalInput(limit) {
  return limit.output >= limit.context ? physicalInputLimit(limit) : limit.context - limit.output;
}

/** Return the capped input for one catalogue model, or null to keep it native. */
function v2CappedInput(providerID, model, budget) {
  const limit = model.limit;
  if (!hasUsableWindow(limit)) return null;
  const target = isXaiGrokModel({ providerID, id: model.id })
    ? Math.min(budget.target, XAI_GROK_COMPACTION_TARGET) : budget.target;
  const physical = v2PhysicalInput(limit);
  const capped = Math.min(physical, target + budget.buffer);
  if (physical <= target || capped <= 0) return null;
  if (limit.input !== undefined && limit.input <= capped) return null;
  return capped;
}

/**
 * Cap only model input; keep context, output, variants, and short windows native.
 * xAI Grok uses its lower price-band target (GH#34538) under the same opt-out.
 */
export function applyV2ContextBudget(editor, budget) {
  if (!budget) return 0;
  let changed = 0;
  for (const record of editor.provider.list()) {
    for (const model of record.models.values()) {
      const capped = v2CappedInput(record.provider.id, model, budget);
      if (capped === null) continue;
      editor.model.update(record.provider.id, model.id, (draft) => {
        draft.limit.input = capped;
      });
      changed++;
    }
  }
  return changed;
}
