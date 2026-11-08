// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: session-bus inbox reads, delivery claims, notify-when-idle
// subscriptions and the gateway outbox. A delivery is claimed by renaming the
// message into delivered/, so exactly one process wins it.

import { renameSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

import {
  BUS_VERSION,
  LIMITS,
  deliveredDir,
  ensureDir,
  fileTime,
  inboxDir,
  isSafeId,
  listDir,
  messageFiles,
  outboxDir,
  readJson,
  sentDir,
  subsDir,
  writeJsonAtomic,
} from "./session-bus-files.mjs";

export function pendingMessages(root, sessionID) {
  const dir = inboxDir(root, sessionID);
  const entries = [];
  for (const name of messageFiles(dir)) {
    const message = readJson(join(dir, name));
    if (message?.v === BUS_VERSION && message.to === sessionID) entries.push({ name, message });
  }
  return entries;
}

function moveMessage(from, to, name) {
  try {
    ensureDir(to);
    renameSync(join(from, name), join(to, name));
    return true;
  } catch {
    return false;
  }
}

/** Claim a pending message by renaming it into delivered/. True only for the winner. */
export function claimMessage(root, sessionID, entry) {
  return moveMessage(inboxDir(root, sessionID), deliveredDir(root, sessionID), entry.name);
}

/** Return a claimed message to the inbox when its delivery channel failed. */
export function unclaimMessage(root, sessionID, entry) {
  return moveMessage(deliveredDir(root, sessionID), inboxDir(root, sessionID), entry.name);
}

function lastMessages(dir, limit) {
  return messageFiles(dir).slice(-limit).map((name) => readJson(join(dir, name))).filter(Boolean);
}

/** Recent traffic for one session, newest first: received (pending flagged) and sent. */
export function recentTraffic(root, sessionID, { limit = 6 } = {}) {
  if (!isSafeId(sessionID)) return [];
  const rows = [
    ...lastMessages(inboxDir(root, sessionID), limit).map((message) => ({ direction: "in", pending: true, message })),
    ...lastMessages(deliveredDir(root, sessionID), limit).map((message) => ({ direction: "in", pending: false, message })),
    ...lastMessages(sentDir(root, sessionID), limit).map((message) => ({ direction: "out", pending: false, message })),
  ];
  return rows.sort((left, right) => right.message.created_ms - left.message.created_ms).slice(0, limit);
}

export function findReceived(root, sessionID, messageID) {
  if (!isSafeId(sessionID) || !isSafeId(messageID)) return null;
  const suffix = `-${messageID}.json`;
  for (const dir of [deliveredDir(root, sessionID), inboxDir(root, sessionID)]) {
    const name = messageFiles(dir).find((file) => file.endsWith(suffix));
    if (name) return readJson(join(dir, name));
  }
  return null;
}

const messagesSince = (dir, since) => messageFiles(dir).filter((name) => fileTime(name) >= since)
  .map((name) => readJson(join(dir, name))).filter(Boolean);

const repliedIDs = (messages) => new Set(messages.filter((message) => message.type === "reply").map((message) => message.re));

const unansweredAsks = (messages, replied, limit) =>
  messages.filter((message) => message.type === "ask" && !replied.has(message.id)).slice(-limit);

/**
 * Open request/response obligations for the compaction note: asks this
 * session received without sending a reply, and asks it sent without
 * receiving one. Bounded by retention and `limit`.
 */
export function openAsks(root, sessionID, { limit = 5, now = Date.now() } = {}) {
  if (!isSafeId(sessionID)) return { toAnswer: [], awaiting: [] };
  const since = now - LIMITS.retentionMs;
  const received = [...messagesSince(deliveredDir(root, sessionID), since), ...messagesSince(inboxDir(root, sessionID), since)];
  const sent = messagesSince(sentDir(root, sessionID), since);
  return {
    toAnswer: unansweredAsks(received, repliedIDs(sent), limit),
    awaiting: unansweredAsks(sent, repliedIDs(received), limit),
  };
}

// ---------------------------------------------------------------------------
// notify-when-idle subscriptions (one-shot)
// ---------------------------------------------------------------------------

export function addIdleSubscription(root, targetID, subscriber) {
  if (!isSafeId(targetID) || !isSafeId(subscriber?.session_id)) throw new Error("invalid subscription");
  writeJsonAtomic(join(subsDir(root, targetID), `${subscriber.session_id}.json`), {
    v: BUS_VERSION,
    subscriber: subscriber.session_id,
    handle: String(subscriber.handle || "").slice(0, 80),
    created_ms: Date.now(),
  });
}

function takeFile(file) {
  const record = readJson(file);
  rmSync(file, { force: true });
  return record;
}

export function takeIdleSubscriptions(root, targetID) {
  if (!isSafeId(targetID)) return [];
  const dir = subsDir(root, targetID);
  return listDir(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => takeFile(join(dir, name)))
    .filter((record) => record?.v === BUS_VERSION && isSafeId(record.subscriber));
}

// ---------------------------------------------------------------------------
// Outbox for chat gateways (Phase 3 contract; no gateway ships yet)
// ---------------------------------------------------------------------------

const GATEWAY_APP = /^[a-z0-9-]{1,32}$/;

export function readOutbox(root, app) {
  if (!GATEWAY_APP.test(String(app || ""))) throw new Error("invalid gateway app name");
  const dir = outboxDir(root, app);
  return listDir(dir).filter((name) => name.endsWith(".json")).sort()
    .map((name) => readJson(join(dir, name))).filter(Boolean);
}

function fileExists(file) {
  try {
    statSync(file);
    return true;
  } catch {
    return false;
  }
}

export function ackOutbox(root, app, messageID) {
  if (!GATEWAY_APP.test(String(app || "")) || !isSafeId(messageID)) return false;
  const file = join(outboxDir(root, app), `${messageID}.json`);
  if (!fileExists(file)) return false;
  rmSync(file, { force: true });
  return true;
}
