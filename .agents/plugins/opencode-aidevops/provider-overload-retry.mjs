// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

/**
 * Resume interactive sessions stopped by a provider overload (t19362 / GH#40283).
 *
 * OpenCode retries an overloaded provider inside the turn, but only five times
 * over roughly a minute (2 s doubling backoff, 30 s cap). A longer overload
 * (Anthropic HTTP 529 `overloaded_error`, OpenAI "servers are currently
 * overloaded") ends the turn with a terminal `session.error`, and the session
 * stays idle until someone types "continue".
 *
 * After that terminal error this module waits (default 60 s) and sends one
 * synthetic continuation with the session's last agent, model and variant.
 *
 * Rules:
 * - Root interactive sessions only. Headless runs exit on the error and own
 *   their retry policy. A child session's error has already reached the
 *   parent's Task call.
 * - Overload errors only (provider-overload-policy.mjs). Auth, permission,
 *   request, context-length and abort failures are never retried.
 * - Any other start of work cancels the pending retry: a new user message
 *   (typed, or another plugin's prompt) or a completed reply. The live
 *   session status is checked just before prompting; a busy session, or one
 *   whose status or agent/model cannot be confirmed, is never prompted.
 * - At most AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS retries (default 5) per
 *   episode. A completed reply or a new user message starts a new episode.
 * - Content-free: logs and toasts carry only counts and a session hash.
 *
 * Settings: AIDEVOPS_OVERLOAD_RETRY=0 disables it;
 * AIDEVOPS_OVERLOAD_RETRY_DELAY_SECONDS (default 60);
 * AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS (default 5).
 */

import {
  isProviderOverloadError,
  overloadRetrySettings,
  requestIdentity,
  sessionHash,
} from "./provider-overload-policy.mjs";
import { lastRequest, liveStatus, sendContinuation, sessionParentID, showToast } from "./provider-overload-client.mjs";

export { isProviderOverloadError, overloadRetryEnabled, overloadRetrySettings } from "./provider-overload-policy.mjs";

const MAX_SESSIONS = 64;
const MAX_TRACKED_MESSAGES = 32;
const ACTIVE_STATES = new Set(["busy", "retry"]);
const UNNOTIFIED_SKIPS = new Set(["disabled", "session_busy"]);
// One pending retry per session across plugin instances in this process.
const PENDING_REGISTRY = Symbol.for("aidevops.provider-overload-retry.pending");

function sessionIDFrom(event) {
  const properties = event?.properties || {};
  const candidates = [properties.sessionID, properties.info?.sessionID, properties.info?.id];
  return String(candidates.find(Boolean) || "");
}

function pendingRegistry() {
  globalThis[PENDING_REGISTRY] ||= new Map();
  return globalThis[PENDING_REGISTRY];
}

function initialState() {
  return {
    attempts: 0,
    gaveUp: false,
    lastErrorAt: 0,
    ownPromptPending: false,
    parentID: null,
    pendingTicket: null,
    request: null,
    seenUserMessages: new Set(),
    takeovers: 0,
  };
}

// Why a due retry must not prompt, or "" when it may. Unknown status or
// identity fails closed: never prompt a possibly busy session, or with
// another agent or model than the one that stopped.
function skipReason(settings, headless, status, request) {
  if (!settings.enabled || headless) return "disabled";
  if (ACTIVE_STATES.has(status)) return "session_busy";
  if (!status) return "status_unknown";
  return request ? "" : "identity_unknown";
}

function rememberMessage(state, messageID) {
  if (state.seenUserMessages.has(messageID)) return false;
  state.seenUserMessages.add(messageID);
  if (state.seenUserMessages.size > MAX_TRACKED_MESSAGES) {
    state.seenUserMessages.delete(state.seenUserMessages.values().next().value);
  }
  return true;
}

function resetEpisode(state) {
  state.attempts = 0;
  state.gaveUp = false;
}

class ProviderOverloadRetry {
  constructor(options) {
    Object.assign(this, options);
    this.sessions = new Map();
    this.pending = pendingRegistry();
    this.nextTicket = 1;
    this.handlers = new Map([
      ["session.created", this.updateSession],
      ["session.updated", this.updateSession],
      ["session.deleted", this.forget],
      ["message.updated", this.updateMessage],
      ["session.error", this.recordError],
    ]);
  }

  stateFor(sessionID) {
    let state = this.sessions.get(sessionID);
    if (!state) {
      state = initialState();
      this.sessions.set(sessionID, state);
      if (this.sessions.size > MAX_SESSIONS) this.forget(this.sessions.keys().next().value);
    }
    return state;
  }

  forget(sessionID) {
    this.cancel(sessionID);
    this.sessions.delete(sessionID);
  }

  async handle(input) {
    if (this.isHeadless()) return;
    const event = input?.event || input || {};
    const handler = this.handlers.get(event.type);
    const sessionID = sessionIDFrom(event);
    if (handler && sessionID) await handler.call(this, sessionID, event.properties?.info || {}, event);
  }

  updateSession(sessionID, info) {
    const state = this.stateFor(sessionID);
    if (Object.hasOwn(info, "parentID") || state.parentID === null) state.parentID = String(info.parentID || "");
  }

  // Every start of work creates a user message (typed input, another
  // plugin's prompt, a command, compaction), so that cancels a pending retry;
  // status events alone are not used. fire() re-checks the live status.
  updateMessage(sessionID, info) {
    if (info.role === "user") this.recordUserMessage(sessionID, info);
    else if (info.role === "assistant") this.recordAssistantMessage(sessionID, info);
  }

  recordUserMessage(sessionID, info) {
    const state = this.stateFor(sessionID);
    state.request = requestIdentity(info) || state.request;
    if (!info.id || !rememberMessage(state, String(info.id))) return;
    // Re-published older messages (summary/diff updates) are not new input.
    if (Number(info.time?.created) < state.lastErrorAt) return;
    if (state.ownPromptPending) {
      state.ownPromptPending = false;
      return;
    }
    state.takeovers += 1;
    this.cancel(sessionID, "user_message");
    resetEpisode(state);
  }

  recordAssistantMessage(sessionID, info) {
    const state = this.sessions.get(sessionID);
    const completed = Number(info.time?.completed);
    if (!state || info.error || !completed || completed < state.lastErrorAt) return;
    this.cancel(sessionID, "reply_completed");
    resetEpisode(state);
  }

  async recordError(sessionID, _info, event) {
    if (!isProviderOverloadError(event.properties?.error)) return;
    const settings = overloadRetrySettings(this.env);
    if (!settings.enabled) return;
    const state = this.stateFor(sessionID);
    state.lastErrorAt = this.now();
    state.ownPromptPending = false;
    const takeovers = state.takeovers;
    const root = await this.isRoot(sessionID, state);
    // A takeover or eviction during the root lookup wins.
    const current = this.sessions.get(sessionID) === state && state.takeovers === takeovers;
    if (!root || !current || state.pendingTicket !== null) return;
    if (state.attempts < settings.maxAttempts) await this.schedule(sessionID, state, settings);
    else await this.giveUp(sessionID, state, settings);
  }

  async isRoot(sessionID, state) {
    state.parentID ??= await sessionParentID(this.client, sessionID);
    return state.parentID === "";
  }

  async schedule(sessionID, state, settings) {
    const attempt = state.attempts + 1;
    const ticket = this.nextTicket++;
    this.pending.get(sessionID)?.cancel();
    state.pendingTicket = ticket;
    const handle = this.setTimer(() => {
      this.fire(sessionID, ticket, attempt).catch((error) => {
        this.log("WARN", `[overload-retry] retry failed: ${error?.name || "Error"}`);
      });
    }, settings.delayMs);
    handle?.unref?.();
    const cancel = () => {
      this.clearTimer(handle);
      if (this.pending.get(sessionID)?.cancel === cancel) this.pending.delete(sessionID);
      if (state.pendingTicket === ticket) state.pendingTicket = null;
    };
    this.pending.set(sessionID, { cancel });
    const seconds = Math.round(settings.delayMs / 1000);
    this.log("INFO", `[overload-retry] scheduled attempt=${attempt}/${settings.maxAttempts} delay_s=${seconds} session=${sessionHash(sessionID)}`);
    await showToast(this.client, {
      title: "Provider overloaded",
      message: `The turn stopped after the provider's built-in retries. Retrying automatically in ${seconds}s (attempt ${attempt}/${settings.maxAttempts}). Send a message to take over instead.`,
      variant: "warning",
    }, this.log);
  }

  cancel(sessionID, reason = "") {
    const state = this.sessions.get(sessionID);
    const entry = this.pending.get(sessionID);
    if (!entry && state?.pendingTicket == null) return;
    entry?.cancel();
    if (state) state.pendingTicket = null;
    if (reason) this.log("INFO", `[overload-retry] cancelled reason=${reason} session=${sessionHash(sessionID)}`);
  }

  // Claim the pending ticket after the async lookups; null when another
  // start of work already cancelled it.
  claim(sessionID, state, ticket, status, request) {
    if (state.pendingTicket !== ticket) return null;
    this.cancel(sessionID);
    const settings = overloadRetrySettings(this.env);
    return { settings, reason: skipReason(settings, this.isHeadless(), status, request) };
  }

  async fire(sessionID, ticket, attempt) {
    const state = this.sessions.get(sessionID);
    if (state?.pendingTicket !== ticket) return false;
    const request = state.request || await lastRequest(this.client, sessionID);
    const status = await liveStatus(this.client, this.directory, sessionID);
    const claimed = this.claim(sessionID, state, ticket, status, request);
    if (!claimed) return false;
    const { settings, reason } = claimed;
    if (reason) {
      await this.skip(sessionID, reason);
      return false;
    }
    state.attempts = attempt;
    state.request ||= request;
    state.ownPromptPending = true;
    const sent = await sendContinuation(this, sessionID, state.request, attempt, settings.maxAttempts);
    if (!sent) state.ownPromptPending = false;
    return sent;
  }

  async skip(sessionID, reason) {
    this.log("INFO", `[overload-retry] skipped reason=${reason} session=${sessionHash(sessionID)}`);
    // Busy: the session is already working. Disabled: the user's choice.
    if (!UNNOTIFIED_SKIPS.has(reason)) {
      await showToast(this.client, {
        title: "Automatic retry skipped",
        message: "The provider-overload retry could not confirm the session state, so nothing was sent. Send a message to continue.",
        variant: "warning",
      }, this.log);
    }
  }

  async giveUp(sessionID, state, settings) {
    if (state.gaveUp) return;
    state.gaveUp = true;
    this.log("WARN", `[overload-retry] gave up attempts=${state.attempts}/${settings.maxAttempts} session=${sessionHash(sessionID)}`);
    await showToast(this.client, {
      title: "Provider still overloaded",
      message: `Stopped after ${settings.maxAttempts} automatic retries. Send a message (for example "continue") when the provider recovers, or switch model.`,
      variant: "error",
    }, this.log);
  }
}

/**
 * Create the interactive provider-overload retry observer (t19362).
 * @returns {{ handleEvent: Function, pendingCount: Function }}
 */
export function createProviderOverloadRetry({
  client,
  directory = "",
  isHeadless = () => false,
  env = process.env,
  now = () => Date.now(),
  setTimer = (callback, milliseconds) => setTimeout(callback, milliseconds),
  clearTimer = (handle) => clearTimeout(handle),
  log = () => {},
} = {}) {
  const retry = new ProviderOverloadRetry({ client, directory, isHeadless, env, now, setTimer, clearTimer, log });
  return {
    handleEvent: retry.handle.bind(retry),
    pendingCount: () => [...retry.sessions.values()].filter((state) => state.pendingTicket !== null).length,
  };
}
