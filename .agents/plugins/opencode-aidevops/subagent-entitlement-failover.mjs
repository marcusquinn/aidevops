// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#36698: after a definite pre-generation entitlement rejection, re-prompt
// the same child on the next connected candidate of its own tier, in routing
// table order and at most once per distinct candidate. Never substitutes a
// lower tier or a model outside the active routing table.

import { routingCandidates, selectConnectedRoutingCandidate } from "./model-routing.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";
import { responseError, responseText, toolFailed } from "./subagent-escalation-text.mjs";

const FAILOVER_PROMPT = "Continue the original task in this session. The previous model was unavailable before generation.";
const STOP = Object.freeze({ result: null });

function rejectedForAuth(escalator, model) {
  return isModelUnavailable(model, escalator.availability().authSignature);
}

function childFailed(escalator, output, childID) {
  return toolFailed(output) || escalator.lifecycle.terminalEvidence(childID) === "error";
}

function blockedBySideEffects(escalator, output, childID) {
  if (!escalator.sideEffects.get(childID)) return false;
  escalator.skippedForSideEffects(output);
  return true;
}

function eligiblePolicy(escalator, output, childID) {
  const rejected = escalator.lifecycle.takeEntitlementRejection(childID);
  const policy = escalator.context.policies.get(childID);
  const routed = policy && !policy.pinned && policy.routedModel?.startsWith("openai/");
  if (!routed || !rejected || !childFailed(escalator, output, childID)) return null;
  return rejectedForAuth(escalator, policy.routedModel) ? policy : null;
}

async function failoverState(escalator, output, childID) {
  const policy = eligiblePolicy(escalator, output, childID);
  if (!policy || blockedBySideEffects(escalator, output, childID)) return null;
  const child = await escalator.loadChildSession(childID);
  const providerState = await escalator.context.resolveProviderState();
  const candidates = routingCandidates(policy.armRouting || escalator.context.modelRouting, policy.effort);
  const start = candidates.indexOf(policy.routedModel);
  if (!child.available || !providerState || start < 0) return null;
  return {
    child,
    childID,
    output,
    policy,
    providerState,
    rejected: [policy.routedModel],
    remaining: [...new Set(candidates.slice(start + 1))].filter((model) => model !== policy.routedModel),
    requested: policy.routedModel,
    tier: policy.effort,
  };
}

function candidateConnected(escalator, state, model) {
  const route = { tiers: { [state.tier]: { models: [model] } } };
  return Boolean(selectConnectedRoutingCandidate(route, state.tier, state.providerState, undefined, escalator.availability()));
}

function skipCandidate(escalator, state, model) {
  // Already rejected for this auth inside the TTL: skip without a request.
  if (rejectedForAuth(escalator, model)) {
    state.rejected.push(model);
    return true;
  }
  return !candidateConnected(escalator, state, model);
}

async function promptCandidate(escalator, state, model) {
  const { policy, tier } = state;
  console.error(`[aidevops] entitlement failover tier=${tier} requested=${state.requested} rejected=${state.rejected.join(",")} next=${model}`);
  escalator.prepareRoute(policy, tier, model);
  policy.reason = "entitlement_failover";
  policy.escalated = false;
  try {
    return { response: await escalator.promptNextTier(state.childID, state.child.session, model, FAILOVER_PROMPT) };
  } catch {
    return null;
  } finally {
    policy.awaitingEscalationPrompt = false;
  }
}

function responseAccepted(response) {
  return !responseError(response) && !response?.data?.info?.error;
}

function completeFailover(escalator, state, model, response) {
  const text = responseText(response);
  if (!text) return null;
  const failover = { tier: state.tier, requested: state.requested, rejected: [...state.rejected], model };
  state.output.output = text;
  state.output.metadata = { ...state.output.metadata, status: "completed", aidevopsRoutingFailover: failover };
  escalator.lifecycle.takeEntitlementRejection(state.childID);
  escalator.lifecycle.rememberStatus(state.childID, "completed");
  return failover;
}

function continueAfterRejection(escalator, state, model) {
  const rejectedAgain = escalator.lifecycle.takeEntitlementRejection(state.childID) && rejectedForAuth(escalator, model);
  if (!rejectedAgain) return STOP;
  state.rejected.push(model);
  return blockedBySideEffects(escalator, state.output, state.childID) ? STOP : null;
}

/** Returns null to try the next candidate, otherwise `{ result }` to finish. */
async function attemptCandidate(escalator, state, model) {
  if (skipCandidate(escalator, state, model)) return null;
  const attempt = await promptCandidate(escalator, state, model);
  if (!attempt) return STOP;
  if (responseAccepted(attempt.response)) return { result: completeFailover(escalator, state, model, attempt.response) };
  return continueAfterRejection(escalator, state, model);
}

function reportExhausted(state) {
  const message = `[aidevops] No available ${state.tier} model: requested=${state.requested} rejected=${state.rejected.join(",")}; check provider access or routing configuration.`;
  console.error(message);
  state.output.output = message;
}

/**
 * Fail a rejected child Task over to the next same-tier candidate.
 * `escalator` supplies lifecycle, policies, side-effect tracking and prompting.
 */
export async function failoverTask(escalator, output, childID) {
  const state = await failoverState(escalator, output, childID);
  if (!state) return null;
  for (const model of state.remaining) {
    const outcome = await attemptCandidate(escalator, state, model);
    if (outcome) return outcome.result;
  }
  reportExhausted(state);
  return null;
}
