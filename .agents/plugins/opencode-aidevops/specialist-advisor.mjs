// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { routingCandidates, routingModelIdentity, routingProfile, routingTierForModel, routingVariant, selectConnectedRoutingCandidate } from "./model-routing.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";

export const SPECIALIST_ADVISOR = "specialist-advisor";

// A separate explicit profile, never another rung in the automatic tier ladder.
// Existing user profiles (including disable:true) retain ownership of their name.
export function registerSpecialistAdvisor(config, agentsDir, routing, state) {
  const route = routing?.specialistAdvisor;
  if (state && state.specialistAdvisor !== config.agent?.[SPECIALIST_ADVISOR]) {
    delete state.specialistAdvisor;
  }
  if (!route || config.agent?.[SPECIALIST_ADVISOR]) return 0;
  let prompt;
  try {
    prompt = readFileSync(join(agentsDir, "prompts/specialist-advisor.md"), "utf8").trim();
  } catch {
    return 0; // Missing canonical guidance must not create an unbounded adviser.
  }
  if (!prompt) return 0;
  config.agent ||= {};
  config.agent[SPECIALIST_ADVISOR] = {
    description: "Explicit higher-capability advisory inference over supplied evidence; requires an escalation reason",
    mode: "subagent",
    model: route.model,
    variant: route.variant,
    prompt,
    tools: { "*": false },
    permission: { "*": "deny" },
  };
  if (state) state.specialistAdvisor = config.agent[SPECIALIST_ADVISOR];
  state?.pinned?.add(SPECIALIST_ADVISOR);
  return 1;
}

export function validateSpecialistRequest(text) {
  let envelope;
  try {
    envelope = JSON.parse(String(text).replace(/^\[effort:(simple|standard|thinking)\]\s*/i, ""));
  } catch {
    throw new Error("[aidevops] Specialist adviser requires a bounded JSON evidence envelope");
  }
  const required = ["objective", "scope", "evidence", "escalation_reason", "output"];
  if (!required.every((key) => typeof envelope?.[key] === "string" && envelope[key].trim())) {
    throw new Error("[aidevops] Specialist adviser requires objective, scope, evidence, escalation_reason and output");
  }
}

// Defaults only: never migrate an explicit user model/effort pin behind their back.
export function applyDailyDriverDefaults(config, routing) {
  const route = routing?.interactiveDefault || routingProfile(routing, "thinking");
  if (!route.model) return;
  config.model ||= route.model;
  for (const profile of Object.values(config.agent || {})) {
    if (profile?.mode !== "primary" || profile.variant) continue;
    if ((profile.model || config.model) === route.model && route.variant) {
      profile.variant = route.variant;
    }
  }
}

export function primaryRoutingExhausted(state) {
  return new Error(`[aidevops] No available ${state.tier} model after rejection of ${state.requested}. Re-authenticate or change the model routing configuration.`);
}

// Same candidate walk as child entitlement recovery: only later, connected
// candidates in this tier; the selector also enforces auth TTL and local-only.
export async function nextPrimaryRoutingCandidate(context, state) {
  const models = routingCandidates(context.modelRouting, state.tier);
  const start = models.indexOf(state.model);
  if (start < 0) return "";
  const remaining = [...new Set(models.slice(start + 1))];
  const providerState = await context.resolveProviderState();
  if (!providerState) return null; // Failed lookup is not exhaustion.
  return selectConnectedRoutingCandidate(
    { tiers: { [state.tier]: { models: remaining } } }, state.tier,
    providerState, undefined, context.resolveAvailability(),
  );
}

async function knownPrimarySession(context, sessionID) {
  try {
    const session = await context.getSession(context.client, sessionID);
    return session?.id === sessionID && !session.parentID;
  } catch {
    return false; // Unknown ancestry must never compete with child recovery.
  }
}

// Defaults and recovery share this module; explicit models outside the table
// remain owned by the user, but a cached definite rejection still fails fast.
export async function resolvePrimaryRoute(context, input, message) {
  const sessionID = message.sessionID || input.sessionID;
  if (!sessionID || !await knownPrimarySession(context, sessionID)) return null;
  const model = context.modelIdentity(message.model || input.model);
  const tier = routingTierForModel(context.modelRouting, model, message.variant);
  const rejected = isModelUnavailable(model, context.resolveAvailability().authSignature);
  if (!tier) {
    if (rejected) throw new Error(`[aidevops] Rejected model ${model} has no routing tier. Re-authenticate or change the model routing configuration.`);
    return null;
  }
  const route = { sessionID, model, tier, requested: model, agent: message.agent };
  if (rejected) {
    const next = await nextPrimaryRoutingCandidate(context, route);
    if (next === null) return route; // Provider lookup failed: keep requested model.
    route.model = next;
    if (!route.model) throw primaryRoutingExhausted(route);
    message.model = routingModelIdentity(route.model);
    message.variant = routingVariant(context.modelRouting, tier, route.model) || undefined;
  }
  return route;
}
