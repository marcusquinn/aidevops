// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#39151: finish=length responses produce exactly one steering note.

import assert from "node:assert/strict";
import test from "node:test";

import { createOutputLimitNotice, OUTPUT_LIMIT_NOTE } from "../session-turn-state.mjs";

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

test("other finishes, roles and sessions are ignored", () => {
  const notice = createOutputLimitNotice();
  notice.observe(updated({ id: "m1", sessionID: "s1", role: "assistant", finish: "stop" }));
  notice.observe(updated({ id: "m2", sessionID: "s1", role: "user", finish: "length" }));
  notice.observe({ type: "session.idle", properties: { sessionID: "s1" } });
  notice.observe(updated({ id: "m3", sessionID: "s2", role: "assistant", finish: "length" }));
  assert.equal(notice.take("s1"), "");
  assert.equal(notice.take("s2"), OUTPUT_LIMIT_NOTE);
});
