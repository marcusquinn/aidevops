// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import plugin, {
  computeTerminalTitle,
  createTerminalTitleSync,
  createVersionReader,
  resolveSessionTitleStatus,
  setupTerminalTitle,
} from "../v2-plugin/tui.mjs";

const OWNED_ENV = { AIDEVOPS_TERMINAL_TITLE_OWNER: "aidevops" };

function fakeApi({ route = { type: "session", sessionID: "root" }, status = {}, permission = {}, title = "Fix tabs" } = {}) {
  const writes = [];
  const state = { route, status, permission, title };
  return {
    writes,
    state,
    renderer: { setTerminalTitle: (value) => writes.push(value) },
    ui: { router: { current: () => state.route } },
    data: {
      session: {
        root: (id) => (id === "child" ? "root" : id),
        family: (id) => (id === "root" ? ["root", "child"] : [id]),
        get: (id) => (id === "root" ? { id, title: state.title } : undefined),
        status: (id) => state.status[id] ?? "idle",
        permission: { list: (id) => state.permission[id] },
      },
    },
  };
}

test("V2 TUI plugin module satisfies the OpenCode V2 TUI contract", () => {
  assert.equal(typeof plugin.id, "string");
  assert.ok(plugin.id.length > 0);
  assert.equal(typeof plugin.setup, "function");
});

test("V2 TUI status maps running, permission and idle across the session family", () => {
  assert.equal(resolveSessionTitleStatus(fakeApi().data, "root"), "idle");
  assert.equal(resolveSessionTitleStatus(fakeApi({ status: { child: "running" } }).data, "root"), "busy");
  assert.equal(
    resolveSessionTitleStatus(fakeApi({ status: { root: "running" }, permission: { child: [{ id: "p1" }] } }).data, "child"),
    "permission",
  );
});

test("V2 TUI title decorates root session titles and leaves plugin routes alone", () => {
  assert.equal(computeTerminalTitle(fakeApi({ status: { root: "running" } })), "⚪ Fix tabs");
  assert.equal(computeTerminalTitle(fakeApi({ route: { type: "session", sessionID: "child" } })), "🟢 Fix tabs");
  assert.equal(computeTerminalTitle(fakeApi({ title: "x".repeat(60) })), `🟢 ${"x".repeat(37)}…`);
  assert.equal(computeTerminalTitle(fakeApi({ route: { type: "home" } })), "OpenCode");
  assert.equal(computeTerminalTitle(fakeApi({ route: { type: "plugin", name: "p" } })), "");
});

test("V2 TUI title appends the AIDevOps version like V1 session titles", () => {
  assert.equal(computeTerminalTitle(fakeApi(), "3.37.2"), "🟢 Fix tabs · AIDevOps 3.37.2");
  assert.equal(computeTerminalTitle(fakeApi({ title: "Old · AIDevOps 3.1.0" }), "3.37.2"), "🟢 Old · AIDevOps 3.37.2");
  assert.equal(computeTerminalTitle(fakeApi({ route: { type: "home" } }), "3.37.2"), "OpenCode · AIDevOps 3.37.2");
  assert.equal(computeTerminalTitle(fakeApi({ route: { type: "plugin", name: "p" } }), "3.37.2"), "");
});

test("V2 TUI version reader caches reads and keeps the last value on failure", () => {
  let clock = 0;
  let reads = 0;
  let fail = false;
  const getVersion = createVersionReader({
    agentsDir: "/unused",
    now: () => clock,
    cacheMs: 1000,
    readVersion: () => {
      reads += 1;
      if (fail) throw new Error("unreadable");
      return `3.37.${reads}`;
    },
  });
  assert.equal(getVersion(), "3.37.1");
  clock = 500;
  assert.equal(getVersion(), "3.37.1");
  clock = 1000;
  assert.equal(getVersion(), "3.37.2");
  fail = true;
  clock = 2000;
  assert.equal(getVersion(), "3.37.2");
  assert.equal(reads, 3);
});

test("V2 TUI title sync writes on change, refreshes after native overwrites, and yields to native ownership", () => {
  const api = fakeApi();
  let clock = 1000;
  const sync = createTerminalTitleSync(api, { env: OWNED_ENV, refreshMs: 2000, now: () => clock });
  assert.equal(sync(), true);
  clock += 300;
  assert.equal(sync(), false);
  api.state.status.root = "running";
  assert.equal(sync(), true);
  // Unchanged state is re-applied after refreshMs so a native `OC | …` write cannot stick.
  clock += 2000;
  assert.equal(sync(), true);
  assert.deepEqual(api.writes, ["🟢 Fix tabs", "⚪ Fix tabs", "⚪ Fix tabs"]);
  assert.notEqual(plugin.id, "aidevops");

  const native = fakeApi();
  assert.equal(createTerminalTitleSync(native, { env: { AIDEVOPS_TERMINAL_TITLE_OWNER: "native" } })(), false);
  assert.deepEqual(native.writes, []);
});

test("V2 TUI setup polls with an unref'd timer and returns cleanup", () => {
  const api = fakeApi();
  const calls = { set: 0, clear: 0, unref: 0 };
  const timers = {
    setInterval: (fn, ms) => {
      calls.set += 1;
      assert.equal(ms, 50);
      return { unref: () => { calls.unref += 1; } };
    },
    clearInterval: () => { calls.clear += 1; },
  };
  const cleanup = setupTerminalTitle(api, { env: OWNED_ENV, pollMs: 50, timers, getVersion: () => "3.37.2" });
  assert.deepEqual(api.writes, ["🟢 Fix tabs · AIDevOps 3.37.2"]);
  cleanup();
  assert.deepEqual(calls, { set: 1, clear: 1, unref: 1 });
  assert.equal(setupTerminalTitle(fakeApi(), { env: { AIDEVOPS_TERMINAL_TITLE_OWNER: "native" }, timers }), undefined);
});
