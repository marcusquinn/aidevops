// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createSessionContinuationGuard } from "../session-continuation-guard.mjs";

const fixtureDir = mkdtempSync(join(tmpdir(), "aidevops-continuation-"));

try {
  const repository = join(fixtureDir, "repository");
  const checkpointHelper = join(fixtureDir, "checkpoint-helper.sh");
  mkdirSync(repository);
  writeFileSync(checkpointHelper, `#!/usr/bin/env bash
if [[ "$1" == "recovery-status" && "$2" == "--json" ]]; then
  printf '%s\\n' '{"status":"recovering","unresolved":true,"remaining":"Verify checkpoint recovery"}'
fi
`, { mode: 0o644 });

  const guard = createSessionContinuationGuard({
    repository,
    checkpointHelper: relative(process.cwd(), checkpointHelper),
  });
  const state = guard.getState({ sessionID: "non-executable-helper" });

  assert.equal(state.recovery?.status, "recovering");
  assert.equal(state.recovery?.remaining, "Verify checkpoint recovery");

  for (const [name, payload] of [
    ["null", null],
    ["array", [{ status: "recovering" }]],
    ["primitive", "recovering"],
    ["non-string-status", { status: 1 }],
    ["inactive", { status: "none" }],
  ]) {
    const ignoredGuard = createSessionContinuationGuard({
      repository,
      checkpointAdapter: { load: () => payload },
    });
    const ignoredState = ignoredGuard.getState({ sessionID: `ignored-${name}` });
    assert.equal(ignoredState.recovery, null, `${name} checkpoint payload should be ignored`);
  }

  // GH#33888: a blocker yield with another active todo is steered, never
  // auto-continued; all-blocked, question, human-dependency and malformed
  // inputs keep their current behaviour.
  // GH#34123: steering is model-only. Visible text is never modified; the
  // steering is delivered once as a synthetic message by injectSteering().
  const blockerGuard = createSessionContinuationGuard({ repository, checkpointAdapter: { load: () => null } });
  const writeTodos = (sessionID, todos, callID) => {
    blockerGuard.beforeTool({ sessionID, tool: "todowrite", callID }, { args: { todos } });
    blockerGuard.afterTool({ sessionID, tool: "todowrite", callID }, { output: "ok", metadata: { status: "completed" } });
  };
  const request = (sessionID) => ({ messages: [{ info: { id: "u1", sessionID, role: "user" }, parts: [] }] });
  const mixedTodos = [
    { content: "Run dependency audit", status: "in_progress" },
    { content: "Update the docs", status: "pending" },
    { content: "Write the hook", status: "completed" },
  ];
  writeTodos("mixed", mixedTodos, "c1");
  const blockedText = "BLOCKED: dependency audit fails with a registry error.";
  const mixed = { text: blockedText };
  const mixedResult = blockerGuard.completeText({ sessionID: "mixed" }, mixed);
  assert.equal(mixedResult.corrected, true, "mixed blocked + safe todos should be steered");
  assert.equal(mixed.text, blockedText, "visible text must never be modified");
  assert.equal(blockerGuard.getState({ sessionID: "mixed" }).tasks.length, 2, "steering must not change todo state");
  const nextCall = request("mixed");
  const injected = blockerGuard.injectSteering({ sessionID: "mixed" }, nextCall);
  assert.equal(injected.injected, true, "queued steering reaches the next model call");
  const steeringMessage = nextCall.messages.at(-1);
  assert.equal(steeringMessage.info.role, "user");
  assert.equal(steeringMessage.parts[0].synthetic, true, "steering is a synthetic message");
  assert.match(steeringMessage.parts[0].text, /pauses only its own path/);
  assert.match(steeringMessage.parts[0].text, /Update the docs/);
  assert.equal(blockerGuard.injectSteering({ sessionID: "mixed" }, request("mixed")).injected, false, "steering is delivered once");

  // A later tool call means the text was not the yield, so steering is dropped.
  blockerGuard.completeText({ sessionID: "mixed" }, { text: blockedText });
  blockerGuard.beforeTool({ sessionID: "mixed", tool: "bash", callID: "c3" }, { args: {} });
  assert.equal(blockerGuard.injectSteering({ sessionID: "mixed" }, request("mixed")).injected, false, "a later tool call clears stale steering");

  const whatNextAsk = [
    "PR is open.",
    "",
    "**What next**",
    "- **Session:** fix X — Blocked",
    "- **Needed from you:**",
    "  1. **Approve the release?** (explicit)",
    "- **Left to capture:** None",
    "- **Close:** Not yet: waiting on 1",
    "- **Reply:** `1y`",
  ].join("\n");
  for (const [name, text] of [
    ["question", "Blocked on the audit. Should I skip it?"],
    ["human dependency", "Blocked: this needs your approval to rotate the token."],
    ["no blocker", "Progress update: the hook is written."],
    ["negated blocker", "Docs updated; no blocker remains and the audit is not blocked."],
    ["what next ask", whatNextAsk],
    ["code-span blocker", "The label `BLOCKED` is applied by the pulse."],
    ["malformed", undefined],
  ]) {
    const output = { text };
    const result = blockerGuard.completeText({ sessionID: "mixed" }, output);
    assert.equal(result.corrected, false, `${name} yield should not be steered`);
    assert.equal(output.text, text, `${name} yield text should be unchanged`);
  }
  assert.equal(blockerGuard.injectSteering({ sessionID: "mixed" }, request("mixed")).injected, false, "handbacks queue no steering");

  writeTodos("all-blocked", [{ content: "Run dependency audit", status: "in_progress" }], "c2");
  const single = { text: "BLOCKED: dependency audit fails." };
  assert.equal(blockerGuard.completeText({ sessionID: "all-blocked" }, single).corrected, false, "single blocked todo keeps the stop");
  assert.equal(single.text, "BLOCKED: dependency audit fails.");

  const claim = { text: "The task is complete." };
  assert.equal(blockerGuard.completeText({ sessionID: "mixed" }, claim).corrected, true, "completion claims keep their correction");
  assert.equal(claim.text, "The task is complete.", "completion correction must not modify visible text");
  const claimCall = request("mixed");
  assert.equal(blockerGuard.injectSteering({ sessionID: "mixed" }, claimCall).kind, "completion");
  assert.match(claimCall.messages.at(-1).parts[0].text, /not yet valid/);
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
