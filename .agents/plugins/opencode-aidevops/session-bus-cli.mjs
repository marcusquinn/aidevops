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
import { notifyReleaseCommand, watchReleaseCommand } from "./session-bus-cli-release.mjs";
import { DEFAULT_SERVER } from "./session-bus-launch.mjs";
import { bindCommand, bindingsCommand, launchSessionCommand, unbindCommand } from "./session-bus-cli-bindings.mjs";
import {
  inboxCommand,
  listCommand,
  outboxCommand,
  print,
  pruneCommand,
  replyCommand,
  sendCommand,
  showCommand,
  whoCommand,
} from "./session-bus-cli-commands.mjs";

const USAGE = `Usage: aidevops sessions <command> [options]

  list [--all] [--json] [--redact]   Live messageable OpenCode sessions, workers included (--all adds read-only)
  chat-wake <target> on|off          Opt in/out of verified-owner chat asks (default off)
  show <target> [--json]             One session's presence record
  who <target…> [--repo <slug>] [--json]  Other live sessions (workers included) on #issue, PR#n, repo, worktree or file path
  send <target> <text…>              Info message; waits for the recipient's next tool result or turn
  ask <target> <text…> [--wait <s>]  Question; may wake an idle session (never a worker). --wait 1-120 prints the reply (exit 0) or exits 2 on timeout
  reply <msg-id> <text…>             Answer an ask this session received (from an OpenCode session's shell)
  inbox [<session-id>] [--json]      Recent traffic for a session (read-only; default: this session)
  outbox <app> [--json] [--ack <id>] Replies for a sender with no session (cli or a chat gateway)
  prune                              Remove dead presence, messages older than 7 days and stale bindings
  watch-release <owner/repo> [--off] This session gets one info notice per lane finalize or dead executor (7 days)
  notify-release --repo <owner/repo> --source-pr <n> --event published|superseded|failed|executor-dead
                 [--tag <v>] [--receipt <r>] [--executor-state <s>] [--recovery <cmd>] [--owner-session <id>] [--marker <m>]
                                     Release-lane notice to watchers and the lane owner session (never wakes)
  bind <app> <channel> <target>      Bind a chat channel to a session [--actor <id>] [--server <url>] [--json]
  unbind <app> <channel>             Remove a channel binding
  bindings [--app <app>] [--json]    Channel bindings and whether each bound session is live
  launch --bind <app>:<channel> --title <t> --actor <id> [--server <url>] [--directory <path>] <text…>
                                     Create a session on opencode serve, bind the channel, opt in to
                                     owner chat wakes and send the text as the owner's ask

Message text: positional words, --text-file <path>, or - for stdin (max ${store.LIMITS.textChars} chars).
--sender <label>               names a sessionless sender (e.g. pulse); attribution and its own rate limit only.
--origin chat:<app>:<channel>  marks a scanned gateway message.
--actor <entity-id>            verifies an exact confirmed app/channel link; never inferred from text.
--server <url>                 default ${DEFAULT_SERVER}; any non-loopback server must use https.
Targets: session ID, @id (from the session title), handle, #issue, PR#n, repo, worktree path, or channel:<app>:<channel>.
Exit codes: 0 ok, 1 error, 2 ask --wait timeout, 3 bound session not live, 4 launch created a session but did not finish.`;

const BOOLEAN_FLAGS = { "--json": "json", "--all": "all", "--redact": "redact", "--off": "off", "-h": "help", "--help": "help" };
const VALUE_FLAGS = {
  "--text-file": "textFile", "--origin": "origin", "--actor": "actor", "--ack": "ack", "--wait": "wait", "--sender": "sender",
  "--repo": "repo",
  // t18892 bindings and launch
  "--app": "app", "--server": "server", "--title": "title", "--bind": "bind", "--directory": "directory",
};
const RELEASE_VALUE_FLAGS = {
  "--source-pr": "sourcePr", "--event": "event", "--tag": "tag", "--receipt": "receipt",
  "--executor-state": "executorState", "--recovery": "recovery", "--owner-session": "ownerSession", "--marker": "marker",
};

function parseWait(value) {
  const seconds = Number(value);
  if (!Number.isInteger(seconds) || seconds < 1 || seconds > 120) throw new Error("--wait must be a whole number of seconds from 1 to 120");
  return seconds;
}

export function parseArgs(argv) {
  const options = {
    positional: [], json: false, all: false, textFile: "", origin: "", ack: "", wait: 0, sender: "", repo: "",
    app: "", server: "", title: "", bind: "", directory: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const valueFlags = options.positional[0] === "notify-release" ? { ...VALUE_FLAGS, ...RELEASE_VALUE_FLAGS } : VALUE_FLAGS;
    if (Object.hasOwn(BOOLEAN_FLAGS, arg)) options[BOOLEAN_FLAGS[arg]] = true;
    else if (Object.hasOwn(valueFlags, arg)) {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      options[valueFlags[arg]] = arg === "--wait" ? parseWait(argv[index]) : argv[index];
    } else options.positional.push(arg);
  }
  return options;
}

const COMMANDS = {
  "chat-wake": chatWakeCommand,
  list: listCommand,
  show: showCommand,
  who: whoCommand,
  send: (context) => sendCommand(context, "info"),
  ask: (context) => sendCommand(context, "ask"),
  reply: replyCommand,
  inbox: inboxCommand,
  outbox: outboxCommand,
  prune: pruneCommand,
  "watch-release": watchReleaseCommand,
  "notify-release": notifyReleaseCommand,
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
export function main(argv = process.argv.slice(2), {
  env = process.env, out = process.stdout, err = process.stderr, root = store.busRoot(env), fetch,
} = {}) {
  const options = parseArgs(argv);
  const command = options.positional[0] || "list";
  if (options.help || command === "help") {
    print(out, USAGE, false);
    return 0;
  }
  if (!Object.hasOwn(COMMANDS, command)) throw new Error(`unknown command: ${command}\n\n${USAGE}`);
  const pending = COMMANDS[command]({ root, options, out, err, env, fetch });
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
