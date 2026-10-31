// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { compactionAgent } from "./compaction-routing.mjs";
import { COMPACTION_REASONING_DEFAULT, compactionReasoning } from "./model-routing-variant.mjs";
import { clampReasoningVariant } from "./subagent-effort.mjs";

// GH#36169: OpenCode builds compaction options from the parent user message's
// variant only (session/llm/request.ts), so `agent.compaction.variant` has no
// effect and a `low` session compacts at `low`, or at the provider default
// when the parent variant does not exist on the compaction model. The
// chat.params hook therefore applies one fixed compaction effort, up or down.
// GH#32934: Opus 5.5 `max` compactions stalled 165-196s; legacy
// AIDEVOPS_COMPACTION_MAX_EFFORT still caps the target.
const EFFORT_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const EFFORT_KEYS = ["effort", "reasoningEffort", "reasoning_effort"];

function envEffort(env, key) {
  const value = String(env?.[key] || "").toLowerCase();
  return EFFORT_LEVELS.includes(value) ? value : "";
}

/** Effective compaction effort: AIDEVOPS_COMPACTION_EFFORT, else the table setting, capped by the legacy ceiling. */
export function compactionEffortTarget(routing, env = process.env) {
  const target = envEffort(env, "AIDEVOPS_COMPACTION_EFFORT")
    || compactionReasoning(routing?.compactionReasoning ?? COMPACTION_REASONING_DEFAULT);
  const ceiling = envEffort(env, "AIDEVOPS_COMPACTION_MAX_EFFORT");
  return ceiling ? clampReasoningVariant(target, ceiling) : target;
}

// Highest catalogued variant at or below the target (Luna has no `max`).
function catalogVariant(variants, target) {
  if (!variants || typeof variants !== "object") return "";
  for (let rank = EFFORT_LEVELS.indexOf(target); rank >= 0; rank -= 1) {
    const name = EFFORT_LEVELS[rank];
    if (variants[name] && typeof variants[name] === "object") return name;
  }
  return "";
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function mergeOptions(target, source) {
  for (const [key, value] of Object.entries(source)) {
    if (isPlainObject(value) && isPlainObject(target[key])) mergeOptions(target[key], value);
    else target[key] = isPlainObject(value) ? structuredClone(value) : value;
  }
}

function currentEffort(options) {
  for (const target of [options, options?.reasoning, options?.output_config]) {
    for (const key of EFFORT_KEYS) {
      if (typeof target?.[key] === "string") return target[key];
    }
  }
  return "";
}

function clampEffortKeys(target, ceiling) {
  if (!target || typeof target !== "object") return;
  for (const key of EFFORT_KEYS) {
    if (typeof target[key] === "string") target[key] = clampReasoningVariant(target[key], ceiling);
  }
}

/**
 * Apply one compaction effort, raising or lowering the parent variant's, by
 * merging the compaction model's own catalogued variant options (so each
 * provider gets its native shape). Without a variant catalogue, existing
 * effort keys are only clamped down. Only the compaction agent is affected.
 * @param {object} [opts] - `env` (effort overrides), `log(level, msg)`
 * @returns {{from: string, to: string}|null} applied change
 */
export function applyCompactionEffort(input, output, routing, { env = process.env, log } = {}) {
  if (compactionAgent(input) !== "compaction" || !output?.options) return null;
  const target = compactionEffortTarget(routing, env);
  const { options } = output;
  const from = currentEffort(options) || "default";
  const model = input?.model?.id ?? input?.model?.modelID ?? "unknown model";
  const name = catalogVariant(input?.model?.variants, target);
  if (name) {
    mergeOptions(options, input.model.variants[name]);
  } else {
    [options, options.reasoning, options.output_config].forEach((part) => clampEffortKeys(part, target));
  }
  const to = currentEffort(options) || from;
  if (to === from) return null;
  log?.("INFO", `[compaction] effort ${from} -> ${to} (${model})`);
  return { from, to };
}
