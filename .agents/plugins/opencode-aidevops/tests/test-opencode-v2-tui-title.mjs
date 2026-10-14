// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import plugin, {
  computeTerminalTitle,
  createTerminalTitleSync,
  createTabbyRecoverySync,
  createVersionReader,
  extractPromptRows,
  isPromptsEnabled,
  isTabbyRecoveryEnabled,
  resolveSessionTitleStatus,
  setupPromptsSlot,
  setupTerminalTitle,
} from "../v2-plugin/tui.mjs";

const OWNED_ENV = { AIDEVOPS_TERMINAL_TITLE_OWNER: "aidevops" };

test("prompt rows extract only real V1 text parts, newest first", () => {
  const messages = [
    { id: "first", role: "user" },
    { id: "assistant", role: "assistant" },
    { id: "last", role: "user" },
    { id: "file", role: "user" },
    { id: "compaction", role: "user" },
  ];
  const parts = {
    first: [{ type: "text", text: "  first\n prompt  " }],
    last: [
      { type: "text", text: "injected", synthetic: true },
      { type: "text", text: "ignored", ignored: true },
      { type: "text", text: "newest" },
      { type: "text", text: "prompt" },
    ],
    file: [{ type: "file", text: "not a prompt" }],
    compaction: [{ type: "compaction" }],
  };
  assert.deepEqual(extractPromptRows(messages, (id) => parts[id]), [
    { id: "last", text: "newest prompt" }, { id: "first", text: "first prompt" },
  ]);
  assert.deepEqual(extractPromptRows(messages, () => { throw new Error("missing parts"); }), []);
});

test("V2 prompt rows use type, cap at eight, and truncate without splitting Unicode", () => {
  const messages = Array.from({ length: 12 }, (_, i) => ({ id: String(i), type: "user", text: `prompt ${i}` }));
  messages.push(
    { type: "synthetic", text: "injected" }, { type: "compaction", text: "summary" },
    { type: "user", text: "ignored", ignored: true }, { type: "user", text: "synthetic", synthetic: true },
    { type: "user", text: "\n\t " }, { type: "user", files: ["file"] },
  );
  assert.deepEqual(extractPromptRows(messages).map((row) => row.id), ["11", "10", "9", "8", "7", "6", "5", "4"]);
  assert.deepEqual(extractPromptRows([{ id: "emoji", type: "user", text: "😀abc\n def" }], undefined, { width: 4 }), [
    { id: "emoji", text: "😀ab…" },
  ]);
  assert.equal(extractPromptRows(messages, undefined, { limit: 1 })[0].text, "prompt 11");
  assert.deepEqual(extractPromptRows(undefined), []);
  assert.deepEqual(extractPromptRows(messages, undefined, { limit: 0 }), []);
  assert.equal(extractPromptRows([{ type: "user", text: "x".repeat(35) }])[0].text, `${"x".repeat(33)}…`);
});

function fakePromptsRenderer() {
  const solid = {
    createElement: (type) => ({ type, props: {}, children: [] }),
    setProp: (node, name, value) => { node.props[name] = value; },
    effect: (fn) => fn(),
    insert: (node, child) => node.children.push(child),
  };
  const solidJs = {
    createMemo: (fn) => fn,
    createSignal: (initial) => {
      let value = initial;
      return [() => value, (next) => { value = typeof next === "function" ? next(value) : next; }];
    },
  };
  const nodes = (value) => {
    if (typeof value === "function") return nodes(value());
    if (Array.isArray(value)) return value.flatMap(nodes);
    if (!value || typeof value !== "object") return [];
    return [value, ...value.children.flatMap(nodes)];
  };
  const label = (node) => node.children.map((child) => typeof child === "function" ? child() : child).join("");
  return { loadSolid: async () => solid, loadSolidJs: async () => solidJs, nodes, label };
}

test("V2 Prompts prepends a reactive, collapsible view and dispatches the native timeline", async () => {
  const renderer = fakePromptsRenderer();
  let claim;
  let removed = 0;
  let messages = [{ id: "one", type: "user", text: "first prompt" }];
  const dispatched = [];
  const api = {
    ui: { slot: (value) => { claim = value; return () => { removed += 1; }; } },
    data: { session: { message: { list: (id) => { assert.equal(id, "session"); return messages; } } } },
    theme: { text: { default: "white", subdued: "grey" } },
    keymap: { dispatch: (id) => dispatched.push(id) },
  };
  const cleanup = setupPromptsSlot(api, { env: {}, ...renderer });
  await cleanup.ready;
  assert.equal(claim.prepend, "sidebar.content");
  assert.equal(claim.append, undefined);
  const view = claim.render({ sessionID: "session" });
  const texts = () => renderer.nodes(view).filter((node) => node.type === "text");
  assert.deepEqual(texts().map(renderer.label), ["▼ Prompts", "first prompt"]);
  assert.equal(texts()[1].props.wrapMode, "none");
  texts()[1].props.onMouseUp();
  texts()[0].props.onMouseUp();
  assert.deepEqual(texts().map(renderer.label), ["▶ Prompts", " (1)"]);
  assert.equal(texts()[1].props.fg, "grey");
  texts()[1].props.onMouseUp();
  assert.deepEqual(dispatched, ["session.timeline", "session.timeline"]);
  texts()[0].props.onMouseUp();
  messages.push({ id: "two", type: "user", text: "latest prompt" });
  assert.deepEqual(texts().map(renderer.label), ["▼ Prompts", "latest prompt", "first prompt"]);
  api.keymap.dispatch = () => { throw new Error("unavailable"); };
  assert.doesNotThrow(() => texts()[1].props.onMouseUp());
  delete api.keymap;
  assert.doesNotThrow(() => texts()[1].props.onMouseUp());
  messages = [];
  assert.equal(view(), undefined);
  delete api.data;
  assert.equal(view(), undefined);
  cleanup();
  cleanup();
  assert.equal(removed, 1);
});

test("Prompts opt-out and unavailable APIs/renderers never break setup or disposal", async () => {
  for (const value of ["false", "0", "none", " FALSE "]) {
    assert.equal(isPromptsEnabled({ AIDEVOPS_TUI_PROMPTS: value }), false);
    assert.equal(setupPromptsSlot({ ui: { slot: () => assert.fail("disabled") } }, { env: { AIDEVOPS_TUI_PROMPTS: value } }), undefined);
  }
  assert.equal(isPromptsEnabled({}), true);
  assert.equal(isPromptsEnabled({ AIDEVOPS_TUI_PROMPTS: "true" }), true);
  assert.equal(setupPromptsSlot({}), undefined);
  const unavailable = setupPromptsSlot({ ui: { slot() {} } }, {
    loadSolid: async () => { throw new Error("missing renderer"); }, loadSolidJs: async () => ({}),
  });
  await unavailable.ready;
  unavailable();
  const cancelled = setupPromptsSlot({ ui: { slot: () => assert.fail("disposed before imports resolved") } }, fakePromptsRenderer());
  cancelled();
  await cancelled.ready;
  const missingSlot = setupPromptsSlot({ ui: { slot: () => { throw new Error("missing slot"); } } }, fakePromptsRenderer());
  await missingSlot.ready;
  missingSlot();
});

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

test("V2 TUI records one Tabby recovery marker per routed root session (GH#32700)", () => {
  assert.equal(isTabbyRecoveryEnabled({ AIDEVOPS_TABBY_V2_RECOVERY: "1", XDG_DATA_HOME: "/v2" }), true);
  assert.equal(isTabbyRecoveryEnabled({ AIDEVOPS_TABBY_V2_RECOVERY: "0", XDG_DATA_HOME: "/v2" }), false);
  assert.equal(isTabbyRecoveryEnabled({ AIDEVOPS_TABBY_V2_RECOVERY: "1" }), false);

  const api = fakeApi({ route: { type: "session", sessionID: "child" } });
  let directory;
  api.data.session.get = (id) => (id === "root" && directory ? { id, location: { directory } } : undefined);
  const markers = [];
  const reported = [];
  const sync = createTabbyRecoverySync(api, {
    env: { XDG_DATA_HOME: "/v2" },
    workDir: "/work",
    writeMarker: (marker) => markers.push(marker) && `/work/marker/${marker.sessionID}`,
    writeDirectory: (path) => reported.push(path),
  });
  assert.equal(sync(), false, "unsynced session data is retried later");
  directory = "/repo";
  assert.equal(sync(), true);
  assert.equal(sync(), false, "an unchanged root session is not rewritten");
  assert.deepEqual(markers, [{ sessionID: "root", directory: "/repo", dataDir: "/v2", workDir: "/work", runtime: "v2" }]);
  assert.deepEqual(reported, ["/work/marker/root"]);
  api.state.route = { type: "home" };
  assert.equal(sync(), false, "home keeps the last session marker");
});

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
