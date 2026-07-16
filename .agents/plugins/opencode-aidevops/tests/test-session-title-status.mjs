// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { createSessionTitleStatusHandler } from "../session-title-status.mjs";
import {
  createTerminalTitleController,
  terminalTitleSequence,
  withTerminalTitleStatus,
} from "../terminal-title.mjs";

function event(type, properties = {}) {
  return { event: { type, properties } };
}

test("terminal titles map OpenCode status to compact idempotent emoji prefixes", () => {
  assert.equal(withTerminalTitleStatus("Issue #123: improve tabs", "busy"), "⚪ Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("🟢 Issue #123: improve tabs", "retry"), "⚪ Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("⚪ Issue #123: improve tabs", "permission"), "🟡 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("🟡 Issue #123: improve tabs", "idle"), "🟢 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("[RUN] Issue #123: improve tabs", "idle"), "🟢 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("Issue #123: improve tabs", "unknown"), "Issue #123: improve tabs");
});

test("terminal title controller preserves status across later session title updates", () => {
  const writes = [];
  const controller = createTerminalTitleController({
    isEnabled: () => true,
    writeTitle: (title) => writes.push(title),
  });

  controller.emit("Issue #123: initial title");
  controller.setStatus("busy");
  controller.emit("Issue #123: renamed title");
  controller.setStatus("retry");
  controller.setStatus("permission");
  controller.setStatus("busy");
  controller.setStatus("idle");
  controller.setStatus("");
  controller.reset();
  controller.setStatus("busy");

  assert.deepEqual(writes, [
    "Issue #123: initial title",
    "⚪ Issue #123: initial title",
    "⚪ Issue #123: renamed title",
    "🟡 Issue #123: renamed title",
    "⚪ Issue #123: renamed title",
    "🟢 Issue #123: renamed title",
    "Issue #123: renamed title",
  ]);
});

test("terminal title sequences reject empty and control-only titles", () => {
  assert.equal(terminalTitleSequence("\n\t"), "");
  assert.equal(terminalTitleSequence("Task\u0007 title"), "\u001B]0;Task  title\u0007");
});

test("session status handler follows only the active interactive root session", async () => {
  const statuses = [];
  let resets = 0;
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("session.created", { info: { id: "root-1", title: "Root" } }));
  await handler(event("session.created", { info: { id: "child-1", parentID: "root-1", title: "Child" } }));
  await handler(event("session.status", { sessionID: "child-1", status: { type: "busy" } }));
  await handler(event("permission.replied", { requestID: "unknown", sessionID: "root-1", reply: "once" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "busy" } }));
  await handler(event("permission.asked", { id: "permission-child", sessionID: "child-1" }));
  await handler(event("permission.asked", { id: "permission-root", sessionID: "root-1" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "idle" } }));
  await handler(event("permission.replied", { requestID: "permission-root", sessionID: "root-1", reply: "once" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "retry" } }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "idle" } }));
  await handler(event("session.created", { info: { id: "root-2", title: "New root" } }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "busy" } }));
  await handler(event("session.status", { sessionID: "root-2", status: { type: "idle" } }));

  assert.equal(resets, 2);
  assert.deepEqual(statuses, ["busy", "permission", "busy", "retry", "idle", "idle"]);
});

test("session status handler supports hot-loaded root sessions and ignores headless sessions", async () => {
  const statuses = [];
  let resets = 0;
  const interactiveHandler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });
  await interactiveHandler(event("session.updated", { info: { id: "restored-root", title: "Restored" } }));
  await interactiveHandler(event("session.status", { sessionID: "restored-root", status: { type: "busy" } }));

  const headlessHandler = createSessionTitleStatusHandler({
    isHeadless: () => true,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });
  await headlessHandler(event("session.created", { info: { id: "headless-root" } }));
  await headlessHandler(event("session.status", { sessionID: "headless-root", status: { type: "idle" } }));

  assert.equal(resets, 1);
  assert.deepEqual(statuses, ["busy"]);
});
