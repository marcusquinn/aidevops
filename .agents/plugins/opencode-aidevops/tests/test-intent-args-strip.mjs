// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for GH#25895: intent metadata is schema-injected so it
// can reach the plugin, but must be consumed before executable tool args reach
// OpenCode's host-side validation/execution paths.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { extractAndStoreIntent, consumeIntent } from "../intent-tracing.mjs";

describe("extractAndStoreIntent", () => {
  test("stores and strips agent__intent while preserving Bash workdir", () => {
    const callID = "call-gh-25895-bash";
    const args = {
      command: "git status --short",
      workdir: "/tmp/aidevops-workspace",
      agent__intent: " Inspecting repository state before editing ",
    };

    const intent = extractAndStoreIntent(callID, args);

    assert.equal(intent, "Inspecting repository state before editing");
    assert.equal(consumeIntent(callID), "Inspecting repository state before editing");
    assert.equal(args.workdir, "/tmp/aidevops-workspace");
    assert.ok(!Object.prototype.hasOwnProperty.call(args, "agent__intent"));
  });

  test("strips agent__intent from Read filePath args before execution", () => {
    const callID = "call-gh-25895-read";
    const args = {
      filePath: "/tmp/aidevops-workspace/README.md",
      agent__intent: "Reading a file to understand context",
    };

    extractAndStoreIntent(callID, args);

    assert.equal(consumeIntent(callID), "Reading a file to understand context");
    assert.deepEqual(args, { filePath: "/tmp/aidevops-workspace/README.md" });
  });

  test("strips malformed intent metadata without storing it", () => {
    const callID = "call-gh-25895-custom";
    const args = {
      target: "custom-tool",
      agent__intent: 42,
    };

    const intent = extractAndStoreIntent(callID, args);

    assert.equal(intent, undefined);
    assert.equal(consumeIntent(callID), undefined);
    assert.deepEqual(args, { target: "custom-tool" });
  });

  test("stores intent without throwing for non-configurable args", () => {
    const callID = "call-gh-25992-nonconfigurable";
    const args = { target: "custom-tool" };
    Object.defineProperty(args, "agent__intent", {
      value: "Recording intent from immutable host args",
      configurable: false,
      enumerable: true,
    });

    const intent = extractAndStoreIntent(callID, args);

    assert.equal(intent, "Recording intent from immutable host args");
    assert.equal(consumeIntent(callID), "Recording intent from immutable host args");
    assert.equal(args.agent__intent, "Recording intent from immutable host args");
  });
});
