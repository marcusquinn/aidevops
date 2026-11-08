// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { routingCandidates, routingModelIdentity, routingVariant } from "./model-routing.mjs";
import { isModelUnavailable } from "./model-unavailability.mjs";
import { SubagentLifecycleTracker } from "./subagent-lifecycle-tracker.mjs";
import { nextPrimaryRoutingCandidate, primaryRoutingExhausted, resolvePrimaryRoute } from "./specialist-advisor.mjs";

const CONTINUE = "Continue the original user request in this session. The previous model was unavailable before generation.";

function idleEvent(event) {
  return event.type === "session.idle" || (event.type === "session.status" && event.properties.status.type === "idle");
}

function replayBlocked(state) {
  return state.recovering || state.generated || state.stopped;
}

class PrimaryEntitlementFailover {
  constructor(context, options) {
    this.context = context;
    this.isHeadless = options.isHeadless || (() => false);
    this.sessions = new Map();
    this.lifecycle = new SubagentLifecycleTracker();
  }

  unavailable(model) {
    return isModelUnavailable(model, this.context.resolveAvailability().authSignature);
  }

  async chatMessage(input, output) {
    if (this.isHeadless()) return;
    const sessionID = output.message.sessionID || input.sessionID;
    const previous = this.sessions.get(sessionID);
    if (previous?.recovering) {
      this.acceptContinuation(previous, output);
    } else {
      this.sessions.delete(sessionID);
      const route = await resolvePrimaryRoute(this.context, input, output.message);
      if (route) this.sessions.set(sessionID, {
        ...route, generated: false, recovering: false, stopped: false,
        pending: false, completed: false, assistants: new Set(),
      });
      while (this.sessions.size > 64) this.sessions.delete(this.sessions.keys().next().value);
    }
  }

  acceptContinuation(state, output) {
    if (!output.parts.some((part) => part.synthetic && part.text === CONTINUE)) {
      throw new Error("[aidevops] Model entitlement recovery is already in progress for this session; no duplicate request was sent.");
    }
    output.message.model = routingModelIdentity(state.model);
  }

  chatParams(input) {
    const state = this.sessions.get(input.sessionID);
    if (!state) return;
    // SDK Model uses `id`; UserMessage.model uses `modelID`.
    const model = this.context.modelIdentity({ providerID: input.model.providerID, modelID: input.model.id || input.model.modelID });
    if (routingCandidates(this.context.modelRouting, state.tier).includes(model)) state.model = model;
    else this.sessions.delete(input.sessionID); // Compaction/internal request.
  }

  async reportExhausted(state) {
    state.stopped = true;
    const message = primaryRoutingExhausted(state).message;
    this.context.qualityLog?.("WARN", message);
    // Native clients consume the toast; ACP retries fail in chat.message before
    // egress. Client-side retry policy itself is not controlled by this plugin.
    await this.context.client.tui?.showToast?.({ body: { title: "Model routing exhausted", message, variant: "error" } });
  }

  async prompt(sessionID, state) {
    const response = await this.context.client.session.prompt({
      path: { id: sessionID },
      body: {
        agent: state.agent, model: routingModelIdentity(state.model),
        variant: routingVariant(this.context.modelRouting, state.tier, state.model) || undefined,
        parts: [{ type: "text", text: CONTINUE, synthetic: true }],
      },
    });
    const error = response?.data?.info?.error || response?.error;
    this.lifecycle.handleEvent({ type: "session.error", properties: { sessionID, error } });
    return this.lifecycle.takeEntitlementRejection(sessionID) && !state.generated;
  }

  async recover(sessionID, state) {
    state.recovering = true;
    try {
      let retry = true;
      while (retry && this.unavailable(state.model)) {
        const model = await nextPrimaryRoutingCandidate(this.context, state);
        if (model === null) {
          this.context.qualityLog?.("WARN", "[aidevops] Primary entitlement recovery skipped: provider lookup failed");
          retry = false;
        } else if (model) {
          state.model = model;
          retry = await this.prompt(sessionID, state);
        } else {
          await this.reportExhausted(state);
          retry = false;
        }
      }
    } catch {
      this.context.qualityLog?.("WARN", "[aidevops] Primary entitlement recovery stopped after a non-entitlement error");
    } finally {
      state.recovering = false;
    }
  }

  recordGeneration(state, event) {
    const { info, part } = event.properties;
    if (event.type === "message.updated" && info.role === "assistant") {
      state.assistants.add(info.id);
      state.completed = Boolean(info.time?.completed);
    }
    if (event.type === "message.part.updated" && state.assistants.has(part.messageID)) {
      const generatedText = ["text", "reasoning"].includes(part.type) && part.text;
      if (part.type === "tool" || generatedText) state.generated = true;
    }
  }

  async observe(state, event) {
    if (replayBlocked(state)) return;
    if (event.type === "session.error") {
      this.lifecycle.handleEvent(event);
      const rejected = this.lifecycle.takeEntitlementRejection(state.sessionID);
      state.pending = Boolean(rejected && this.unavailable(state.model));
    }
    // Error precedes processor cleanup. Only the idle after assistant completion
    // proves run-state teardown; an earlier idle would join the failing run.
    if (state.pending && state.completed && idleEvent(event)) {
      state.pending = false;
      await this.recover(state.sessionID, state);
    }
  }

  async handleEvent(input) {
    const event = input.event || input;
    const props = event.properties || {};
    const sessionID = props.sessionID || props.info?.sessionID || props.part?.sessionID;
    if (event.type === "session.deleted") this.sessions.delete(sessionID || props.info?.id);
    const state = this.sessions.get(sessionID);
    if (state && !this.isHeadless()) {
      this.recordGeneration(state, event);
      await this.observe(state, event);
    }
  }
}

export function createPrimaryEntitlementFailover(context, options = {}) {
  const handler = new PrimaryEntitlementFailover(context, options);
  return {
    chatMessage: handler.chatMessage.bind(handler),
    chatParams: handler.chatParams.bind(handler),
    handleEvent: handler.handleEvent.bind(handler),
  };
}
