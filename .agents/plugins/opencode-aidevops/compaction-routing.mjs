// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { DEFAULT_COMPACTION_TARGET } from "./context-budget-policy.mjs";
import { activeLocalOnlyPolicy, configuredLocalProviders, isLocalProvider } from "./local-only-policy.mjs";
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

// GH#35893: OpenCode 1.x reads the compaction model only from global agent
// config (session/compaction.ts: `agent.model ?? userMessage.model`); no hook
// can change it per session. Residency is therefore decided here, once:
// - bound local-only policy: only local candidates, else the (local) parent;
// - unbound with a local default `config.model`: same, from the configured
//   local-provider list, so a local session's history stays on the device;
// - otherwise: every candidate, as before.
function allowedCompactionProvider(config, policy, localProviders) {
  if (policy?.bound) return (providerID) => isLocalProvider(policy, providerID);
  const { providerID: defaultProvider } = routingModelIdentity(config?.model);
  if (!defaultProvider) return () => true;
  const local = typeof localProviders === "function" ? localProviders() : localProviders;
  if (!local?.includes(defaultProvider)) return () => true;
  return (providerID) => local.includes(providerID);
}

/**
 * Route unpinned OpenCode compaction summaries to the first simple-tier
 * candidate that can accept the full managed compaction input and is allowed
 * by local-provider residency. Candidates that are too small (Haiku's 168K)
 * or non-local for a local session are skipped rather than disabling the
 * route; with no fitting candidate compaction stays on the parent model.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object} routing - resolved aidevops routing table
 * @param {object} [opts] - `policy` (local-only binding) and `localProviders`
 *   (list or thunk; read only when the default model needs classifying)
 * @returns {boolean} whether a compaction route was applied
 */
export function applyCompactionRouting(config, routing, {
  policy = activeLocalOnlyPolicy(),
  localProviders = () => configuredLocalProviders(),
} = {}) {
  if (!config || !routing) return false;
  config.agent ??= {};
  const compaction = config.agent.compaction ??= {};
  if (String(compaction.model || "") || String(compaction.variant || "")) return false;

  const allowed = allowedCompactionProvider(config, policy, localProviders);
  for (const model of routingCandidates(routing, "simple")) {
    if (!allowed(routingModelIdentity(model).providerID)) continue;
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

/**
 * Warn once per process when an unbound session whose last model was local
 * is compacted on a non-local provider (GH#35893). Config-time routing cannot
 * see a session that switched to a local model after startup. Content-free:
 * only provider IDs are logged. Bound sessions never get here, because the
 * egress gate refuses the request first.
 * @param {object} [opts] - `localProviders` (list or thunk), `log(level, msg)`
 * @returns {(input: object, parentModel: string) => boolean} true when warned
 */
export function createCompactionResidencyWarning({
  localProviders = () => configuredLocalProviders(),
  log,
} = {}) {
  let warned = false;
  return (input, parentModel) => {
    if (warned || compactionAgent(input) !== "compaction") return false;
    const parentProvider = routingModelIdentity(parentModel).providerID;
    const provider = String(input?.model?.providerID ?? input?.provider?.id ?? "");
    if (!parentProvider || !provider || parentProvider === provider) return false;
    const local = typeof localProviders === "function" ? localProviders() : localProviders;
    if (!local?.includes(parentProvider) || local.includes(provider)) return false;
    warned = true;
    log?.("WARN", `[compaction] local provider "${parentProvider}" session compacted on non-local provider `
      + `"${provider}"; pin agent.compaction.model to a local model or launch with AIDEVOPS_RUNTIME_POLICY=local-only`);
    return true;
  };
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
 * @param {object} [opts] - `env` for the ceiling override, `log(level, msg)`
 * @returns {{from: string, to: string}[]} applied clamps
 */
export function capCompactionEffort(input, output, routing, { env = process.env, log } = {}) {
  if (compactionAgent(input) !== "compaction" || !output?.options) return [];
  const ceiling = compactionEffortCeiling(input, routing, env);
  const { options } = output;
  const applied = [options, options.reasoning, options.output_config]
    .flatMap((target) => clampEffortKeys(target, ceiling));
  const model = input?.model?.id ?? input?.model?.modelID ?? "unknown model";
  for (const { from, to } of applied) {
    log?.("INFO", `[compaction] effort capped ${from} -> ${to} (${model})`);
  }
  return applied;
}

function clampEffortKeys(target, ceiling) {
  if (!target || typeof target !== "object") return [];
  const applied = [];
  for (const key of EFFORT_KEYS) {
    const current = target[key];
    const next = typeof current === "string" ? clampReasoningVariant(current, ceiling) : current;
    if (next === current) continue;
    target[key] = next;
    applied.push({ from: current, to: next });
  }
  return applied;
}
