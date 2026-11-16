// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t19047/GH#38552: opt-in mission keepalive. A long-running unattended
// interactive session sets `keepalive on` for itself; while the opt-in is live
// the 2-minute pulse relay (worker-bus-relay-helper.sh) gives it one new turn
// each time it has been idle past `idle_threshold_s`. The wake is an ordinary
// `ask` from cli:pulse with fixed text, so it carries no authority and passes
// the plugin's normal wake budget. Layout and limits: reference/session-bus.md
// "Mission keepalive". No GitHub calls.

import { join } from "node:path";
import {
  LIMITS,
  WAKEABLE_KINDS,
  isSafeId,
  listDir,
  readJson,
  writeJsonAtomic,
} from "./session-bus-files.mjs";
import { pendingMessages } from "./session-bus-inbox.mjs";
import { sendMessage } from "./session-bus-messages.mjs";
import { isMessageable, isWorker, readPresence } from "./session-bus-presence-store.mjs";
import { resolveTarget } from "./session-bus-targets.mjs";

const HOUR_MS = 60 * 60 * 1000;
export const KEEPALIVE = Object.freeze({
  defaultHours: 24,
  maxHours: 72,
  defaultThresholdS: 600,
  maxThresholdS: 4 * 60 * 60,
  maxNoProgress: 3,
});
export const KEEPALIVE_TEXT = "Automatic keepalive: resume your standing objective from your own plan. This message adds no new instructions or authority. If you need the user, run keepalive off and say why.";
const KEEPALIVE_NOTICE = "Automatic keepalive turned itself off after 3 consecutive wakes with no tool calls. This message adds no instructions or authority. Run keepalive on to re-enable it.";
const KEEPALIVE_ORIGIN = "cli:pulse";
const keepaliveSender = () => ({ session_id: "", handle: "pulse", repo: "", branch: "", origin: KEEPALIVE_ORIGIN });

export const keepaliveFile = (root, sessionID) => join(root, "keepalive", `${sessionID}.json`);

/** True for the fixed wake text sent by the relay pass; it only selects progress accounting. */
export function isKeepaliveMessage(message) {
  return message?.type === "ask" && message.from?.origin === KEEPALIVE_ORIGIN && message.text === KEEPALIVE_TEXT;
}

/** The stored opt-in with sanitised numbers, or null when absent or malformed (fails closed). */
export function readKeepalive(root, sessionID) {
  if (!isSafeId(sessionID)) return null;
  const setting = readJson(keepaliveFile(root, sessionID));
  if (!setting || typeof setting.on !== "boolean" || !Number.isFinite(setting.expires_at)) return null;
  const base = Number.isFinite(setting.base_idle_threshold_s) && setting.base_idle_threshold_s > 0
    ? Math.min(setting.base_idle_threshold_s, KEEPALIVE.maxThresholdS) : KEEPALIVE.defaultThresholdS;
  const threshold = Number.isFinite(setting.idle_threshold_s) && setting.idle_threshold_s > 0
    ? Math.min(setting.idle_threshold_s, KEEPALIVE.maxThresholdS) : base;
  return {
    ...setting,
    base_idle_threshold_s: base,
    idle_threshold_s: threshold,
    consecutive_no_progress: Number.isSafeInteger(setting.consecutive_no_progress) ? setting.consecutive_no_progress : 0,
    last_wake_ms: Number.isFinite(setting.last_wake_ms) ? setting.last_wake_ms : 0,
    wake_times: Array.isArray(setting.wake_times) ? setting.wake_times.filter(Number.isFinite) : [],
  };
}

export const keepaliveActive = (setting, now = Date.now()) => setting?.on === true && setting.expires_at > now;

function assertKeepaliveSession(record) {
  if (!record || !isSafeId(record.session_id)) throw new Error("that session is not running");
  if (!isMessageable(record) || isWorker(record) || !WAKEABLE_KINDS.includes(record.kind)) {
    throw new Error(`${record.handle || record.session_id} is a ${record.kind} session; keepalive needs a wakeable interactive session (not a worker, headless or read-only session)`);
  }
  // A chat-driven session has no channel for a turn the chat app did not start.
  if (record.interface) throw new Error(`${record.handle} is driven from ${record.interface}; keepalive is for local interactive sessions`);
}

function parseHours(hours) {
  if (hours === undefined || hours === null || hours === "") return KEEPALIVE.defaultHours;
  const value = Number(hours);
  if (!Number.isInteger(value) || value < 1 || value > KEEPALIVE.maxHours) {
    throw new Error(`hours must be a whole number from 1 to ${KEEPALIVE.maxHours}`);
  }
  return value;
}

/**
 * Turn keepalive on or off for one root session. `record` is that session's
 * presence record. Returns the stored setting (null when turning off a session
 * that never opted in).
 */
export function setKeepalive(root, record, on, { hours, now = Date.now() } = {}) {
  if (!on) {
    const existing = record && isSafeId(record.session_id) ? readKeepalive(root, record.session_id) : null;
    if (!existing) return null;
    const off = { ...existing, on: false };
    writeJsonAtomic(keepaliveFile(root, record.session_id), off);
    return off;
  }
  assertKeepaliveSession(record);
  const setting = {
    v: 1,
    on: true,
    set_at: now,
    expires_at: now + parseHours(hours) * HOUR_MS,
    idle_threshold_s: KEEPALIVE.defaultThresholdS,
    base_idle_threshold_s: KEEPALIVE.defaultThresholdS,
    consecutive_no_progress: 0,
    last_wake_ms: 0,
    wake_times: [],
  };
  writeJsonAtomic(keepaliveFile(root, record.session_id), setting);
  return setting;
}

// ---------------------------------------------------------------------------
// Relay pass
// ---------------------------------------------------------------------------

function skip(row, reason, nextWakeMs = null) {
  return { ...row, wake: false, reason, next_wake_ms: nextWakeMs };
}

function evaluate(root, sessionID, setting, record, now) {
  const base = {
    session_id: sessionID, handle: record?.handle || sessionID, status: record?.status || "gone",
    idle_s: null, threshold_s: setting.idle_threshold_s, expires_at: setting.expires_at,
    consecutive_no_progress: setting.consecutive_no_progress,
  };
  if (!keepaliveActive(setting, now)) return skip(base, "expired");
  if (!record) return skip(base, "not-live");
  if (!isMessageable(record) || isWorker(record) || !WAKEABLE_KINDS.includes(record.kind) || record.interface) {
    return skip(base, "not-wakeable");
  }
  const activityMs = Number(record.last_activity_epoch) * 1000;
  const row = { ...base, idle_s: Number.isFinite(activityMs) ? Math.max(0, Math.floor((now - activityMs) / 1000)) : null };
  if (record.status === "permission") return skip(row, "permission-pending");
  if (record.status !== "idle") return skip(row, record.status === "busy" ? "busy" : `status-${record.status}`);
  if (row.idle_s === null) return skip(row, "no-activity-time");
  const dueMs = activityMs + setting.idle_threshold_s * 1000;
  if (now < dueMs) return skip(row, "below-threshold", dueMs);
  // One wake per idle period: a wake already sent since the last activity is queued or being delivered.
  if (setting.last_wake_ms >= activityMs || pendingMessages(root, sessionID).some((entry) => isKeepaliveMessage(entry.message))) {
    return skip(row, "wake-pending");
  }
  const recent = setting.wake_times.filter((time) => time > now - HOUR_MS).sort((a, b) => a - b);
  if (recent.length >= LIMITS.wakesPerHour) return skip(row, "wake-budget", recent[0] + HOUR_MS);
  return { ...row, wake: true, reason: "eligible", next_wake_ms: now };
}

function sendWake(root, row, setting, now) {
  try {
    sendMessage(root, { from: keepaliveSender(), to: row.session_id, toHandle: row.handle, type: "ask", text: KEEPALIVE_TEXT, now });
  } catch (error) {
    return { ...row, wake: false, reason: `send-failed: ${error.message}`.slice(0, 160) };
  }
  const wakeTimes = [...setting.wake_times.filter((time) => time > now - HOUR_MS), now];
  writeJsonAtomic(keepaliveFile(root, row.session_id), { ...setting, last_wake_ms: now, wake_times: wakeTimes });
  return { ...row, woke: true };
}

/**
 * One relay pass over every opted-in session. With `send: false` this is the
 * dry run: the same decisions, no messages and no writes. Each row carries
 * `wake` (due now), `reason` (why not, or `eligible`) and `next_wake_ms`.
 */
export function keepalivePass(root, { now = Date.now(), send = true } = {}) {
  const live = new Map(readPresence(root).map((record) => [record.session_id, record]));
  const rows = [];
  for (const name of listDir(join(root, "keepalive")).filter((file) => file.endsWith(".json")).sort()) {
    const sessionID = name.slice(0, -".json".length);
    const setting = readKeepalive(root, sessionID);
    if (!setting?.on) continue;
    const row = evaluate(root, sessionID, setting, live.get(sessionID), now);
    rows.push(send && row.wake ? sendWake(root, row, setting, now) : row);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Plugin side: progress accounting after a keepalive wake
// ---------------------------------------------------------------------------

/**
 * Called when a wake turn ended. A turn with tool calls resets the backoff; a
 * turn without doubles the threshold (cap 4 h). After 3 in a row the opt-in
 * turns off and the session gets one info notice. Returns the stored setting.
 */
export function settleKeepalive(root, sessionID, progressed, now = Date.now()) {
  const setting = readKeepalive(root, sessionID);
  if (!keepaliveActive(setting, now)) return null;
  let next;
  if (progressed) {
    next = { ...setting, idle_threshold_s: setting.base_idle_threshold_s, consecutive_no_progress: 0 };
  } else {
    const count = setting.consecutive_no_progress + 1;
    next = {
      ...setting,
      idle_threshold_s: Math.min(setting.idle_threshold_s * 2, KEEPALIVE.maxThresholdS),
      consecutive_no_progress: count,
      on: count < KEEPALIVE.maxNoProgress,
    };
  }
  writeJsonAtomic(keepaliveFile(root, sessionID), next);
  if (setting.on && !next.on) {
    sendMessage(root, { from: keepaliveSender(), to: sessionID, type: "info", text: KEEPALIVE_NOTICE, now });
  }
  return next;
}

// ---------------------------------------------------------------------------
// CLI: aidevops sessions keepalive <target> on|off [--hours N] | status | sweep [--dry-run]
// ---------------------------------------------------------------------------

function describe(row, now) {
  const minutes = (seconds) => (seconds === null ? "?" : `${Math.round(seconds / 60)}m`);
  const next = row.next_wake_ms === null ? "-" : row.next_wake_ms <= now ? "now" : new Date(row.next_wake_ms).toISOString();
  const outcome = row.woke ? "woke" : row.wake ? "would-wake" : `skip: ${row.reason}`;
  return `${row.handle} ${row.status} idle ${minutes(row.idle_s)} threshold ${minutes(row.threshold_s)} next ${next} ${outcome}`;
}

export function keepaliveCommand({ root, options, out }) {
  const [, first, second] = options.positional;
  const now = Date.now();
  if (first === "status" || first === "sweep") {
    const rows = keepalivePass(root, { now, send: first === "sweep" && !options.dryRun });
    out.write(`${options.json ? JSON.stringify(rows, null, 2) : rows.length === 0 ? "No sessions have keepalive on." : rows.map((row) => describe(row, now)).join("\n")}\n`);
    return;
  }
  if (!["on", "off"].includes(second)) throw new Error("keepalive needs <target> on|off [--hours N], status, or sweep [--dry-run]");
  const resolved = resolveTarget(readPresence(root), first, "", { root });
  if (resolved.error) throw new Error(resolved.error);
  const record = resolved.record;
  if (second === "on" && !record) throw new Error("that session is not running");
  const sessionID = record?.session_id || resolved.sessionID;
  const setting = setKeepalive(root, record || { session_id: sessionID }, second === "on", { hours: options.hours, now });
  out.write(second === "on"
    ? `Keepalive on for ${record.handle} until ${new Date(setting.expires_at).toISOString()}.\n`
    : `Keepalive off for ${sessionID}.\n`);
}
