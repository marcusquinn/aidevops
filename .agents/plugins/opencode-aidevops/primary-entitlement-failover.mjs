// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { routingCandidates, routingModelIdentity, routingTierForModel, routingVariant, selectConnectedRoutingCandidate } from "./model-routing.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";
import { SubagentLifecycleTracker } from "./subagent-lifecycle-tracker.mjs";

const CONTINUE = "Continue the original user request in this session. The previous model was unavailable before generation.";

// OpenCode 1 (including ACP) reports terminal provider errors on the event bus.
// A root has no Task after-hook, so resume it here; subsequent user/client turns
// are routed in chat.message before they can request the rejected model again.
export function createPrimaryEntitlementFailover(context, { isHeadless = () => false } = {}) {
  const sessions = new Map();
  const lifecycle = new SubagentLifecycleTracker();
  const availability = () => context.resolveAvailability?.() || {};

  function exhausted(state) {
    return new Error(`[aidevops] No available ${state.tier} model after rejection of ${state.requested}. Re-authenticate or change the model routing configuration.`);
  }

  async function nextModel(state) {
    const models = routingCandidates(context.modelRouting, state.tier);
    const start = models.indexOf(state.model);
    if (start < 0) return "";
    const remaining = models.slice(start + 1);
    return selectConnectedRoutingCandidate(
      { tiers: { [state.tier]: { models: [...new Set(remaining)] } } },
      state.tier, await context.resolveProviderState(), undefined, availability(),
    );
  }

  async function root(sessionID) {
    if (!sessionID || isHeadless()) return null;
    try {
      const session = await context.getSession(context.client, sessionID);
      return session?.id === sessionID && !session.parentID ? session : null;
    } catch {
      return null; // Unknown ancestry must never compete with child recovery.
    }
  }

  async function chatMessage(input, output) {
    const message = output?.message;
    const sessionID = message?.sessionID || input?.sessionID;
    if (!await root(sessionID)) return;
    const model = context.modelIdentity(message?.model || input?.model);
    const tier = routingTierForModel(context.modelRouting, model, message?.variant);
    if (!tier) {
      sessions.delete(sessionID); // A new explicit out-of-table model clears stale state.
      if (isModelUnavailable(model, availability().authSignature)) {
        throw new Error(`[aidevops] Rejected model ${model} has no routing tier. Re-authenticate or change the model routing configuration.`);
      }
      return;
    }
    const previous = sessions.get(sessionID);
    if (previous?.recovering) {
      if (!output.parts?.some((part) => part.synthetic && part.text === CONTINUE)) {
        throw new Error("[aidevops] Model entitlement recovery is already in progress for this session; no duplicate request was sent.");
      }
      message.model = routingModelIdentity(previous.model);
      return;
    }
    const state = {
      model, tier, requested: model, agent: message?.agent,
      generated: false, recovering: false, stopped: false, assistants: new Set(),
      pending: false, completed: false,
    };
    if (isModelUnavailable(model, availability().authSignature)) {
      state.model = await nextModel(state);
      if (!state.model) throw exhausted(state);
      message.model = routingModelIdentity(state.model);
      message.variant = routingVariant(context.modelRouting, tier, state.model) || undefined;
    }
    sessions.delete(sessionID);
    sessions.set(sessionID, state);
    while (sessions.size > 64) sessions.delete(sessions.keys().next().value);
  }

  function chatParams(input) {
    const state = sessions.get(input?.sessionID);
    if (!state) return;
    // chat.params carries the actual resolved model, not an agent/default guess.
    const model = context.modelIdentity({ providerID: input.model?.providerID, modelID: input.model?.id || input.model?.modelID });
    if (!routingCandidates(context.modelRouting, state.tier).includes(model)) {
      sessions.delete(input.sessionID); // Compaction/internal requests do not inherit the user's tier.
      return;
    }
    state.model = model;
  }

  async function recover(sessionID, state) {
    state.recovering = true;
    try {
      while (isModelUnavailable(state.model, availability().authSignature)) {
        const model = await nextModel(state);
        if (!model) {
          state.stopped = true;
          const message = exhausted(state).message;
          context.qualityLog?.("WARN", message);
          // Native clients consume this event; ACP retries receive the same
          // actionable failure from chat.message before any provider request.
          await context.client.tui?.showToast?.({ body: { title: "Model routing exhausted", message, variant: "error" } });
          return;
        }
        state.model = model;
        const response = await context.client.session.prompt({
          path: { id: sessionID },
          body: {
            agent: state.agent,
            model: routingModelIdentity(model),
            variant: routingVariant(context.modelRouting, state.tier, model) || undefined,
            parts: [{ type: "text", text: CONTINUE, synthetic: true }],
          },
        });
        const error = response?.data?.info?.error || response?.error;
        if (!error) return;
        lifecycle.handleEvent({ type: "session.error", properties: { sessionID, error } });
        if (!lifecycle.takeEntitlementRejection(sessionID) || state.generated) return;
      }
    } catch {
      // Do not throw out of the event bus or recursively prompt on other failures.
      context.qualityLog?.("WARN", "[aidevops] Primary entitlement recovery stopped after a non-entitlement error");
    } finally {
      state.recovering = false;
    }
  }

  async function handleEvent(input) {
    const event = input?.event || input;
    const props = event?.properties || {};
    const sessionID = props.sessionID || props.info?.sessionID || props.part?.sessionID;
    if (event?.type === "session.deleted") {
      sessions.delete(sessionID || props.info?.id);
      return;
    }
    const state = sessions.get(sessionID);
    if (!state || isHeadless()) return;
    if (event.type === "message.updated" && props.info?.role === "assistant") {
      state.assistants.add(props.info.id);
      if (props.info.time?.completed) state.completed = true;
    }
    if (event.type === "message.part.updated" && state.assistants.has(props.part?.messageID)) {
      const part = props.part;
      if (part?.type === "tool" || (["text", "reasoning"].includes(part?.type) && part.text)) state.generated = true;
    }
    // session.error is published before the original run is released. Starting
    // a prompt there can join that failing run instead of starting a new one.
    // Wait for its completed assistant and following idle (run-state teardown).
    if ((event.type === "session.idle" || (event.type === "session.status" && props.status?.type === "idle"))
      && state.pending && state.completed && !state.recovering && !state.generated && !state.stopped) {
      state.pending = false;
      await recover(sessionID, state);
      return;
    }
    if (event.type !== "session.error" || state.recovering || state.generated || state.stopped) return;
    lifecycle.handleEvent(event);
    if (!lifecycle.takeEntitlementRejection(sessionID)) return;
    // The provider fetch boundary records the exact model/auth pair. Neither
    // generic 403s nor errors attributed only by session name authorize replay.
    if (!isModelUnavailable(state.model, availability().authSignature)) return;
    state.pending = true;
  }

  return { chatMessage, chatParams, handleEvent };
}
