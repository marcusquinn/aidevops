// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// t19362 / GH#40283: synthetic event sequences only; no transcripts or private data.

import assert from "node:assert/strict";
import test from "node:test";

import {
  createProviderOverloadRetry,
  isProviderOverloadError,
  overloadRetrySettings,
} from "../provider-overload-retry.mjs";
import { classifyError, shouldNotify } from "../session-turn-outcomes.mjs";

const ROOT = "ses_root_overload";
const SENTINEL = "PRIVATE-SENTINEL-9c21";
const OVERLOAD_529 = {
  name: "APIError",
  data: { statusCode: 529, isRetryable: true, message: "Overloaded", responseBody: `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded ${SENTINEL}"}}` },
};
const STREAM_OVERLOAD = { name: "UnknownError", data: { message: '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' } };

function event(type, properties) {
  return { event: { type, properties } };
}

function fixture({ env = {}, headless = false, parentID = "", status = {}, messages = null } = {}) {
  let current = 1_000_000;
  const timers = [];
  const prompts = [];
  const toasts = [];
  const logs = [];
  const client = {
    session: {
      get: async () => ({ data: { id: ROOT, parentID } }),
      status: async () => ({ data: status }),
      messages: async () => ({ data: messages || [] }),
      promptAsync: async (request) => { prompts.push(request); return { data: true }; },
    },
    tui: { showToast: async (toast) => { toasts.push(toast); } },
  };
  const retry = createProviderOverloadRetry({
    client,
    isHeadless: () => headless,
    env,
    now: () => current,
    setTimer: (callback, delay) => { const timer = { callback, delay, cleared: false }; timers.push(timer); return timer; },
    clearTimer: (timer) => { if (timer) timer.cleared = true; },
    log: (level, message) => logs.push(`${level} ${message}`),
  });
  const send = (type, properties) => retry.handleEvent(event(type, { sessionID: ROOT, ...properties }));
  return {
    client,
    logs,
    prompts,
    retry,
    send,
    status,
    timers,
    toasts,
    advance: (milliseconds) => { current += milliseconds; },
    now: () => current,
    async userMessage(id, extra = {}) {
      await send("message.updated", { info: {
        id, sessionID: ROOT, role: "user", time: { created: current }, agent: "build-plus",
        model: { providerID: "anthropic", modelID: "claude-opus-5-5" }, variant: "high", ...extra,
      } });
    },
    async overload(error = OVERLOAD_529) {
      current += 1_000;
      await send("session.error", { error });
    },
    async fireLatest() {
      const timer = timers.at(-1);
      assert.ok(timer, "a retry timer is scheduled");
      assert.equal(timer.cleared, false, "the latest retry timer is still pending");
      current += timer.delay;
      timer.callback();
      // Let fire() settle its awaited lookups and the prompt call.
      for (let index = 0; index < 10; index += 1) await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

test("classifies overload errors and leaves other provider failures alone", () => {
  assert.equal(isProviderOverloadError(OVERLOAD_529), true);
  assert.equal(isProviderOverloadError(STREAM_OVERLOAD), true);
  assert.equal(isProviderOverloadError({ name: "APIError", data: { statusCode: 503, message: "The server is overloaded" } }), true);
  assert.equal(isProviderOverloadError({ name: "APIError", data: { statusCode: 503, responseBody: '{"error":{"code":"server_is_overloaded"}}' } }), true);
  assert.equal(isProviderOverloadError({ name: "APIError", data: { statusCode: 503, message: "Service Unavailable" } }), false);
  assert.equal(isProviderOverloadError({ name: "APIError", data: { statusCode: 400, message: "prompt mentions overloaded" } }), false);
  assert.equal(isProviderOverloadError({ name: "ProviderAuthError", data: { message: "overloaded" } }), false);
  assert.equal(isProviderOverloadError({ name: "MessageAbortedError", data: { message: "overloaded" } }), false);
  assert.equal(isProviderOverloadError(null), false);
});

test("settings default to a 60 s delay and five attempts, with bounded overrides", () => {
  assert.deepEqual(overloadRetrySettings({}), { enabled: true, delayMs: 60_000, maxAttempts: 5 });
  assert.deepEqual(
    overloadRetrySettings({ AIDEVOPS_OVERLOAD_RETRY: "0", AIDEVOPS_OVERLOAD_RETRY_DELAY_SECONDS: "90", AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS: "2" }),
    { enabled: false, delayMs: 90_000, maxAttempts: 2 },
  );
  assert.deepEqual(
    overloadRetrySettings({ AIDEVOPS_OVERLOAD_RETRY_DELAY_SECONDS: "-5", AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS: "999" }),
    { enabled: true, delayMs: 60_000, maxAttempts: 50 },
  );
});

test("a terminal overload resumes the root session after the delay with the same agent, model and variant", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload();
  assert.equal(f.timers.length, 1);
  assert.equal(f.timers[0].delay, 60_000);
  assert.match(f.toasts[0].body.message, /Retrying automatically in 60s \(attempt 1\/5\)/);

  await f.fireLatest();
  assert.equal(f.prompts.length, 1);
  const { path, body } = f.prompts[0];
  assert.deepEqual(path, { id: ROOT });
  assert.equal(body.agent, "build-plus");
  assert.deepEqual(body.model, { providerID: "anthropic", modelID: "claude-opus-5-5" });
  assert.equal(body.variant, "high");
  assert.equal(body.parts[0].synthetic, true);
  assert.match(body.parts[0].text, /PROVIDER OVERLOAD RETRY \(1\/5\)/);
  assert.match(body.parts[0].text, /Do not repeat side effects/);
});

test("a stream overload without an HTTP status is retried too", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload(STREAM_OVERLOAD);
  await f.fireLatest();
  assert.equal(f.prompts.length, 1);
});

test("a new user message during the delay cancels the retry", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload();
  f.advance(5_000);
  await f.userMessage("msg_user_2");
  assert.equal(f.timers[0].cleared, true);
  assert.equal(f.retry.pendingCount(), 0);
  f.timers[0].callback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.prompts.length, 0);
  assert.ok(f.logs.some((line) => line.includes("cancelled reason=user_message")));
});

test("a re-published older user message does not cancel the retry", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  const created = f.now();
  await f.overload();
  await f.send("message.updated", { info: { id: "msg_user_0", sessionID: ROOT, role: "user", time: { created: created - 10_000 } } });
  await f.fireLatest();
  assert.equal(f.prompts.length, 1);
});

test("a session that became busy is never prompted", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload();
  f.status[ROOT] = { type: "busy" };
  await f.fireLatest();
  assert.equal(f.prompts.length, 0);
  assert.ok(f.logs.some((line) => line.includes("skipped reason=session_busy")));
});

test("an unknown live status or agent/model fails closed with a toast", async () => {
  const unknownStatus = fixture();
  unknownStatus.client.session.status = async () => { throw new Error("unavailable"); };
  await unknownStatus.userMessage("msg_user_1");
  await unknownStatus.overload();
  await unknownStatus.fireLatest();
  assert.equal(unknownStatus.prompts.length, 0);
  assert.ok(unknownStatus.logs.some((line) => line.includes("skipped reason=status_unknown")));
  assert.equal(unknownStatus.toasts.at(-1).body.title, "Automatic retry skipped");

  const unknownIdentity = fixture();
  await unknownIdentity.overload();
  await unknownIdentity.fireLatest();
  assert.equal(unknownIdentity.prompts.length, 0);
  assert.ok(unknownIdentity.logs.some((line) => line.includes("skipped reason=identity_unknown")));
});

test("a user message during the root-session lookup prevents scheduling", async () => {
  const f = fixture();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const get = f.client.session.get;
  f.client.session.get = async (args) => { await gate; return get(args); };
  await f.userMessage("msg_user_1");
  const pending = f.overload();
  await new Promise((resolve) => setImmediate(resolve));
  f.advance(1_000);
  await f.userMessage("msg_user_2");
  release();
  await pending;
  assert.equal(f.timers.length, 0);
  assert.equal(f.toasts.length, 0);
});

test("disabling the retry during the delay stops the pending prompt", async () => {
  const env = {};
  const f = fixture({ env });
  await f.userMessage("msg_user_1");
  await f.overload();
  env.AIDEVOPS_OVERLOAD_RETRY = "0";
  await f.fireLatest();
  assert.equal(f.prompts.length, 0);
  assert.ok(f.logs.some((line) => line.includes("skipped reason=disabled")));
});

test("child, headless and disabled sessions are not retried", async () => {
  for (const options of [{ parentID: "ses_parent" }, { headless: true }, { env: { AIDEVOPS_OVERLOAD_RETRY: "0" } }]) {
    const f = fixture(options);
    await f.userMessage("msg_user_1");
    await f.overload();
    assert.equal(f.timers.length, 0, JSON.stringify(options));
    assert.equal(f.toasts.length, 0, JSON.stringify(options));
  }
});

test("non-overload errors are not retried", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload({ name: "APIError", data: { statusCode: 401, message: "unauthorized" } });
  await f.overload({ name: "MessageAbortedError", data: { message: "aborted" } });
  assert.equal(f.timers.length, 0);
});

test("retries stop after the attempt limit and a completed reply starts a new episode", async () => {
  const f = fixture({ env: { AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS: "2" } });
  await f.userMessage("msg_user_1");
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    await f.overload();
    await f.fireLatest();
    // The continuation's own user message must not reset the episode.
    await f.userMessage(`msg_retry_${attempt}`);
  }
  assert.equal(f.prompts.length, 2);
  await f.overload();
  assert.equal(f.timers.length, 2, "no third retry is scheduled");
  assert.equal(f.toasts.at(-1).body.title, "Provider still overloaded");

  f.advance(1_000);
  await f.send("message.updated", { info: { id: "msg_assistant_ok", sessionID: ROOT, role: "assistant", time: { created: f.now(), completed: f.now() } } });
  await f.overload();
  assert.equal(f.timers.length, 3, "a new episode schedules again");
});

test("falls back to the latest stored user message when none was observed", async () => {
  const messages = [
    { info: { id: "msg_a", role: "user", agent: "plan", model: { providerID: "openai", modelID: "gpt-5.6-sol" }, variant: "medium" } },
    { info: { id: "msg_b", role: "assistant" } },
  ];
  const f = fixture({ messages });
  await f.overload();
  await f.fireLatest();
  assert.equal(f.prompts[0].body.agent, "plan");
  assert.deepEqual(f.prompts[0].body.model, { providerID: "openai", modelID: "gpt-5.6-sol" });
  assert.equal(f.prompts[0].body.variant, "medium");
});

test("logs and toasts stay content-free", async () => {
  const f = fixture();
  await f.userMessage("msg_user_1");
  await f.overload();
  await f.fireLatest();
  const serialized = JSON.stringify({ toasts: f.toasts, logs: f.logs });
  assert.doesNotMatch(serialized, new RegExp(SENTINEL));
  assert.doesNotMatch(serialized, new RegExp(ROOT));
});

test("turn diagnostics stay quiet for an overload only while automatic retry is enabled", () => {
  const error = classifyError(OVERLOAD_529);
  assert.equal(error.overloaded, true);
  const state = { error, notified: new Set() };
  assert.equal(shouldNotify("provider_error", state, {}), false);
  assert.equal(shouldNotify("provider_error", state, { AIDEVOPS_OVERLOAD_RETRY: "0" }), true);
  const other = { error: classifyError({ name: "APIError", data: { statusCode: 503, message: "unavailable" } }), notified: new Set() };
  assert.equal(shouldNotify("provider_error", other, {}), true);
});
