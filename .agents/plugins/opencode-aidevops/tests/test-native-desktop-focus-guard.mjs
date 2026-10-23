// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  changesNativeFocus,
  createNativeDesktopFocusGuard,
  DEFAULT_NATIVE_FOCUS_BUDGET,
} from "../native-desktop-focus-guard.mjs";

const RAISE_APPLESCRIPT = 'tell application "System Events" to tell process "Brave Browser"\n  set frontmost to true\n  perform action "AXRaise" of window 1\nend tell';
const RAISE_JXA = "const p = Application('System Events').processes['Brave Browser']; p.frontmost=true; p.windows[0].actions.byName('AXRaise').perform();";

function scriptCall(sessionID, script) {
  return [{ tool: "macos-automator_execute_script", sessionID, callID: `call-${Math.random()}` }, { args: { script_content: script } }];
}

test("classifies the GH#35528 focus-raising scripts and leaves observation alone", () => {
  assert.equal(changesNativeFocus("macos-automator_execute_script", { script_content: RAISE_APPLESCRIPT }), true);
  assert.equal(changesNativeFocus("macos-automator_execute_script", { script_content: RAISE_JXA, language: "javascript" }), true);
  assert.equal(changesNativeFocus("macos-automator_execute_script", { script_content: 'tell application "Safari" to activate' }), true);
  assert.equal(changesNativeFocus("macos-automator_accessibility_query", {
    command: "perform", locator: { app: "Finder", role: "AXWindow", match: {} }, action_to_perform: "AXRaise",
  }), true);
  assert.equal(changesNativeFocus("bash", { command: "osascript -e 'tell application \"Finder\" to activate'" }), true);

  assert.equal(changesNativeFocus("macos-automator_execute_script", { script_content: 'tell application "Safari" to get URL of front document' }), false);
  assert.equal(changesNativeFocus("macos-automator_execute_script", {
    script_content: 'tell application "System Events" to get name of first process whose frontmost is true',
  }), false);
  assert.equal(changesNativeFocus("macos-automator_execute_script", { script_content: "deactivated items" }), false);
  assert.equal(changesNativeFocus("macos-automator_accessibility_query", {
    command: "query", locator: { app: "Finder", role: "AXButton", match: {} },
  }), false);
  assert.equal(changesNativeFocus("macos-automator_accessibility_query", {
    command: "perform", locator: { app: "Finder", role: "AXButton", match: {} }, action_to_perform: "AXPress",
  }), false);
  assert.equal(changesNativeFocus("bash", { command: "echo activate" }), false);
  assert.equal(changesNativeFocus("read", { filePath: "/tmp/activate.png" }), false);
});

test("blocks focus changes beyond the per-turn budget and resets when the turn ends", () => {
  const logs = [];
  const guard = createNativeDesktopFocusGuard({ env: {}, log: (level, message) => logs.push([level, message]) });
  for (let index = 0; index < DEFAULT_NATIVE_FOCUS_BUDGET; index += 1) {
    guard.beforeTool(...scriptCall("child-a", RAISE_APPLESCRIPT));
  }
  assert.throws(() => guard.beforeTool(...scriptCall("child-a", RAISE_JXA)), /Native focus budget exhausted .*bounded handoff/);
  assert.equal(logs.length, 1);
  assert.equal(logs[0][0], "WARN");
  assert.doesNotMatch(logs[0][1], /child-a|Brave/);

  // Non-focus observation keeps working after the budget is spent.
  guard.beforeTool(...scriptCall("child-a", 'tell application "Safari" to get URL of front document'));
  guard.beforeTool({ tool: "macos-automator_accessibility_query", sessionID: "child-a" }, {
    args: { command: "query", locator: { app: "Brave Browser", role: "AXStaticText", match: {} } },
  });

  // Another session is counted independently.
  guard.beforeTool(...scriptCall("child-b", RAISE_APPLESCRIPT));

  guard.handleEvent({ event: { type: "session.idle", properties: { sessionID: "child-a" } } });
  guard.beforeTool(...scriptCall("child-a", RAISE_APPLESCRIPT));

  guard.handleEvent({ event: { type: "session.status", properties: { sessionID: "child-a", status: { type: "idle" } } } });
  for (let index = 0; index < DEFAULT_NATIVE_FOCUS_BUDGET; index += 1) {
    guard.beforeTool(...scriptCall("child-a", RAISE_APPLESCRIPT));
  }
  assert.throws(() => guard.beforeTool(...scriptCall("child-a", RAISE_APPLESCRIPT)), /Native focus budget exhausted/);
});

test("honours an explicit budget override and rejects malformed values", () => {
  const zero = createNativeDesktopFocusGuard({ env: { AIDEVOPS_NATIVE_FOCUS_BUDGET: "0" } });
  assert.throws(() => zero.beforeTool(...scriptCall("s", RAISE_APPLESCRIPT)), /\(0 focus-changing/);

  const wider = createNativeDesktopFocusGuard({ env: { AIDEVOPS_NATIVE_FOCUS_BUDGET: "5" } });
  for (let index = 0; index < 5; index += 1) wider.beforeTool(...scriptCall("s", RAISE_APPLESCRIPT));
  assert.throws(() => wider.beforeTool(...scriptCall("s", RAISE_APPLESCRIPT)), /\(5 focus-changing/);

  const malformed = createNativeDesktopFocusGuard({ env: { AIDEVOPS_NATIVE_FOCUS_BUDGET: "-1" } });
  for (let index = 0; index < DEFAULT_NATIVE_FOCUS_BUDGET; index += 1) malformed.beforeTool(...scriptCall("s", RAISE_APPLESCRIPT));
  assert.throws(() => malformed.beforeTool(...scriptCall("s", RAISE_APPLESCRIPT)), /Native focus budget exhausted/);
});
