// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { routingCandidateIndex, routingTierForModel } from "./model-routing.mjs";

function childModelFrom(context, input) {
  return context.modelIdentity({
    providerID: input?.provider?.id ?? input?.model?.providerID,
    modelID: input?.model?.id ?? input?.model?.modelID,
  });
}

function currentVariantFrom(context, input, output) {
  return context.extractVariant(input.message)
    || output?.options?.reasoningEffort
    || output?.options?.reasoning_effort
    || context.extractVariant(input.model);
}

async function recordRootRouting(context, sessionID, input, childModel, currentVariant) {
  const rootTier = routingTierForModel(context.modelRouting, childModel);
  const dispatchTier = process.env.AIDEVOPS_DISPATCH_TIER || "";
  const shouldRecord = rootTier && !dispatchTier
    && typeof context.onRoutingDecision === "function";
  if (!shouldRecord) return;

  const routedVariant = context.resolveTierReasoning(
    rootTier, input?.provider?.id, input?.model?.id, context.tierReasoning,
  );
  await context.onRoutingDecision(sessionID, {
    tier: rootTier,
    model: childModel === "/" ? "" : childModel,
    variant: currentVariant || routedVariant,
    requestedVariant: routedVariant,
    resolvedVariant: currentVariant || routedVariant,
    candidateIndex: routingCandidateIndex(context.modelRouting, rootTier, childModel),
    attempt: 1,
    reason: "model_profile",
    population: "top_level_profile",
  });
}

async function effectiveChildVariant(context, childSession, childModel, requestedVariant, currentVariant) {
  const parentRoute = await context.getParentRoute(context.client, childSession);
  const comparableModels = [requestedVariant, parentRoute.variant, parentRoute.model].every(Boolean);
  if (comparableModels && parentRoute.model === childModel) {
    return context.clampReasoningVariant(requestedVariant, parentRoute.variant);
  }
  return requestedVariant || currentVariant;
}

function applyRequestedVariant(output, requestedVariant, effectiveVariant) {
  if (!requestedVariant) return;
  output.options.reasoningEffort = effectiveVariant;
  if (Object.hasOwn(output.options, "reasoning_effort")) {
    output.options.reasoning_effort = effectiveVariant;
  }
}

async function recordChildRouting(context, {
  sessionID, childSession, childModel, desiredEffort, effectiveVariant, policy,
}) {
  if (typeof context.onRoutingDecision !== "function") return;
  await context.onRoutingDecision(sessionID, {
    parentSessionID: policy?.parentSessionID || childSession.parentID,
    tier: desiredEffort,
    model: policy?.routedModel || (childModel === "/" ? "" : childModel),
    variant: effectiveVariant,
    requestedVariant: policy?.requestedVariant || effectiveVariant,
    resolvedVariant: effectiveVariant,
    candidateIndex: policy?.candidateIndex
      ?? routingCandidateIndex(context.modelRouting, desiredEffort, childModel),
    attempt: policy?.attempt || 1,
    reason: policy?.reason || "agent_default",
    escalated: Boolean(policy?.escalated),
    population: "interactive_child",
  });
}

function applyProtectedChildParams(context, input, output, policy) {
  const domainName = input?.message?.agent;
  const creative = context.agentRoutingState?.inheritParentRoute?.has(domainName);
  // Preserve native explicit model/variant pins on creative executors.
  if (creative && context.agentRoutingState?.pinned?.has(domainName)) return true;
  if (policy?.reason?.startsWith("browser_")
    && childModelFrom(context, input) !== policy.routedModel) {
    throw new Error("[aidevops] Browser child model changed; verify state before continuing");
  }
  if (!["bounded_domain", "creative_parent"].includes(policy?.reason)
    && !creative && !context.agentRoutingState?.domainDelegation?.profiles?.has(domainName)) return false;
  if (!policy?.domainVariant || childModelFrom(context, input) !== policy.routedModel) {
    throw new Error("[aidevops] Domain parent ceiling unavailable or model changed");
  }
  applyRequestedVariant(output, policy.domainVariant, policy.domainVariant);
  return true;
}

function requestedChildVariant(context, input, policy, effort) {
  if (policy?.browserVariant) return policy.browserVariant;
  if (policy?.reason === "specialist_advice") return context.agentRoutingState.specialistAdvisor.variant;
  return context.resolveTierReasoning(
    effort, input?.provider?.id, input?.model?.id, context.tierReasoning,
  );
}

export async function routeChatParams(context, input, output) {
  const sessionID = input?.message?.sessionID;
  if (!sessionID) return;

  const domainPolicy = context.policies.get(sessionID);
  if (applyProtectedChildParams(context, input, output, domainPolicy)) return;

  try {
    const childSession = await context.getSession(context.client, sessionID);
    const childModel = childModelFrom(context, input);
    const currentVariant = currentVariantFrom(context, input, output);
    if (!childSession.parentID) {
      await recordRootRouting(context, sessionID, input, childModel, currentVariant);
      return;
    }

    const policy = context.policies.get(sessionID);
    const desiredEffort = policy?.effort
      ?? context.inferSubagentEffort(input.message.agent ?? childSession.agent);
    const requestedVariant = requestedChildVariant(context, input, policy, desiredEffort);
    const effectiveVariant = await effectiveChildVariant(
      context, childSession, childModel, requestedVariant, currentVariant,
    );
    if (policy) policy.requestedVariant = requestedVariant;
    applyRequestedVariant(output, requestedVariant, effectiveVariant);
    await recordChildRouting(context, {
      sessionID, childSession, childModel, desiredEffort, effectiveVariant, policy,
    });
  } catch (error) {
    // A browser route may have acted on a site: never silently lose its model
    // or effort ceiling when parent/session metadata cannot be verified.
    if (domainPolicy?.reason?.startsWith("browser_")) throw error;
    // Other provider requests preserve their existing fail-open behavior.
  }
}
