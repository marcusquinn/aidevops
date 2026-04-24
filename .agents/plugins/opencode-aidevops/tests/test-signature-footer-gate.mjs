// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for the signature footer gate (t2685)
// ---------------------------------------------------------------------------
// Validates that checkSignatureFooterGate (and its helpers) correctly:
//   • detects gh write commands vs unrelated commands
//   • exempts machine-protocol comments (DISPATCH_CLAIM et al)
//   • accepts trusted signals (marker, helper call, footer variable)
//   • auto-repairs simple --body and --body-file commands by mutating args
//   • throws a mentoring error for unparseable commands
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs
// ---------------------------------------------------------------------------

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

import {
  SIG_MARKER,
  isGhWriteCommand,
  isMachineProtocolCommand,
  hasTrustedSignatureSignal,
  tryRepairSignature,
  checkSignatureFooterGate,
} from "../quality-hooks.mjs";

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function setupStubHelper() {
  const dir = mkdtempSync(join(tmpdir(), "t2685-"));
  const helper = join(dir, "gh-signature-helper.sh");
  writeFileSync(
    helper,
    `#!/usr/bin/env bash
# Stub emits a canonical footer with the sig marker.
printf '\\n\\n${SIG_MARKER}\\n---\\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub\\n'
`,
  );
  chmodSync(helper, 0o755);
  return dir;
}

function makeLogger() {
  const entries = [];
  return {
    log: (level, msg) => entries.push({ level, msg }),
    entries,
  };
}

// ---------------------------------------------------------------------------
// isGhWriteCommand
// ---------------------------------------------------------------------------

describe("isGhWriteCommand", () => {
  test("detects gh issue comment", () => {
    assert.equal(isGhWriteCommand('gh issue comment 1 --body "x"'), true);
  });

  test("detects gh issue create", () => {
    assert.equal(isGhWriteCommand('gh issue create --title "t" --body "x"'), true);
  });

  test("detects gh pr create", () => {
    assert.equal(isGhWriteCommand('gh pr create --title "t" --body "x"'), true);
  });

  test("detects gh pr comment", () => {
    assert.equal(isGhWriteCommand('gh pr comment 1 --body "x"'), true);
  });

  test("ignores gh issue view (read)", () => {
    assert.equal(isGhWriteCommand("gh issue view 1"), false);
  });

  test("ignores gh api", () => {
    assert.equal(isGhWriteCommand("gh api /user"), false);
  });

  test("ignores git commit (not gh)", () => {
    assert.equal(isGhWriteCommand('git commit -m "fix"'), false);
  });

  test("ignores commented-out line", () => {
    assert.equal(isGhWriteCommand('# gh issue comment 1 --body "x"'), false);
  });

  test("detects one write line in multi-line command", () => {
    const cmd = `echo hello
gh issue comment 1 --body "x"
echo done`;
    assert.equal(isGhWriteCommand(cmd), true);
  });

  // GH#20735 — false-positive regression tests
  // These cases must NOT be treated as gh write commands.

  test("FP1: heredoc body containing gh issue create prose → ALLOW", () => {
    const cmd = `cat > /tmp/body.md <<'BODY'\nsome prose about gh issue create invocations\nBODY`;
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP1: multi-line heredoc body with gh issue create line → ALLOW", () => {
    const cmd = [
      "cat > /tmp/body.md <<'EOF'",
      "gh issue create --title X --body Y",
      "EOF",
    ].join("\n");
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP2: memory-helper.sh --content quoting gh issue create → ALLOW", () => {
    const cmd =
      'memory-helper.sh store --content "the gh create step fails on label validation"';
    assert.equal(isGhWriteCommand(cmd), false);
  });

  test("FP2: any non-gh tool with quoted gh issue create arg → ALLOW", () => {
    assert.equal(
      isGhWriteCommand('echo "to file a comment, run gh issue comment N"'),
      false,
    );
  });

  test("FP3: rg pattern containing gh issue create → ALLOW", () => {
    assert.equal(isGhWriteCommand('rg "gh issue create" src/'), false);
  });

  test("FP3: grep pattern containing gh pr create → ALLOW", () => {
    assert.equal(
      isGhWriteCommand('grep -n "gh pr create" --include="*.md"'),
      false,
    );
  });

  // Legitimate chained gh invocations must still be detected.

  test("chained: foo && gh issue create → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('foo && gh issue create --title X --body Y'),
      true,
    );
  });

  test("command substitution: $(gh issue comment N) → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('result=$(gh issue comment 123 --body "x")'),
      true,
    );
  });

  test("semicolon chain: setup; gh pr create → BLOCK", () => {
    assert.equal(
      isGhWriteCommand('git add .; gh pr create --title t --body b'),
      true,
    );
  });
});

// ---------------------------------------------------------------------------
// isMachineProtocolCommand
// ---------------------------------------------------------------------------

describe("isMachineProtocolCommand", () => {
  test("detects DISPATCH_CLAIM", () => {
    assert.equal(
      isMachineProtocolCommand(
        'gh issue comment 1 --body "DISPATCH_CLAIM pid=123"',
      ),
      true,
    );
  });

  test("detects KILL_WORKER", () => {
    assert.equal(
      isMachineProtocolCommand('gh issue comment 1 --body "KILL_WORKER reason=foo"'),
      true,
    );
  });

  test("detects MERGE_SUMMARY marker", () => {
    assert.equal(
      isMachineProtocolCommand(
        'gh issue comment 1 --body "<!-- MERGE_SUMMARY -->\\nsummary"',
      ),
      true,
    );
  });

  test("ignores plain prose", () => {
    assert.equal(
      isMachineProtocolCommand('gh issue comment 1 --body "thanks for the fix"'),
      false,
    );
  });
});

// ---------------------------------------------------------------------------
// hasTrustedSignatureSignal
// ---------------------------------------------------------------------------

describe("hasTrustedSignatureSignal", () => {
  test("accepts gh-signature-helper.sh invocation", () => {
    assert.equal(
      hasTrustedSignatureSignal(
        'gh issue comment 1 --body "x $(gh-signature-helper.sh footer)"',
      ),
      true,
    );
  });

  test("accepts inline canonical marker", () => {
    assert.equal(
      hasTrustedSignatureSignal(
        `gh issue comment 1 --body "body\\n\\n${SIG_MARKER}\\n---\\nfooter"`,
      ),
      true,
    );
  });

  test("accepts $FOOTER variable interpolation", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "msg $FOOTER"'),
      true,
    );
  });

  test("accepts ${SIGNATURE} interpolation", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "msg ${SIGNATURE}"'),
      true,
    );
  });

  test("REJECTS bare 'aidevops.sh' literal (t2685 regression)", () => {
    // This is the precise failure mode that t2685 fixes.
    // Prior implementation accepted any command containing "aidevops.sh",
    // so a hallucinated human-readable footer passed the gate.
    assert.equal(
      hasTrustedSignatureSignal(
        'gh issue comment 1 --body "... from aidevops.sh interactive session."',
      ),
      false,
    );
  });

  test("rejects plain prose", () => {
    assert.equal(
      hasTrustedSignatureSignal('gh issue comment 1 --body "thanks"'),
      false,
    );
  });
});

// ---------------------------------------------------------------------------
// tryRepairSignature
// ---------------------------------------------------------------------------

describe("tryRepairSignature", () => {
  test("repairs --body \"...\" by appending sig before closing quote", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.notEqual(out, null);
    assert.ok(out.includes(SIG_MARKER), `expected marker in repaired cmd: ${out}`);
    assert.ok(out.includes("hello"), "original body preserved");
  });

  test("repairs --body=value equals form", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body="hello"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.notEqual(out, null);
    assert.ok(out.includes(SIG_MARKER));
    assert.ok(out.includes("hello"));
  });

  test("appends sig to --body-file on disk", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "body.md");
    writeFileSync(bodyFile, "unsigned content\n");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    const out = tryRepairSignature(cmd, dir, log);
    assert.notEqual(out, null, "repair should succeed on body-file");
    const fileContent = readFileSync(bodyFile, "utf-8");
    assert.ok(
      fileContent.includes(SIG_MARKER),
      `sig should be appended to file: ${fileContent}`,
    );
    assert.ok(fileContent.includes("unsigned content"), "original preserved");
  });

  test("is idempotent on already-signed --body-file", () => {
    const dir = setupStubHelper();
    const bodyFile = join(dir, "signed.md");
    writeFileSync(bodyFile, `already\n\n${SIG_MARKER}\n---\nsig\n`);
    const before = readFileSync(bodyFile, "utf-8");
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --repo o/r --body-file ${bodyFile}`;
    tryRepairSignature(cmd, dir, log);
    const after = readFileSync(bodyFile, "utf-8");
    assert.equal(before, after, "signed file should not be modified");
  });

  test("refuses to repair heredoc-sourced body", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "$(cat <<EOF\nhello\nEOF\n)"';
    const out = tryRepairSignature(cmd, dir, log);
    assert.equal(out, null, "heredoc body should not be auto-repaired");
  });

  test("returns null when helper is missing", () => {
    const missingDir = "/nonexistent/path/aidevops-t2685";
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "x"';
    const out = tryRepairSignature(cmd, missingDir, log);
    assert.equal(out, null);
  });
});

// ---------------------------------------------------------------------------
// checkSignatureFooterGate (end-to-end)
// ---------------------------------------------------------------------------

describe("checkSignatureFooterGate", () => {
  test("no-ops on non-gh-write commands", () => {
    const { log } = makeLogger();
    const output = { args: { command: "ls -la" } };
    // Should not throw, should not mutate
    checkSignatureFooterGate("ls -la", log, "/nonexistent", output);
    assert.equal(output.args.command, "ls -la");
  });

  test("no-ops on machine-protocol commands", () => {
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --body "DISPATCH_CLAIM pid=123"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("no-ops on commands with canonical marker in body", () => {
    const { log } = makeLogger();
    const cmd = `gh issue comment 1 --body "x\\n${SIG_MARKER}\\nfooter"`;
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("no-ops on commands calling gh-signature-helper", () => {
    const { log } = makeLogger();
    const cmd =
      'gh issue comment 1 --body "body $(gh-signature-helper.sh footer)"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, "/nonexistent", output);
    assert.equal(output.args.command, cmd);
  });

  test("REPAIRS simple --body command in place (t2685)", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd = 'gh issue comment 1 --repo o/r --body "hello"';
    const output = { args: { command: cmd } };
    checkSignatureFooterGate(cmd, log, dir, output);
    assert.notEqual(output.args.command, cmd, "command should be mutated");
    assert.ok(
      output.args.command.includes(SIG_MARKER),
      `repaired command should have marker: ${output.args.command}`,
    );
  });

  test("BLOCKS unparseable body (heredoc) with mentoring error", () => {
    const dir = setupStubHelper();
    const { log } = makeLogger();
    const cmd =
      'gh issue comment 1 --body-file <(echo "dynamic body via process subst")';
    const output = { args: { command: cmd } };
    assert.throws(
      () => checkSignatureFooterGate(cmd, log, dir, output),
      /missing signature footer/,
    );
  });

  test("BLOCKS bare 'aidevops.sh' prose (t2685 regression test)", () => {
    // The canonical t2685 failure mode: a command where the body prose
    // contains the literal "aidevops.sh" but no sig marker and no helper
    // invocation. Prior hook accepted this; the tightened hook blocks.
    const dir = setupStubHelper();
    const { log } = makeLogger();
    // Use a body form the repair path cannot safely rewrite (heredoc)
    // so we exercise the block path specifically.
    const cmd =
      'gh issue comment 1 --body <<(cat <<EOF\n... from aidevops.sh session\nEOF\n)';
    const output = { args: { command: cmd } };
    assert.throws(
      () => checkSignatureFooterGate(cmd, log, dir, output),
      /missing signature footer/,
    );
  });
});
