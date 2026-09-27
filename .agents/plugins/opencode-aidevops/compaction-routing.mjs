// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { GPT6_COMPACTION_TARGET } from "./model-limits.mjs";
import { routingModelIdentity, routingProfile } from "./model-routing.mjs";

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
 * Route unpinned OpenCode compaction summaries through the simple tier only
 * when its configured model can accept the full managed compaction input.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object} routing - resolved aidevops routing table
 * @returns {boolean} whether a compaction route was applied
 */
export function applyCompactionRouting(config, routing) {
  if (!config || !routing) return false;
  config.agent ??= {};
  const compaction = config.agent.compaction ??= {};
  if (String(compaction.model || "") || String(compaction.variant || "")) return false;

  const profile = routingProfile(routing, "simple");
  if (!profile.model || inputLimit(config, profile.model) < GPT6_COMPACTION_TARGET) return false;
  compaction.model = profile.model;
  if (profile.variant) compaction.variant = profile.variant;
  return true;
}
