// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18888/GH#37157: OpenCode 2 adapter for the session bus (session-bus-v2.mjs)
// and the V2 sidebar Messages slot (tui-messages.mjs).

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import * as store from "../session-bus-store.mjs";
import { createSessionBus } from "../session-bus.mjs";
import { createV2SessionBusHooks, normalizeV2BusEvent } from "../session-bus-v2.mjs";
import { setupMessagesSlot } from "../tui-messages.mjs";
import { setupPromptsSlot } from "../tui-prompts.mjs";

// The process kind reads these, so a worker or CI runner would make every
// test bus headless (process-start-identity.mjs isWorkerContext).
const ENV_KEYS = [
  "AIDEVOPS_SESSION_BUS_DIR", "AIDEVOPS_WORKER_ID", "FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS",
  "OPENCODE_HEADLESS", "CLAUDE_HEADLESS", "Claude_HEADLESS", "HEADLESS", "GITHUB_ACTIONS",
  "WORKER_ISSUE_NUMBER", "WORKER_REPO_SLUG", "AIDEVOPS_DISPATCH_TIER", "AIDEVOPS_ATTEMPT_ID", "AIDEVOPS_ATTEMPT_STARTED_AT",
];
let root;
let savedEnv;
const opened = [];
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "session-bus-v2-test-"));
  savedEnv = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]));
  for (const key of ENV_KEYS) delete process.env[key];
  process.env.AIDEVOPS_SESSION_BUS_DIR = root;
});
afterEach(() => {
  for (const bus of opened.splice(0)) bus.dispose();
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  rmSync(root, { recursive: true, force: true });
});

const peer = (id, extra = {}) => ({ session_id: id, handle: `peer-${id.slice(-2)}`, repo: "o/r", branch: "main", origin: "opencode", ...extra });

// V2 plugin context subset: Session.Info keeps the directory in `location`.
function fakeCtx(sessions) {
  const calls = { synthetic: [] };
  return {
    calls,
    session: {
      get: async ({ sessionID }) => sessions[sessionID],
      synthetic: async (input) => {
        calls.synthetic.push(input);
        return { id: `syn_${calls.synthetic.length}` };
      },
    },
  };
}

function v2Hooks(ctx, options = {}) {
  const hooks = createV2SessionBusHooks({ ctx, directory: root, ...options });
  opened.push(hooks);
  return hooks;
}

const v2Event = (type, data) => ({ event: { type, data } });

test("V2 events map onto the bus vocabulary", () => {
  assert.deepEqual(normalizeV2BusEvent({ type: "session.execution.started", data: { sessionID: "ses_a" } }),
    { type: "session.status", properties: { sessionID: "ses_a", status: { type: "busy" } } });
  for (const type of ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"]) {
    assert.equal(normalizeV2BusEvent({ type, data: { sessionID: "ses_a" } }).type, "session.idle");
  }
  const created = normalizeV2BusEvent({ type: "session.created", data: { sessionID: "ses_a", info: { id: "ses_a", location: { directory: "/w/a" } } } });
  assert.equal(created.properties.info.directory, "/w/a");
  assert.deepEqual(normalizeV2BusEvent({ type: "session.created", data: { sessionID: "ses_a" } }).properties, { sessionID: "ses_a" });
  assert.equal(normalizeV2BusEvent({ type: "session.tool.called", data: { sessionID: "ses_a" } }).type, "message.updated");
  assert.equal(normalizeV2BusEvent({ type: "session.deleted", data: { sessionID: "ses_a" } }).properties.sessionID, "ses_a");
  const v1 = { type: "session.idle", properties: { sessionID: "ses_a" } };
  assert.equal(normalizeV2BusEvent(v1), v1);
  assert.equal(normalizeV2BusEvent({}), null);
});

test("V2 publishes root presence and delivers through tool results, prompts and synthetic wakes", async () => {
  const ctx = fakeCtx({
    ses_v2root1: { id: "ses_v2root1", title: "Issue #9: v2", location: { directory: root } },
    ses_v2child: { id: "ses_v2child", parentID: "ses_v2root1", location: { directory: root } },
  });
  const hooks = v2Hooks(ctx);
  assert.equal(hooks.bus.messageable, true);
  const tools = {};
  hooks.addTool(tools, Object.assign((definition) => definition, { schema: fakeSchema() }));
  assert.ok(tools.aidevops_sessions, "messageable V2 processes get the tool");

  await hooks.handleEvent(v2Event("session.created", { sessionID: "ses_v2root1", info: { id: "ses_v2root1", title: "Issue #9: v2", location: { directory: root } } }));
  await hooks.handleEvent(v2Event("session.created", { sessionID: "ses_v2child", info: { id: "ses_v2child", parentID: "ses_v2root1" } }));
  const [presence] = store.readPresence(root);
  assert.equal(presence.session_id, "ses_v2root1");
  assert.equal(presence.issue, 9);
  assert.equal(presence.directory, root);
  assert.equal(store.readPresence(root).length, 1, "child sessions publish no presence");

  // Busy: completed tool results carry messages; failed results claim nothing.
  await hooks.handleEvent(v2Event("session.execution.started", { sessionID: "ses_v2root1" }));
  store.sendMessage(root, { from: peer("ses_peer01"), to: "ses_v2root1", type: "info", text: "FYI merged" });
  const failed = { output: "boom" };
  hooks.toolAfter({ sessionID: "ses_v2root1", tool: "bash", status: "error" }, failed);
  assert.equal(failed.output, "boom");
  const child = { output: "child" };
  hooks.toolAfter({ sessionID: "ses_v2child", tool: "bash", status: "completed" }, child);
  assert.equal(child.output, "child");
  const done = { output: "done" };
  hooks.toolAfter({ sessionID: "ses_v2root1", tool: "bash", status: "completed" }, done);
  assert.match(done.output, /^done\n\n\[aidevops session-bus\] Message/);

  // Next user turn: appended to the prompt text after the user's own words.
  store.sendMessage(root, { from: peer("ses_peer02"), to: "ses_v2root1", type: "info", text: "later" });
  const prompt = { sessionID: "ses_v2root1", messageID: "msg_u2", prompt: { text: "next" } };
  await hooks.prompt(prompt);
  assert.match(prompt.prompt.text, /^next\n\n\[aidevops session-bus\][\s\S]*later/);
  assert.equal(store.pendingMessages(root, "ses_v2root1").length, 0);

  // Idle: info and chat-origin asks wait; an ask wakes with a synthetic message.
  await hooks.handleEvent(v2Event("session.execution.succeeded", { sessionID: "ses_v2root1" }));
  store.sendMessage(root, { from: peer("ses_peer03"), to: "ses_v2root1", type: "info", text: "no wake" });
  store.sendMessage(root, { from: peer("", { handle: "chat:matrix", origin: "chat:matrix:!r" }), to: "ses_v2root1", type: "ask", text: "chat ask" });
  await hooks.bus.tick();
  assert.equal(ctx.calls.synthetic.length, 0, "info and chat-origin messages never wake");
  store.sendMessage(root, { from: peer("ses_peer04"), to: "ses_v2root1", type: "ask", text: "which branch?", hops: 1 });
  await hooks.bus.tick();
  assert.equal(ctx.calls.synthetic.length, 1);
  const [wake] = ctx.calls.synthetic;
  assert.equal(wake.sessionID, "ses_v2root1");
  assert.equal(wake.resume, true);
  assert.match(wake.text, /which branch\?/);

  // The woken turn starts without a prompt hook; it still carries hops forward.
  await hooks.handleEvent(v2Event("session.execution.started", { sessionID: "ses_v2root1" }));
  const sender = await hooks.bus.sender({ sessionID: "ses_v2child" });
  assert.equal(sender.sessionID, "ses_v2root1");
  assert.equal(sender.hops, 2);

  // Rename updates the published title; deletion withdraws presence.
  await hooks.handleEvent(v2Event("session.renamed", { sessionID: "ses_v2root1", title: "PR #44: renamed" }));
  assert.equal(store.readPresence(root)[0].pr, 44);
  await hooks.handleEvent(v2Event("session.deleted", { sessionID: "ses_v2root1" }));
  assert.equal(store.readPresence(root).length, 0);
});

test("headless V2 workers receive at tool results, get no tool or poll and are never woken (t18905)", async () => {
  Object.assign(process.env, { WORKER_ISSUE_NUMBER: "321", WORKER_REPO_SLUG: "o/r", AIDEVOPS_DISPATCH_TIER: "standard" });
  const ctx = fakeCtx({ ses_v2head1: { id: "ses_v2head1", title: "", location: { directory: root } } });
  const hooks = v2Hooks(ctx, { headless: true });
  assert.equal(hooks.bus.messageable, true);
  assert.equal(hooks.bus.wakeable, false);
  assert.equal(hooks.bus.timer, null, "workers run no poll timer");
  const tools = {};
  hooks.addTool(tools, Object.assign((definition) => definition, { schema: fakeSchema() }));
  assert.equal(tools.aidevops_sessions, undefined, "workers get no tool schema");
  await hooks.handleEvent(v2Event("session.created", { sessionID: "ses_v2head1", info: { id: "ses_v2head1", location: { directory: root } } }));
  const [record] = store.readPresence(root);
  assert.equal(record.kind, "headless");
  assert.equal(store.isWorker(record), true);
  assert.equal(record.issue, 321);
  assert.match(record.handle, /-321-worker$/);
  assert.equal(record.worker.repo, "o/r");
  assert.equal(record.worker.tier, "standard");
  assert.match(store.formatPresenceRow(record), /\[worker\]/);

  // The running tool is published with the record and cleared after it.
  hooks.toolBefore({ sessionID: "ses_v2head1", tool: "bash" });
  assert.equal(hooks.bus.record(hooks.bus.state("ses_v2head1")).tool.name, "bash");

  const sender = v2Hooks(fakeCtx({ ses_v2send1: { id: "ses_v2send1", title: "", location: { directory: root } } }));
  const senderTools = {};
  sender.addTool(senderTools, Object.assign((definition) => definition, { schema: fakeSchema() }));
  const sent = await senderTools.aidevops_sessions.execute({ action: "ask", to: "ses_v2head1", text: "still retrying?" }, { sessionID: "ses_v2send1" });
  assert.match(sent, /pulse worker[\s\S]*never woken/);

  // Idle is the end of a worker's run: nothing wakes it.
  await hooks.handleEvent(v2Event("session.execution.succeeded", { sessionID: "ses_v2head1" }));
  await hooks.bus.tick();
  assert.equal(ctx.calls.synthetic.length, 0);
  assert.equal(store.pendingMessages(root, "ses_v2head1").length, 1);

  // A failed result carries nothing; the next completed one carries the ask with CLI reply guidance.
  hooks.toolBefore({ sessionID: "ses_v2head1", tool: "bash" });
  const failed = { output: "boom" };
  hooks.toolAfter({ sessionID: "ses_v2head1", tool: "bash", status: "error" }, failed);
  assert.equal(failed.output, "boom");
  assert.equal(hooks.bus.record(hooks.bus.state("ses_v2head1")).tool, undefined, "a failed tool clears the running tool");
  const done = { output: "ok" };
  hooks.toolAfter({ sessionID: "ses_v2head1", tool: "bash", status: "completed" }, done);
  assert.match(done.output, /answer from your shell: aidevops sessions reply msg_\w+/);
  assert.match(done.output, /you run without a user/);
  assert.equal(store.pendingMessages(root, "ses_v2head1").length, 0);
});

test("a session held by a V1 and a V2 process gets each message exactly once", async () => {
  const info = { id: "ses_shared1", title: "", directory: root };
  const v1 = createSessionBus({
    client: { session: { get: async () => ({ data: info }) } }, directory: root, root, kind: "tui", start: false, git: async () => ({ stdout: "" }),
  });
  opened.push(v1);
  const v2 = v2Hooks(fakeCtx({ ses_shared1: { id: "ses_shared1", title: "", location: { directory: root } } }));
  await v1.handleEvent({ event: { type: "session.created", properties: { info } } });
  await v2.handleEvent(v2Event("session.created", { sessionID: "ses_shared1", info: { id: "ses_shared1", location: { directory: root } } }));
  store.sendMessage(root, { from: peer("ses_peer09"), to: "ses_shared1", type: "info", text: "once" });
  const first = { output: "a" };
  const second = { output: "b" };
  const delivered = v1.toolAfter({ sessionID: "ses_shared1", tool: "bash" }, first);
  v2.toolAfter({ sessionID: "ses_shared1", tool: "bash", status: "completed" }, second);
  const copies = [first.output, second.output].filter((text) => text.includes("once")).length;
  assert.equal(delivered, 1);
  assert.equal(copies, 1);
});

// --- V2 TUI slot -----------------------------------------------------------

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

const renderer = { loadSolid: async () => fakeSolid, loadSolidJs: async () => ({ createMemo: (fn) => fn, createSignal: fakeSignal }) };

function walk(value) {
  const resolved = typeof value === "function" ? value() : value;
  if (Array.isArray(resolved)) return resolved.flatMap(walk);
  return resolved && typeof resolved === "object" ? [resolved, ...resolved.children.flatMap(walk)] : [];
}

const label = (node) => node.children.map((child) => (typeof child === "function" ? child() : child)).join("");

function fakeTimers() {
  const intervals = new Set();
  return {
    intervals,
    setInterval: (fn) => { const handle = { fn }; intervals.add(handle); return handle; },
    clearInterval: (handle) => intervals.delete(handle),
  };
}

test("V2 Messages registers under Prompts, shows root-session rows and honours the switch", async () => {
  const claims = [];
  const dialogs = [];
  const dialog = { alert: (input) => { dialogs.push(input); return Promise.resolve(); }, set: (opts) => dialogs.push(opts) };
  const api = {
    ui: { dialog, slot: (claim) => { claims.push(claim); return () => claims.splice(claims.indexOf(claim), 1); } },
    data: { session: {
      get: (id) => (id === "ses_child" ? { parentID: "ses_root" } : { id }),
      message: { list: () => [{ id: "u1", type: "user", text: "first prompt" }] },
    } },
    theme: { text: { default: "white", subdued: "grey" } },
  };
  const detail = { title: "Message from peer", message: "ID: m1\n\nhi there, in full" };
  let rows = [{ id: "m1", pending: true, direction: "in", text: "• ← peer: hi", detail }];
  const seen = [];
  const timers = fakeTimers();
  const prompts = setupPromptsSlot(api, { env: {}, ...renderer });
  const messages = setupMessagesSlot(api, {
    env: {}, after: prompts.ready, timers, ...renderer,
    readRows: (sessionID) => { seen.push(sessionID); return rows; },
  });
  await messages.ready;
  assert.equal(claims.length, 2);
  assert.ok(claims.every((claim) => claim.prepend === "sidebar.content"));
  assert.equal(label(walk(claims[0].render({ sessionID: "ses_root" })).find((node) => node.type === "text")), "▼ Prompts");

  const view = claims[1].render({ sessionID: "ses_child" });
  const texts = () => walk(view).filter((node) => node.type === "text");
  assert.deepEqual(texts().map(label), ["▼ Messages", "• ← peer: hi"]);
  assert.equal(seen.at(-1), "ses_root", "a subagent view shows its root session's traffic");
  assert.equal(texts()[1].props.fg, "white", "undelivered rows stay prominent");
  texts()[1].props.onMouseUp();
  assert.deepEqual(dialogs, [detail, { size: "large" }], "a row click opens the full message");
  rows = [...rows, { id: "m2", pending: false, direction: "out", text: "→ peer: ok" }];
  assert.equal(texts()[2].props.fg, "grey");
  texts()[0].props.onMouseUp();
  assert.deepEqual(texts().map(label), ["▶ Messages", " (2)"]);
  rows = [];
  assert.equal(walk(view).length, 0, "hidden without traffic");

  assert.equal(timers.intervals.size, 1);
  messages();
  assert.equal(timers.intervals.size, 0);
  assert.equal(claims.length, 1);
  prompts();

  assert.equal(setupMessagesSlot(api, { env: { AIDEVOPS_TUI_MESSAGES: "false" }, ...renderer }), undefined);
});

function fakeSchema() {
  const chain = () => ({ optional: chain, int: chain, min: chain, max: chain });
  return { enum: chain, string: chain, number: chain };
}
