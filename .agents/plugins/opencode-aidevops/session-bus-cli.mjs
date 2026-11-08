#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: `aidevops sessions` CLI over the session bus. It gives the
// user a terminal view of live OpenCode sessions. It is also the entry point
// that chat gateways use (Phase 3, `--origin chat:<app>:<channel>`).
// Subcommands: session-bus-cli-commands.mjs.

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import * as store from "./session-bus-store.mjs";
import {
  inboxCommand,
  listCommand,
  outboxCommand,
  print,
  pruneCommand,
  sendCommand,
  showCommand,
} from "./session-bus-cli-commands.mjs";

const USAGE = `Usage: aidevops sessions <command> [options]

  list [--all] [--json]              Live OpenCode sessions (interactive by default)
  show <target> [--json]             One session's presence record
  send <target> <text…>              Info message; waits for the recipient's next tool result or turn
  ask <target> <text…> [--wait <s>]  Question; may wake an idle session. --wait 1-120 prints the reply (exit 0) or exits 2 on timeout
  inbox [<session-id>] [--json]      Recent traffic for a session (read-only; default: this session)
  outbox <app> [--json] [--ack <id>] Replies for a sender with no session (cli or a chat gateway)
  prune                              Remove dead presence and messages older than 7 days

Message text: positional words, --text-file <path>, or - for stdin (max ${store.LIMITS.textChars} chars).
--origin chat:<app>:<channel>  marks a gateway message (external, unverified, never wakes).
Targets: session ID, handle, #issue, PR#n, repo, or worktree path.`;

const BOOLEAN_FLAGS = { "--json": "json", "--all": "all", "-h": "help", "--help": "help" };
const VALUE_FLAGS = { "--text-file": "textFile", "--origin": "origin", "--ack": "ack", "--wait": "wait" };

function parseWait(value) {
  const seconds = Number(value);
  if (!Number.isInteger(seconds) || seconds < 1 || seconds > 120) throw new Error("--wait must be a whole number of seconds from 1 to 120");
  return seconds;
}

export function parseArgs(argv) {
  const options = { positional: [], json: false, all: false, textFile: "", origin: "", ack: "", wait: 0 };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (Object.hasOwn(BOOLEAN_FLAGS, arg)) options[BOOLEAN_FLAGS[arg]] = true;
    else if (Object.hasOwn(VALUE_FLAGS, arg)) {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      options[VALUE_FLAGS[arg]] = arg === "--wait" ? parseWait(argv[index]) : argv[index];
    } else options.positional.push(arg);
  }
  return options;
}

const COMMANDS = {
  list: listCommand,
  show: showCommand,
  send: (context) => sendCommand(context, "info"),
  ask: (context) => sendCommand(context, "ask"),
  inbox: inboxCommand,
  outbox: outboxCommand,
  prune: pruneCommand,
};

export function main(argv = process.argv.slice(2), { env = process.env, out = process.stdout, root = store.busRoot(env) } = {}) {
  const options = parseArgs(argv);
  const command = options.positional[0] || "list";
  if (options.help || command === "help") {
    print(out, USAGE, false);
    return 0;
  }
  if (!Object.hasOwn(COMMANDS, command)) throw new Error(`unknown command: ${command}\n\n${USAGE}`);
  const pending = COMMANDS[command]({ root, options, out, env });
  // `ask --wait` returns a Promise of the exit code (0 reply, 2 timeout).
  return pending && typeof pending.then === "function" ? pending : 0;
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
    process.exitCode = await main();
  } catch (error) {
    process.stderr.write(`aidevops sessions: ${error?.message ?? error}\n`);
    process.exitCode = 1;
  }
}
