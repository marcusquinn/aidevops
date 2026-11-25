// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { createV2ProviderAuthRuntime } from "../v2-provider-auth.mjs";
import { buildKeepaliveBody } from "../cache-keepalive.mjs";
import { transformRequestBody } from "../provider-auth-request.mjs";

function v2KeepaliveFixture({ status = 200, fetchFails = false } = {}) {
  const account = { email: "keepalive@example.test", access: "initial-token" };
  const sent = [];
  const timers = [];
  const runtime = createV2ProviderAuthRuntime({
    getAccounts: (provider) => provider === "anthropic" ? [account] : [],
    selectRuntimePoolAccount: async () => account,
    ensureValidToken: async () => { account.access = "refreshed-token"; return true; },
    patchAccount: () => {},
    ensureProviderActivation: () => {},
    fetch: async (request) => {
      if (fetchFails) throw new Error("fixture transport failure");
      sent.push({ request, body: await request.json() });
      return Response.json({ usage: { cache_read_input_tokens: 150000, cache_creation_input_tokens: 0 } });
    },
    cacheKeepaliveOptions: {
      setTimer: (fn) => { const timer = { fn }; timers.push(timer); return timer; },
      clearTimer: (timer) => { timer.cleared = true; },
      log: () => {},
    },
  });
  const original = {
    model: "claude-sonnet-5-5", max_tokens: 32000, stream: true,
    system: [{ type: "text", text: "Stable system prefix", cache_control: { type: "ephemeral" } }],
    tools: [{ name: "bash", input_schema: { type: "object" } }],
    messages: [{ role: "user", content: [{ type: "text", text: "Keep unicode café 日本語" }] }],
  };
  const controller = new AbortController();
  const event = {
    sessionID: "keepalive-session", model: { providerID: "anthropic", id: original.model },
    request: new Request("https://example.test/v1/messages", {
      method: "POST", headers: { "content-type": "application/json", "content-length": "999" },
      body: JSON.stringify(original), signal: controller.signal,
    }),
  };
  return {
    runtime, event, controller, sent, original,
    async record() {
      await runtime.httpRequest(event);
      const transformed = await event.request.clone().json();
      await runtime.httpResponse({ ...event, response: new Response("{}", { status }) });
      return transformed;
    },
    async fire() {
      const timer = timers.find((entry) => !entry.cleared && !entry.fired);
      if (!timer) return;
      timer.fired = true;
      timer.fn();
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

test("V2 keep-alive reuses the transformed prefix and fresh seat token only while tools run", async () => {
  const h = v2KeepaliveFixture();
  const transformed = await h.record();
  h.controller.abort(); // A completed host request must not abort the refresh.
  h.runtime.cacheKeepalive.toolStarted(h.event.sessionID, "first");
  h.runtime.cacheKeepalive.toolStarted(h.event.sessionID, "second");
  h.runtime.cacheKeepalive.toolFinished(h.event.sessionID, "first");
  await h.fire();
  assert.equal(h.sent.length, 1);
  const { request, body } = h.sent[0];
  // The billing CCH signs the full body, so it must reflect max_tokens/stream.
  assert.deepEqual(body, JSON.parse(transformRequestBody(
    buildKeepaliveBody(JSON.stringify(h.original)), { sessionID: h.event.sessionID },
  )));
  assert.deepEqual(body.messages, transformed.messages);
  assert.deepEqual(body.tools, transformed.tools);
  assert.equal(body.max_tokens, 1);
  assert.equal(body.stream, false);
  assert.equal(request.headers.get("authorization"), "Bearer refreshed-token");
  assert.equal(request.headers.get("accept"), "application/json");
  assert.equal(request.headers.get("content-length"), null);
  assert.equal(request.signal.aborted, false);
  assert.equal(request.url, h.event.request.url);
  h.runtime.cacheKeepalive.toolFinished(h.event.sessionID, "second");
  await h.fire();
  assert.equal(h.sent.length, 1);
  assert.equal(h.runtime.cacheKeepalive.state(h.event.sessionID), null);
  const source = readFileSync(new URL("../v2.mjs", import.meta.url), "utf8");
  assert.match(source, /cacheKeepalive\.toolStarted\(event.sessionID, event.id\)/);
  assert.match(source, /cacheKeepalive\.toolFinished\(event.sessionID, event.id\)/);
});

test("V2 keep-alive ignores failed responses and tools finished before the first timer", async () => {
  for (const status of [200, 400, 500]) {
    const h = v2KeepaliveFixture({ status });
    await h.record();
    h.runtime.cacheKeepalive.toolStarted(h.event.sessionID, "tool");
    if (status === 200) h.runtime.cacheKeepalive.toolFinished(h.event.sessionID, "tool");
    await h.fire();
    assert.equal(h.sent.length, 0);
    assert.equal(h.runtime.cacheKeepalive.state(h.event.sessionID), null);
  }
});

test("V2 keep-alive obeys the environment opt-out and fails open on transport errors", async () => {
  const previous = process.env.AIDEVOPS_CACHE_KEEPALIVE;
  try {
    process.env.AIDEVOPS_CACHE_KEEPALIVE = "0";
    const disabled = v2KeepaliveFixture();
    await disabled.record();
    disabled.runtime.cacheKeepalive.toolStarted(disabled.event.sessionID, "tool");
    await disabled.fire();
    assert.equal(disabled.sent.length, 0);
    assert.equal(disabled.runtime.cacheKeepalive.state(disabled.event.sessionID), null);
    delete process.env.AIDEVOPS_CACHE_KEEPALIVE;
    const failed = v2KeepaliveFixture({ fetchFails: true });
    await failed.record();
    failed.runtime.cacheKeepalive.toolStarted(failed.event.sessionID, "tool");
    await failed.fire();
    assert.equal(failed.runtime.cacheKeepalive.state(failed.event.sessionID), null);
  } finally {
    if (previous === undefined) delete process.env.AIDEVOPS_CACHE_KEEPALIVE;
    else process.env.AIDEVOPS_CACHE_KEEPALIVE = previous;
  }
});

test("V2 keep-alive disposal clears active sessions and prevents stale timer sends", async () => {
  const h = v2KeepaliveFixture();
  await h.record();
  h.runtime.cacheKeepalive.toolStarted(h.event.sessionID, "tool");
  h.runtime.cacheKeepalive.dispose();
  await h.fire();
  assert.equal(h.sent.length, 0);
  assert.equal(h.runtime.cacheKeepalive.state(h.event.sessionID), null);
  const source = readFileSync(new URL("../v2.mjs", import.meta.url), "utf8");
  assert.match(source, /providerAuth\?\.cacheKeepalive.dispose\(\)/);
});
