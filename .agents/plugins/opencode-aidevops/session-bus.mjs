// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: OpenCode session bus runtime, one per plugin instance.
// - Presence: one record per root session this process owns. It is written
//   when the session's state changes, throttled for activity, and removed on
//   exit (session-bus-presence.mjs).
// - Delivery uses only channels that persist in the session: the next tool
//   result, the next user turn, or a promptAsync wake for an idle session
//   (session-bus-delivery.mjs). A toast announces each arrival. A 5s poll
//   drives toasts and wakes. Nothing runs while the inboxes are empty, apart
//   from one readdir per owned session.
// Store, limits and framing: session-bus-store.mjs; docs: reference/session-bus.md.

import * as store from "./session-bus-store.mjs";
import { sessionIDFrom } from "./session-turn-state.mjs";
import { ArrivalToasts, warn } from "./session-bus-client.mjs";
import { SessionTree } from "./session-bus-identity.mjs";
import { GitInfoCache, PresencePublisher } from "./session-bus-presence.mjs";
import {
  applyEvent,
  isSessionInfoEvent,
  isStatusEvent,
  isTrackedEvent,
  newSessionState,
  rememberTurn,
  setStatus,
} from "./session-bus-events.mjs";
import {
  appendToolMessages,
  appendTurnMessages,
  deliverToIdle,
  pollInboxes,
  sendIdleNotices,
} from "./session-bus-delivery.mjs";

export { processKind, parseRepoSlug } from "./session-bus-presence.mjs";
export { isWakeEligible } from "./session-bus-delivery.mjs";

const POLL_MS = 5000;
const SWEEP_DELAY_MS = 3000;
const MAX_TRACKED = 64;
const BUS_TOOL = "aidevops_sessions";

class SessionBus {
  constructor({ client, directory = "", root = store.busRoot(), kind = "tui", now = () => Date.now(), timers = globalThis, git } = {}) {
    Object.assign(this, { client, directory, root, kind, now, timers });
    this.messageable = store.MESSAGEABLE_KINDS.includes(kind);
    this.sessions = new Map();
    this.tree = new SessionTree({ client, onRootInfo: (info) => this.updateRootInfo(info) });
    this.toasts = new ArrivalToasts(client);
    const gitInfo = new GitInfoCache({ now, git, onChange: (changed) => this.republish(changed) });
    this.presence = new PresencePublisher({ root, kind, messageable: this.messageable, directory, now, timers, gitInfo });
    this.timer = null;
    this.ticking = false;
  }

  start() {
    const sweep = this.timers.setTimeout(() => this.sweep(), SWEEP_DELAY_MS);
    sweep?.unref?.();
    if (this.messageable) {
      this.timer = this.timers.setInterval(() => this.tick(), POLL_MS);
      this.timer?.unref?.();
    }
    return this;
  }

  sweep() {
    try {
      store.readPresence(this.root, { sweep: true });
      store.pruneBus(this.root, this.now());
    } catch (error) {
      warn("sweep", error);
    }
  }

  get disposed() {
    return this.presence.disposed;
  }

  dispose() {
    this.presence.disposed = true;
    if (this.timer) this.timers.clearInterval(this.timer);
    for (const sessionID of this.sessions.keys()) this.presence.remove(sessionID, { quiet: true });
  }

  // -------------------------------------------------------------------------
  // Session identity and state
  // -------------------------------------------------------------------------

  updateRootInfo(info) {
    const state = this.state(info.id);
    if (typeof info.title === "string") state.title = info.title;
    if (info.directory) state.directory = info.directory;
  }

  isRoot(sessionID, info = null) {
    return this.tree.isRoot(sessionID, info);
  }

  state(sessionID) {
    let state = this.sessions.get(sessionID);
    if (!state) {
      state = newSessionState(sessionID, this.directory, this.now());
      this.sessions.set(sessionID, state);
      while (this.sessions.size > MAX_TRACKED) this.forget(this.sessions.keys().next().value);
    }
    return state;
  }

  forget(sessionID) {
    const state = this.sessions.get(sessionID);
    if (state) this.presence.clearTimer(state);
    this.sessions.delete(sessionID);
    this.presence.remove(sessionID);
  }

  // -------------------------------------------------------------------------
  // Presence
  // -------------------------------------------------------------------------

  record(state) {
    return this.presence.record(state);
  }

  writePresence(state) {
    return this.presence.write(state);
  }

  schedulePresence(state, urgent) {
    return this.presence.schedule(state, urgent);
  }

  /** Git facts for a directory changed: rewrite every record that uses it. */
  republish(directory) {
    for (const state of this.sessions.values()) {
      if ((state.directory || this.directory) === directory) this.writePresence(state);
    }
  }

  // -------------------------------------------------------------------------
  // Hooks
  // -------------------------------------------------------------------------

  async handleEvent(input) {
    const type = input?.event?.type;
    if (!type) return;
    const sessionID = sessionIDFrom(input.event);
    if (!store.isSafeId(sessionID)) return;
    if (type === "session.deleted") this.onDeleted(sessionID);
    else if (isTrackedEvent(type)) await this.onTrackedEvent(sessionID, type, input.event.properties || {});
  }

  onDeleted(sessionID) {
    this.tree.markDeleted(sessionID);
    this.forget(sessionID);
  }

  async onTrackedEvent(sessionID, type, props) {
    const info = isSessionInfoEvent(type) && props.info?.id === sessionID ? props.info : null;
    if (!(await this.isRoot(sessionID, info))) return;
    const state = this.state(sessionID);
    this.schedulePresence(state, applyEvent(state, type, props, this.now()));
    if (state.status === "idle" && isStatusEvent(type)) await this.onIdle(sessionID);
  }

  async chatMessage(input, output) {
    const sessionID = input?.sessionID;
    if (!(await this.isRoot(sessionID))) return;
    const state = this.state(sessionID);
    rememberTurn(state, input, this.now());
    this.schedulePresence(state, setStatus(state, "busy"));
    if (this.messageable && Array.isArray(output?.parts)) {
      appendTurnMessages(output, this.claimPending(sessionID), sessionID);
    }
  }

  /**
   * A turn began without chat.message: an OpenCode 2 wake inserts a synthetic
   * message, which never passes the prompt hook. Carry the wake's hop count
   * into that turn, as chatMessage does for a V1 promptAsync wake (t18888).
   */
  turnStarted(sessionID) {
    const state = this.sessions.get(sessionID);
    if (state?.wakePending) rememberTurn(state, {}, this.now());
  }

  /** Busy delivery for root sessions; returns the number of messages appended. */
  toolAfter(input, output) {
    if (!this.messageable || !this.tree.isKnownRoot(input?.sessionID)) return 0;
    if (input.tool === BUS_TOOL || typeof output?.output !== "string") return 0;
    return appendToolMessages(output, this.claimPending(input.sessionID));
  }

  // -------------------------------------------------------------------------
  // Delivery
  // -------------------------------------------------------------------------

  claimPending(sessionID, limit = store.LIMITS.deliverPerBatch, entries = null) {
    const candidates = entries || store.pendingMessages(this.root, sessionID).slice(0, limit);
    return candidates.filter((entry) => store.claimMessage(this.root, sessionID, entry));
  }

  async onIdle(sessionID) {
    const state = this.state(sessionID);
    sendIdleNotices(this, sessionID, state);
    if (this.messageable) await this.deliverToIdle(sessionID, state);
  }

  deliverToIdle(sessionID, state, pending) {
    return deliverToIdle(this, sessionID, state, pending);
  }

  async tick() {
    if (this.ticking || this.disposed) return;
    this.ticking = true;
    try {
      await pollInboxes(this);
    } catch (error) {
      warn("poll", error);
    } finally {
      this.ticking = false;
    }
  }

  // -------------------------------------------------------------------------
  // Tool support
  // -------------------------------------------------------------------------

  fromFor(sessionID) {
    const record = this.record(this.state(sessionID));
    return {
      session_id: sessionID,
      handle: record.handle,
      repo: record.repo,
      branch: record.branch,
      origin: "opencode",
    };
  }

  /** Sender identity from ToolContext, never from model-supplied arguments. */
  async sender(context) {
    const sessionID = await this.tree.rootOf(context?.sessionID);
    if (!sessionID) throw new Error("aidevops_sessions could not resolve this session's root session");
    const state = this.state(sessionID);
    if (!state.lastWriteMs) this.writePresence(state);
    return { sessionID, from: this.fromFor(sessionID), hops: state.turnHops, record: this.record(state) };
  }
}

export function createSessionBus(options = {}) {
  const bus = new SessionBus(options);
  if (options.start !== false) {
    bus.start();
    process.once("exit", () => bus.dispose());
  }
  return bus;
}
