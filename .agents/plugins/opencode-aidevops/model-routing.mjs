// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Provider-neutral routing-table reader shared by OpenCode config and request
// hooks. Candidate order is policy: availability moves right within a tier;
// capability failure moves down escalationOrder.

import { existsSync, readFileSync } from "fs";
import {
  compactionReasoning,
  floorReasoning,
  normalizeInteractiveDefault,
  normalizeSpecialistAdvisor,
  reasoningFloor,
} from "./model-routing-variant.mjs";
import { activeLocalOnlyPolicy, isLocalProvider } from "./local-only-policy.mjs";
import { providerHasUsableCredentials } from "./provider-credentials.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";

export { providerHasUsableCredentials };

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
    chatgptOAuthUnsupported: (Array.isArray(value?.chatgpt_oauth_restrictions?.openai_unsupported)
      ? value.chatgpt_oauth_restrictions.openai_unsupported : []).filter((model) => typeof model === "string"),
    specialistAdvisor: normalizeSpecialistAdvisor(value.specialist_advisor),
    interactiveDefault: normalizeInteractiveDefault(value.interactive_default),
    minimumReasoning: reasoningFloor(value?.settings?.minimum_reasoning),
    compactionReasoning: compactionReasoning(value?.settings?.compaction_reasoning),
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
  merged.chatgptOAuthUnsupported = Object.hasOwn(override?.chatgpt_oauth_restrictions || {}, "openai_unsupported")
    ? normalizeModelRouting(override).chatgptOAuthUnsupported
    : [...(base?.chatgptOAuthUnsupported || [])];
  merged.minimumReasoning = reasoningFloor(override?.settings?.minimum_reasoning ?? base?.minimumReasoning);
  merged.compactionReasoning = compactionReasoning(
    override?.settings?.compaction_reasoning ?? base?.compactionReasoning,
  );
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
function providerRegistersModel(provider, modelID) {
  const models = provider.models && typeof provider.models === "object" ? provider.models : {};
  return Object.entries(models).some(([key, value]) => key === modelID || value?.id === modelID);
}

/**
 * GH#37649: live rate-limit reset for a candidate whose provider OAuth pool is
 * exhausted (`availability.rateLimitedProviders`); 0 when routable. Expired
 * resets are ignored, so recovery needs no configuration change.
 */
export function candidateRateLimitedUntil(candidate, availability = {}, now = Date.now()) {
  const { providerID } = routingModelIdentity(candidate);
  const until = Number(availability?.rateLimitedProviders?.[providerID]) || 0;
  return until > now ? until : 0;
}

/**
 * GH#36698/GH#37649: actionable detail naming same-tier models rejected for
 * the current auth or rate limited (`rate_limited=model@reset`); "" if none.
 */
export function routingUnavailableDetail(routing, tier, availability = {}) {
  const candidates = routingCandidates(routing, tier);
  const rejected = candidates.filter((candidate) => isModelUnavailable(candidate, availability.authSignature));
  const limited = candidates
    .map((candidate) => [candidate, candidateRateLimitedUntil(candidate, availability)])
    .filter(([, until]) => until)
    .map(([candidate, until]) => `${candidate}@${new Date(until).toISOString()}`);
  const parts = [];
  if (rejected.length) parts.push(`rejected=${rejected.join(",")} (entitlement rejected for current auth; retried after expiry or re-login)`);
  if (limited.length) parts.push(`rate_limited=${limited.join(",")} (provider rate limit; routable again after the listed reset)`);
  return parts.length ? `: requested=${candidates[0]} ${parts.join(" ")}` : "";
}

function candidateRoutable(candidate, scope) {
  // GH#36698/GH#37649: skip a model with a live entitlement rejection for this
  // auth, or whose provider OAuth pool is exhausted until its reset.
  if (isModelUnavailable(candidate, scope.authSignature)
    || candidateRateLimitedUntil(candidate, scope.availability, scope.now)) return false;
  const { providerID, modelID } = routingModelIdentity(candidate);
  if (providerID === "openai" && scope.openAIAuthType === "oauth"
    && scope.chatgptOAuthUnsupported.includes(modelID)) return false;
  if (scope.policy?.bound && !isLocalProvider(scope.policy, providerID)) return false;
  const provider = scope.providers.get(providerID);
  // Connected is not authenticated: skip credential-less config providers (GH#35762).
  if (!provider || !scope.connected.has(providerID) || !providerHasUsableCredentials(provider)) return false;
  return providerRegistersModel(provider, modelID);
}

export function selectConnectedRoutingCandidate(routing, tier, providerState, policy = activeLocalOnlyPolicy(), availability = {}) {
  const scope = {
    authSignature: availability?.authSignature,
    availability,
    now: Date.now(),
    openAIAuthType: availability?.openAIAuthType,
    chatgptOAuthUnsupported: routing?.chatgptOAuthUnsupported || [],
    connected: new Set(Array.isArray(providerState?.connected) ? providerState.connected : []),
    policy,
    providers: new Map(
      (Array.isArray(providerState?.all) ? providerState.all : [])
        .filter((provider) => provider?.id)
        .map((provider) => [provider.id, provider]),
    ),
  };
  return routingCandidates(routing, tier).find((candidate) => candidateRoutable(candidate, scope)) || "";
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
