// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
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

  // GH#35121: a closeout that asks for nothing while files this session
  // edited remain uncommitted is steered toward the Capture Check, across
  // every touched repository. Read-only sessions, asks, committed edits and
  // dirty files the session never edited are left alone.
  const gitIn = (cwd, ...args) => execFileSync("git", ["-C", cwd, ...args], { stdio: "ignore" });
  const makeRepo = (name) => {
    const root = join(fixtureDir, name);
    mkdirSync(root);
    gitIn(root, "init", "-q");
    gitIn(root, "config", "user.email", "fixture@example.invalid");
    gitIn(root, "config", "user.name", "Fixture");
    writeFileSync(join(root, "tracked.md"), "base\n");
    writeFileSync(join(root, "user-owned.md"), "base\n");
    gitIn(root, "add", ".");
    gitIn(root, "-c", "commit.gpgSign=false", "commit", "-qm", "base");
    return root;
  };
  const siteRepo = makeRepo("site");
  const coordRepo = makeRepo("coordinating");
  const captureGuard = createSessionContinuationGuard({ repository: siteRepo, checkpointAdapter: { load: () => null } });
  const runTool = (sessionID, tool, args, callID) => {
    captureGuard.beforeTool({ sessionID, tool, callID }, { args });
    captureGuard.afterTool({ sessionID, tool, callID }, { output: "ok", metadata: { status: "completed" } });
  };
  const closeout = [
    "Changes remain uncommitted and undeployed.",
    "",
    "### What next",
    "- **Needed from you:** Nothing for this validation.",
    "- **Left to capture:** Accessibility results.",
    "- **Close readiness:** Not yet.",
  ].join("\n");

  writeFileSync(join(siteRepo, "tracked.md"), "session edit\n");
  writeFileSync(join(siteRepo, "user-owned.md"), "user edit\n");
  writeFileSync(join(coordRepo, "workflow.md"), "new workflow doc\n");
  runTool("multi", "edit", { filePath: join(siteRepo, "tracked.md"), oldString: "base", newString: "session edit" }, "e1");
  runTool("multi", "apply_patch", { patchText: `*** Begin Patch\n*** Add File: ${join(coordRepo, "workflow.md")}\n+new workflow doc\n*** End Patch` }, "e2");
  runTool("multi", "todowrite", { todos: [{ content: "Validate", status: "completed" }] }, "e3");
  const captureResult = captureGuard.completeText({ sessionID: "multi" }, { text: closeout });
  assert.equal(captureResult.corrected, true, "unasked closeout with dirty session edits is steered");
  assert.equal(captureResult.dirty.length, 2, "both touched repositories are reported");
  const captureCall = request("multi");
  assert.equal(captureGuard.injectSteering({ sessionID: "multi" }, captureCall).kind, "capture");
  const captureText = captureCall.messages.at(-1).parts[0].text;
  assert.match(captureText, /tracked\.md/);
  assert.match(captureText, /workflow\.md/);
  assert.doesNotMatch(captureText, /user-owned\.md/, "dirty files the session never edited are excluded");
  assert.match(captureText, /Not yet/);
  assert.equal(captureGuard.completeText({ sessionID: "multi" }, { text: closeout }).corrected, false, "an unchanged dirty set is steered once");

  const askCloseout = closeout.replace("Nothing for this validation.", "\n  1. **Approve commit and PR for both worktrees?**");
  assert.equal(captureGuard.completeText({ sessionID: "multi-ask" }, { text: askCloseout }).corrected, false, "closeouts with an ask are not steered");
  runTool("multi-ask", "write", { filePath: join(siteRepo, "tracked.md"), content: "x" }, "e4");
  assert.equal(captureGuard.completeText({ sessionID: "multi-ask" }, { text: askCloseout }).corrected, false, "a commit-approval ask satisfies the capture check");

  assert.equal(captureGuard.completeText({ sessionID: "read-only" }, { text: closeout }).corrected, false, "read-only sessions acquire no Git ask");
  runTool("read-only", "read", { filePath: join(siteRepo, "tracked.md") }, "e5");
  assert.equal(captureGuard.completeText({ sessionID: "read-only" }, { text: closeout }).corrected, false, "reads are not edits");

  gitIn(siteRepo, "add", "tracked.md");
  gitIn(siteRepo, "-c", "commit.gpgSign=false", "commit", "-qm", "session edit");
  gitIn(coordRepo, "add", "workflow.md");
  gitIn(coordRepo, "-c", "commit.gpgSign=false", "commit", "-qm", "workflow");
  assert.equal(captureGuard.completeText({ sessionID: "multi" }, { text: closeout }).corrected, false, "committed session edits are captured");

  // GH#35968: repeated-operation cycles of period 1-4, failing or not, are
  // detected; only progress (a new edit or a todo change) clears the window.
  const loopFixture = () => {
    const saved = [];
    const guard = createSessionContinuationGuard({ repository, checkpointAdapter: { load: () => null, save: (recovery) => saved.push(recovery) } });
    let callNumber = 0;
    const call = (tool, args, output, sessionID = "loop") => {
      callNumber += 1;
      const callID = `loop-${callNumber}`;
      guard.beforeTool({ sessionID, tool, callID }, { args });
      return guard.afterTool({ sessionID, tool, callID }, output);
    };
    return { guard, saved, call };
  };
  const failOut = () => ({ output: "error: failed", metadata: { exit: 1 } });
  const okOut = (text = "ok") => ({ output: text, metadata: { status: "completed" } });
  const fires = (steps) => steps.map((step) => step()).flatMap((result, index) => (result.replan ? [index + 1] : []));

  const identical = loopFixture();
  assert.deepEqual(fires(Array.from({ length: 6 }, () => () => identical.call("bash", { command: "A" }, failOut()))), [3], "identical failures fire once at the threshold");
  assert.equal(identical.saved.length, 1);
  assert.match(identical.saved[0].trigger, /^3 identical bash operations failed/);

  const alternating = loopFixture();
  const alternatingResults = Array.from({ length: 20 }, (_, index) => alternating.call("bash", { command: index % 2 ? "B" : "A" }, failOut()));
  assert.deepEqual(alternatingResults.flatMap((result, index) => (result.replan ? [index + 1] : [])), [6], "A/B failures fire once by threshold x period");
  assert.match(alternatingResults[5].correction, /bash -> bash tool-call cycle repeated 3 times with failures/);
  assert.equal(alternating.saved.length, 1, "a failing cycle saves one recovery checkpoint");
  assert.equal(alternating.saved[0].status, "recovering");

  const mixedLoop = loopFixture();
  assert.deepEqual(fires(Array.from({ length: 8 }, (_, index) => () => (index % 2
    ? mixedLoop.call("read", { filePath: "notes.md" }, okOut(`read ${index}`))
    : mixedLoop.call("bash", { command: "npm test" }, failOut())))), [6], "fail/success alternation fires");

  const successLoop = loopFixture();
  const successFires = fires(Array.from({ length: 14 }, (_, index) => () => successLoop.call("bash", { command: index % 2 ? "git status" : "gh pr checks 1" }, okOut("unchanged"))));
  assert.deepEqual(successFires, [10], "identical successful A/B cycles fire after threshold+2 repetitions");
  assert.equal(successLoop.saved.length, 0, "non-progressing successes steer without a recovery checkpoint");
  assert.equal(successLoop.guard.completeText({ sessionID: "loop" }, { text: "The task is complete." }).corrected, false, "a success-only loop never blocks completion");

  const changingOutputs = loopFixture();
  assert.deepEqual(fires(Array.from({ length: 20 }, (_, index) => () => changingOutputs.call("bash", { command: "gh pr checks 1" }, okOut(`pending ${index}`)))), [], "polling with changing output is not a loop");

  const progressing = loopFixture();
  const readThenEdit = [];
  for (let round = 0; round < 4; round += 1) {
    for (const file of ["a.md", "b.md", "c.md"]) readThenEdit.push(() => progressing.call("read", { filePath: file }, okOut("same")));
    readThenEdit.push(() => progressing.call("edit", { filePath: "a.md", oldString: `v${round}`, newString: `v${round + 1}` }, okOut("Edit applied successfully.")));
  }
  assert.deepEqual(fires(readThenEdit), [], "distinct reads followed by new edits are progress");

  const editReset = loopFixture();
  const test = () => editReset.call("bash", { command: "npm test" }, failOut());
  const sameEdit = () => editReset.call("edit", { filePath: "a.md", oldString: "x", newString: "y" }, okOut());
  assert.deepEqual(fires([test, test, test, sameEdit, test, test, test]), [3, 7], "a new edit clears the signalled set so the same loop can fire again");
  assert.equal(editReset.saved.length, 2, "each signalled failing loop saves a recovery checkpoint");
  const windowReset = loopFixture();
  const windowTest = () => windowReset.call("bash", { command: "npm test" }, failOut());
  const windowEdit = () => windowReset.call("edit", { filePath: "a.md", oldString: "x", newString: "y" }, okOut());
  assert.deepEqual(fires([windowTest, windowEdit, windowTest, windowEdit, windowTest, windowEdit, windowTest]), [7], "progress clears stale window entries");
  const reapply = loopFixture();
  const reapplyTest = () => reapply.call("bash", { command: "npm test" }, failOut());
  const reapplyEdit = () => reapply.call("edit", { filePath: "a.md", oldString: "x", newString: "y" }, okOut());
  assert.deepEqual(fires([reapplyEdit, reapplyTest, reapplyEdit, reapplyTest, reapplyEdit, reapplyTest]), [6], "re-applying the same edit is not progress");

  const todoReset = loopFixture();
  const todoFail = () => todoReset.call("bash", { command: "npm test" }, failOut());
  const todoChange = () => todoReset.call("todowrite", { todos: [{ content: "Fix test", status: "in_progress" }] }, okOut());
  assert.deepEqual(fires([todoFail, todoFail, todoFail, todoChange, todoFail, todoFail, todoFail]), [3, 7], "a todo status change clears the signalled set");

  const polling = loopFixture();
  assert.deepEqual(fires(Array.from({ length: 30 }, () => () => polling.call("aidevops_bounded_operation", { action: "status", operation_id: "op-1", wait_seconds: 30 }, okOut("running")))), [], "designed bounded-operation polling is exempt");
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
