// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression tests for the OpenCode plugin credential transcript scrubber.
// ---------------------------------------------------------------------------
// The JS hook must mirror the Python and shell scrubbers' boundary invariant:
// credential prefixes embedded mid-word are not credentials, but credentials
// at start-of-string or after non-identifier boundaries are redacted.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-credential-scrub.mjs
// ---------------------------------------------------------------------------

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { scrubCredentials } from "../quality-hooks.mjs";

const REDACTION_TOKEN = "[redacted-credential]";

function assertScrub(input, expected, expectedCount) {
  const { scrubbed, count } = scrubCredentials(input);
  assert.equal(scrubbed, expected);
  assert.equal(count, expectedCount);
}

describe("credential transcript scrub boundary", () => {
  test("does not redact credential prefix embedded mid-word", () => {
    assertScrub("module task-syntheticfixture", "module task-syntheticfixture", 0);
  });

  test("does not redact embedded prefix with long suffix past token length gate", () => {
    assertScrub(
      "url https://example.invalid/vendor-ghp_syntheticIdentifierSuffix",
      "url https://example.invalid/vendor-ghp_syntheticIdentifierSuffix",
      0,
    );
  });

  test("redacts credential after whitespace boundary", () => {
    assertScrub(`API key sk-${"a".repeat(10)} invalid`, `API key ${REDACTION_TOKEN} invalid`, 1);
  });

  test("redacts credential at start of string", () => {
    assertScrub(`ghp_${"b".repeat(10)}`, REDACTION_TOKEN, 1);
  });

  test("redacts credential after colon boundary", () => {
    assertScrub(`token:glpat-${"c".repeat(10)}`, `token:${REDACTION_TOKEN}`, 1);
  });

  test("redacts credential after equals boundary", () => {
    assertScrub(`token=xoxb-${"d".repeat(10)}`, `token=${REDACTION_TOKEN}`, 1);
  });

  test("redacts credential after parenthesis boundary", () => {
    assertScrub(`(${"xoxp-"}${"e".repeat(10)})`, `(${REDACTION_TOKEN})`, 1);
  });
});
