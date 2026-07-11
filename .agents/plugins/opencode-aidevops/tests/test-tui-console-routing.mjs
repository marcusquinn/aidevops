// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for informational tool telemetry leaking into OpenCode's
// stderr-backed TUI. Tool titles are unbounded payloads (often full commands),
// so they must go to persistent logs rather than console.error.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  installPluginConsoleGuard,
  shouldSuppressPluginConsole,
} from "../plugin-console.mjs";
import { sanitizeOperationTitle } from "../quality-hooks.mjs";

test("payload words cannot promote informational diagnostics into TUI errors", () => {
  const command = "[aidevops] Git operation detected: git add headless-runtime-failure.sh && git commit";
  assert.equal(shouldSuppressPluginConsole([command], false), true);
});

test("actual Error objects and untagged host errors remain visible", () => {
  assert.equal(shouldSuppressPluginConsole(["[aidevops] request failed", new Error("boom")], false), false);
  assert.equal(shouldSuppressPluginConsole(["host error"], false), false);
});

test("debug mode preserves tagged plugin diagnostics", () => {
  assert.equal(shouldSuppressPluginConsole(["[aidevops] diagnostic"], true), false);
});

test("persisted operation titles are redacted, single-line, and bounded", () => {
  const credential = `ghp_${"a".repeat(36)}`;
  const title = `git commit\n${credential}\t${"x".repeat(600)}`;
  const sanitized = sanitizeOperationTitle(title);

  assert.doesNotMatch(sanitized, /[\r\n\t]/);
  assert.doesNotMatch(sanitized, /ghp_/);
  assert.match(sanitized, /\[redacted-credential]/);
  assert.equal(sanitized.length, 500);
});

test("installed guard suppresses tagged strings without writing to stderr", () => {
  const calls = [];
  const fakeConsole = {
    error(...args) {
      calls.push(args);
    },
  };
  const restore = installPluginConsoleGuard(fakeConsole, {});

  fakeConsole.error("[aidevops] Git operation detected: failure.sh");
  fakeConsole.error("host error");
  restore();
  fakeConsole.error("[aidevops] visible after restore");

  assert.deepEqual(calls, [
    ["host error"],
    ["[aidevops] visible after restore"],
  ]);
});
