// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#34138: explain a silent turn with content-free runtime metadata.
// Diagnostics only: this module never aborts, prompts, retries, grants
// permissions, or changes routing. It reads event metadata (status, error
// class, tool name, permission ID) and never stores prompt, completion,
// reasoning, or tool payload text.

import { createHash } from "node:crypto";

import { classifyError, classifyTurn, shouldNotify, toastFor } from "./session-turn-outcomes.mjs";
import { ACTIVE_SESSION_STATES, applyEvent, initialState, sessionIDFrom } from "./session-turn-state.mjs";

const DEFAULT_STALE_MS = 10 * 60_000;
const DEFAULT_CHECK_MS = 60_000;
const MAX_SESSIONS = 64;
const SCHEDULER_REGISTRY = Symbol.for("aidevops.session-turn-diagnostics.registry");

function sessionHash(sessionID) {
  return `sha256:${createHash("sha256").update(sessionID).digest("hex").slice(0, 12)}`;
}

function isStale(state, idleMs, staleMs) {
  return state.turnActive && ACTIVE_SESSION_STATES.has(state.status) && idleMs >= staleMs;
}

class SessionTurnDiagnostics {
  constructor({ client, isHeadless, now, staleMs, log }) {
    this.client = client;
    this.isHeadless = isHeadless;
    this.now = now;
    this.staleMs = staleMs;
    this.log = log;
    this.sessions = new Map();
  }

  stateFor(sessionID) {
    if (!this.sessions.has(sessionID)) {
      this.sessions.set(sessionID, initialState());
      while (this.sessions.size > MAX_SESSIONS) this.sessions.delete(this.sessions.keys().next().value);
    }
    return this.sessions.get(sessionID);
  }

  async handle(input) {
    if (this.isHeadless()) return;
    const event = input?.event || input || {};
    const sessionID = sessionIDFrom(event);
    if (!sessionID) return;
    if (event.type === "session.deleted") {
      this.sessions.delete(sessionID);
      return;
    }
    const state = this.stateFor(sessionID);
    if (applyEvent(state, event, this.now())) await this.finishTurn(state, sessionID);
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
      if (!isStale(state, idleMs, this.staleMs)) continue;
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

export { classifyError, DEFAULT_STALE_MS };
