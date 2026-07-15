// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "child_process";
import { createHash } from "crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

import { registerApprovedWorkerPermissions } from "../config-hook.mjs";

function blockerEvents(root) {
  return readFileSync(join(root, "blockers.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
}

function signedGrant(root, options = {}) {
  const key = join(root, "approval.key");
  execFileSync("ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", key]);
  const payload = JSON.stringify({
    schema: "aidevops-permission-grant/v1",
    authority: "worker-permissions",
    target: { kind: "issue", repository: "owner/repo", number: 123 },
    request_id: "perm-0123456789abcdef",
    request_sha256: "a".repeat(64),
    worker: {
      session: "issue-123",
      branch: options.branch === undefined ? "feature/auto-gh123" : options.branch,
      worktree_sha256: createHash("sha256").update(root).digest("hex"),
    },
    capabilities: [{
      permission: options.permission || "external_directory",
      patterns: [options.pattern || "~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
      tool: "read",
      intent: "Inspect generated SDK declarations",
      risk: { level: "medium", grantable: true, reason: "external directory" },
    }],
    issued_at: options.issuedAt || new Date().toISOString(),
    expires_at: options.expiresAt || new Date(Date.now() + 60_000).toISOString(),
  });
  const signed = spawnSync("ssh-keygen", ["-Y", "sign", "-f", key, "-n", "aidevops-approve", "-q", "-"], {
    input: payload,
    encoding: "utf8",
  });
  assert.equal(signed.status, 0, signed.stderr);
  const grantPath = join(root, "grant.json");
  writeFileSync(grantPath, JSON.stringify({ payload, signature: signed.stdout }));
  return { grantPath, publicKey: `${key}.pub` };
}

test("verified unexpired grant adds exact rules globally and per agent", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
  const grant = signedGrant(root);
  const old = { issue: process.env.WORKER_ISSUE_NUMBER, repo: process.env.WORKER_REPO_SLUG };
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  process.env.WORKER_SESSION_KEY = "issue-123";
  const config = { agent: { review: { permission: { read: "allow" } } } };
  assert.equal(registerApprovedWorkerPermissions(config, {
    grantPath: grant.grantPath, publicKey: grant.publicKey, tempBase: root, repositoryDir: root,
    currentSession: "issue-123", currentBranch: "feature/auto-gh123", pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 2);
  const pattern = "~/.cache/opencode/node_modules/@opencode-ai/sdk/**";
  assert.equal(config.permission.external_directory[pattern], "allow");
  assert.equal(config.agent.review.permission.external_directory[pattern], "allow");
  assert.equal(blockerEvents(root).at(-1).blocking, false);
  for (const [key, value] of Object.entries({ WORKER_ISSUE_NUMBER: old.issue, WORKER_REPO_SLUG: old.repo })) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  rmSync(root, { recursive: true, force: true });
});

test("expired grant is ignored even with a valid signature", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
  const grant = signedGrant(root, { expiresAt: new Date(Date.now() - 60_000).toISOString() });
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  const config = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(config, {
    grantPath: grant.grantPath, publicKey: grant.publicKey, tempBase: root, repositoryDir: root,
    currentSession: "issue-123", currentBranch: "feature/auto-gh123", pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(config.permission, undefined);
  assert.equal(blockerEvents(root).at(-1).reason, "grant_expired");
  rmSync(root, { recursive: true, force: true });
});

test("grant cannot be replayed from a different worktree", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
  const grant = signedGrant(root);
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  const config = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(config, {
    grantPath: grant.grantPath,
    publicKey: grant.publicKey,
    tempBase: root,
    repositoryDir: join(root, "different-worktree"),
    currentSession: "issue-123",
    currentBranch: "feature/auto-gh123",
    pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(config.permission, undefined);
  assert.equal(blockerEvents(root).at(-1).reason, "grant_worktree_mismatch");
  const differentSessionConfig = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(differentSessionConfig, {
    grantPath: grant.grantPath,
    publicKey: grant.publicKey,
    tempBase: root,
    repositoryDir: root,
    currentSession: "issue-999",
    currentBranch: "feature/auto-gh123",
    pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(differentSessionConfig.permission, undefined);
  assert.equal(blockerEvents(root).at(-1).session_key, "issue-999");
  const differentRequestConfig = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(differentRequestConfig, {
    grantPath: grant.grantPath,
    publicKey: grant.publicKey,
    tempBase: root,
    repositoryDir: root,
    currentSession: "issue-123",
    currentBranch: "feature/auto-gh123",
    pendingRequest: "perm-fedcba9876543210",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(blockerEvents(root).at(-1).request_id, "perm-fedcba9876543210");
  rmSync(root, { recursive: true, force: true });
});

test("branch lookup failure cannot match a null grant branch", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
  const grant = signedGrant(root, { branch: null });
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  const config = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(config, {
    grantPath: grant.grantPath,
    publicKey: grant.publicKey,
    tempBase: root,
    repositoryDir: root,
    currentSession: "issue-123",
    pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(config.permission, undefined);
  rmSync(root, { recursive: true, force: true });
});

test("signature verification temp failure ignores the grant without crashing", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
  const grant = signedGrant(root);
  const blocker = join(root, "not-a-directory");
  writeFileSync(blocker, "block");
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  const config = { agent: {} };
  assert.equal(registerApprovedWorkerPermissions(config, {
    grantPath: grant.grantPath,
    publicKey: grant.publicKey,
    tempBase: join(blocker, "verification"),
    repositoryDir: root,
    currentSession: "issue-123",
    currentBranch: "feature/auto-gh123",
    pendingRequest: "perm-0123456789abcdef",
    blockerLogPath: join(root, "blockers.jsonl"),
  }), 0);
  assert.equal(config.permission, undefined);
  rmSync(root, { recursive: true, force: true });
});

for (const [name, options] of [
  ["sensitive signed grant", { pattern: "~/.ssh/**" }],
  ["unbounded signed grant", { pattern: "**" }],
  ["action-only signed grant", { permission: "webfetch", pattern: "example.invalid" }],
  ["grant longer than four hours", {
    issuedAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 5 * 60 * 60 * 1000).toISOString(),
  }],
]) {
  test(`${name} is ignored`, () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-worker-grant-"));
    const grant = signedGrant(root, options);
    process.env.WORKER_ISSUE_NUMBER = "123";
    process.env.WORKER_REPO_SLUG = "owner/repo";
    const config = { agent: {} };
    assert.equal(registerApprovedWorkerPermissions(config, {
      grantPath: grant.grantPath, publicKey: grant.publicKey, tempBase: root, repositoryDir: root,
      currentSession: "issue-123", currentBranch: "feature/auto-gh123", pendingRequest: "perm-0123456789abcdef",
      blockerLogPath: join(root, "blockers.jsonl"),
    }), 0);
    assert.equal(config.permission, undefined);
    rmSync(root, { recursive: true, force: true });
  });
}
