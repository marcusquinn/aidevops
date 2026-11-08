#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: `aidevops sessions` CLI over the session bus. It gives the
// user a terminal view of live OpenCode sessions. It is also the entry point
// that chat gateways use (Phase 3, `--origin chat:<app>:<channel>`).

import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import * as store from "./session-bus-store.mjs";

const USAGE = `Usage: aidevops sessions <command> [options]

  list [--all] [--json]              Live OpenCode sessions (interactive by default)
  show <target> [--json]             One session's presence record
  send <target> <text…>              Info message; waits for the recipient's next tool result or turn
  ask <target> <text…>               Question; may wake an idle session
  inbox [<session-id>] [--json]      Recent traffic for a session (read-only; default: this session)
  outbox <app> [--json] [--ack <id>] Replies for a sender with no session (cli or a chat gateway)
  prune                              Remove dead presence and messages older than 7 days

Message text: positional words, --text-file <path>, or - for stdin (max ${store.LIMITS.textChars} chars).
--origin chat:<app>:<channel>  marks a gateway message (external, unverified, never wakes).
Targets: session ID, handle, #issue, PR#n, repo, or worktree path.`;

export function parseArgs(argv) {
  const options = { positional: [], json: false, all: false, textFile: "", origin: "", ack: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[index];
    };
    if (arg === "--json") options.json = true;
    else if (arg === "--all") options.all = true;
    else if (arg === "--text-file") options.textFile = next();
    else if (arg === "--origin") options.origin = next();
    else if (arg === "--ack") options.ack = next();
    else if (arg === "-h" || arg === "--help") options.help = true;
    else options.positional.push(arg);
  }
  return options;
}

function readText(options, words) {
  if (options.textFile) return readFileSync(options.textFile, "utf8");
  if (words.length === 1 && words[0] === "-") return readFileSync(0, "utf8");
  return words.join(" ");
}

function senderFrom(root, origin, env) {
  if (origin) {
    const chat = store.parseChatOrigin(origin);
    if (!chat) throw new Error("--origin must look like chat:<app>:<channel>");
    return { session_id: "", handle: `chat:${chat.app}`, repo: "", branch: "", origin };
  }
  const sessionID = env.AIDEVOPS_OPENCODE_SESSION_ID || env.OPENCODE_SESSION_ID || "";
  const self = store.isSafeId(sessionID)
    ? store.readPresence(root).find((record) => record.session_id === sessionID)
    : null;
  return {
    session_id: store.isSafeId(sessionID) ? sessionID : "",
    handle: self?.handle || (sessionID ? `session-${sessionID.slice(-6)}` : `shell:${env.USER || "user"}`),
    repo: self?.repo || "",
    branch: self?.branch || "",
    origin: "cli",
  };
}

function print(out, value, json) {
  out.write(`${json ? JSON.stringify(value, null, 2) : value}\n`);
}

function listCommand(root, options, out) {
  const all = store.sortPresence(store.readPresence(root, { sweep: true }));
  const records = options.all ? all : all.filter(store.isMessageable);
  if (options.json) return print(out, records, true);
  const hidden = all.length - records.length;
  const lines = records.map((record) => store.formatPresenceRow(record));
  if (lines.length === 0) lines.push("No live interactive OpenCode sessions.");
  if (hidden > 0) lines.push(`(${hidden} headless/read-only session(s) hidden; use --all)`);
  return print(out, lines.join("\n"), false);
}

function showCommand(root, options, out) {
  const resolved = store.resolveTarget(store.readPresence(root), options.positional[1], "");
  if (resolved.error) throw new Error(resolved.error);
  if (!resolved.record) throw new Error("that session is not running");
  return print(out, options.json ? resolved.record : store.formatPresenceRow(resolved.record), options.json);
}

function sendCommand(root, options, out, env, type) {
  const [, target, ...words] = options.positional;
  const from = senderFrom(root, options.origin, env);
  const resolved = store.resolveTarget(store.readPresence(root), target, from.session_id);
  if (resolved.error) throw new Error(resolved.error);
  if (resolved.record && !store.isMessageable(resolved.record)) {
    throw new Error(`${resolved.record.handle} is a ${resolved.record.kind} session and cannot be messaged`);
  }
  const message = store.sendMessage(root, {
    from,
    to: resolved.record ? resolved.record.session_id : resolved.sessionID,
    toHandle: resolved.record?.handle || "",
    type,
    text: readText(options, words),
  });
  const replyHint = type === "ask" && !from.session_id
    ? ` Read the reply with: aidevops sessions outbox ${store.parseChatOrigin(from.origin)?.app || "cli"}`
    : "";
  return print(out, `Sent ${type} ${message.id} to ${resolved.record?.handle || resolved.sessionID}.${replyHint}`, false);
}

function inboxCommand(root, options, out, env) {
  const sessionID = options.positional[1] || env.AIDEVOPS_OPENCODE_SESSION_ID || env.OPENCODE_SESSION_ID || "";
  if (!store.isSafeId(sessionID)) throw new Error("inbox needs a session ID (or run it inside an OpenCode session)");
  const rows = store.recentTraffic(root, sessionID, { limit: 20 });
  if (options.json) return print(out, rows, true);
  const lines = rows.map(({ direction, pending, message }) => {
    const peer = direction === "in" ? message.from?.handle : message.to_handle || message.to;
    return `${pending ? "• " : ""}${direction === "in" ? "←" : "→"} ${message.type} ${message.id} ${peer}: ${store.messagePreview(message, 120)}`;
  });
  return print(out, lines.length > 0 ? lines.join("\n") : "No messages.", false);
}

function outboxCommand(root, options, out) {
  const app = options.positional[1];
  if (options.ack) {
    if (!store.ackOutbox(root, app, options.ack)) throw new Error(`no outbox message ${options.ack} for ${app}`);
    return print(out, `Acknowledged ${options.ack}.`, false);
  }
  const messages = store.readOutbox(root, app);
  if (options.json) return print(out, messages, true);
  const lines = messages.map((message) =>
    `${message.id} re ${message.re} from ${message.from?.handle}: ${store.messagePreview(message, 160)}`);
  return print(out, lines.length > 0 ? lines.join("\n") : "Outbox empty.", false);
}

export function main(argv = process.argv.slice(2), { env = process.env, out = process.stdout, root = store.busRoot(env) } = {}) {
  const options = parseArgs(argv);
  const command = options.positional[0] || "list";
  if (options.help || command === "help") {
    print(out, USAGE, false);
    return 0;
  }
  switch (command) {
    case "list": listCommand(root, options, out); break;
    case "show": showCommand(root, options, out); break;
    case "send": sendCommand(root, options, out, env, "info"); break;
    case "ask": sendCommand(root, options, out, env, "ask"); break;
    case "inbox": inboxCommand(root, options, out, env); break;
    case "outbox": outboxCommand(root, options, out); break;
    case "prune": {
      const live = store.readPresence(root, { sweep: true }).length;
      print(out, `Pruned ${store.pruneBus(root)} expired message(s); ${live} live session(s).`, false);
      break;
    }
    default:
      throw new Error(`unknown command: ${command}\n\n${USAGE}`);
  }
  return 0;
}

function invokedDirectly() {
  // ~/.aidevops/agents can be a symlink into a runtime bundle; Node gives
  // the main module its real path, but argv[1] keeps the path as invoked.
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  try {
    process.exitCode = main();
  } catch (error) {
    process.stderr.write(`aidevops sessions: ${error?.message ?? error}\n`);
    process.exitCode = 1;
  }
}
