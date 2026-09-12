// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Observed parent-session lookup and explicit creative-route inheritance.
import { routingModelIdentity } from "./model-routing.mjs";

export function resetCreativeRouting(state) {
  if (state) state.inheritParentRoute = new Set();
}

export function recordCreativeRouting(state, mcp) {
  if (mcp.inheritParentRoute) state.inheritParentRoute.add(mcp.agentName);
}

export async function loadChildSessionWithParent(context, sessionID) {
  try {
    const childSession = await context.getSession(context.client, sessionID);
    return childSession?.parentID ? childSession : null;
  } catch {
    return null;
  }
}

export async function routeCreativeMessage(context, output) {
  const child = await loadChildSessionWithParent(context, output.message.sessionID);
  if (!child) throw new Error("[aidevops] Creative executor requires an observed parent session");
  const parent = await context.getParentRoute(context.client, child);
  if (!parent.model || !["none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(parent.variant)) {
    throw new Error("[aidevops] Creative parent model/effort unavailable; execution refused");
  }
  output.message.model = routingModelIdentity(parent.model);
  context.policies.set(output.message.sessionID, {
    effort: "thinking", reason: "creative_parent", pinned: true, attempt: 1,
    createdAt: Date.now(), parentSessionID: child.parentID,
    routedModel: parent.model, domainVariant: parent.variant,
  });
}
