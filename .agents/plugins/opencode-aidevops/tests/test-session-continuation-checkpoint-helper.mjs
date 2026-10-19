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
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
