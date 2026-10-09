// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#34138: synthetic event sequences only; no transcripts or private data.

import assert from "node:assert/strict";
import test from "node:test";

import { classifyError, createSessionTurnDiagnostics } from "../session-turn-diagnostics.mjs";

const SENTINEL = "PRIVATE-SENTINEL-7f3a";
const ROOT = "ses_root";

function event(type, properties) {
  return { event: { type, properties } };
}

function fixture({ headless = false, parentID = "", beforeGet = async () => {} } = {}) {
  let current = 1_000_000;
  const toasts = [];
  const logs = [];
  const calls = { abort: 0, prompt: 0 };
  const client = {
    session: {
      abort: async () => { calls.abort += 1; return { data: true }; },
      prompt: async () => { calls.prompt += 1; return { data: true }; },
      get: async () => {
        await beforeGet();
        return { data: { id: ROOT, parentID } };
      },
    },
    tui: { showToast: async (toast) => { toasts.push(toast); } },
  };
  const diagnostics = createSessionTurnDiagnostics({
    client,
    isHeadless: () => headless,
    now: () => current,
    staleMs: 1_000,
    schedule: false,
    log: (level, message) => logs.push(`${level} ${message}`),
  });
  const send = (type, properties) => diagnostics.handleEvent(event(type, { sessionID: ROOT, ...properties }));
  return {
    advance: (milliseconds) => { current += milliseconds; },
    calls,
    diagnostics,
    logs,
    send,
    toasts,
    async startTurn(id = "msg_user_1") {
      await diagnostics.handleEvent(event("message.updated", { info: { id, sessionID: ROOT, role: "user" } }));
      await diagnostics.handleEvent(event("message.part.updated", {
        part: { sessionID: ROOT, messageID: id, type: "text", text: `user asks ${SENTINEL}` },
      }));
      await send("session.status", { status: { type: "busy" } });
    },
    async endTurn() {
      await send("session.status", { status: { type: "idle" } });
      await send("session.idle", {});
    },
  };
}

function assertContentFree(f) {
  const serialized = JSON.stringify({ toasts: f.toasts, logs: f.logs });
  assert.doesNotMatch(serialized, new RegExp(SENTINEL));
  assert.doesNotMatch(serialized, new RegExp(ROOT));
}

function assertNoReplay(f) {
  assert.deepEqual(f.calls, { abort: 0, prompt: 0 });
}

test("an answered turn stays silent", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "text", text: "Blocked: X. Continuing with Y." },
  }));
  await f.endTurn();
  assert.equal(f.toasts.length, 0);
  assertNoReplay(f);
});

test("a turn that ends without visible text reports an unknown-cause no_response once", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "reasoning", text: SENTINEL },
  }));
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "text", text: SENTINEL, synthetic: true },
  }));
  await f.endTurn();
  await f.endTurn();
  assert.equal(f.toasts.length, 1);
  assert.match(f.toasts[0].body.message, /cause is unknown/);
  assert.match(f.toasts[0].body.message, /Nothing was retried automatically/);
  assert.match(f.logs.join("\n"), /outcome=no_response session=sha256:[0-9a-f]{12}/);
  assertContentFree(f);
  assertNoReplay(f);
});

test("a model step that only calls tools and stops is still a missing reply", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "step-start" },
  }));
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "tool", callID: "call_1", tool: "read", state: { status: "completed" } },
  }));
  await f.endTurn();
  assert.equal(f.toasts.length, 1);
  assert.match(f.logs.join("\n"), /outcome=no_response/);
});

test("a user shell command without a model step is not a missing reply", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "tool", callID: "call_1", tool: "bash", state: { status: "completed" } },
  }));
  await f.endTurn();
  assert.equal(f.toasts.length, 0);
  assert.match(f.logs.join("\n"), /outcome=tool_only/);
});

test("user cancellation is classified but never toasted or replayed", async () => {
  const f = fixture();
  await f.startTurn();
  await f.send("session.error", { error: { name: "MessageAbortedError", data: { message: SENTINEL } } });
  await f.endTurn();
  assert.equal(f.toasts.length, 0);
  assert.match(f.logs.join("\n"), /outcome=cancelled/);
  assertContentFree(f);
  assertNoReplay(f);
});

test("provider failure and incomplete stream are explained without response content", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "text", text: "partial" },
  }));
  await f.send("session.error", {
    error: { name: "APIError", data: { statusCode: 503, message: SENTINEL, responseBody: SENTINEL } },
  });
  await f.endTurn();
  assert.equal(f.toasts.length, 1);
  assert.match(f.toasts[0].body.message, /HTTP 503/);
  assert.match(f.toasts[0].body.message, /missing or incomplete/);
  assertContentFree(f);
  assertNoReplay(f);
});

test("403 denials are left to the provider-error handler", async () => {
  const f = fixture();
  await f.startTurn();
  await f.send("session.error", { error: { name: "APIError", data: { statusCode: 403, responseBody: "denied" } } });
  await f.endTurn();
  assert.equal(f.toasts.length, 0);
});

test("a pending permission is reported as a wait, once, and never replayed", async () => {
  const f = fixture();
  await f.startTurn();
  await f.send("permission.asked", { id: "per_1" });
  f.advance(2_000);
  await f.diagnostics.checkNow();
  await f.diagnostics.checkNow();
  assert.equal(f.toasts.length, 1);
  assert.match(f.toasts[0].body.message, /permission reply/);
  assert.match(f.toasts[0].body.message, /paused, not stuck/);
  assertNoReplay(f);
});

test("a long-running tool is reported as a tool wait with only its name", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "tool", callID: "call_1", tool: "bash", state: { status: "running", input: { command: SENTINEL } } },
  }));
  f.advance(2_000);
  await f.diagnostics.checkNow();
  assert.equal(f.toasts.length, 1);
  assert.match(f.toasts[0].body.message, /A bash tool call/);
  assertContentFree(f);
  assertNoReplay(f);
});

test("silence with no tool or permission is no_activity, and activity resets the threshold", async () => {
  const f = fixture();
  await f.startTurn();
  f.advance(500);
  await f.send("message.part.delta", { messageID: "msg_asst_1", delta: SENTINEL });
  f.advance(700);
  assert.deepEqual(await f.diagnostics.checkNow(), []);
  f.advance(400);
  const reported = await f.diagnostics.checkNow();
  assert.deepEqual(reported.map((item) => item.outcome), ["no_activity"]);
  assert.match(f.toasts[0].body.message, /cannot tell a stalled provider stream/);
  assertContentFree(f);
  assertNoReplay(f);
});

test("a queued follow-up during a turn keeps the earlier answer evidence", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { sessionID: ROOT, messageID: "msg_asst_1", type: "text", text: "answer" },
  }));
  await f.diagnostics.handleEvent(event("message.updated", { info: { id: "msg_user_2", sessionID: ROOT, role: "user" } }));
  await f.endTurn();
  assert.equal(f.toasts.length, 0);
});

test("a new turn resets deduplication after a resumed session", async () => {
  const f = fixture();
  await f.startTurn("msg_user_1");
  await f.endTurn();
  await f.startTurn("msg_user_2");
  await f.endTurn();
  assert.equal(f.toasts.length, 2);
});

test("text streamed only as deltas to a known text part counts as a reply", async () => {
  const f = fixture();
  await f.startTurn();
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { id: "prt_text", sessionID: ROOT, messageID: "msg_asst_1", type: "text", text: "" },
  }));
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { id: "prt_reason", sessionID: ROOT, messageID: "msg_asst_1", type: "reasoning", text: "" },
  }));
  await f.send("message.part.delta", { messageID: "msg_asst_1", partID: "prt_reason", field: "text", delta: "thinking" });
  await f.endTurn();
  assert.equal(f.toasts.length, 1, "reasoning deltas are not a visible reply");

  await f.startTurn("msg_user_2");
  await f.diagnostics.handleEvent(event("message.part.updated", {
    part: { id: "prt_text_2", sessionID: ROOT, messageID: "msg_asst_2", type: "text", text: "" },
  }));
  await f.send("message.part.delta", { messageID: "msg_asst_2", partID: "prt_text_2", field: "text", delta: "Done." });
  await f.endTurn();
  assert.equal(f.toasts.length, 1);
});

test("overlapping checks during a slow root lookup deliver one toast", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const f = fixture({ beforeGet: () => gate });
  await f.startTurn();
  f.advance(2_000);
  const first = f.diagnostics.checkNow();
  const second = f.diagnostics.checkNow();
  release();
  await Promise.all([first, second]);
  assert.equal(f.toasts.length, 1);
});

test("a report made stale by a new turn during root lookup is dropped", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const f = fixture({ beforeGet: () => gate });
  await f.startTurn("msg_user_1");
  const ending = f.send("session.idle", {});
  await f.diagnostics.handleEvent(event("message.updated", { info: { id: "msg_user_2", sessionID: ROOT, role: "user" } }));
  release();
  await ending;
  assert.equal(f.toasts.length, 0);
});

test("child sessions and headless runs never toast", async () => {
  const child = fixture({ parentID: "ses_parent" });
  await child.startTurn();
  await child.endTurn();
  assert.equal(child.toasts.length, 0);

  const headless = fixture({ headless: true });
  await headless.startTurn();
  await headless.endTurn();
  assert.equal(headless.toasts.length, 0);
  assert.deepEqual(await headless.diagnostics.checkNow(), []);
});

test("error classification keeps only the error class", () => {
  assert.deepEqual(classifyError({ name: "MessageAbortedError" }), { kind: "cancelled" });
  assert.deepEqual(classifyError({ name: "MessageOutputLengthError" }), { kind: "output_limit" });
  assert.deepEqual(classifyError({ name: "SomethingNew", data: { message: SENTINEL } }), { kind: "runtime_error", name: "unknown" });
  assert.equal(classifyError(null), null);
});
