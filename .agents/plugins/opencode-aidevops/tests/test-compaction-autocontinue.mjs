// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { createCompactionAutoContinueGuard } from "../compaction-lifecycle.mjs";

function clientFor(session, messages, options = {}) {
  return {
    session: {
      get: async () => {
        if (options.getError) throw new Error("session lookup unavailable");
        return { data: session };
      },
      messages: async () => {
        if (options.messagesError) throw new Error("message lookup unavailable");
        return { data: messages };
      },
    },
  };
}

function assistant(sessionID, finish, overrides = {}) {
  return {
    info: {
      id: `message-${finish || "missing"}`,
      sessionID,
      role: "assistant",
      finish,
      ...overrides,
    },
    parts: [],
  };
}

test("terminal child completion disables synthetic compaction continuation", async () => {
  const sessionID = "child-terminal";
  const logs = [];
  const guard = createCompactionAutoContinueGuard(
    clientFor(
      { id: sessionID, parentID: "parent-session" },
      [assistant(sessionID, "tool-calls"), assistant(sessionID, "stop")],
    ),
    { qualityLog: (level, message) => logs.push({ level, message }) },
  );
  const input = Object.freeze({
    sessionID,
    agent: "research-only",
    model: Object.freeze({ providerID: "openai", modelID: "gpt-5.6-sol" }),
    provider: Object.freeze({ source: "config" }),
    message: Object.freeze({ tools: Object.freeze({ read: true, bash: false }) }),
    overflow: false,
  });
  const before = JSON.stringify(input);
  const output = { enabled: true };

  assert.deepEqual(await guard.autoContinue(input, output), {
    enabled: false,
    reason: "child_terminal",
    finish: "stop",
  });
  assert.equal(output.enabled, false);
  assert.equal(JSON.stringify(input), before, "capability-bearing hook input must remain byte-equivalent");
  assert.equal(logs.length, 1);
  assert.match(logs[0].message, /reason=child_terminal/);
  assert.doesNotMatch(logs[0].message, /child-terminal|parent-session/);
});

test("incomplete child and eligible primary preserve existing continuation state", async () => {
  const childID = "child-incomplete";
  const childGuard = createCompactionAutoContinueGuard(
    clientFor({ id: childID, parentID: "parent" }, [assistant(childID, "tool-calls")]),
  );
  const childOutput = { enabled: true, marker: "unchanged" };
  assert.equal((await childGuard.autoContinue({ sessionID: childID }, childOutput)).enabled, true);
  assert.deepEqual(childOutput, { enabled: true, marker: "unchanged" });

  const primaryID = "primary-incomplete";
  const primaryGuard = createCompactionAutoContinueGuard(
    clientFor({ id: primaryID }, [assistant(primaryID, "stop")]),
  );
  const primaryOutput = { enabled: true };
  assert.deepEqual(await primaryGuard.autoContinue({ sessionID: primaryID }, primaryOutput), {
    enabled: true,
    reason: "primary_session",
  });
  assert.equal(primaryOutput.enabled, true);

  const preDisabled = { enabled: false };
  await primaryGuard.autoContinue({ sessionID: primaryID }, preDisabled);
  assert.equal(preDisabled.enabled, false, "the guard must never widen another lifecycle denial");
});

test("missing or contradictory child lifecycle fails closed with event fallback", async () => {
  const childID = "child-event-fallback";
  const guard = createCompactionAutoContinueGuard(
    clientFor(null, [], { getError: true, messagesError: true }),
  );
  guard.handleEvent({ event: {
    type: "session.created",
    properties: { info: { id: childID, parentID: "parent" } },
  } });
  guard.handleEvent({ event: {
    type: "message.updated",
    properties: { info: { sessionID: childID, role: "assistant", finish: "stop" } },
  } });

  const eventBackedOutput = { enabled: true };
  assert.deepEqual(await guard.autoContinue({ sessionID: childID }, eventBackedOutput), {
    enabled: false,
    reason: "child_terminal",
    finish: "stop",
  });
  assert.equal(eventBackedOutput.enabled, false);

  const malformedID = "child-malformed";
  const malformed = createCompactionAutoContinueGuard(
    clientFor({ id: malformedID, parentID: "parent" }, [
      assistant(malformedID, "stop", { summary: true, mode: "compaction" }),
      assistant(malformedID, "mystery"),
    ]),
  );
  const malformedOutput = { enabled: true };
  assert.deepEqual(await malformed.autoContinue({ sessionID: malformedID }, malformedOutput), {
    enabled: false,
    reason: "child_finish_unknown",
    finish: "mystery",
  });
  assert.equal(malformedOutput.enabled, false);

  const unknownOutput = { enabled: true };
  const unknown = createCompactionAutoContinueGuard(clientFor(null, [], { getError: true }));
  assert.equal((await unknown.autoContinue({ sessionID: "unknown" }, unknownOutput)).reason, "session_lifecycle_unknown");
  assert.equal(unknownOutput.enabled, false);
});
