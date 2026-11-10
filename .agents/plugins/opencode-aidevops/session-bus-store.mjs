// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: file store for the OpenCode session bus. The plugin
// (session-bus.mjs), the CLI (session-bus-cli.mjs) and the TUI sidebar
// (tui-messages.mjs) share it. It does not use npm packages, a daemon or
// SQLite. Each presence file has one writer, every write is temp+rename, and a
// delivery is claimed by renaming the message into delivered/, so exactly one
// process wins a delivery. Layout and limits: reference/session-bus.md.
//
// This module is the store's single import surface; each concern lives in
// its own module:
//   session-bus-files.mjs           layout, limits, atomic JSON I/O, retention
//   session-bus-presence-store.mjs  presence records and process liveness
//   session-bus-targets.mjs         `to` argument resolution
//   session-bus-messages.mjs        validation, send and reply
//   session-bus-inbox.mjs           inbox reads, claims, subscriptions, outbox
//   session-bus-format.mjs          presence rows, previews, delivery framing
//   session-bus-bindings.mjs        chat channel -> session bindings (t18892)

import { LIMITS, pruneBusFiles } from "./session-bus-files.mjs";
import { pruneBindings } from "./session-bus-bindings.mjs";

export * from "./session-bus-files.mjs";
export * from "./session-bus-bindings.mjs";
export * from "./session-bus-presence-store.mjs";
export * from "./session-bus-targets.mjs";
export * from "./session-bus-messages.mjs";
export * from "./session-bus-inbox.mjs";
export * from "./session-bus-format.mjs";

/**
 * Full bus retention: messages, markers and settings (pruneBusFiles), then
 * t18892 channel bindings whose session has been gone and idle for the
 * retention period. Returns the number of messages and markers removed.
 * Bindings import the file primitives, so the two are composed here.
 */
export function pruneBus(root, now = Date.now()) {
  const removed = pruneBusFiles(root, now);
  pruneBindings(root, now - LIMITS.retentionMs);
  return removed;
}
