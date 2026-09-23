// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import {
  routingCandidates,
  routingModelIdentity,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";

export const BROWSER_AGENT = "playwright";
const BROWSER_MODEL = "openai/gpt-6-luna";

function connectedModel(providerState, model, tier = "simple") {
  if (!providerState) return "";
  return selectConnectedRoutingCandidate({ tiers: { [tier]: { models: [model] } } }, tier, providerState);
}

export async function routeBrowserDelegate(context, childSession, message, policy) {
  // This is a task-specific route, not a change to the global simple tier.
  // Respect local routing overrides that remove Luna and explicit agent pins.
  if (!routingCandidates(context.modelRouting, "simple").includes(BROWSER_MODEL)) return false;
  const providerState = await context.resolveProviderState();
  const luna = connectedModel(providerState, BROWSER_MODEL);
  if (luna) {
    message.model = routingModelIdentity(luna);
    policy.routedModel = luna;
    policy.browserVariant = "xhigh";
    policy.reason = "browser_delegate";
  } else {
    const sol = routingCandidates(context.modelRouting, "thinking").includes("openai/gpt-6-sol")
      ? connectedModel(providerState, "openai/gpt-6-sol", "thinking") : "";
    const parent = sol ? null : await context.getParentRoute(context.client, childSession);
    const fallback = sol || parent?.model;
    if (!fallback || (!sol && !parent?.variant)) {
      throw new Error("[aidevops] Browser delegate and parent model/effort unavailable");
    }
    if (!sol && providerState && !connectedModel(providerState, fallback)) {
      throw new Error("[aidevops] Parent browser fallback is not connected");
    }
    message.model = routingModelIdentity(fallback);
    policy.routedModel = fallback;
    policy.browserVariant = sol ? "medium" : parent.variant;
    policy.reason = sol ? "browser_sol_fallback" : "browser_parent_fallback";
  }
  // Browser actions can change remote state: never auto-escalate/replay them.
  policy.pinned = true;
  return true;
}
