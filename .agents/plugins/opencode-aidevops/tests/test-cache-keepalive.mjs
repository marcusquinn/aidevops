// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { buildKeepaliveBody, createCacheKeepalive } from "../cache-keepalive.mjs";

const agentBody = (extra = {}) => JSON.stringify({
  model: "claude-sonnet-5-5",
  max_tokens: 32000,
  stream: true,
  tools: [{ name: "bash", input_schema: { type: "object" } }],
  messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }],
  ...extra,
});

function harness({ status = 200, maxRefreshes = 3 } = {}) {
  const timers = [];
  const sent = [];
  const logs = [];
  const keepalive = createCacheKeepalive({
    send: async (request, body) => {
      sent.push({ request, body: JSON.parse(body) });
      return new Response(JSON.stringify({ usage: { cache_read_input_tokens: 150000, cache_creation_input_tokens: 0 } }), { status });
    },
    setTimer: (fn) => { const t = { fn }; timers.push(t); return t; },
    clearTimer: (t) => { t.cleared = true; },
    enabled: () => true,
    log: (line) => logs.push(line),
    intervalMs: 240000,
    maxRefreshes,
  });
  const fire = async () => {
    const t = timers.filter((x) => !x.cleared && !x.fired).at(-1);
    if (!t) return false;
    t.fired = true;
    await t.fn();
    await new Promise((resolve) => setImmediate(resolve));
    return true;
  };
  return { keepalive, timers, sent, logs, fire };
}

describe("buildKeepaliveBody", () => {
  it("keeps every cache-relevant field and only shrinks the response", () => {
    const body = JSON.parse(buildKeepaliveBody(agentBody({ thinking: { type: "adaptive" }, tool_choice: { type: "auto" } })));
    assert.equal(body.max_tokens, 1);
    assert.equal(body.stream, false);
    assert.deepEqual(body.thinking, { type: "adaptive" });
    assert.deepEqual(body.tool_choice, { type: "auto" });
    assert.equal(body.messages.length, 1);
  });

  it("skips bodies a refresh cannot serve", () => {
    assert.equal(buildKeepaliveBody(agentBody({ tools: [] })), null, "aux request without tools");
    assert.equal(buildKeepaliveBody(agentBody({ stream: false })), null, "non-streamed request");
    assert.equal(buildKeepaliveBody(agentBody({ thinking: { type: "enabled", budget_tokens: 8000 } })), null, "fixed budget");
    assert.equal(buildKeepaliveBody("not json"), null);
    assert.equal(buildKeepaliveBody(undefined), null);
  });
});

describe("createCacheKeepalive", () => {
  it("refreshes only while a tool runs, and stops when it finishes", async () => {
    const h = harness();
    h.keepalive.recordRequest("ses_1", { id: "req" }, agentBody(), 200);
    h.keepalive.toolStarted("ses_1", "call_1");
    assert.equal(await h.fire(), true);
    assert.equal(h.sent.length, 1);
    assert.equal(h.sent[0].body.max_tokens, 1);
    assert.match(h.logs[0], /refresh=1\/3 status=200 cache_read=150000/);
    h.keepalive.toolFinished("ses_1", "call_1");
    await h.fire();
    assert.equal(h.sent.length, 1, "no refresh after the tool finished");
    assert.equal(h.keepalive.state("ses_1"), null);
  });

  it("does nothing for an idle session with no running tool", async () => {
    const h = harness();
    h.keepalive.recordRequest("ses_idle", {}, agentBody(), 200);
    await h.fire();
    assert.equal(h.sent.length, 0);
  });

  it("caps refreshes per gap", async () => {
    const h = harness({ maxRefreshes: 2 });
    h.keepalive.recordRequest("ses_2", {}, agentBody(), 200);
    h.keepalive.toolStarted("ses_2", "c");
    while (await h.fire()) { /* drain */ }
    assert.equal(h.sent.length, 2);
  });

  it("a new request resets the gap and drops the old timer", async () => {
    const h = harness();
    h.keepalive.recordRequest("ses_3", {}, agentBody(), 200);
    h.keepalive.toolStarted("ses_3", "c");
    h.keepalive.recordRequest("ses_3", {}, agentBody(), 200);
    assert.equal(h.timers[0].cleared, true);
    await h.fire();
    assert.equal(h.sent.length, 0, "tools from the previous step no longer count");
  });

  it("stops after a failed refresh and ignores failed requests", async () => {
    const h = harness({ status: 400 });
    h.keepalive.recordRequest("ses_4", {}, agentBody(), 200);
    h.keepalive.toolStarted("ses_4", "c");
    await h.fire();
    assert.equal(h.keepalive.state("ses_4"), null);
    h.keepalive.recordRequest("ses_5", {}, agentBody(), 429);
    assert.equal(h.keepalive.state("ses_5"), null);
  });
});
