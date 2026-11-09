// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: `aidevops sessions` subcommands. session-bus-cli.mjs
// parses arguments and dispatches here.

import { readFileSync } from "node:fs";

import * as store from "./session-bus-store.mjs";
import { chatTrust, setChatWake } from "./session-bus-chat-trust.mjs";

function readText(options, words) {
  if (options.textFile) return readFileSync(options.textFile, "utf8");
  if (words.length === 1 && words[0] === "-") return readFileSync(0, "utf8");
  return words.join(" ");
}

export const envSessionID = (env) => env.AIDEVOPS_OPENCODE_SESSION_ID || env.OPENCODE_SESSION_ID || "";

function chatSender(origin) {
  const chat = store.parseChatOrigin(origin);
  if (!chat) throw new Error("--origin must look like chat:<app>:<channel>");
  return { session_id: "", handle: `chat:${chat.app}`, repo: "", branch: "", origin };
}

// Inside an OpenCode bash tool the shell inherits the session ID, so a CLI
// send is attributed to that session; elsewhere it comes from shell:<user>.
function shellSender(root, env) {
  const raw = envSessionID(env);
  const sessionID = store.isSafeId(raw) ? raw : "";
  const self = sessionID ? store.readPresence(root).find((record) => record.session_id === sessionID) : null;
  const fallback = raw ? `session-${raw.slice(-6)}` : `shell:${env.USER || "user"}`;
  return {
    session_id: sessionID,
    handle: self?.handle || fallback,
    repo: self?.repo || "",
    branch: self?.branch || "",
    origin: "cli",
  };
}

const senderFrom = (root, origin, env) => (origin ? chatSender(origin) : shellSender(root, env));

export function print(out, value, json) {
  out.write(`${json ? JSON.stringify(value, null, 2) : value}\n`);
}

const printLines = (out, lines, empty) => print(out, lines.length > 0 ? lines.join("\n") : empty, false);

export function listCommand({ root, options, out }) {
  const all = store.sortPresence(store.readPresence(root, { sweep: true }));
  let records = options.all ? all : all.filter(store.isMessageable);
  if (options.redact) records = records.map((record) => ({
    session_id: record.session_id, handle: record.session_id, kind: record.kind,
    messageable: record.messageable, status: record.status, last_activity_epoch: record.last_activity_epoch,
  }));
  if (options.json) return print(out, records, true);
  const hidden = all.length - records.length;
  const lines = records.map((record) => store.formatPresenceRow(record));
  if (lines.length === 0) lines.push("No live interactive OpenCode sessions.");
  if (hidden > 0) lines.push(`(${hidden} headless/read-only session(s) hidden; use --all)`);
  return print(out, lines.join("\n"), false);
}

export function showCommand({ root, options, out }) {
  const resolved = store.resolveTarget(store.readPresence(root), options.positional[1], "");
  if (resolved.error) throw new Error(resolved.error);
  if (!resolved.record) throw new Error("that session is not running");
  return print(out, options.json ? resolved.record : store.formatPresenceRow(resolved.record), options.json);
}

function messageableTarget(root, target, from) {
  const resolved = store.resolveTarget(store.readPresence(root), target, from.session_id);
  if (resolved.error) throw new Error(resolved.error);
  if (resolved.record && !store.isMessageable(resolved.record)) {
    throw new Error(`${resolved.record.handle} is a ${resolved.record.kind} session and cannot be messaged`);
  }
  return resolved;
}

function replyHint(type, from) {
  if (type !== "ask" || from.session_id) return "";
  return ` Read the reply with: aidevops sessions outbox ${store.parseChatOrigin(from.origin)?.app || "cli"}`;
}

const WAIT_POLL_MS = 1000;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// t18897: poll the outbox for the reply to `askID`, acknowledge it, print it.
// Returns 0 with the reply, or 2 on timeout. A waiting sender is sessionless,
// so the reply is always written to outbox/<app>.
async function waitForOutboxReply({ root, out, options }, askID, app) {
  const deadline = Date.now() + options.wait * 1000;
  const pollMs = options.waitPollMs || WAIT_POLL_MS;
  for (;;) {
    const reply = store.readOutbox(root, app).find((message) => message.re === askID);
    if (reply) {
      store.ackOutbox(root, app, reply.id);
      print(out, options.json ? reply : store.frameMessage(reply), options.json);
      return 0;
    }
    if (Date.now() >= deadline) break;
    await sleep(Math.min(pollMs, Math.max(1, deadline - Date.now())));
  }
  print(out, `No reply within ${options.wait}s; ask ${askID}. Read it later with: aidevops sessions outbox ${app}`, false);
  return 2;
}

/** Sends a message. Returns undefined, or a Promise of the exit code when `--wait` is used. */
export function sendCommand(context, type) {
  const { root, options, out, env } = context;
  const [, target, ...words] = options.positional;
  if (options.wait && type !== "ask") throw new Error("--wait is only valid with ask");
  // A waiting sender has no session, so the reply lands in outbox/<app>.
  const from = options.wait && !options.origin
    ? { session_id: "", handle: `shell:${env.USER || "user"}`, repo: "", branch: "", origin: "cli" }
    : senderFrom(root, options.origin, env);
  const resolved = messageableTarget(root, target, from);
  const text = store.validBody(readText(options, words));
  if (options.origin) from.trust = chatTrust(options.origin, options.actor, text, env);
  const message = store.sendMessage(root, {
    from,
    to: resolved.record ? resolved.record.session_id : resolved.sessionID,
    toHandle: resolved.record?.handle || "",
    type,
    text,
  });
  print(out, `Sent ${type} ${message.id} to ${resolved.record?.handle || resolved.sessionID}.${replyHint(type, from)}`, false);
  if (!options.wait) return undefined;
  return waitForOutboxReply(context, message.id, store.parseChatOrigin(from.origin)?.app || "cli");
}

function trafficLine({ direction, pending, message }) {
  const incoming = direction === "in";
  const peer = incoming ? message.from?.handle : message.to_handle || message.to;
  return `${pending ? "• " : ""}${incoming ? "←" : "→"} ${message.type} ${message.id} ${peer}: ${store.messagePreview(message, 120)}`;
}

export function inboxCommand({ root, options, out, env }) {
  const sessionID = options.positional[1] || envSessionID(env);
  if (!store.isSafeId(sessionID)) throw new Error("inbox needs a session ID (or run it inside an OpenCode session)");
  const rows = store.recentTraffic(root, sessionID, { limit: 20 });
  if (options.json) return print(out, rows, true);
  return printLines(out, rows.map(trafficLine), "No messages.");
}

export function outboxCommand({ root, options, out }) {
  const app = options.positional[1];
  if (options.ack) {
    if (!store.ackOutbox(root, app, options.ack)) throw new Error(`no outbox message ${options.ack} for ${app}`);
    return print(out, `Acknowledged ${options.ack}.`, false);
  }
  const messages = store.readOutbox(root, app);
  if (options.json) return print(out, messages, true);
  const lines = messages.map((message) =>
    `${message.id} re ${message.re} from ${message.from?.handle}: ${store.messagePreview(message, 160)}`);
  return printLines(out, lines, "Outbox empty.");
}

export function pruneCommand({ root, out }) {
  const live = store.readPresence(root, { sweep: true }).length;
  return print(out, `Pruned ${store.pruneBus(root)} expired message(s); ${live} live session(s).`, false);
}

export function chatWakeCommand({ root, options, out }) {
  const [, target, setting] = options.positional;
  if (!["on", "off"].includes(setting)) throw new Error("chat-wake needs <target> on|off");
  const resolved = store.resolveTarget(store.readPresence(root), target, "");
  if (resolved.error) throw new Error(resolved.error);
  const sessionID = resolved.record?.session_id || resolved.sessionID;
  setChatWake(root, sessionID, setting === "on");
  print(out, `Chat owner wakes ${setting} for ${sessionID}.`, false);
}
