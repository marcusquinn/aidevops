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

  // GH#33888: a blocker yield with another active todo is annotated, never
  // auto-continued; all-blocked, question, human-dependency and malformed
  // inputs keep their current behaviour.
  const blockerGuard = createSessionContinuationGuard({ repository, checkpointAdapter: { load: () => null } });
  const writeTodos = (sessionID, todos, callID) => {
    blockerGuard.beforeTool({ sessionID, tool: "todowrite", callID }, { args: { todos } });
    blockerGuard.afterTool({ sessionID, tool: "todowrite", callID }, { output: "ok", metadata: { status: "completed" } });
  };
  const mixedTodos = [
    { content: "Run dependency audit", status: "in_progress" },
    { content: "Update the docs", status: "pending" },
    { content: "Write the hook", status: "completed" },
  ];
  writeTodos("mixed", mixedTodos, "c1");
  const mixed = { text: "BLOCKED: dependency audit fails with a registry error." };
  const mixedResult = blockerGuard.completeText({ sessionID: "mixed" }, mixed);
  assert.equal(mixedResult.corrected, true, "mixed blocked + safe todos should be annotated");
  assert.match(mixed.text, /SESSION_CONTINUATION_BLOCKER/);
  assert.match(mixed.text, /pauses only its own path/);
  assert.match(mixed.text, /Update the docs/);
  assert.equal(blockerGuard.getState({ sessionID: "mixed" }).tasks.length, 2, "annotation must not change todo state");
  const annotated = mixed.text;
  blockerGuard.completeText({ sessionID: "mixed" }, mixed);
  assert.equal(mixed.text, annotated, "annotation is idempotent");

  for (const [name, text] of [
    ["question", "Blocked on the audit. Should I skip it?"],
    ["human dependency", "Blocked: this needs your approval to rotate the token."],
    ["no blocker", "Progress update: the hook is written."],
    ["code-span blocker", "The label `BLOCKED` is applied by the pulse."],
    ["malformed", undefined],
  ]) {
    const output = { text };
    const result = blockerGuard.completeText({ sessionID: "mixed" }, output);
    assert.equal(result.corrected, false, `${name} yield should not be annotated`);
    assert.equal(output.text, text, `${name} yield text should be unchanged`);
  }

  writeTodos("all-blocked", [{ content: "Run dependency audit", status: "in_progress" }], "c2");
  const single = { text: "BLOCKED: dependency audit fails." };
  assert.equal(blockerGuard.completeText({ sessionID: "all-blocked" }, single).corrected, false, "single blocked todo keeps the stop");
  assert.equal(single.text, "BLOCKED: dependency audit fails.");

  const claim = { text: "The task is complete." };
  assert.equal(blockerGuard.completeText({ sessionID: "mixed" }, claim).corrected, true, "completion claims keep their correction");
  assert.match(claim.text, /SESSION_CONTINUATION_GUARD/);
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
