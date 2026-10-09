// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Provider-neutral routing-table reader shared by OpenCode config and request
// hooks. Candidate order is policy: availability moves right within a tier;
// capability failure moves down escalationOrder.

import { existsSync, readFileSync } from "fs";
import { floorReasoning, reasoningFloor, normalizeInteractiveDefault, normalizeSpecialistAdvisor } from "./model-routing-variant.mjs";
import { activeLocalOnlyPolicy, isLocalProvider } from "./local-only-policy.mjs";

export const DEFAULT_ESCALATION_ORDER = ["simple", "standard", "thinking"];

export function normalizeRoutingTier(value) {
  const tier = String(value || "").trim().toLowerCase();
  return DEFAULT_ESCALATION_ORDER.includes(tier) ? tier : "standard";
}

function normalizeTierConfig(value) {
  const models = Array.isArray(value?.models)
    ? value.models.filter((model) => typeof model === "string" && model.includes("/"))
    : [];
  const reasoning = value?.reasoning && typeof value.reasoning === "object"
    ? { ...value.reasoning }
    : {};
  return { models, reasoning };
}

export function normalizeModelRouting(value = {}) {
  const configuredOrder = Array.isArray(value?.escalation_order)
    ? value.escalation_order.filter((tier) => DEFAULT_ESCALATION_ORDER.includes(tier))
    : [];
  const escalationOrder = [...new Set(configuredOrder)];
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    if (!escalationOrder.includes(tier)) escalationOrder.push(tier);
  }

  const tiers = {};
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    tiers[tier] = normalizeTierConfig(value?.tiers?.[tier]);
  }
  return {
    tiers,
    escalationOrder,
    specialistAdvisor: normalizeSpecialistAdvisor(value.specialist_advisor),
    interactiveDefault: normalizeInteractiveDefault(value.interactive_default),
    minimumReasoning: reasoningFloor(value?.settings?.minimum_reasoning),
  };
}

function mergeTier(baseTier, tierOverride) {
  const merged = {
    models: [...(baseTier?.models || [])],
    reasoning: { ...(baseTier?.reasoning || {}) },
  };
  if (!tierOverride || typeof tierOverride !== "object") return merged;
  if (Array.isArray(tierOverride.models)) {
    merged.models = tierOverride.models.filter((model) => typeof model === "string" && model.includes("/"));
  }
  if (tierOverride.reasoning && typeof tierOverride.reasoning === "object") {
    merged.reasoning = { ...merged.reasoning, ...tierOverride.reasoning };
  }
  return merged;
}

export function mergeModelRouting(base, override = {}) {
  const merged = normalizeModelRouting();
  merged.minimumReasoning = reasoningFloor(override?.settings?.minimum_reasoning ?? base?.minimumReasoning);
  merged.interactiveDefault = Object.hasOwn(override, "interactive_default")
    ? normalizeInteractiveDefault(override.interactive_default)
    : base?.interactiveDefault || null;
  merged.specialistAdvisor = Object.hasOwn(override, "specialist_advisor")
    ? normalizeSpecialistAdvisor(override.specialist_advisor)
    : base?.specialistAdvisor || null;
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    merged.tiers[tier] = mergeTier(base?.tiers?.[tier], override?.tiers?.[tier]);
  }
  merged.escalationOrder = Array.isArray(override?.escalation_order)
    ? normalizeModelRouting(override).escalationOrder
    : [...(base?.escalationOrder || DEFAULT_ESCALATION_ORDER)];
  return merged;
}

export function loadModelRouting(paths) {
  let routing = normalizeModelRouting();
  for (const path of [...(paths || [])].reverse()) {
    if (!path || !existsSync(path)) continue;
    try {
      routing = mergeModelRouting(routing, JSON.parse(readFileSync(path, "utf8")));
    } catch {
      // Continue through lower-precedence valid tables when an override is invalid.
    }
  }
  return routing;
}

export function routingCandidates(routing, tier) {
  return routing?.tiers?.[normalizeRoutingTier(tier)]?.models || [];
}

export function routingModelIdentity(model) {
  const value = String(model || "");
  const separator = value.indexOf("/");
  if (separator <= 0 || separator === value.length - 1) {
    return { providerID: "", modelID: "" };
  }
  return {
    providerID: value.slice(0, separator),
    modelID: value.slice(separator + 1),
  };
}

// A local-only bound session (GH#34125) never routes to a non-local provider;
// no local candidate yields "", which callers treat as no route (child
// routing throws, escalation and browser delegation are skipped). The
// chat.params egress gate still refuses any non-local current model.
export function selectConnectedRoutingCandidate(routing, tier, providerState, policy = activeLocalOnlyPolicy()) {
  const connected = new Set(Array.isArray(providerState?.connected) ? providerState.connected : []);
  const providers = new Map(
    (Array.isArray(providerState?.all) ? providerState.all : [])
      .filter((provider) => provider?.id)
      .map((provider) => [provider.id, provider]),
  );

  for (const candidate of routingCandidates(routing, tier)) {
    const { providerID, modelID } = routingModelIdentity(candidate);
    if (policy?.bound && !isLocalProvider(policy, providerID)) continue;
    const provider = providers.get(providerID);
    if (!provider || !connected.has(providerID)) continue;
    const models = provider.models && typeof provider.models === "object" ? provider.models : {};
    const registered = Object.entries(models).some(
      ([key, value]) => key === modelID || value?.id === modelID,
    );
    if (registered) return candidate;
  }
  return "";
}

export function routingPrimary(routing, tier) {
  return routingCandidates(routing, tier)[0] || "";
}

export function routingVariant(routing, tier, model) {
  const policy = routing?.tiers?.[normalizeRoutingTier(tier)]?.reasoning || {};
  const provider = String(model || "").split("/", 1)[0];
  return floorReasoning(policy[model] ?? policy[provider] ?? policy.default ?? "", routing?.minimumReasoning);
}

export function routingCandidateIndex(routing, tier, model) {
  return routingCandidates(routing, tier).indexOf(model);
}

// A model may serve several tiers at different reasoning levels (Sol is
// standard and thinking at medium). Prefer the tier whose configured
// variant matches the observed one; otherwise the lowest tier listing it.
export function routingTierForModel(routing, model, variant = "") {
  const tiers = (routing?.escalationOrder || DEFAULT_ESCALATION_ORDER)
    .filter((tier) => routingCandidates(routing, tier).includes(model));
  const matching = variant ? tiers.find((tier) => routingVariant(routing, tier, model) === variant) : "";
  return matching || tiers[0] || "";
}

export function nextRoutingTier(routing, tier) {
  const order = routing?.escalationOrder || DEFAULT_ESCALATION_ORDER;
  const index = order.indexOf(normalizeRoutingTier(tier));
  if (index < 0) return "";
  return order.slice(index + 1).find((candidate) => routingCandidates(routing, candidate).length > 0) || "";
}

export function routingProfile(routing, tier) {
  const normalizedTier = normalizeRoutingTier(tier);
  const model = routingPrimary(routing, normalizedTier);
  if (!model) return { tier: normalizedTier, model: "", variant: "" };
  return {
    tier: normalizedTier,
    model,
    variant: routingVariant(routing, normalizedTier, model),
  };
}
