// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { checkSecretReadWithApproval, SOURCE_ACCESS_REASON } from "../source-access-approval.mjs";
import { BROKER_PYTHON, sourceAccessVersionChanged } from "../source-access-guidance.mjs";

const requestId = "0123456789abcdef0123456789abcdef";
const gate = () => { throw new Error("[secret-read-guard] blocked read"); };

test("changed deployed VERSION denies a source read and tells the user to restart", () => {
  const root = mkdtempSync(join(tmpdir(), "source-access-version-"));
  const scriptsDir = join(root, "scripts");
  try {
    mkdirSync(scriptsDir);
    writeFileSync(join(root, "VERSION"), "3.37.23\n");
    assert.equal(sourceAccessVersionChanged(scriptsDir, "3.37.22"), true);
    assert.equal(sourceAccessVersionChanged(scriptsDir, "3.37.23"), false);
    assert.equal(sourceAccessVersionChanged(scriptsDir, ""), false);
    assert.throws(() => checkSecretReadWithApproval({
      tool: "read", args: { filePath: "/repo/secret-helper.sh" },
      sessionId: "ses_fixture_123456", scriptsDir, loadedVersion: "3.37.22",
      isReadTool: () => true, secretReadBlockReason: () => SOURCE_ACCESS_REASON,
      checkSecretReadGate: gate,
      brokerMatches: () => { throw new Error("stale plugin must not use broker"); },
      verify: () => { throw new Error("stale plugin must not verify approval"); },
      requestRun: () => { throw new Error("stale plugin must not request approval"); },
    }), /aidevops was updated after this OpenCode session started; restart OpenCode to use the updated source-access flow/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("approval guidance leads with aidevops CLI and keeps the root broker ceremony", () => {
  assert.throws(() => checkSecretReadWithApproval({
    tool: "read", args: { filePath: "/repo/secret-helper.sh" },
    sessionId: "ses_fixture_123456", scriptsDir: "/framework/scripts",
    isReadTool: () => true, secretReadBlockReason: () => SOURCE_ACCESS_REASON,
    checkSecretReadGate: gate, brokerMatches: () => true, verify: () => false,
    requestRun: () => requestId,
  }), (error) => {
    const cli = error.message.indexOf("aidevops source-access status");
    assert.match(BROKER_PYTHON, /^\/.*\/python3$/);
    const broker = error.message.indexOf(`sudo -k ${BROKER_PYTHON} -I -B /etc/aidevops/source-access/source-access-helper.py approve ${requestId} --ttl 12h`);
    assert.ok(cli >= 0 && broker > cli);
    return true;
  });
});

test("broker mismatch identifies the release change and gives one setup command", () => {
  assert.throws(() => checkSecretReadWithApproval({
    tool: "read", args: { filePath: "/repo/secret-helper.sh" },
    sessionId: "ses_fixture_123456", scriptsDir: "/framework/scripts",
    isReadTool: () => true, secretReadBlockReason: () => SOURCE_ACCESS_REASON,
    checkSecretReadGate: gate, brokerMatches: () => false,
    requestRun: () => { throw new Error("must not request"); },
  }), (error) => {
    assert.match(error.message, /This aidevops release changed the root-owned source-access broker/);
    assert.match(error.message, /Run aidevops setup --scope source-access from an interactive terminal/);
    assert.doesNotMatch(error.message, /sudo -k/);
    return true;
  });
});
