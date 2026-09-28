// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#32834: plugin state root must match the broker's platform default,
// and snapshots under both the current and legacy roots stay unreadable.

import test from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";

import { SOURCE_ACCESS_REASON, checkSecretReadWithApproval } from "../source-access-approval.mjs";
import { DEFAULT_STATE_DIR } from "../source-access-manifest-approval.mjs";

const fail = (label) => () => {
  throw new Error(`${label} must not run`);
};

function readAttempt(filePath) {
  return checkSecretReadWithApproval({
    tool: "read",
    args: { filePath },
    sessionId: "ses_fixture_123456",
    callId: "call_fixture_123456",
    scriptsDir: "/framework/scripts",
    isReadTool: (tool) => tool.toLowerCase() === "read",
    secretReadBlockReason: () => SOURCE_ACCESS_REASON,
    brokerMatches: () => true,
    checkSecretReadGate: fail("gate"),
    verify: fail("verifier"),
    requestRun: fail("request helper"),
  });
}

test("plugin default state root matches the broker platform default", () => {
  assert.equal(DEFAULT_STATE_DIR, process.platform === "darwin"
    ? "/private/var/db/aidevops/source-access"
    : "/var/run/aidevops/source-access");
});

test("snapshot and bundle reads are denied under current and legacy roots", () => {
  for (const root of [DEFAULT_STATE_DIR, "/var/run/aidevops/source-access"]) {
    for (const directory of ["snapshots", "bundles"]) {
      assert.throws(() => readAttempt(join(root, directory, "501", "example.source")),
        /direct reads of approval snapshots are denied/);
    }
  }
});
