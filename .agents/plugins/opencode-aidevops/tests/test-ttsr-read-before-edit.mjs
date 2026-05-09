// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for GH#23226: read-before-edit is a tool-history
// invariant, not a reliable text-output regex.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-ttsr-read-before-edit.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { BUILTIN_TTSR_RULES, scanForViolations } from "../ttsr-rules.mjs";

function createState() {
  return {
    ttsrRules: [...BUILTIN_TTSR_RULES],
    readIfExists: () => "",
  };
}

describe("TTSR read-before-edit rule", () => {
  test("keeps the read-before-edit instruction in system rules", () => {
    const rule = BUILTIN_TTSR_RULES.find((candidate) => candidate.id === "read-before-edit");

    assert.ok(rule, "read-before-edit rule must remain available");
    assert.match(rule.systemPrompt, /ALWAYS Read a file before Edit or Write/);
  });

  test("does not flag edit intent from plain output text", () => {
    const violations = scanForViolations(
      "I'll edit the existing file now that I have read it.",
      createState(),
    );

    assert.deepEqual(
      violations.filter((violation) => violation.rule.id === "read-before-edit"),
      [],
      "text-only read-before-edit regex must not fire without tool-history context",
    );
  });
});
