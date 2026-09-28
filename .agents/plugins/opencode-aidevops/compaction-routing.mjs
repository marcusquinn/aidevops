// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { DEFAULT_COMPACTION_TARGET } from "./context-budget-policy.mjs";
import { routingCandidates, routingModelIdentity, routingVariant } from "./model-routing.mjs";
import { clampReasoningVariant } from "./subagent-effort.mjs";

// GH#32934: OpenCode sends the session variant with compaction, and variant
// options merge last, so `agent.compaction.variant` cannot lower effort. Opus
// 5.5 `max` compactions ran 165-196s with no output before being aborted.
export const COMPACTION_EFFORT_CEILING = "high";
const EFFORT_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const EFFORT_KEYS = ["effort", "reasoningEffort", "reasoning_effort"];

function inputLimit(config, model) {
  const { providerID, modelID } = routingModelIdentity(model);
  const limit = config?.provider?.[providerID]?.models?.[modelID]?.limit;
  if (!limit || typeof limit !== "object") return 0;
  if (Number.isFinite(limit.input)) return limit.input;
  if (Number.isFinite(limit.context) && Number.isFinite(limit.output)) {
    return limit.context - limit.output;
  }
  return 0;
}

/**
 * Route unpinned OpenCode compaction summaries to the first simple-tier
 * candidate that can accept the full managed compaction input. Candidates
 * that are too small (Haiku's 168K) are skipped rather than disabling the
 * route; with no fitting candidate compaction stays on the parent model.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object} routing - resolved aidevops routing table
 * @returns {boolean} whether a compaction route was applied
 */
export function applyCompactionRouting(config, routing) {
  if (!config || !routing) return false;
  config.agent ??= {};
  const compaction = config.agent.compaction ??= {};
  if (String(compaction.model || "") || String(compaction.variant || "")) return false;

  for (const model of routingCandidates(routing, "simple")) {
    if (inputLimit(config, model) < DEFAULT_COMPACTION_TARGET) continue;
    compaction.model = model;
    const variant = routingVariant(routing, "simple", model);
    if (variant) compaction.variant = variant;
    return true;
  }
  return false;
}

function compactionAgent(input) {
  return typeof input?.agent === "string" ? input.agent : input?.agent?.name;
}

function compactionEffortCeiling(input, routing, env) {
  const override = String(env?.AIDEVOPS_COMPACTION_MAX_EFFORT || "").toLowerCase();
  const ceiling = EFFORT_LEVELS.includes(override) ? override : COMPACTION_EFFORT_CEILING;
  const providerID = input?.model?.providerID ?? input?.provider?.id ?? "";
  const modelID = input?.model?.id ?? input?.model?.modelID ?? "";
  const model = `${providerID}/${modelID}`;
  if (!routingCandidates(routing, "simple").includes(model)) return ceiling;
  const routed = routingVariant(routing, "simple", model);
  return routed ? clampReasoningVariant(routed, ceiling) : ceiling;
}

/**
 * Clamp compaction reasoning effort down (never up) to the routed simple-tier
 * variant, or to COMPACTION_EFFORT_CEILING on the parent model. Covers
 * Anthropic adaptive `effort`, OpenAI `reasoningEffort`/`reasoning_effort`,
 * and nested `reasoning.effort`/`output_config.effort` shapes.
 * @returns {{from: string, to: string}[]} applied clamps
 */
export function capCompactionEffort(input, output, routing, env = process.env) {
  if (compactionAgent(input) !== "compaction" || !output?.options) return [];
  const ceiling = compactionEffortCeiling(input, routing, env);
  const options = output.options;
  const applied = [];
  for (const target of [options, options.reasoning, options.output_config]) {
    if (!target || typeof target !== "object") continue;
    for (const key of EFFORT_KEYS) {
      const current = target[key];
      if (typeof current !== "string") continue;
      const next = clampReasoningVariant(current, ceiling);
      if (next === current) continue;
      target[key] = next;
      applied.push({ from: current, to: next });
    }
  }
  return applied;
}
