// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#37667: move a running OpenCode V2 Task child off a provider whose OAuth
// pool is fully rate limited. V2 reloads the session model before every retry
// attempt (SessionRunner.runStep -> SessionContext.load -> resolveModel), so
// switching the child session's model inside the `retry` hook makes the next
// attempt of the same Task run use the next routable same-tier model, and the
// parent receives that child's normal result. Nothing is cancelled: when no
// candidate qualifies, the host's own retry decision stands.

import { activeLocalOnlyPolicy } from "./local-only-policy.mjs";
import {
  DEFAULT_ESCALATION_ORDER,
  candidateRateLimitedUntil,
  routingCandidates,
  routingModelIdentity,
  routingUnavailableDetail,
  routingVariant,
} from "./model-routing.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";
import { resolveRoutingAvailability } from "./provider-rate-limits.mjs";
import { SPECIALIST_ADVISOR } from "./specialist-advisor.mjs";

// Agents whose model is the parent's exact route by design.
const PARENT_ROUTE_AGENTS = new Set([SPECIALIST_ADVISOR, "domain-focused", "domain-light"]);
const MAX_FAILOVER_SESSIONS = 64;
const HOST_APIS = [["session", "get"], ["session", "switchModel"], ["agent", "get"], ["model", "list"]];

// V2 model refs are `{ providerID, id, variant }`.
function routingModelKey(model) {
  return model?.providerID && model.id ? `${model.providerID}/${model.id}` : "";
}

// Host APIs return either the record or a `{ data }` envelope.
function unwrapRecord(result) {
  return result && typeof result === "object" && "data" in result ? result.data : result;
}

function modelList(result) {
  const value = unwrapRecord(result);
  return Array.isArray(value) ? value : [];
}

/**
 * The highest tier listing a running model, preferring tiers whose configured
 * variant matches. Failing over within the highest listed tier never drops a
 * child below the tier it already runs at.
 */
export function routingFailoverTier(routing, model, variant = "") {
  const order = routing?.escalationOrder || DEFAULT_ESCALATION_ORDER;
  const tiers = order.filter((tier) => routingCandidates(routing, tier).includes(model));
  const matching = tiers.filter((tier) => routingVariant(routing, tier, model) === variant);
  return (variant && matching.at(-1)) || tiers.at(-1) || "";
}

function candidateBlocked(routing, candidate, availability, now) {
  if (isModelUnavailable(candidate, availability.authSignature)) return true;
  if (candidateRateLimitedUntil(candidate, availability, now)) return true;
  const { providerID, modelID } = routingModelIdentity(candidate);
  return providerID === "openai" && availability.openAIAuthType === "oauth"
    && (routing?.chatgptOAuthUnsupported || []).includes(modelID);
}

function variantIds(entry) {
  return Array.isArray(entry?.variants) ? entry.variants.map((item) => item?.id).filter(Boolean) : [];
}

// The host model payload for a candidate; null when the host does not list the
// model or lacks its configured reasoning variant (never run at lower effort).
function availableModel(available, candidate, required) {
  const { providerID, modelID } = routingModelIdentity(candidate);
  const entry = available.find((model) => model?.providerID === providerID && model.id === modelID);
  if (!entry) return null;
  const variants = variantIds(entry);
  if (!required || variants.length === 0) return { providerID, id: modelID };
  return variants.includes(required) ? { providerID, id: modelID, variant: required } : null;
}

/**
 * Next same-tier candidate for a running child. `available` is the host's
 * model list (`{ providerID, id, variants }`). The exhausted current model is
 * skipped as rate limited. Same tier only: returns null rather than a lower tier.
 */
export function selectSameTierFailoverCandidate(routing, tier, {
  available = [], availability = {}, policy = activeLocalOnlyPolicy(), now = Date.now(),
} = {}) {
  if (policy?.bound) return null;
  for (const candidate of routingCandidates(routing, tier)) {
    if (candidateBlocked(routing, candidate, availability, now)) continue;
    const model = availableModel(available, candidate, routingVariant(routing, tier, candidate));
    if (model) return { candidate, model };
  }
  return null;
}

async function agentRouteBlocker(state, agentID) {
  if (!agentID || PARENT_ROUTE_AGENTS.has(agentID)) return "parent_route_agent";
  const agent = unwrapRecord(await state.getAgent({ agentID }));
  if (!agent) return "agent_unknown";
  return agent.model ? "pinned_agent" : "";
}

// The model a child runs on when it follows its route: its last failover
// target, otherwise its parent's model.
async function expectedChildModel(state, sessionID, parentID) {
  const routed = state.switched.get(sessionID);
  if (routed) return routed.candidate;
  const parent = unwrapRecord(await state.getSession({ sessionID: parentID }));
  return routingModelKey(parent?.model);
}

// Why a child must keep its model; "" when it follows its parent's route.
async function childRouteBlocker(state, event, current) {
  const session = unwrapRecord(await state.getSession({ sessionID: event.sessionID }));
  if (!session?.parentID) return "root_session";
  const agentBlocker = await agentRouteBlocker(state, session.agent || event.agent || "");
  if (agentBlocker) return agentBlocker;
  // A child off its expected model was spawned with an explicit model.
  return await expectedChildModel(state, event.sessionID, session.parentID) === current ? "" : "pinned_model";
}

function rememberFailover(switched, sessionID, failover) {
  switched.delete(sessionID);
  switched.set(sessionID, failover);
  while (switched.size > MAX_FAILOVER_SESSIONS) switched.delete(switched.keys().next().value);
}

async function failOver(state, event, current, availability) {
  if (await childRouteBlocker(state, event, current)) return false;
  // A repeated failover keeps the tier of the first one.
  const tier = state.switched.get(event.sessionID)?.tier
    || routingFailoverTier(state.routing, current, event.model.variant);
  if (!tier) return false;
  const next = selectSameTierFailoverCandidate(state.routing, tier, {
    available: modelList(await state.listModels()),
    availability,
    policy: state.resolvePolicy(),
    now: state.now(),
  });
  if (!next) {
    state.log("WARN", `[aidevops] Subagent rate-limit failover found no routable '${tier}' model for session ${event.sessionID}${routingUnavailableDetail(state.routing, tier, availability)}`);
    return false;
  }
  await state.switchModel({ sessionID: event.sessionID, model: next.model });
  rememberFailover(state.switched, event.sessionID, { candidate: next.candidate, tier });
  event.decision = { retry: true, delay: 0 };
  state.log("INFO", `[aidevops] Subagent rate-limit failover: session ${event.sessionID} ${current} -> ${next.candidate} ('${tier}' tier)`);
  return true;
}

async function handleRetry(state, event) {
  // Only a retry the host already scheduled; a terminal decision stays terminal.
  if (event?.decision?.retry !== true || !state.routing || !event.sessionID) return false;
  const availability = state.resolveAvailability();
  const current = routingModelKey(event.model);
  // API-key providers and partially limited pools are never reported here.
  if (!candidateRateLimitedUntil(current, availability, state.now()) || state.resolvePolicy()?.bound) return false;
  try {
    return await failOver(state, event, current, availability);
  } catch (error) {
    state.log("WARN", `[aidevops] Subagent rate-limit failover skipped: ${String(error)}`);
    return false;
  }
}

/**
 * Failover handler over injected host APIs.
 * @returns {(event: object) => Promise<boolean>} true when the child switched
 */
export function createV2SubagentRateLimitFailover({
  getSession,
  getAgent,
  listModels,
  switchModel,
  routing,
  resolvePolicy = activeLocalOnlyPolicy,
  resolveAvailability = resolveRoutingAvailability,
  log = () => {},
  now = Date.now,
} = {}) {
  const state = {
    getSession, getAgent, listModels, switchModel, routing, resolvePolicy, resolveAvailability, log, now,
    switched: new Map(),
  };
  return (event) => handleRetry(state, event);
}

async function unsupportedHost() {
  return false;
}

/**
 * Bind failover to the V2 plugin context. A host lacking any required API gets
 * a handler that never acts (no failover, no cancellation).
 */
export function createV2SubagentFailover(ctx, routing, log) {
  if (HOST_APIS.some(([domain, method]) => typeof ctx?.[domain]?.[method] !== "function")) return unsupportedHost;
  return createV2SubagentRateLimitFailover({
    getSession: (input) => ctx.session.get(input),
    getAgent: (input) => ctx.agent.get(input),
    listModels: () => ctx.model.list(),
    switchModel: (input) => ctx.session.switchModel(input),
    routing,
    log: (level, message) => log(level, message),
  });
}
