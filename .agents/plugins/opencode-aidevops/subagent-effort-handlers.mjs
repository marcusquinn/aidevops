// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  routingCandidateIndex,
  routingCandidates,
  routingModelIdentity,
  nextRoutingTier,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";
import { loadDelegatedDomainKnowledge } from "./agent-loader.mjs";
import { SPECIALIST_ADVISOR, validateSpecialistRequest } from "./specialist-advisor.mjs";
import { loadChildSessionWithParent, routeCreativeMessage } from "./subagent-parent-routing.mjs";
import { BROWSER_AGENT, routeBrowserDelegate } from "./browser-delegate-routing.mjs";
import { routeChatParams } from "./subagent-effort-params.mjs";

const DOMAIN_KNOWLEDGE_MARKER = "\n\n[AIDEvOps canonical domain knowledge]";
const DOMAIN_REQUIRED_FIELDS = ["task", "objective", "scope", "source", "decisions", "evidence", "output"];

function validDomainEnvelope(envelope) {
  if (!envelope) return false;
  const hasText = (key) => typeof envelope[key] === "string" && Boolean(envelope[key].trim());
  const checks = [
    DOMAIN_REQUIRED_FIELDS.every(hasText),
    ["simple", "standard"].includes(envelope.effort),
    envelope.authority === "inference-only",
    Array.isArray(envelope.tools) && envelope.tools.length === 0,
  ];
  return checks.every(Boolean);
}

function domainEnvelope(text) {
  let envelope;
  try {
    envelope = JSON.parse(text.split(DOMAIN_KNOWLEDGE_MARKER)[0]
      .replace(/^\[effort:(simple|standard|thinking)\]\s*/i, ""));
  } catch {
    throw new Error("[aidevops] Domain delegation requires a JSON child envelope");
  }
  if (!validDomainEnvelope(envelope)) {
    throw new Error("[aidevops] Invalid domain envelope: bounded evidence, effort and inference-only authority required");
  }
  return envelope;
}

async function routeDomainMessage(context, output, registry, agentName) {
  const envelope = domainEnvelope(context.messageText(output.parts));
  const child = await loadChildSessionWithParent(context, output.message.sessionID);
  if (!child) throw new Error("[aidevops] Domain delegation requires an observed parent session");
  const parent = await context.getParentRoute(context.client, child);
  if (!parent.model || !["none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(parent.variant)) {
    throw new Error("[aidevops] Parent model/effort ceiling unavailable; domain delegation refused");
  }
  const light = agentName === "domain-light";
  const delivered = loadDelegatedDomainKnowledge(registry, envelope.source, light);
  const effort = light ? "simple" : envelope.effort;
  // Keep the exact parent model: cross-model effort names are not compute ceilings.
  output.message.model = routingModelIdentity(parent.model);
  const variant = context.clampReasoningVariant(effort === "simple" ? "low" : "medium", parent.variant);
  context.policies.set(output.message.sessionID, {
    effort, reason: "bounded_domain", pinned: true, attempt: 1, createdAt: Date.now(),
    parentSessionID: child.parentID, routedModel: parent.model, domainVariant: variant,
  });
  const target = output.parts.find((part) => part.type === "text");
  target.text = `${JSON.stringify(envelope)}${DOMAIN_KNOWLEDGE_MARKER}\nSource: ${delivered.source}\nSHA256: ${delivered.sha256}\n${delivered.knowledge}`;
  // No second transcript or duplicated canonical payload on repeated transformation.
  output.parts = output.parts.filter((part) => part.type !== "text" || part === target);
}

async function applyConnectedRoutingModel(context, route, message, policy) {
  const providerState = await context.resolveProviderState();
  if (!providerState) {
    policy.reason = "provider_state_unavailable_inherit";
    return;
  }
  const routedModel = selectConnectedRoutingCandidate(
    context.modelRouting,
    route.effort,
    providerState,
  );
  if (!routedModel) {
    throw new Error(`[aidevops] No connected model is available for '${route.effort}' routing`);
  }
  message.model = routingModelIdentity(routedModel);
  policy.routedModel = routedModel;
  policy.candidateIndex = routingCandidateIndex(context.modelRouting, route.effort, routedModel);
}

function applySpecialistPolicy(context, agentName, text, policy) {
  if (agentName !== SPECIALIST_ADVISOR || !context.agentRoutingState?.specialistAdvisor) return;
  validateSpecialistRequest(text);
  policy.effort = "thinking";
  policy.reason = "specialist_advice";
}

async function routeChatMessage(context, output) {
  const message = output?.message || {};
  const sessionID = message.sessionID;
  if (!sessionID) return;

  const now = Date.now();
  context.prunePolicies(context.policies, now);
  const existingPolicy = context.policies.get(sessionID);
  if (existingPolicy?.reason?.startsWith("browser_") && existingPolicy.routedModel) {
    existingPolicy.createdAt = now;
    message.model = routingModelIdentity(existingPolicy.routedModel);
    return;
  }
  if (existingPolicy?.awaitingEscalationPrompt) {
    existingPolicy.awaitingEscalationPrompt = false;
    existingPolicy.createdAt = now;
    if (existingPolicy.routedModel) {
      message.model = routingModelIdentity(existingPolicy.routedModel);
    }
    return;
  }

  const text = context.messageText(output.parts);
  const agentName = String(message.agent ?? message.mode ?? "");
  const domainRegistry = context.agentRoutingState?.domainDelegation;
  if (domainRegistry?.profiles?.has(agentName)) {
    await routeDomainMessage(context, output, domainRegistry, agentName);
    return;
  }
  if (context.agentRoutingState?.inheritParentRoute?.has(agentName)
    && !context.agentRoutingState?.pinned?.has(agentName)) {
    await routeCreativeMessage(context, output);
    return;
  }
  await routeTierMessage(context, output, { agentName, text, now });
}

async function routeTierMessage(context, output, { agentName, text, now }) {
  const message = output.message;
  const sessionID = message.sessionID;
  const route = context.routedPolicy(context.agentRoutingState, agentName, text);
  const policy = {
    effort: route.effort,
    reason: route.pinned ? "explicit_model" : route.reason,
    attempt: 1,
    escalated: false,
    pinned: route.pinned,
    createdAt: now,
  };
  applySpecialistPolicy(context, agentName, text, policy);
  context.policies.set(sessionID, policy);

  if (!context.modelRouting || route.pinned) return;
  const candidates = routingCandidates(context.modelRouting, route.effort);
  if (candidates.length === 0) {
    throw new Error(`[aidevops] Model routing tier '${route.effort}' is disabled`);
  }

  const childSession = await loadChildSessionWithParent(context, sessionID);
  if (!childSession) return;
  policy.parentSessionID = childSession.parentID;
  if (agentName === BROWSER_AGENT && await routeBrowserDelegate(context, childSession, message, policy)) return;
  if (nextRoutingTier(context.modelRouting, route.effort)) {
    context.appendCapabilityEscalationContract(output);
  }

  await applyConnectedRoutingModel(context, route, message, policy);
}

export function createSubagentEffortHandlers(context) {
  return {
    chatMessage: (_input, output) => routeChatMessage(context, output),
    chatParams: (input, output) => routeChatParams(context, input, output),
  };
}
