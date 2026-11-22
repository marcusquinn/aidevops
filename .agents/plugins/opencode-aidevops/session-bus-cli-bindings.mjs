// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18892: channel binding and per-task launch subcommands for
// `aidevops sessions`. Store helpers: session-bus-bindings.mjs; server calls:
// session-bus-launch.mjs.
import * as store from "./session-bus-store.mjs";
import { readText } from "./session-bus-cli-input.mjs";
import { print, printLines, resolvedOrThrow } from "./session-bus-cli-commands.mjs";
import { launchCommand, validServerUrl } from "./session-bus-launch.mjs";

function bindMessage(label, sessionID, { resolved, previous, changed }) {
  if (!changed) return `${label} is already bound to ${sessionID}.`;
  const replaced = previous ? ` (was ${previous.session_id})` : "";
  const offline = resolved.record ? "" : " That session is not live; sends exit 3 until it is.";
  return `Bound ${label} to ${resolved.record?.handle || sessionID}${replaced}.${offline}`;
}

/** `bind <app> <channel> <target>`: the target is resolved once, now. */
export function bindCommand({ root, options, out }) {
  const [, app, channel, target] = options.positional;
  const chat = store.validChannel(app, channel);
  if (!target) throw new Error("bind needs <app> <channel> <target>");
  if (store.isChannelTarget(target)) throw new Error("bind a channel to a session, not to another channel");
  const resolved = resolvedOrThrow(store.resolveTarget(store.readPresence(root), target, "", { root }));
  const sessionID = resolved.record?.session_id || resolved.sessionID;
  const server = options.server ? validServerUrl(options.server) : "";
  const written = store.writeBinding(root, {
    app: chat.app, channel: chat.channel, sessionID, actor: options.actor, server,
  });
  if (options.json) return print(out, written.record, true);
  return print(out, bindMessage(store.channelLabel(chat), sessionID, { resolved, ...written }), false);
}

export function unbindCommand({ root, options, out }) {
  const [, app, channel] = options.positional;
  const chat = store.validChannel(app, channel);
  const removed = store.removeBinding(root, chat.app, chat.channel);
  return print(out, `${removed ? "Unbound" : "No binding for"} ${store.channelLabel(chat)}.`, false);
}

function bindingLine(row, peer) {
  const state = peer ? `live ${peer.handle}` : "not live";
  return `${store.channelLabel(row)} → ${row.session_id} (${state})${row.server ? ` on ${row.server}` : ""}`;
}

export function bindingsCommand({ root, options, out }) {
  const live = new Map(store.readPresence(root).map((record) => [record.session_id, record]));
  const rows = store.listBindings(root, { app: options.app }).map((record) => ({ ...record, live: live.has(record.session_id) }));
  if (options.json) return print(out, rows, true);
  return printLines(out, rows.map((row) => bindingLine(row, live.get(row.session_id))), "No channel bindings.");
}

/** Returns a Promise of the exit code (0 launched, 4 partial failure). */
export function launchSessionCommand(context) {
  const [, ...words] = context.options.positional;
  return launchCommand(context, readText(context.options, words));
}
