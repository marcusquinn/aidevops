// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#39151: finish=length responses produce exactly one steering note.

import assert from "node:assert/strict";
import test from "node:test";

import { createOutputLimitNotice, OUTPUT_LIMIT_NOTE, EMPTY_TURN_NOTE, EMPTY_TOOL_NOTE, EMPTY_TOOL_ERROR_NOTE } from "../session-turn-state.mjs";

const updated = (info) => ({ type: "message.updated", properties: { info } });

test("finish=length yields one note on the next transform only", () => {
  const notice = createOutputLimitNotice();
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "length" }));
  assert.equal(notice.take("s1"), OUTPUT_LIMIT_NOTE);
  assert.equal(notice.take("s1"), "");
});

test("repeated updates of the same message do not re-arm the note", () => {
  const notice = createOutputLimitNotice();
  const event = updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "length" });
  notice.observe(event);
  assert.equal(notice.take("s1"), OUTPUT_LIMIT_NOTE);
  notice.observe(event);
  assert.equal(notice.take("s1"), "");
});

const part = (p) => ({ type: "message.part.updated", properties: { part: p } });

test("empty assistant message yields the empty-turn note once", () => {
  const notice = createOutputLimitNotice();
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "stop" }));
  assert.equal(notice.take("s1"), EMPTY_TURN_NOTE);
  assert.equal(notice.take("s1"), "");
});

test("message with text or completed tool is not a dead turn", () => {
  const notice = createOutputLimitNotice();
  notice.observe(part({ id: "p1", messageID: "m1", sessionID: "s1", type: "text", text: "hi" }));
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "stop" }));
  notice.observe(part({ id: "p2", messageID: "m2", sessionID: "s1", type: "tool", state: { status: "completed", input: { a: 1 } } }));
  notice.observe(updated({ id: "m2", sessionID: "s1", role: "assistant", finish: "stop" }));
  notice.observe(updated({ id: "m3", sessionID: "s1", role: "assistant", finish: "tool-calls" }));
  assert.equal(notice.take("s1"), "");
});

test("aborted tool part with empty input yields the empty-tool note", () => {
  const notice = createOutputLimitNotice();
  notice.observe(part({ id: "p1", messageID: "m1", sessionID: "s1", type: "tool", state: { status: "error", error: "Tool execution aborted", input: {} } }));
  assert.equal(notice.take("s1"), EMPTY_TOOL_NOTE);
  notice.observe(part({ id: "p2", messageID: "m2", sessionID: "s1", type: "tool", state: { status: "error", input: {} } }));
  assert.equal(notice.take("s1"), EMPTY_TOOL_ERROR_NOTE);
});

test("length finish replaces a pending tool notice", () => {
  const notice = createOutputLimitNotice();
  notice.observe(part({ id: "p1", messageID: "m1", sessionID: "s1", type: "tool", state: { status: "aborted", input: {} } }));
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "length" }));
  assert.equal(notice.take("s1"), OUTPUT_LIMIT_NOTE);
});

test("other finishes, roles and sessions are ignored", () => {
  const notice = createOutputLimitNotice();
  notice.observe(part({ id: "p0", messageID: "m1", sessionID: "s1", type: "text", text: "ok" }));
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "stop" }));
  notice.observe(updated({ id: "m2", sessionID: "s1", role: "user", finish: "length" }));
  notice.observe({ type: "session.idle", properties: { sessionID: "s1" } });
  notice.observe(updated({ id: "m3", sessionID: "s2", role: "assistant", finish: "length" }));
  assert.equal(notice.take("s1"), "");
  assert.equal(notice.take("s2"), OUTPUT_LIMIT_NOTE);
});
