// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18892: chat channel -> session bindings, `bindings/<app>/<channel>.json`.
// A gateway binds a channel once and then sends to `channel:<app>:<channel>`.
// The last atomic write wins; a binding never retargets by itself. Retention:
// pruneBindings below, run by pruneBus in session-bus-store.mjs.

import { linkSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

import {
  BUS_VERSION,
  bindingsDir,
  deliveredDir,
  fileTime,
  inboxDir,
  isSafeId,
  listDir,
  messageFiles,
  parseChatOrigin,
  presenceDir,
  pruneTemp,
  readJson,
  writeJsonAtomic,
} from "./session-bus-files.mjs";

export const CHANNEL_TARGET_PREFIX = "channel:";

const clip = (value, width) => String(value || "").slice(0, width);

// The regex already excludes `/`; a leading dot or `..` could still name a
// hidden or parent-looking file, so both are refused too.
const pathSafe = (text) => !text.startsWith(".") && !text.includes("..");
const sameParts = (parsed, app, channel) => parsed?.app === app && parsed.channel === channel;

/**
 * Validate an app and channel pair with the chat-origin rules, plus path
 * safety: no `/`, no `..`, no leading `.`, no empty part. Returns
 * `{ app, channel }` or throws.
 */
export function validChannel(app, channel) {
  const parsed = parseChatOrigin(`chat:${app ?? ""}:${channel ?? ""}`);
  const text = String(channel ?? "");
  if (!sameParts(parsed, app, text) || !pathSafe(text)) {
    throw new Error("invalid channel: app must be 1-32 of [a-z0-9-] and channel 1-128 of [A-Za-z0-9._:@!#+=-], with no leading dot or `..`");
  }
  return parsed;
}

/** Parse `<app>:<channel>` (the --bind value and the body of a `channel:` target). */
export function parseChannelRef(ref) {
  const text = String(ref ?? "");
  const split = text.indexOf(":");
  if (split < 0) throw new Error("channel reference must look like <app>:<channel>");
  return validChannel(text.slice(0, split), text.slice(split + 1));
}

export const isChannelTarget = (to) => String(to ?? "").trim().startsWith(CHANNEL_TARGET_PREFIX);

export const channelLabel = ({ app, channel }) => `${CHANNEL_TARGET_PREFIX}${app}:${channel}`;

export const bindingFile = (root, app, channel) => join(bindingsDir(root), app, `${channel}.json`);

function validRecord(record, app, channel) {
  return record?.v === BUS_VERSION && record.app === app && record.channel === channel && isSafeId(record.session_id);
}

/** The binding for an app and channel, or null when absent or malformed. */
export function readBinding(root, app, channel) {
  const chat = validChannel(app, channel);
  const record = readJson(bindingFile(root, chat.app, chat.channel));
  return validRecord(record, chat.app, chat.channel) ? record : null;
}

/**
 * Bind a channel to a session. Rebinding the same session (with the same
 * actor and server) is a no-op and returns `changed: false`.
 */
export function writeBinding(root, { app, channel, sessionID, actor = "", server = "", now = Date.now() }) {
  const chat = validChannel(app, channel);
  if (!isSafeId(sessionID)) throw new Error("invalid session ID for binding");
  const cleanActor = isSafeId(actor) ? actor : "";
  const cleanServer = clip(server, 200);
  const previous = readBinding(root, chat.app, chat.channel);
  const sameSession = previous?.session_id === sessionID;
  if (sameSession && previous.actor === cleanActor && previous.server === cleanServer) {
    return { record: previous, previous, changed: false };
  }
  const stamp = new Date(now).toISOString();
  const record = {
    v: BUS_VERSION,
    app: chat.app,
    channel: chat.channel,
    session_id: sessionID,
    actor: cleanActor,
    server: cleanServer,
    created_at: sameSession && previous.created_at ? previous.created_at : stamp,
    updated_at: stamp,
  };
  writeJsonAtomic(bindingFile(root, chat.app, chat.channel), record);
  return { record, previous, changed: true };
}

/** Remove a binding; returns whether one existed. */
export function removeBinding(root, app, channel) {
  const chat = validChannel(app, channel);
  const existed = Boolean(readBinding(root, chat.app, chat.channel));
  rmSync(bindingFile(root, chat.app, chat.channel), { force: true });
  return existed;
}

/** Valid bindings, optionally for one app, sorted by app then channel. */
export function listBindings(root, { app = "" } = {}) {
  const apps = app ? [validChannel(app, "x").app] : listDir(bindingsDir(root)).sort();
  const records = [];
  for (const name of apps) {
    for (const file of listDir(join(bindingsDir(root), name)).filter((entry) => entry.endsWith(".json")).sort()) {
      const record = readJson(join(bindingsDir(root), name, file));
      if (validRecord(record, name, file.slice(0, -5))) records.push(record);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Retention
// ---------------------------------------------------------------------------

// The newest sign of life for a bound session: a presence file, or its
// latest pending or delivered message (both are kept for retention).
function sessionActivity(root, sessionID) {
  if (readJson(join(presenceDir(root), `${sessionID}.json`))) return Infinity;
  const times = [...messageFiles(inboxDir(root, sessionID)), ...messageFiles(deliveredDir(root, sessionID))].map(fileTime);
  return times.length > 0 ? Math.max(...times) : 0;
}

function isStale(root, binding, cutoff) {
  if (messageFiles(inboxDir(root, binding.session_id)).length > 0) return false;
  const updated = Date.parse(binding.updated_at);
  return Math.max(Number.isFinite(updated) ? updated : 0, sessionActivity(root, binding.session_id)) < cutoff;
}

const sameRecord = (left, right) => left?.session_id === right.session_id && left?.updated_at === right.updated_at;

function restore(aside, file) {
  try {
    linkSync(aside, file);
  } catch {
    // A newer binding already took the name; it wins.
  }
}

// Lock-free removal that cannot delete a concurrent rebind: move the file
// aside, then drop it only if it is still the record judged stale. A rebind
// that landed between the read and the move is linked back. The aside name
// ends in .tmp, so a crash here leaves a file the next prune clears.
function removeIfUnchanged(file, stale) {
  const aside = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.prune.tmp`;
  try {
    renameSync(file, aside);
  } catch {
    return false;
  }
  const unchanged = sameRecord(readJson(aside), stale);
  if (!unchanged) restore(aside, file);
  rmSync(aside, { force: true });
  return unchanged;
}

function pruneBindingFile(root, file, cutoff) {
  if (file.endsWith(".tmp")) {
    pruneTemp(file);
    return false;
  }
  const binding = file.endsWith(".json") ? readJson(file) : null;
  if (!isSafeId(binding?.session_id) || !isStale(root, binding, cutoff)) return false;
  return removeIfUnchanged(file, binding);
}

/**
 * Remove bindings whose session has had no presence, no pending message and
 * no delivered message since `cutoff`. Returns the number removed.
 */
export function pruneBindings(root, cutoff) {
  let removed = 0;
  for (const app of listDir(bindingsDir(root))) {
    for (const name of listDir(join(bindingsDir(root), app))) {
      if (pruneBindingFile(root, join(bindingsDir(root), app, name), cutoff)) removed += 1;
    }
  }
  return removed;
}
