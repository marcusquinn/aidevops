// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import test from "node:test";
import { assertPlaywriterExplicitlyRequested, createPlaywriterSelectionGuard, resolveLatestUserText } from "../playwriter-selection-guard.mjs";

const task = { tool: "task", args: { subagent_type: "playwriter" } };
const connect = { tool: "aidevops_mcp", args: { action: "connect", name: "playwriter" } };
const blockMessage = "Playwriter (extension relay) is not Playwright. Use subagent_type playwright / @playwright unless the user writes 'Playwriter'.";
const user = (text) => ({ info: { role: "user" }, parts: [{ type: "text", text }] });

test("Task and MCP connect require a case-insensitive explicit user mention", () => {
  for (const selection of [task, connect]) {
    for (const latestUserText of ["use playwright headed", "", "use the browser"]) {
      assert.throws(() => assertPlaywriterExplicitlyRequested({ ...selection, latestUserText }), { message: blockMessage });
    }
    for (const latestUserText of ["connect Playwriter", "use PLAYWRITER", null, undefined]) {
      assert.doesNotThrow(() => assertPlaywriterExplicitlyRequested({ ...selection, latestUserText }));
    }
  }
});

test("Playwright, unrelated tools, and MCP disconnect remain untouched", () => {
  for (const selection of [
    { tool: "task", args: { subagent_type: "playwright" } },
    { tool: "read", args: task.args },
    { tool: "aidevops_mcp", args: { action: "disconnect", name: "playwriter" } },
    { tool: "aidevops_mcp", args: { action: "connect", name: "playwright" } },
  ]) assert.doesNotThrow(() => assertPlaywriterExplicitlyRequested({ ...selection, latestUserText: "browse" }));
});

function fixture(history, { headless = false } = {}) {
  const calls = [];
  const logs = [];
  const client = { session: {
    get: async ({ path }) => {
      calls.push(path.id);
      return { data: { id: path.id, parentID: path.id === "child" ? "root" : undefined } };
    },
    messages: async ({ path }) => {
      assert.equal(path.id, "root");
      return { data: history };
    },
  } };
  return { client, calls, logs, guard: createPlaywriterSelectionGuard({ client, isHeadless: () => headless, log: (...args) => logs.push(args) }) };
}

test("child requests use the latest root user text, not old requests or assistant/synthetic mentions", async () => {
  const history = [user("connect Playwriter"), user("use playwright headed"),
    { info: { role: "assistant" }, parts: [{ type: "text", text: "Playwriter" }] },
    { info: { role: "user" }, parts: [{ type: "text", synthetic: true, text: "Playwriter" }] }];
  const { guard, calls } = fixture(history);
  await assert.rejects(guard({ tool: "task", sessionID: "child" }, { args: { ...task.args, prompt: "Playwriter" } }), { message: blockMessage });
  assert.deepEqual(calls, ["child", "root"]);
  history.push(user("connect Playwriter"));
  await guard({ tool: "aidevops_mcp", sessionID: "root" }, { args: connect.args });
});

test("headless and unrelated calls do not look up messages", async () => {
  const headless = fixture([], { headless: true });
  await headless.guard({ tool: "task", sessionID: "root" }, { args: task.args });
  assert.deepEqual(headless.calls, []);
  const interactive = fixture([]);
  await interactive.guard({ tool: "read" }, { args: task.args });
  assert.deepEqual(interactive.calls, []);
});

test("missing, malformed, failed and timed-out lookups fail open with one warning", async () => {
  for (const history of [[], null, [ { info: { role: "user" } } ]]) {
    const { guard, logs } = fixture(history);
    for (let i = 0; i < 2; i += 1) await guard({ tool: "task", sessionID: "root" }, { args: task.args });
    assert.equal(logs.length, 1);
  }
  const client = { session: { get: async () => { throw new Error("unavailable"); } } };
  assert.equal(await resolveLatestUserText(client, "root"), null);
  client.session.get = () => new Promise(() => {});
  assert.equal(await resolveLatestUserText(client, "root", { timeoutMs: 5 }), null);
});

test("parent cycles fail open and image-only real user messages cannot authorize Playwriter", async () => {
  const { client } = fixture([user("Playwriter"), { info: { role: "user" }, parts: [{ type: "file" }] }]);
  assert.equal(await resolveLatestUserText(client, "root"), "");
  client.session.get = async ({ path }) => ({ data: { id: path.id, parentID: path.id } });
  assert.equal(await resolveLatestUserText(client, "root"), null);
});
