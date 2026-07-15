// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  appendWorkerBlockerEvent,
  normalizeWorkerBlockerEvent,
  WORKER_BLOCKER_SCHEMA,
} from "../../../scripts/worker-blocker-log.mjs";

const LOGGER_PATH = fileURLToPath(new URL("../../../scripts/worker-blocker-log.mjs", import.meta.url));

function appendInSubprocess(logPath, event) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [LOGGER_PATH, "append", "--log-file", logPath, "--event", event]);
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`blocker logger exited ${code}: ${stderr}`));
    });
  });
}

test("worker blocker event normalization redacts credentials and local paths", () => {
  const event = normalizeWorkerBlockerEvent({
    event: "permission_request_captured",
    reason: "permission_required",
    detail: "/Users/example/worktree token=secret-value credential=placeholder-value Authorization: Bearer bearer-value",
    repo_slug: "Owner/Repo",
    issue_number: "123",
  }, { home: "/Users/example", workDir: "/Users/example/worktree", now: new Date("2026-07-14T12:00:00Z") });
  assert.equal(event.schema, WORKER_BLOCKER_SCHEMA);
  assert.equal(event.repo_slug, "owner/repo");
  assert.equal(event.issue_number, 123);
  assert.doesNotMatch(event.detail, /secret-value|placeholder-value|bearer-value|ghp_|\/Users\/example/);
  assert.match(event.detail, /\$WORKTREE|~/);
});

test("append trims oldest complete records before the bounded log exceeds its cap", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blockers-"));
  const logPath = join(root, "worker-progress-blockers.jsonl");
  const maxBytes = 1_200;
  for (let index = 0; index < 20; index++) {
    assert.equal(appendWorkerBlockerEvent({
      event: `event-${index}`,
      reason: "permission_required",
      source: "test",
      issue_number: 123,
      repo_slug: "owner/repo",
      session_key: "issue-123",
      detail: "bounded append fixture",
    }, { logPath, maxBytes }), true);
  }
  const content = readFileSync(logPath, "utf8");
  const events = content.trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(statSync(logPath).size <= maxBytes);
  assert.equal(statSync(logPath).mode & 0o777, 0o600);
  assert.equal(events.at(-1).event, "event-19");
  assert.equal(events.some((event) => event.event === "event-0"), false);
  rmSync(root, { recursive: true, force: true });
});

test("append fails open when the parent path is not a directory", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-parent-"));
  const parentFile = join(root, "not-a-directory");
  writeFileSync(parentFile, "occupied");
  assert.equal(appendWorkerBlockerEvent(
    { event: "permission_blocked" },
    { logPath: join(parentFile, "events.jsonl") },
  ), false);
  rmSync(root, { recursive: true, force: true });
});

test("append rejects symlinked logs", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-symlink-"));
  const target = join(root, "target.txt");
  const logPath = join(root, "events.jsonl");
  writeFileSync(target, "unchanged");
  symlinkSync(target, logPath);
  assert.equal(appendWorkerBlockerEvent({ event: "permission_blocked" }, { logPath }), false);
  assert.equal(readFileSync(target, "utf8"), "unchanged");
  rmSync(root, { recursive: true, force: true });
});

test("append reclaims a stale owned lock", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-stale-"));
  const logPath = join(root, "events.jsonl");
  const lockPath = `${logPath}.lock`;
  writeFileSync(lockPath, "abandoned", { mode: 0o600 });
  const staleTime = new Date(Date.now() - 60_000);
  utimesSync(lockPath, staleTime, staleTime);
  assert.equal(appendWorkerBlockerEvent({ event: "permission_blocked" }, { logPath }), true);
  assert.equal(JSON.parse(readFileSync(logPath, "utf8")).event, "permission_blocked");
  rmSync(root, { recursive: true, force: true });
});

test("parallel appenders recover after a stale reclaim lock", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-reclaim-"));
  const logPath = join(root, "events.jsonl");
  const reclaimPath = `${logPath}.lock.reclaim`;
  writeFileSync(reclaimPath, "abandoned", { mode: 0o600 });
  const staleTime = new Date(Date.now() - 60_000);
  utimesSync(reclaimPath, staleTime, staleTime);
  const eventNames = Array.from({ length: 12 }, (_, index) => `recovered-${index}`);
  await Promise.all(eventNames.map((event) => appendInSubprocess(logPath, event)));
  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(new Set(events.map((event) => event.event)), new Set(eventNames));
  rmSync(root, { recursive: true, force: true });
});

test("concurrent appenders preserve complete JSONL records", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-concurrent-"));
  const logPath = join(root, "events.jsonl");
  const eventNames = Array.from({ length: 12 }, (_, index) => `concurrent-${index}`);
  await Promise.all(eventNames.map((event) => appendInSubprocess(logPath, event)));
  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(new Set(events.map((event) => event.event)), new Set(eventNames));
  rmSync(root, { recursive: true, force: true });
});
