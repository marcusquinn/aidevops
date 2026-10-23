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

export function defaultActivityDir(env = process.env, home = homedir()) {
  return env.OPENCODE_DB_ACTIVITY_DIR
    || join(home, ".aidevops", ".agent-workspace", "state", "opencode-activity");
}

/**
 * Create a heartbeat writer for one plugin instance. Several plugin instances
 * may share a PID, so each writes `<pid>-<instance>.json`; the archive gate
 * requires every file for a holder PID to report idle.
 */
export function createDbActivityHeartbeat(options = {}) {
  const dir = options.dir || defaultActivityDir(options.env);
  const pid = options.pid ?? process.pid;
  const instance = options.instance || randomUUID().slice(0, 8);
  const now = options.now || (() => Date.now());
  const throttleMs = options.throttleMs ?? DEFAULT_THROTTLE_MS;
  const file = join(dir, `${pid}-${instance}.json`);
  const busy = new Set();
  const sessions = new Set();
  let lastActivityAt = now();
  let lastWriteAt = 0;
  let timer = null;
  let disabled = false;

  function rememberSession(sessionID) {
    if (!SAFE_SESSION_ID.test(sessionID)) return;
    sessions.delete(sessionID);
    sessions.add(sessionID);
    while (sessions.size > MAX_TRACKED_SESSIONS) sessions.delete(sessions.values().next().value);
  }

  function snapshot() {
    return {
      pid,
      instance,
      busy_sessions: busy.size,
      last_activity_epoch: Math.floor(lastActivityAt / 1000),
      updated_epoch: Math.floor(now() / 1000),
      sessions: [...sessions],
    };
  }

  function write() {
    if (disabled) return false;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    try {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const temporary = `${file}.${process.pid}.tmp`;
      writeFileSync(temporary, `${JSON.stringify(snapshot())}\n`, { mode: 0o600 });
      renameSync(temporary, file);
      lastWriteAt = now();
      return true;
    } catch {
      // Unwritable state means no heartbeat; the archive gate then defers.
      disabled = true;
      return false;
    }
  }

  function writeThrottled() {
    const wait = throttleMs - (now() - lastWriteAt);
    if (wait <= 0) return write();
    if (!timer) {
      timer = setTimeout(write, wait);
      timer.unref?.();
    }
    return false;
  }

  function updateStatus(sessionID, status) {
    const wasBusy = busy.has(sessionID);
    if (ACTIVE_SESSION_STATES.has(status)) busy.add(sessionID);
    else if (status === "idle") busy.delete(sessionID);
    return wasBusy !== busy.has(sessionID);
  }

  function handleEvent(input) {
    const event = input?.event;
    if (!event?.type) return;
    const sessionID = sessionIDFrom(event);
    if (sessionID) rememberSession(sessionID);
    let transition = false;
    if (event.type === "session.status") {
      const status = String(event.properties?.status?.type || "").toLowerCase();
      transition = updateStatus(sessionID, status);
      lastActivityAt = now();
    } else if (event.type === "session.idle") {
      transition = busy.delete(sessionID);
      lastActivityAt = now();
    } else if (event.type === "session.deleted") {
      busy.delete(sessionID);
      sessions.delete(sessionID);
      transition = true;
    } else if (ACTIVITY_EVENTS.has(event.type)) {
      lastActivityAt = now();
    } else {
      return;
    }
    if (transition) write();
    else writeThrottled();
  }

  function remove() {
    if (timer) clearTimeout(timer);
    timer = null;
    disabled = true;
    try {
      rmSync(file, { force: true });
    } catch {
      // Best effort: a stale file for a dead PID is ignored by the gate.
    }
  }

  return { file, handleEvent, write, remove, snapshot };
}

/** Install the process-wide heartbeat once and remove it on normal exit. */
export function installDbActivityHeartbeat(options = {}) {
  const heartbeat = createDbActivityHeartbeat(options);
  heartbeat.write();
  process.once("exit", () => heartbeat.remove());
  return heartbeat;
}
