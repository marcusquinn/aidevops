// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { collapseRepetitions, repetitionAtTail } from "../compaction-loop-detect.mjs";
import { repairCompactedHistory } from "../compaction-history-repair.mjs";
import { createCompactionLoopGuard } from "../compaction-loop-guard.mjs";
import { findCompactionAnchor } from "../compaction-replay-collect.mjs";
import { CONTINUE_TEXT } from "../compaction-loop-recovery.mjs";

// Shape of the GH#37997 incident: a summary that copies a quoted aim, then
// repeats one ~90-char span of it back-to-back.
const PREFIX = "## Objective\n- **active** — “full-loop the fixes through to release, test for success, and continue refining";
const UNIT = " the shared workflow to improve overall throughput and continue refining";
const looping = (repeats) => PREFIX + UNIT.repeat(repeats);
const CLEAN = [
  "## Objective", "- **active** — “ship the fix”", "", "## Work State",
  "- Completed: PR #1 merged (abc1234).", "- Active: worktree <worktree>, branch bugfix/x.",
  "", "## Next Move", "ACTIVE", "Continuation required: yes",
].join("\n").repeat(3);

test("tail detector flags a back-to-back loop and ignores ordinary summaries", () => {
  const loop = repetitionAtTail(looping(40));
  assert.equal(loop?.period, UNIT.length);
  assert.ok(loop.repeats >= 4);
  assert.equal(repetitionAtTail(looping(5)), null, "short repeats stay below the threshold");
  assert.equal(repetitionAtTail(CLEAN), null);
});

test("collapse keeps one copy of the repeated unit and marks the removal", () => {
  const text = `${looping(60)}\n\n## Next Move\nACTIVE`;
  const collapsed = collapseRepetitions(text);
  assert.equal(collapsed.runs, 1);
  assert.match(collapsed.text, /continue refining the shared workflow to improve overall throughput \[aidevops: removed \d+ chars of repeated summarizer text\]/);
  assert.equal(collapsed.text.split("shared workflow").length, 2, "exactly one copy of the unit survives");
  assert.match(collapsed.text, /## Next Move\nACTIVE$/);
  assert.ok(collapsed.text.length < 600);
  assert.deepEqual(collapseRepetitions(CLEAN), { text: CLEAN, removed: 0, runs: 0 });
});

function msg(id, role, created, extra = {}, parts = []) {
  return { info: { id, role, time: { created }, ...extra }, parts };
}

test("history repair drops failed summaries and applies a misanchored boundary", () => {
  const messages = [
    msg("u0", "user", 1, {}, [{ type: "compaction" }]),
    msg("a0", "assistant", 2, { summary: true, mode: "compaction", parentID: "u0", finish: "stop" }),
    msg("a1", "assistant", 3, { finish: "tool-calls", parentID: "u0" }),
    msg("u1", "user", 4, {}, [{ type: "compaction" }]),
    msg("a2", "assistant", 5, { summary: true, mode: "compaction", parentID: "u1", error: { name: "MessageAbortedError" } }),
    msg("u2", "user", 6, {}, [{ type: "text", text: "what happened?" }]),
    msg("a3", "assistant", 7, { summary: true, mode: "compaction", parentID: "u2", finish: "stop" }),
    msg("u3", "user", 8, {}, [{ type: "text", text: CONTINUE_TEXT, synthetic: true }]),
  ];
  assert.equal(findCompactionAnchor(messages.slice(4)), null, "a typed parent that does not lead is no boundary");
  assert.deepEqual(repairCompactedHistory(messages), { dropped: 1, trimmed: 4 });
  assert.deepEqual(messages.map((m) => m.info.id), ["u2", "a3", "u3"]);
  // Verbatim replay (GH#35186) restores the user turns the trim hid.
  assert.deepEqual(findCompactionAnchor(messages), { anchorIndex: 0, anchorID: "u2", summaryID: "a3", overflow: false });

  const anchored = [
    msg("u1", "user", 1, {}, [{ type: "compaction" }]),
    msg("a1", "assistant", 2, { summary: true, mode: "compaction", parentID: "u1", finish: "stop" }),
    msg("u2", "user", 3, {}, [{ type: "text", text: "next" }]),
  ];
  assert.deepEqual(repairCompactedHistory(anchored), { dropped: 0, trimmed: 0 });
  assert.equal(anchored.length, 3);
});

function fakeClient(calls) {
  const record = (name) => async (request) => {
    calls.push({ name, request });
    return { data: true };
  };
  return {
    session: { abort: record("abort"), summarize: record("summarize"), promptAsync: record("promptAsync") },
    tui: { showToast: record("toast") },
  };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

function startCompaction(guard, { auto = true } = {}) {
  guard.handleEvent({ event: { type: "message.part.updated", properties: { part: { id: "p0", messageID: "u1", sessionID: "s1", type: "compaction", auto } } } });
  guard.chatParams({
    sessionID: "s1",
    agent: "compaction",
    message: { id: "u1", agent: "build", model: { providerID: "anthropic", modelID: "claude-x", variant: "xhigh" } },
  });
  guard.handleEvent({ event: { type: "message.updated", properties: { info: { id: "a1", sessionID: "s1", role: "assistant", mode: "compaction", summary: true, time: { created: 1 } } } } });
}

function stream(guard, text, messageID = "a1") {
  for (let index = 0; index < text.length; index += 40) {
    guard.handleEvent({ event: { type: "message.part.delta", properties: { sessionID: "s1", messageID, partID: `t-${messageID}`, field: "text", delta: text.slice(index, index + 40) } } });
  }
}

function endAborted(guard, messageID = "a1") {
  guard.handleEvent({ event: { type: "message.updated", properties: { info: { id: messageID, sessionID: "s1", role: "assistant", mode: "compaction", summary: true, error: { name: "MessageAbortedError" }, time: { created: 1, completed: 2 } } } } });
  guard.handleEvent({ event: { type: "session.idle", properties: { sessionID: "s1" } } });
}

test("interactive loop is aborted, compaction rerun, and the session continued with its model and variant", async () => {
  const calls = [];
  const logs = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), qualityLog: (level, message) => logs.push(`${level} ${message}`), shouldContinue: async () => true });
  startCompaction(guard);
  stream(guard, looping(80));
  await settle();
  assert.deepEqual(calls.filter((c) => c.name === "abort").map((c) => c.request.path.id), ["s1"]);
  assert.ok(calls.filter((c) => c.name === "abort").length === 1, "one abort per looping summary");
  assert.ok(!calls.some((c) => c.name === "summarize"), "no rerun before the aborted summary ends");

  endAborted(guard);
  await settle();
  await settle();
  const summarize = calls.find((c) => c.name === "summarize");
  assert.deepEqual(summarize.request, { path: { id: "s1" }, body: { providerID: "anthropic", modelID: "claude-x", auto: false } });
  const prompt = calls.find((c) => c.name === "promptAsync");
  assert.deepEqual(prompt.request.body, {
    agent: "build",
    model: { providerID: "anthropic", modelID: "claude-x" },
    variant: "xhigh",
    parts: [{ type: "text", text: CONTINUE_TEXT, synthetic: true }],
  });
  assert.ok(logs.some((line) => line.startsWith("WARN [compaction-loop-guard] repetition loop")));
  assert.ok(logs.every((line) => !line.includes("continue refining")), "logs never carry summary text");
});

test("a loop in the rerun recovers with the original automatic compaction's identity", async () => {
  const calls = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), shouldContinue: async () => true });
  startCompaction(guard);
  stream(guard, looping(80));
  endAborted(guard);
  await settle();
  await settle();
  // The rerun: a manual compaction whose parent has no variant.
  guard.handleEvent({ event: { type: "message.part.updated", properties: { part: { id: "p2", messageID: "u2", sessionID: "s1", type: "compaction", auto: false } } } });
  guard.chatParams({ sessionID: "s1", agent: "compaction", message: { id: "u2", agent: "build", model: { providerID: "anthropic", modelID: "claude-x" } } });
  guard.handleEvent({ event: { type: "message.updated", properties: { info: { id: "a2", sessionID: "s1", role: "assistant", mode: "compaction", summary: true, time: { created: 3 } } } } });
  stream(guard, looping(80), "a2");
  endAborted(guard, "a2");
  await settle();
  await settle();
  assert.equal(calls.filter((c) => c.name === "summarize").length, 2);
  const prompts = calls.filter((c) => c.name === "promptAsync");
  assert.equal(prompts.length, 2, "both reruns continue the automatic compaction");
  assert.equal(prompts.at(-1).request.body.variant, "xhigh");
});

test("manual compaction reruns without a continuation prompt", async () => {
  const calls = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), shouldContinue: async () => true });
  startCompaction(guard, { auto: false });
  stream(guard, looping(80));
  endAborted(guard);
  await settle();
  await settle();
  assert.ok(calls.some((c) => c.name === "summarize"));
  assert.ok(!calls.some((c) => c.name === "promptAsync"));
});

test("retry limit stops rerunning after two loops in the window", async () => {
  const calls = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), shouldContinue: async () => false });
  startCompaction(guard);
  for (const id of ["a1", "a2", "a3"]) {
    guard.handleEvent({ event: { type: "message.updated", properties: { info: { id, sessionID: "s1", role: "assistant", mode: "compaction", summary: true, time: { created: 1 } } } } });
    stream(guard, looping(80), id);
    endAborted(guard, id);
    await settle();
    await settle();
  }
  assert.equal(calls.filter((c) => c.name === "abort").length, 3);
  assert.equal(calls.filter((c) => c.name === "summarize").length, 2);
  assert.ok(!calls.some((c) => c.name === "promptAsync"), "shouldContinue=false blocks the continuation");
});

test("headless runs are never aborted; the completed summary is collapsed instead", async () => {
  const calls = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), isHeadless: () => true });
  startCompaction(guard);
  const text = looping(80);
  stream(guard, text);
  await settle();
  assert.equal(calls.length, 0);
  const output = { text };
  guard.completeText({ sessionID: "s1", messageID: "a1", partID: "t-a1" }, output);
  assert.ok(output.text.length < 600);
  const other = { text };
  guard.completeText({ sessionID: "s1", messageID: "not-a-summary", partID: "x" }, other);
  assert.equal(other.text, text, "only compaction summaries are rewritten");
});

test("AIDEVOPS_COMPACTION_LOOP_GUARD=0 disables every hook", async () => {
  const calls = [];
  const guard = createCompactionLoopGuard({ client: fakeClient(calls), env: { AIDEVOPS_COMPACTION_LOOP_GUARD: "0" } });
  startCompaction(guard);
  stream(guard, looping(80));
  endAborted(guard);
  await settle();
  assert.equal(calls.length, 0);
  const output = { text: looping(80) };
  guard.completeText({ sessionID: "s1", messageID: "a1" }, output);
  assert.equal(output.text, looping(80));
});
