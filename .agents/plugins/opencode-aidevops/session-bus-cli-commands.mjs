// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: `aidevops sessions` subcommands. session-bus-cli.mjs
// parses arguments and dispatches here; senders and message text come from
// session-bus-cli-input.mjs.

import * as store from "./session-bus-store.mjs";
import { chatTrust } from "./session-bus-chat-trust.mjs";
import { cliSender, envSessionID, readText, shellSender } from "./session-bus-cli-input.mjs";

export function print(out, value, json) {
  out.write(`${json ? JSON.stringify(value, null, 2) : value}\n`);
}

export const printLines = (out, lines, empty) => print(out, lines.length > 0 ? lines.join("\n") : empty, false);

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
  if (lines.length === 0) lines.push("No live messageable OpenCode sessions.");
  if (hidden > 0) lines.push(`(${hidden} headless/read-only session(s) hidden; use --all)`);
  return print(out, lines.join("\n"), false);
}

/**
 * t18895: every live session (workers included) on any of the targets:
 * #issue, PR#n, repo, worktree or file path. The caller's own session is
 * excluded; --repo limits matches to one repo (issue numbers are per repo).
 * Exit 0 whether or not anything matches. --json prints the presence records;
 * text prints one row per session, and the no-match note goes to stderr so
 * scripts see empty output.
 */
export function whoCommand({ root, options, out, err, env }) {
  const targets = options.positional.slice(1);
  const scope = { selfID: envSessionID(env), cwd: process.cwd(), repo: options.repo };
  const records = store.sortPresence(store.matchAnySessions(store.readPresence(root, { sweep: true }), targets, scope));
  if (options.json) return print(out, records, true);
  if (records.length === 0) return print(err, `No other live session is working on ${targets.join(", ")}.`, false);
  return print(out, records.map((record) => store.formatWhoRow(record)).join("\n"), false);
}

export function showCommand({ root, options, out }) {
  const resolved = resolvedOrThrow(store.resolveTarget(store.readPresence(root), options.positional[1], "", { root }));
  if (!resolved.record) throw new Error("that session is not running");
  return print(out, options.json ? resolved.record : store.formatPresenceRow(resolved.record), options.json);
}

/** Exit code for a `channel:` target whose bound session is not live (t18892). */
export const NOT_LIVE_EXIT = 3;

export function exitError(message, exitCode) {
  return Object.assign(new Error(message), { exitCode });
}

export function resolvedOrThrow(resolved) {
  if (resolved.error) throw resolved.notLive ? exitError(resolved.error, NOT_LIVE_EXIT) : new Error(resolved.error);
  return resolved;
}

function messageableTarget(root, target, from) {
  const resolved = resolvedOrThrow(store.resolveTarget(store.readPresence(root), target, from.session_id, { root }));
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
  const from = cliSender(root, options, env);
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

/**
 * t18905: answer an ask from a session's own shell. Workers have no
 * aidevops_sessions tool, so their framed asks point here. The sender is the
 * session in the shell environment, never an argument.
 */
export function replyCommand({ root, options, out, env }) {
  if (options.origin || options.sender || options.wait) throw new Error("reply takes no --origin, --sender or --wait; it answers as this session");
  const [, messageID, ...words] = options.positional;
  const sessionID = envSessionID(env);
  if (!store.isSafeId(sessionID)) throw new Error("reply runs in an OpenCode session's shell; it answers an ask that session received");
  const original = store.findReceived(root, sessionID, String(messageID || "").trim());
  if (original?.type !== "ask") throw new Error("reply needs the msg ID of an ask this session received");
  const text = store.validBody(readText(options, words));
  const hops = (Number.isSafeInteger(original.hops) ? original.hops : 0) + 1;
  const { message, outbox } = store.sendReply(root, { from: shellSender(root, env), original, text, hops });
  const target = outbox ? `the ${outbox} outbox for ${original.from?.handle || outbox}` : original.from?.handle || original.from?.session_id;
  return print(out, `Sent reply ${message.id} to ${target}.`, false);
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
