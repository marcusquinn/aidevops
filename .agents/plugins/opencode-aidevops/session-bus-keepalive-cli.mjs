// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t19047/GH#38552: `aidevops sessions keepalive` subcommand.
//   keepalive <target> on|off [--hours N]   opt a session in or out
//   keepalive status [--json]               dry run: decisions only, nothing sent
//   keepalive sweep [--dry-run] [--json]    one relay pass (the 2-minute relay runs this)

import { readPresence } from "./session-bus-presence-store.mjs";
import { resolveTarget } from "./session-bus-targets.mjs";
import { keepalivePass, setKeepalive } from "./session-bus-keepalive.mjs";

const minutes = (seconds) => (seconds === null ? "?" : `${Math.round(seconds / 60)}m`);

function describe(row, now) {
  const next = row.next_wake_ms === null ? "-" : row.next_wake_ms <= now ? "now" : new Date(row.next_wake_ms).toISOString();
  const outcome = row.woke ? "woke" : row.wake ? "would-wake" : `skip: ${row.reason}`;
  return `${row.handle} ${row.status} idle ${minutes(row.idle_s)} threshold ${minutes(row.threshold_s)} next ${next} ${outcome}`;
}

function printPass({ root, options, out }, send) {
  const now = Date.now();
  const rows = keepalivePass(root, { now, send });
  const empty = "No sessions have keepalive on.";
  out.write(`${options.json ? JSON.stringify(rows, null, 2) : rows.map((row) => describe(row, now)).join("\n") || empty}\n`);
}

function toggle({ root, options, out }, target, setting) {
  const resolved = resolveTarget(readPresence(root), target, "", { root });
  if (resolved.error) throw new Error(resolved.error);
  const sessionID = resolved.record?.session_id || resolved.sessionID;
  const on = setting === "on";
  if (on && !resolved.record) throw new Error("that session is not running");
  const stored = setKeepalive(root, resolved.record || { session_id: sessionID }, on, { hours: options.hours });
  out.write(on
    ? `Keepalive on for ${resolved.record.handle} until ${new Date(stored.expires_at).toISOString()}.\n`
    : `Keepalive off for ${sessionID}.\n`);
}

export function keepaliveCommand(context) {
  const [, first, second] = context.options.positional;
  if (first === "status") return printPass(context, false);
  if (first === "sweep") return printPass(context, !context.options.dryRun);
  if (!["on", "off"].includes(second)) throw new Error("keepalive needs <target> on|off [--hours N], status, or sweep [--dry-run]");
  return toggle(context, first, second);
}
