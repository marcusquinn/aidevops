// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  extractPromptRows,
  isPromptsEnabled,
  openPromptsTimeline,
  setupPromptsSlot,
} from "../tui-prompts.mjs";

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

test("timeline opens through V1 dispatchCommand or V2 dispatch and never throws", () => {
  const calls = [];
  assert.equal(openPromptsTimeline({ dispatchCommand: (id) => calls.push(`v1:${id}`) }), true);
  assert.equal(openPromptsTimeline({ dispatch: (id) => calls.push(`v2:${id}`) }), true);
  assert.deepEqual(calls, ["v1:session.timeline", "v2:session.timeline"]);
  assert.equal(openPromptsTimeline({ dispatch: () => { throw new Error("unavailable"); } }), false);
  assert.equal(openPromptsTimeline(undefined), false);
});

// Minimal stand-ins for @opentui/solid and solid-js: memos re-run on read and
// inserted functions are resolved when the tree is walked.
const fakeSolid = {
  createElement: (type) => ({ type, props: {}, children: [] }),
  setProp: (node, name, value) => { node.props[name] = value; },
  effect: (fn) => fn(),
  insert: (node, child) => node.children.push(child),
};

function fakeSignal(initial) {
  let value = initial;
  const set = (next) => { value = typeof next === "function" ? next(value) : next; };
  return [() => value, set];
}

const fakeSolidJs = { createMemo: (fn) => fn, createSignal: fakeSignal };

function fakeRenderer() {
  return { loadSolid: async () => fakeSolid, loadSolidJs: async () => fakeSolidJs };
}

function walk(value) {
  const resolved = typeof value === "function" ? value() : value;
  if (Array.isArray(resolved)) return resolved.flatMap(walk);
  const isNode = resolved && typeof resolved === "object";
  return isNode ? [resolved, ...resolved.children.flatMap(walk)] : [];
}

function label(node) {
  return node.children.map((child) => (typeof child === "function" ? child() : child)).join("");
}

test("V2 Prompts prepends a reactive, collapsible view and dispatches the native timeline", async () => {
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
  const cleanup = setupPromptsSlot(api, { env: {}, ...fakeRenderer() });
  await cleanup.ready;
  assert.equal(claim.prepend, "sidebar.content");
  assert.equal(claim.append, undefined);
  const view = claim.render({ sessionID: "session" });
  const texts = () => walk(view).filter((node) => node.type === "text");
  assert.deepEqual(texts().map(label), ["▼ Prompts", "first prompt"]);
  assert.equal(texts()[1].props.wrapMode, "none");
  texts()[1].props.onMouseUp();
  texts()[0].props.onMouseUp();
  assert.deepEqual(texts().map(label), ["▶ Prompts", " (1)"]);
  assert.equal(texts()[1].props.fg, "grey");
  texts()[1].props.onMouseUp();
  assert.deepEqual(dispatched, ["session.timeline", "session.timeline"]);
  texts()[0].props.onMouseUp();
  messages.push({ id: "two", type: "user", text: "latest prompt" });
  assert.deepEqual(texts().map(label), ["▼ Prompts", "latest prompt", "first prompt"]);
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
  const cancelled = setupPromptsSlot({ ui: { slot: () => assert.fail("disposed before imports resolved") } }, fakeRenderer());
  cancelled();
  await cancelled.ready;
  const missingSlot = setupPromptsSlot({ ui: { slot: () => { throw new Error("missing slot"); } } }, fakeRenderer());
  await missingSlot.ready;
  missingSlot();
});
