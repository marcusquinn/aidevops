// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#35517: per-process OpenCode activity heartbeat for the DB archive idle
// gate. `lsof` proves only that a process holds opencode.db open; this file
// proves whether that process has a busy session and when it last did work.
// opencode-db-archive.sh archives a held DB only when every holder's heartbeat
// reports zero busy sessions for a quiet period, and never archives sessions
// listed here. Metadata only: session IDs, counts and timestamps.

import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

import { ACTIVE_SESSION_STATES, sessionIDFrom } from "./session-turn-state.mjs";

const MAX_TRACKED_SESSIONS = 64;
const DEFAULT_THROTTLE_MS = 30_000;
const SAFE_SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;

// Events that represent model, tool or user work rather than metadata.
const ACTIVITY_EVENTS = new Set([
  "message.updated",
  "message.part.updated",
  "message.part.delta",
  "permission.asked",
  "permission.updated",
  "permission.replied",
  "session.error",
]);

// GH#35898: OpenCode 2.x work events (verified against @opencode/schema 2.2.0).
const V2_ACTIVITY_PREFIXES = [
  "session.step.",
  "session.tool.",
  "session.text.",
  "session.reasoning.",
  "session.shell.",
  "session.compaction.",
  "session.retry.",
];

// GH#35898: V1 events carry `properties`; OpenCode 2.x events carry `data`.
function eventPayload(event) {
  return event.properties || event.data || {};
}

function eventSessionID(event) {
  return sessionIDFrom(event) || String(event.data?.sessionID || "");
}

function isActivityEvent(type) {
  return ACTIVITY_EVENTS.has(type) || V2_ACTIVITY_PREFIXES.some((prefix) => type.startsWith(prefix));
}

const markIdle = (hb, sessionID) => hb.markIdle(sessionID);

// Session lifecycle events: handler returns true when busy state changed,
// which forces an immediate (unthrottled) write. The V2 execution events back
// up `session.status`, which OpenCode 2.x publishes as an ephemeral event.
const LIFECYCLE_HANDLERS = {
  "session.status": (hb, sessionID, event) => hb.updateStatus(sessionID, eventPayload(event).status?.type),
  "session.idle": markIdle,
  "session.deleted": (hb, sessionID) => hb.forget(sessionID),
  "session.execution.started": (hb, sessionID) => hb.updateStatus(sessionID, "busy"),
  "session.execution.succeeded": markIdle,
  "session.execution.failed": markIdle,
  "session.execution.interrupted": markIdle,
};

export function defaultActivityDir(env = process.env, home = homedir()) {
  return env.OPENCODE_DB_ACTIVITY_DIR
    || join(home, ".aidevops", ".agent-workspace", "state", "opencode-activity");
}

/**
 * Heartbeat writer for one plugin instance. Several plugin instances may share
 * a PID, so each writes `<pid>-<instance>.json`; the archive gate requires
 * every file for a holder PID to report idle.
 */
class DbActivityHeartbeat {
  constructor(options = {}) {
    this.dir = options.dir || defaultActivityDir(options.env);
    this.pid = options.pid ?? process.pid;
    this.instance = options.instance || randomUUID().slice(0, 8);
    this.now = options.now || (() => Date.now());
    this.throttleMs = options.throttleMs ?? DEFAULT_THROTTLE_MS;
    this.file = join(this.dir, `${this.pid}-${this.instance}.json`);
    this.busy = new Set();
    this.sessions = new Set();
    this.lastActivityAt = this.now();
    this.lastWriteAt = 0;
    this.timer = null;
    this.disabled = false;
  }

  rememberSession(sessionID) {
    if (!SAFE_SESSION_ID.test(sessionID)) return;
    this.sessions.delete(sessionID);
    this.sessions.add(sessionID);
    while (this.sessions.size > MAX_TRACKED_SESSIONS) {
      this.sessions.delete(this.sessions.values().next().value);
    }
  }

  snapshot() {
    return {
      pid: this.pid,
      instance: this.instance,
      busy_sessions: this.busy.size,
      last_activity_epoch: Math.floor(this.lastActivityAt / 1000),
      updated_epoch: Math.floor(this.now() / 1000),
      sessions: [...this.sessions],
    };
  }

  clearTimer() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  write() {
    if (this.disabled) return false;
    this.clearTimer();
    try {
      mkdirSync(this.dir, { recursive: true, mode: 0o700 });
      const temporary = `${this.file}.${process.pid}.tmp`;
      writeFileSync(temporary, `${JSON.stringify(this.snapshot())}\n`, { mode: 0o600 });
      renameSync(temporary, this.file);
      this.lastWriteAt = this.now();
      return true;
    } catch {
      // Unwritable state means no heartbeat; the archive gate then defers.
      this.disabled = true;
      return false;
    }
  }

  writeThrottled() {
    const wait = this.throttleMs - (this.now() - this.lastWriteAt);
    if (wait <= 0) return this.write();
    if (!this.timer) {
      this.timer = setTimeout(() => this.write(), wait);
      this.timer.unref?.();
    }
    return false;
  }

  updateStatus(sessionID, rawStatus) {
    const status = String(rawStatus || "").toLowerCase();
    const wasBusy = this.busy.has(sessionID);
    if (ACTIVE_SESSION_STATES.has(status)) this.busy.add(sessionID);
    else if (status === "idle") this.busy.delete(sessionID);
    this.lastActivityAt = this.now();
    return wasBusy !== this.busy.has(sessionID);
  }

  markIdle(sessionID) {
    this.lastActivityAt = this.now();
    return this.busy.delete(sessionID);
  }

  forget(sessionID) {
    this.busy.delete(sessionID);
    this.sessions.delete(sessionID);
    return true;
  }

  handleEvent(input) {
    const event = input?.event;
    if (!event?.type) return;
    // Any session this process has seen (even via metadata) stays protected.
    const sessionID = eventSessionID(event);
    if (sessionID) this.rememberSession(sessionID);
    const lifecycle = LIFECYCLE_HANDLERS[event.type];
    if (!lifecycle && !isActivityEvent(event.type)) return;
    if (!lifecycle) {
      this.lastActivityAt = this.now();
      this.writeThrottled();
      return;
    }
    if (lifecycle(this, sessionID, event)) this.write();
    else this.writeThrottled();
  }

  remove() {
    this.clearTimer();
    this.disabled = true;
    try {
      rmSync(this.file, { force: true });
    } catch {
      // Best effort: a stale file for a dead PID is ignored by the gate.
    }
  }
}

export function createDbActivityHeartbeat(options = {}) {
  return new DbActivityHeartbeat(options);
}

/** Install the process-wide heartbeat once and remove it on normal exit. */
export function installDbActivityHeartbeat(options = {}) {
  const heartbeat = createDbActivityHeartbeat(options);
  heartbeat.write();
  process.once("exit", () => heartbeat.remove());
  return heartbeat;
}
