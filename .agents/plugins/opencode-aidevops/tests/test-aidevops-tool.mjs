// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";

import { createTools } from "../tools.mjs";

function aidevopsTool(run) {
  return createTools("/tmp/aidevops-test-scripts", () => "", { aidevopsRun: run }).aidevops;
}

test("aidevops tool returns command output", async () => {
  const tool = aidevopsTool((command, timeout) => {
    assert.equal(command, "aidevops status");
    assert.equal(timeout, 15000);
    return "healthy";
  });

  assert.equal(await tool.execute({ command: "status" }), "healthy");
});

test("aidevops tool distinguishes successful empty output", async () => {
  const tool = aidevopsTool(() => "");

  assert.equal(await tool.execute({ command: "status" }), "Command completed: aidevops status");
});

test("aidevops tool rejects non-zero command exits with stderr", async () => {
  const tool = aidevopsTool(() => {
    const error = new Error("command failed");
    error.status = 1;
    error.stderr = Buffer.from("This command must be run with sudo");
    throw error;
  });

  await assert.rejects(
    tool.execute({ command: "approve permissions issue 123 owner/repo --request perm-0000000000000000" }),
    /aidevops command failed \(exit 1\): This command must be run with sudo/,
  );
});

test("aidevops tool reports timeouts without fabricating success", async () => {
  const tool = aidevopsTool(() => {
    const error = new Error("spawn timeout");
    error.code = "ETIMEDOUT";
    throw error;
  });

  await assert.rejects(tool.execute({ command: "status" }), /aidevops command failed \(timed out\)/);
});

test("aidevops tool redacts and bounds failure diagnostics", async () => {
  const tool = aidevopsTool(() => {
    const error = new Error("command failed");
    error.status = 2;
    error.stderr = `API_TOKEN=unsafe-value ${"x".repeat(5000)}`;
    throw error;
  });

  await assert.rejects(tool.execute({ command: "status" }), (error) => {
    assert.match(error.message, /API_TOKEN=\[redacted-credential\]/);
    assert.doesNotMatch(error.message, /unsafe-value/);
    assert.ok(error.message.length < 4200);
    return true;
  });
});

test("aidevops tool redacts complete diagnostics before bounding them", async () => {
  const tool = aidevopsTool(() => {
    const error = new Error("command failed");
    error.status = 2;
    error.stderr = `${"x".repeat(4000)}-----BEGIN PRIVATE KEY-----\nsensitive\n-----END PRIVATE KEY-----`;
    throw error;
  });

  await assert.rejects(tool.execute({ command: "status" }), (error) => {
    assert.match(error.message, /\[redacted-private-key\]/);
    assert.doesNotMatch(error.message, /BEGIN PRIVATE KEY|sensitive/);
    assert.ok(error.message.length < 4200);
    return true;
  });
});
