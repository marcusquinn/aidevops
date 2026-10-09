// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#34138: explain a silent turn with content-free runtime metadata.
// Diagnostics only: this module never aborts, prompts, retries, grants
// permissions, or changes routing. It reads event metadata (status, error
// class, tool name, permission ID) and never stores prompt, completion,
// reasoning, or tool payload text.

import { createHash } from "node:crypto";

import { normalizeProviderError } from "./provider-error-diagnostics.mjs";

const DEFAULT_STALE_MS = 10 * 60_000;
const DEFAULT_CHECK_MS = 60_000;
const MAX_SESSIONS = 64;
const MAX_TRACKED_IDS = 32;
const ACTIVE_TOOL_STATES = new Set(["pending", "running"]);
const ACTIVE_SESSION_STATES = new Set(["busy", "retry"]);
const KNOWN_ERROR_NAMES = new Set([
  "APIError",
  "MessageAbortedError",
  "MessageOutputLengthError",
  "ProviderAuthError",
  "UnknownError",
]);
// The provider-error handler already explains these with its own toast.
const EXPLAINED_ELSEWHERE = new Set(["gateway_denied", "access_denied"]);
const SCHEDULER_REGISTRY = Symbol.for("aidevops.session-turn-diagnostics.registry");

function eventFrom(input) {
  return input?.event || input || {};
}

function sessionIDFrom(event) {
  const properties = event.properties || {};
  return String(
    properties.sessionID
      || properties.part?.sessionID
      || properties.info?.sessionID
      || properties.info?.id
      || "",
  );
}

function capMap(map, limit) {
  while (map.size > limit) map.delete(map.keys().next().value);
}

function capSet(set, limit) {
  while (set.size > limit) set.delete(set.values().next().value);
}

function sessionHash(sessionID) {
  return `sha256:${createHash("sha256").update(sessionID).digest("hex").slice(0, 12)}`;
}

function safeToolName(tool) {
  const name = String(tool || "").replace(/[^\w.-]/g, "").slice(0, 64);
  return name || "unknown";
}

/** Reduce an OpenCode error object to a content-free outcome class. */
export function classifyError(error) {
  if (!error || typeof error !== "object") return null;
  const name = String(error.name || "");
  if (name === "MessageAbortedError") return { kind: "cancelled" };
  if (name === "MessageOutputLengthError") return { kind: "output_limit" };
  if (name === "ProviderAuthError") return { kind: "provider_error", classification: "authentication_failed", status_code: null };
  if (name === "APIError") {
    const diagnostic = normalizeProviderError(error);
    return { kind: "provider_error", classification: diagnostic.classification, status_code: diagnostic.status_code };
  }
  return { kind: "runtime_error", name: KNOWN_ERROR_NAMES.has(name) ? name : "unknown" };
}

function newTurn(state, now) {
  state.turnID += 1;
  state.turnActive = true;
  state.turnStartedAt = now;
  state.lastActivityAt = now;
  state.textSeen = false;
  state.stepSeen = false;
  state.toolSeen = false;
  state.error = null;
  state.activeTools.clear();
  state.textPartIDs.clear();
  state.notified.clear();
}

function initialState() {
  return {
    activeTools: new Map(),
    error: null,
    lastActivityAt: 0,
    notified: new Set(),
    parentID: null,
    pendingPermissionIDs: new Set(),
    status: "",
    stepSeen: false,
    textPartIDs: new Set(),
    textSeen: false,
    toolSeen: false,
    turnActive: false,
    turnID: 0,
    turnStartedAt: 0,
    userMessageIDs: new Set(),
  };
}

function endedOutcome(state) {
  if (state.textSeen) return "answered";
  // A user shell command (`!cmd`) runs a tool without a model step; its
  // output is the visible reply.
  if (state.toolSeen && !state.stepSeen) return "tool_only";
  return "no_response";
}

/**
 * Classify a turn from tracked metadata. `ended` distinguishes an idle
 * boundary from a still-busy turn that has gone quiet.
 */
export function classifyTurn(state, { ended }) {
  const errorKind = state.error?.kind;
  if (errorKind === "cancelled") return "cancelled";
  if (errorKind) return errorKind;
  if (ended) return endedOutcome(state);
  if (state.pendingPermissionIDs.size > 0) return "permission_wait";
  if (state.activeTools.size > 0) return "tool_wait";
  if (state.status === "retry") return "provider_retry";
  return "no_activity";
}

function minutes(milliseconds) {
  return Math.max(1, Math.round(milliseconds / 60_000));
}

function providerDetail(error) {
  if (error?.status_code) return `HTTP ${error.status_code}`;
  return String(error?.classification || "provider_error").replace(/_/g, " ");
}

const NOT_RETRIED = "Nothing was retried automatically.";

const MESSAGES = {
  no_response: () => `The assistant turn ended without a visible reply. Metadata shows no provider error, cancellation, or pending permission, so the cause is unknown. ${NOT_RETRIED} Ask for status or resend.`,
  provider_error: (state) => `The provider request failed (${providerDetail(state.error)}), so the reply is missing or incomplete. ${NOT_RETRIED} Resend or switch model when ready.`,
  output_limit: () => "The reply stopped at the model output limit. Ask the assistant to continue from where it stopped.",
  runtime_error: (state) => `The turn ended with a runtime error (${state.error?.name || "unknown"}), so the reply is missing or incomplete. ${NOT_RETRIED}`,
  permission_wait: (_state, idleMs) => `Waiting ${minutes(idleMs)}m for a permission reply. The session is paused, not stuck; answer the permission prompt to continue.`,
  tool_wait: (state, idleMs) => `A ${[...state.activeTools.values()].at(-1)} tool call has run for ${minutes(idleMs)}m with no other activity. The session is waiting on the tool, not the model.`,
  provider_retry: (_state, idleMs) => `The provider has been retrying for ${minutes(idleMs)}m. The session is waiting on the provider; ${NOT_RETRIED.toLowerCase()}`,
  no_activity: (_state, idleMs) => `No model or tool activity for ${minutes(idleMs)}m. Metadata cannot tell a stalled provider stream from an event-delivery gap. ${NOT_RETRIED}`,
};

const TITLES = {
  no_response: "No reply",
  provider_error: "Reply interrupted",
  runtime_error: "Reply interrupted",
  output_limit: "Reply truncated",
};

function toastFor(outcome, state, idleMs) {
  const message = MESSAGES[outcome]?.(state, idleMs);
  if (!message) return null;
  return {
    title: TITLES[outcome] || "Still waiting",
    message,
    variant: "warning",
    duration: 15000,
  };
}

const SILENT_OUTCOMES = new Set(["answered", "cancelled", "tool_only"]);

function shouldNotify(outcome, state) {
  if (SILENT_OUTCOMES.has(outcome)) return false;
  if (outcome === "provider_error" && EXPLAINED_ELSEWHERE.has(state.error?.classification)) return false;
  return !state.notified.has(outcome);
}

class SessionTurnDiagnostics {
  constructor({ client, isHeadless, now, staleMs, log }) {
    this.client = client;
    this.isHeadless = isHeadless;
    this.now = now;
    this.staleMs = staleMs;
    this.log = log;
    this.sessions = new Map();
    this.handlers = new Map([
      ["session.created", this.updateSession.bind(this)],
      ["session.updated", this.updateSession.bind(this)],
      ["session.status", this.updateStatus.bind(this)],
      ["session.idle", this.markIdle.bind(this)],
      ["session.error", this.recordSessionError.bind(this)],
      ["message.updated", this.updateMessage.bind(this)],
      ["message.part.updated", this.updatePart.bind(this)],
      ["message.part.delta", this.updateDelta.bind(this)],
      ["permission.asked", this.askPermission.bind(this)],
      ["permission.updated", this.askPermission.bind(this)],
      ["permission.replied", this.replyPermission.bind(this)],
    ]);
  }

  stateFor(sessionID) {
    if (!this.sessions.has(sessionID)) {
      this.sessions.set(sessionID, initialState());
      capMap(this.sessions, MAX_SESSIONS);
    }
    return this.sessions.get(sessionID);
  }

  async handle(input) {
    if (this.isHeadless()) return;
    const event = eventFrom(input);
    const sessionID = sessionIDFrom(event);
    if (!sessionID) return;
    if (event.type === "session.deleted") {
      this.sessions.delete(sessionID);
      return;
    }
    const handler = this.handlers.get(event.type);
    if (handler) await handler(event, this.stateFor(sessionID), sessionID);
  }

  updateSession(event, state) {
    const info = event.properties?.info || {};
    if (Object.hasOwn(info, "parentID") || state.parentID === null) {
      state.parentID = String(info.parentID || "");
    }
  }

  updateStatus(event, state, sessionID) {
    const status = String(event.properties?.status?.type || "").toLowerCase();
    if (!status) return undefined;
    if (ACTIVE_SESSION_STATES.has(status) && !state.turnActive) newTurn(state, this.now());
    state.status = status;
    state.lastActivityAt = this.now();
    return status === "idle" ? this.finishTurn(state, sessionID) : undefined;
  }

  markIdle(_event, state, sessionID) {
    state.status = "idle";
    return this.finishTurn(state, sessionID);
  }

  recordSessionError(event, state) {
    state.lastActivityAt = this.now();
    const classified = classifyError(event.properties?.error);
    if (classified) state.error = classified;
  }

  updateMessage(event, state) {
    const info = event.properties?.info || {};
    const messageID = String(info.id || "");
    state.lastActivityAt = this.now();
    if (info.role === "user") {
      if (messageID && !state.userMessageIDs.has(messageID)) {
        state.userMessageIDs.add(messageID);
        capSet(state.userMessageIDs, MAX_TRACKED_IDS);
        // A queued follow-up during an active turn must not erase evidence
        // that the running turn already answered.
        if (!state.turnActive) newTurn(state, this.now());
      }
      return;
    }
    const classified = info.role === "assistant" ? classifyError(info.error) : null;
    if (classified) state.error = classified;
  }

  updatePart(event, state) {
    const part = event.properties?.part || {};
    state.lastActivityAt = this.now();
    if (part.type === "step-start" || part.type === "step-finish") {
      state.stepSeen = true;
      return;
    }
    if (part.type === "tool") {
      state.toolSeen = true;
      this.updateToolPart(part, state);
      return;
    }
    if (part.type !== "text" || part.synthetic === true || part.ignored === true) return;
    if (state.userMessageIDs.has(String(part.messageID || ""))) return;
    if (part.id) {
      state.textPartIDs.add(String(part.id));
      capSet(state.textPartIDs, MAX_TRACKED_IDS);
    }
    if (typeof part.text === "string" && part.text.trim()) state.textSeen = true;
  }

  // Streaming runtimes may send visible text only as deltas to a text part
  // announced earlier with empty text. Only known assistant text parts count.
  updateDelta(event, state) {
    const properties = event.properties || {};
    state.lastActivityAt = this.now();
    if (!state.textPartIDs.has(String(properties.partID || ""))) return;
    if (typeof properties.delta === "string" && properties.delta.trim()) state.textSeen = true;
  }

  updateToolPart(part, state) {
    const callID = String(part.callID || part.id || "");
    if (!callID) return;
    const status = String(part.state?.status || "").toLowerCase();
    if (ACTIVE_TOOL_STATES.has(status)) {
      state.activeTools.set(callID, safeToolName(part.tool));
      capMap(state.activeTools, MAX_TRACKED_IDS);
    } else {
      state.activeTools.delete(callID);
    }
  }

  askPermission(event, state) {
    const requestID = String(event.properties?.id || "");
    if (requestID) state.pendingPermissionIDs.add(requestID);
    capSet(state.pendingPermissionIDs, MAX_TRACKED_IDS);
    state.lastActivityAt = this.now();
  }

  replyPermission(event, state) {
    const requestID = String(event.properties?.requestID || event.properties?.permissionID || "");
    if (requestID) state.pendingPermissionIDs.delete(requestID);
    state.lastActivityAt = this.now();
  }

  async isRoot(sessionID, state) {
    if (state.parentID !== null) return state.parentID === "";
    try {
      const response = await this.client?.session?.get?.({ path: { id: sessionID } });
      const info = response?.data ?? response;
      if (!info?.id) return false;
      state.parentID = String(info.parentID || "");
      return state.parentID === "";
    } catch {
      return false;
    }
  }

  async finishTurn(state, sessionID) {
    if (!state.turnActive) return;
    state.turnActive = false;
    state.activeTools.clear();
    const outcome = classifyTurn(state, { ended: true });
    await this.report(outcome, state, sessionID, this.now() - state.turnStartedAt);
  }

  async report(outcome, state, sessionID, durationMs) {
    if (outcome === "answered") return;
    this.log("INFO", `[turn-diagnostics] outcome=${outcome} session=${sessionHash(sessionID)} duration_ms=${durationMs}`);
    if (!shouldNotify(outcome, state)) return;
    const body = toastFor(outcome, state, durationMs);
    if (!body || typeof this.client?.tui?.showToast !== "function") return;
    // Reserve synchronously, before any await: overlapping checks cannot
    // duplicate a toast, and a failed toast is not retried (no storms).
    state.notified.add(outcome);
    const turnID = state.turnID;
    if (!await this.isRoot(sessionID, state)) return;
    // A new turn during the root lookup makes this report stale.
    if (state.turnID !== turnID) return;
    try {
      await this.client.tui.showToast({ body });
    } catch (error) {
      this.log("WARN", `[turn-diagnostics] toast failed: ${error?.name || "Error"}`);
    }
  }

  async checkNow() {
    if (this.isHeadless()) return [];
    const reported = [];
    const now = this.now();
    for (const [sessionID, state] of this.sessions) {
      const idleMs = now - state.lastActivityAt;
      if (!state.turnActive || !ACTIVE_SESSION_STATES.has(state.status) || idleMs < this.staleMs) continue;
      const outcome = classifyTurn(state, { ended: false });
      if (state.notified.has(outcome)) continue;
      await this.report(outcome, state, sessionID, idleMs);
      reported.push({ sessionID, outcome });
    }
    return reported;
  }
}

function startScheduler({ client, directory, checkNow, checkMs, log }) {
  const registry = globalThis[SCHEDULER_REGISTRY] || new Map();
  globalThis[SCHEDULER_REGISTRY] = registry;
  const key = client && typeof client === "object" ? client : String(directory || "default");
  registry.get(key)?.();
  const timer = setInterval(() => {
    checkNow().catch((error) => log("WARN", `[turn-diagnostics] check failed: ${error?.name || "Error"}`));
  }, checkMs);
  timer.unref?.();
  const stop = () => {
    clearInterval(timer);
    if (registry.get(key) === stop) registry.delete(key);
  };
  registry.set(key, stop);
  return stop;
}

/** Create the interactive turn-outcome observer (GH#34138). */
export function createSessionTurnDiagnostics({
  client,
  directory = "",
  isHeadless = () => false,
  now = () => Date.now(),
  staleMs = DEFAULT_STALE_MS,
  checkMs = DEFAULT_CHECK_MS,
  schedule = true,
  log = () => {},
} = {}) {
  const diagnostics = new SessionTurnDiagnostics({ client, isHeadless, now, staleMs, log });
  const checkNow = diagnostics.checkNow.bind(diagnostics);
  const stop = schedule ? startScheduler({ client, directory, checkNow, checkMs, log }) : () => {};
  return {
    checkNow,
    handleEvent: diagnostics.handle.bind(diagnostics),
    stop,
  };
}

export { DEFAULT_STALE_MS };
