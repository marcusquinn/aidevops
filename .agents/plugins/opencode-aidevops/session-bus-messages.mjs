// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: session-bus message validation and sending. A send writes
// the recipient's inbox copy and the sender's sent/ copy; replies to senders
// with no session go to outbox/<app>/.

import { join } from "node:path";
import { randomBytes } from "node:crypto";

import {
  BUS_VERSION,
  LIMITS,
  MESSAGE_TYPES,
  fileTime,
  inboxDir,
  isSafeId,
  messageFiles,
  outboxDir,
  parseChatOrigin,
  sentDir,
  writeJsonAtomic,
} from "./session-bus-files.mjs";

export function newMessageId() {
  return `msg_${Date.now().toString(36)}${randomBytes(5).toString("hex")}`;
}

const messageFileName = (message) => `${String(message.created_ms).padStart(13, "0")}-${message.id}.json`;

export function senderKey(from) {
  if (isSafeId(from?.session_id)) return from.session_id;
  const origin = String(from?.origin || "cli").replace(/[^A-Za-z0-9_-]+/g, "-").slice(0, 100);
  return origin || "cli";
}

function cleanText(text) {
  // Control characters other than newline and tab could rewrite a terminal.
  return String(text ?? "").replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "");
}

export function countRecentSends(root, key, now = Date.now(), windowMs = 60_000) {
  return messageFiles(sentDir(root, key)).filter((name) => fileTime(name) > now - windowMs).length;
}

export function pendingCount(root, sessionID) {
  return messageFiles(inboxDir(root, sessionID)).length;
}

const clip = (value, width) => String(value || "").slice(0, width);

export function validBody(text) {
  const body = cleanText(text).trim();
  if (!body) throw new Error("message text is empty");
  if (Array.from(body).length > LIMITS.textChars) {
    throw new Error(`message text exceeds ${LIMITS.textChars} characters; write the detail to a file and send its path`);
  }
  return body;
}

function validateRoute({ from, to, type }) {
  if (!MESSAGE_TYPES.includes(type)) throw new Error(`unknown message type: ${type}`);
  if (from?.session_id && from.session_id === to) throw new Error("messages to yourself are rejected");
}

function checkRate(root, from, now) {
  if (countRecentSends(root, senderKey(from), now) >= LIMITS.sendsPerMinute) {
    throw new Error(`rate limit: at most ${LIMITS.sendsPerMinute} messages per minute per sender`);
  }
}

function viaFields(via) {
  if (!isSafeId(via?.session_id)) return {};
  return { via: { session_id: via.session_id, agent: clip(via.agent, 80) } };
}

function senderFields(from) {
  return {
    ...(parseChatOrigin(from?.origin) && from?.trust ? { trust: from.trust } : {}),
    ...viaFields(from?.via),
    session_id: isSafeId(from?.session_id) ? from.session_id : "",
    handle: clip(from?.handle, 80),
    repo: clip(from?.repo, 120),
    branch: clip(from?.branch, 120),
    origin: parseChatOrigin(from?.origin) ? from.origin : String(from?.origin || "opencode").slice(0, 160),
  };
}

function buildMessage(root, { from, to, toHandle = "", type, text, re = "", hops = 0, now = Date.now() }, releaseNotice = false) {
  validateRoute({ from, to, type });
  const body = validBody(text);
  if (!releaseNotice) checkRate(root, from, now);
  return {
    v: BUS_VERSION,
    id: newMessageId(),
    type,
    from: senderFields(from),
    to,
    to_handle: clip(toHandle, 80),
    re: isSafeId(re) ? re : "",
    text: body,
    hops: Number.isSafeInteger(hops) && hops >= 0 ? hops : 0,
    created_ms: now,
  };
}

/**
 * Write one message into the recipient's inbox and the sender's sent/ copy.
 * Throws on any limit or validation failure, so the caller can surface it.
 */
export function sendMessage(root, options) {
  return writeMessage(root, options, false);
}

// Internal advisory fan-out: fixed sender and info type, still subject to inbox limits.
export function sendReleaseNotice(root, { to, toHandle, text, now }) {
  const from = { session_id: "", handle: "release-lane", repo: "", branch: "", origin: "cli:release-lane" };
  return writeMessage(root, { from, to, toHandle, type: "info", text, now }, true);
}

function writeMessage(root, options, releaseNotice) {
  if (!isSafeId(options?.to)) throw new Error("invalid recipient session ID");
  if (pendingCount(root, options.to) >= LIMITS.inboxPending) {
    throw new Error(`recipient inbox is full (${LIMITS.inboxPending} undelivered messages); try later`);
  }
  const message = buildMessage(root, options, releaseNotice);
  const name = messageFileName(message);
  writeJsonAtomic(join(inboxDir(root, message.to), name), message);
  writeJsonAtomic(join(sentDir(root, senderKey(message.from)), name), message);
  return message;
}

/**
 * Reply to a received ask. A sender with a session gets the reply in its
 * inbox. A shell or chat-gateway sender has no inbox, so the reply goes to
 * outbox/<app>/ (`cli` for a plain shell) for `aidevops sessions outbox`.
 */
export function sendReply(root, { from, original, text, hops = 0, now = Date.now() }) {
  if (original?.type !== "ask") throw new Error("only a received ask can be replied to");
  const senderSession = original.from?.session_id;
  if (isSafeId(senderSession)) {
    const message = sendMessage(root, {
      from, to: senderSession, toHandle: original.from.handle, type: "reply", text, re: original.id, hops, now,
    });
    return { message, outbox: "" };
  }
  const chat = parseChatOrigin(original.from?.origin);
  const app = chat ? chat.app : "cli";
  const message = buildMessage(root, {
    from, to: "", toHandle: original.from?.handle || app, type: "reply", text, re: original.id, hops, now,
  });
  writeJsonAtomic(join(outboxDir(root, app), `${message.id}.json`), { ...message, channel: chat?.channel || "" });
  writeJsonAtomic(join(sentDir(root, senderKey(message.from)), messageFileName(message)), message);
  return { message, outbox: app };
}
