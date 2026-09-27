// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const V2_DEFAULT_BUFFER = 20_000; // OpenCode 2.0.3 local compaction default.

/** V2 budgets are opt-in: its SDK has no mutable per-request model limit. */
export function readV2ContextBudget(file = process.env.AIDEVOPS_SETTINGS_FILE ||
  join(homedir(), ".config", "aidevops", "settings.json")) {
  try {
    const options = JSON.parse(readFileSync(file, "utf8"))?.runtime?.opencode;
    if (options?.v2_compaction_target !== 240000) return null;
    const buffer = options.v2_compaction_buffer ?? V2_DEFAULT_BUFFER;
    if (!Number.isSafeInteger(buffer) || buffer < 0 || buffer > 100000) return null;
    return { target: 240000, buffer };
  } catch {
    return null;
  }
}

/** Cap only model input; keep context, output, variants, and short windows native. */
export function applyV2ContextBudget(editor, budget) {
  if (!budget) return 0;
  let changed = 0;
  for (const record of editor.provider.list()) {
    for (const model of record.models.values()) {
      const limit = model.limit;
      if (!Number.isSafeInteger(limit?.context) || !Number.isSafeInteger(limit.output) ||
          limit.output <= 0 || limit.context <= limit.output) continue;
      const physical = limit.context - limit.output;
      const capped = Math.min(physical, budget.target + budget.buffer);
      if (physical <= budget.target || capped <= 0 ||
          (limit.input !== undefined && limit.input <= capped)) continue;
      editor.model.update(record.provider.id, model.id, (draft) => {
        draft.limit.input = capped;
      });
      changed++;
    }
  }
  return changed;
}
