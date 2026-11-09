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
import { chatWakeCommand } from "./session-bus-chat-trust.mjs";
import { DEFAULT_SERVER } from "./session-bus-launch.mjs";
import {
  bindCommand,
  bindingsCommand,
  launchSessionCommand,
  unbindCommand,
  inboxCommand,
  listCommand,
  outboxCommand,
  print,
  pruneCommand,
  sendCommand,
  showCommand,
} from "./session-bus-cli-commands.mjs";

const USAGE = `Usage: aidevops sessions <command> [options]

  list [--all] [--json] [--redact]   Live OpenCode sessions (interactive by default)
  chat-wake <target> on|off          Opt in/out of verified-owner chat asks (default off)
  show <target> [--json]             One session's presence record
  send <target> <text…>              Info message; waits for the recipient's next tool result or turn
  ask <target> <text…> [--wait <s>]  Question; may wake an idle session. --wait 1-120 prints the reply (exit 0) or exits 2 on timeout
  inbox [<session-id>] [--json]      Recent traffic for a session (read-only; default: this session)
  outbox <app> [--json] [--ack <id>] Replies for a sender with no session (cli or a chat gateway)
  prune                              Remove dead presence, messages older than 7 days and stale bindings
  bind <app> <channel> <target>      Bind a chat channel to a session [--actor <id>] [--server <url>] [--json]
  unbind <app> <channel>             Remove a channel binding
  bindings [--app <app>] [--json]    Channel bindings and whether each bound session is live
  launch --bind <app>:<channel> --title <t> --actor <id> [--server <url>] [--directory <path>] <text…>
                                     Create a session on opencode serve, bind the channel, opt in to
                                     owner chat wakes and send the text as the owner's ask

Message text: positional words, --text-file <path>, or - for stdin (max ${store.LIMITS.textChars} chars).
--origin chat:<app>:<channel>  marks a scanned gateway message.
--actor <entity-id>            verifies an exact confirmed app/channel link; never inferred from text.
--server <url>                 default ${DEFAULT_SERVER}; any non-loopback server must use https.
Targets: session ID, handle, #issue, PR#n, repo, worktree path, or channel:<app>:<channel>.
Exit codes: 0 ok, 1 error, 2 ask --wait timeout, 3 bound session not live, 4 launch created a session but did not finish.`;

const BOOLEAN_FLAGS = { "--json": "json", "--all": "all", "--redact": "redact", "-h": "help", "--help": "help" };
const VALUE_FLAGS = {
  "--text-file": "textFile", "--origin": "origin", "--actor": "actor", "--ack": "ack", "--wait": "wait",
  "--app": "app", "--server": "server", "--title": "title", "--bind": "bind", "--directory": "directory",
};

function parseWait(value) {
  const seconds = Number(value);
  if (!Number.isInteger(seconds) || seconds < 1 || seconds > 120) throw new Error("--wait must be a whole number of seconds from 1 to 120");
  return seconds;
}

export function parseArgs(argv) {
  const options = {
    positional: [], json: false, all: false, textFile: "", origin: "", ack: "", wait: 0,
    app: "", server: "", title: "", bind: "", directory: "",
  };
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
  "chat-wake": chatWakeCommand,
  list: listCommand,
  show: showCommand,
  send: (context) => sendCommand(context, "info"),
  ask: (context) => sendCommand(context, "ask"),
  inbox: inboxCommand,
  outbox: outboxCommand,
  prune: pruneCommand,
  bind: bindCommand,
  unbind: unbindCommand,
  bindings: bindingsCommand,
  launch: launchSessionCommand,
};

/**
 * Runs one subcommand. Returns the exit code, or a Promise of it for
 * `ask --wait` and `launch`. Errors carrying `exitCode` (3: bound session not
 * live) keep that code. `fetch` is injectable for `launch` tests.
 */
export function main(argv = process.argv.slice(2), { env = process.env, out = process.stdout, root = store.busRoot(env), fetch } = {}) {
  const options = parseArgs(argv);
  const command = options.positional[0] || "list";
  if (options.help || command === "help") {
    print(out, USAGE, false);
    return 0;
  }
  if (!Object.hasOwn(COMMANDS, command)) throw new Error(`unknown command: ${command}\n\n${USAGE}`);
  const pending = COMMANDS[command]({ root, options, out, env, fetch });
  // `ask --wait` and `launch` return a Promise of the exit code.
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
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  }
}
