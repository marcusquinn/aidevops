// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

import { createPermissionBroker, sanitizePermissionText } from "../permission-broker.mjs";

test("headless permission event is sanitized, persisted, and rejected", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  const previous = process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: "/Users/example",
  });
  broker.recordToolCall(
    { tool: "read", callID: "call-1" },
    { args: { agent__intent: "Reading SDK declarations token=secret-value" } },
  );
  await broker.handleEvent({ event: { type: "permission.asked", properties: {
    id: "permission-1",
    sessionID: "session-1",
    permission: "external_directory",
    patterns: ["/Users/example/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: { callID: "call-1", messageID: "message-1" },
  } } });
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.issue, "123");
  assert.equal(capture.requests[0].tool, "read");
  assert.match(capture.requests[0].patterns[0], /^~\//);
  assert.doesNotMatch(capture.requests[0].intent, /secret-value/);
  assert.equal(replies[0].body.response, "reject");
  if (previous === undefined) delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
  else process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = previous;
  rmSync(root, { recursive: true, force: true });
});

test("sensitive locations are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example" });
  const output = { status: "ask" };
  await broker.permissionAsk({
    id: "permission-2",
    type: "external_directory",
    pattern: "/Users/example/.ssh/**",
  }, output);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(output.status, "deny");
  assert.equal(capture.requests[0].risk.grantable, false);
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("sanitizer normalizes home and redacts credential-like values", () => {
  const value = sanitizePermissionText("/Users/example/file token=abc123", { home: "/Users/example" });
  assert.equal(value, "~/file token=[REDACTED]");
});
