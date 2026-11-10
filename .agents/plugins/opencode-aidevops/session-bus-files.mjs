// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: session-bus file layout, limits and atomic JSON I/O. Every
// other session-bus store module builds on these primitives. Each presence
// file has one writer, and every write is temp+rename. Layout and limits:
// reference/session-bus.md. Callers import the session-bus-store.mjs barrel.

import {
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomBytes } from "node:crypto";

export const BUS_VERSION = 1;
export const LIMITS = Object.freeze({
  textChars: 2000,
  sendsPerMinute: 10,
  inboxPending: 50,
  wakesPerHour: 6,
  maxWakeHops: 3,
  retentionMs: 7 * 24 * 60 * 60 * 1000,
  listRows: 20,
  deliverPerBatch: 5,
});
export const MESSAGE_TYPES = Object.freeze(["info", "ask", "reply", "idle-notice"]);
// t18905: headless workers receive messages at tool results and turns, but
// are never woken (an idle worker has finished its run) and get no tool.
export const MESSAGEABLE_KINDS = Object.freeze(["tui", "serve", "acp", "headless"]);
export const WAKEABLE_KINDS = Object.freeze(["tui", "serve", "acp"]);
export const FRAME_PREFIX = "[aidevops session-bus]";

const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const CHAT_ORIGIN = /^chat:([a-z0-9-]{1,32}):([A-Za-z0-9._:@!#+=-]{1,128})$/;
const MESSAGE_FILE = /^\d{13}-msg_[A-Za-z0-9]+\.json$/;
const TMP_MAX_AGE_MS = 60 * 60 * 1000;

export function busRoot(env = process.env, home = homedir()) {
  return env.AIDEVOPS_SESSION_BUS_DIR
    || join(home, ".aidevops", ".agent-workspace", "state", "session-bus");
}

export function isSafeId(value) {
  return typeof value === "string" && SAFE_ID.test(value);
}

export function parseChatOrigin(origin) {
  const match = CHAT_ORIGIN.exec(String(origin || ""));
  return match ? { app: match[1], channel: match[2] } : null;
}

export function ensureDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
}

export function writeJsonAtomic(file, value) {
  ensureDir(dirname(file));
  const temporary = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  renameSync(temporary, file);
}

export function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

export function listDir(dir) {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/** Message files in a directory, oldest first (names start with created_ms). */
export function messageFiles(dir) {
  return listDir(dir).filter((name) => MESSAGE_FILE.test(name)).sort();
}

/** created_ms encoded in a message file name. */
export const fileTime = (name) => Number(name.slice(0, 13));

export const presenceDir = (root) => join(root, "presence");
export const inboxDir = (root, sessionID) => join(root, "inbox", sessionID);
export const deliveredDir = (root, sessionID) => join(inboxDir(root, sessionID), "delivered");
export const sentDir = (root, senderKey) => join(root, "sent", senderKey);
export const subsDir = (root, sessionID) => join(root, "subs", sessionID);
export const outboxDir = (root, app) => join(root, "outbox", app);
// t18896: release watches are keyed by repository, unlike subs/ (keyed by the watched session).
export const releaseWatchDir = (root, repoKey) => join(root, "release-watch", repoKey);
export const releaseNoticeDir = (root, repoKey) => join(releaseWatchDir(root, repoKey), "notices");
export const bindingsDir = (root) => join(root, "bindings");

// ---------------------------------------------------------------------------
// Retention
// ---------------------------------------------------------------------------

/** Remove a temp file left by an interrupted atomic write, once it is an hour old. */
export function pruneTemp(file) {
  try {
    if (statSync(file).mtimeMs < Date.now() - TMP_MAX_AGE_MS) rmSync(file, { force: true });
  } catch {
    // A concurrent rename already consumed the temp file.
  }
}

function pruneFiles(dir, cutoff, removed) {
  for (const name of listDir(dir)) {
    const file = join(dir, name);
    if (name.endsWith(".tmp")) pruneTemp(file);
    else if (MESSAGE_FILE.test(name) && fileTime(name) < cutoff) {
      rmSync(file, { force: true });
      removed.count += 1;
    }
  }
}

/** t18895: overlap notice markers (overlaps/<digest>.json) past retention. */
function pruneOverlapMarkers(root, cutoff, removed) {
  const dir = join(root, "overlaps");
  for (const name of listDir(dir)) {
    const file = join(dir, name);
    try {
      if (statSync(file).mtimeMs >= cutoff) continue;
      rmSync(file, { force: true });
      removed.count += 1;
    } catch {
      // Removed by a concurrent prune.
    }
  }
}

// t18896: a release watch ends when it expires or its session has no
// presence; a sent-once notice marker ends with message retention.
function pruneReleaseWatches(root, now, cutoff) {
  for (const key of listDir(join(root, "release-watch"))) {
    const dir = releaseWatchDir(root, key);
    for (const name of listDir(dir).filter((file) => file.endsWith(".json"))) {
      const record = readJson(join(dir, name));
      const expired = !Number.isFinite(record?.expires_ms) || record.expires_ms <= now;
      if (expired || !readJson(join(presenceDir(root), name))) rmSync(join(dir, name), { force: true });
    }
    for (const name of listDir(releaseNoticeDir(root, key))) {
      const file = join(releaseNoticeDir(root, key), name);
      if (name.endsWith(".tmp")) pruneTemp(file);
      else if (!(readJson(file)?.created_ms >= cutoff)) rmSync(file, { force: true });
    }
  }
}

/**
 * Remove messages past retention from every inbox, delivered/ and sent/
 * directory, old overlap markers, release watches and stale chat-wake
 * settings. Returns the number of messages and markers removed. Callers use
 * pruneBus from session-bus-store.mjs, which also prunes t18892 bindings.
 */
export function pruneBusFiles(root, now = Date.now()) {
  const cutoff = now - LIMITS.retentionMs;
  const removed = { count: 0 };
  for (const sessionID of listDir(join(root, "inbox"))) {
    pruneFiles(inboxDir(root, sessionID), cutoff, removed);
    pruneFiles(deliveredDir(root, sessionID), cutoff, removed);
  }
  for (const key of listDir(join(root, "sent"))) pruneFiles(sentDir(root, key), cutoff, removed);
  pruneOverlapMarkers(root, cutoff, removed);
  for (const name of listDir(join(root, "chat-wake"))) {
    const sessionID = name.replace(/\.json$/, "");
    if (!name.endsWith(".json") || !isSafeId(sessionID)) continue;
    const file = join(root, "chat-wake", name);
    const setting = readJson(file);
    const stale = !Number.isFinite(setting?.updated_ms) || setting.updated_ms < cutoff;
    if (!readJson(join(presenceDir(root), name)) && stale) rmSync(file, { force: true });
  }
  pruneReleaseWatches(root, now, cutoff);
  return removed.count;
}
