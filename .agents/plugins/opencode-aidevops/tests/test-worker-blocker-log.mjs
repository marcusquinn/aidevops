// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  appendWorkerBlockerEvent,
  normalizeWorkerBlockerEvent,
  WORKER_BLOCKER_SCHEMA,
} from "../../../scripts/worker-blocker-log.mjs";
import {
  listActiveWorkerBlockerIssues,
  resolveStaleSupervisorWorkerBlockers,
  resolveWorkerBlockersForIssue,
  resolveWorkerBlockersForSession,
} from "../../../scripts/worker-blocker-reconcile.mjs";

const LOGGER_PATH = fileURLToPath(new URL("../../../scripts/worker-blocker-log.mjs", import.meta.url));
const CLI_PATH = fileURLToPath(new URL("../../../scripts/worker-blocker-cli.mjs", import.meta.url));

test("deployed symlink entrypoints execute commands and report invalid commands", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-blocker-entry-"));
  try {
    const scriptsLink = join(root, "deployed scripts");
    symlinkSync(dirname(CLI_PATH), scriptsLink, "dir");
    for (const name of ["worker-blocker-cli.mjs", "worker-blocker-log.mjs"]) {
      const entry = join(scriptsLink, name);
      const logPath = join(root, `${name}.jsonl`);
      const result = spawnSync(process.execPath, [entry, "append", "--log-file", logPath,
        "--event", "permission_request_captured", "--repo-slug", "owner/repo", "--issue-number", "123"], { encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(JSON.parse(readFileSync(logPath, "utf8")).event, "permission_request_captured");
      const invalid = spawnSync(process.execPath, [entry, "unknown-command"], { encoding: "utf8" });
      assert.equal(invalid.status, 2, invalid.stderr);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

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

test("resolve-issue clears every active identity exactly once and preserves correlation", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-resolve-"));
  const logPath = join(root, "events.jsonl");
  const base = {
    reason: "permission_required",
    source: "test",
    issue_number: 123,
    repo_slug: "Owner/Repo",
  };
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    event: "permission_request_captured",
    session_key: "issue-123",
    request_id: "request-a",
  }, { logPath, now: new Date("2026-07-24T12:00:00Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    event: "permission_request_non_grantable",
    session_key: "issue-123-retry",
    request_id: "request-b",
  }, { logPath, now: new Date("2026-07-24T12:00:01Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    event: "permission_grant_applied",
    blocking: false,
    session_key: "issue-123-cleared",
    request_id: "request-c",
  }, { logPath, now: new Date("2026-07-24T12:00:02Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    issue_number: 124,
    session_key: "issue-124",
  }, { logPath, now: new Date("2026-07-24T12:00:03Z") }), true);

  const resolution = resolveWorkerBlockersForIssue({
    issue_number: "123",
    repo_slug: "OWNER/REPO",
    event: "issue_terminal_reconciled",
    reason: "issue_closed_completed",
    source: "dispatch-label-cleanup",
  }, { logPath, now: new Date("2026-07-24T12:00:04Z") });
  assert.deepEqual(resolution, { ok: true, resolvedCount: 2 });

  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const terminal = events.filter((event) => event.event === "issue_terminal_reconciled");
  assert.deepEqual(new Set(terminal.map((event) => event.session_key)), new Set(["issue-123", "issue-123-retry"]));
  assert.deepEqual(new Set(terminal.map((event) => event.request_id)), new Set(["request-a", "request-b"]));
  assert.equal(terminal.every((event) => event.blocking === false), true);
  assert.deepEqual(listActiveWorkerBlockerIssues({ repo_slug: "owner/repo", limit: 10 }, { logPath }), {
    ok: true,
    issues: [124],
  });

  const lineCount = events.length;
  assert.deepEqual(resolveWorkerBlockersForIssue({
    issue_number: 123,
    repo_slug: "owner/repo",
  }, { logPath, now: new Date("2026-07-24T12:00:05Z") }), { ok: true, resolvedCount: 0 });
  assert.equal(readFileSync(logPath, "utf8").trim().split("\n").length, lineCount);

  assert.equal(appendWorkerBlockerEvent({
    ...base,
    event: "permission_request_captured",
    session_key: "issue-123",
    request_id: "request-reopened",
  }, { logPath, now: new Date("2026-07-24T12:00:06Z") }), true);
  assert.deepEqual(listActiveWorkerBlockerIssues({ repo_slug: "owner/repo", limit: 10 }, { logPath }).issues, [123, 124]);
  rmSync(root, { recursive: true, force: true });
});

test("resolve-issue leaves the log unchanged when the terminal batch cannot fit", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-resolve-fail-"));
  const logPath = join(root, "events.jsonl");
  for (const sessionKey of ["issue-321-a", "issue-321-b"]) {
    assert.equal(appendWorkerBlockerEvent({
      event: "permission_request_captured",
      reason: "permission_required",
      source: "test",
      issue_number: 321,
      repo_slug: "owner/repo",
      session_key: sessionKey,
      detail: "x".repeat(200),
    }, { logPath, maxBytes: 4096 }), true);
  }
  const before = readFileSync(logPath, "utf8");
  assert.deepEqual(resolveWorkerBlockersForIssue({
    issue_number: 321,
    repo_slug: "owner/repo",
  }, { logPath, maxBytes: 512 }), { ok: false, resolvedCount: 0 });
  assert.equal(readFileSync(logPath, "utf8"), before);
  rmSync(root, { recursive: true, force: true });
});

test("resolve-session clears only the exact null-issue session and preserves request identity", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-session-resolve-"));
  const logPath = join(root, "events.jsonl");
  const base = {
    event: "permission_request_captured",
    reason: "permission_required",
    source: "test",
    issue_number: null,
    repo_slug: "owner/repo",
    request_id: "request-routine",
  };
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    session_key: "routine-r004",
  }, { logPath, now: new Date("2026-07-24T12:00:00Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    session_key: "routine-r004",
    request_id: "request-routine-b",
  }, { logPath, now: new Date("2026-07-24T12:00:00.500Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    issue_number: 404,
    session_key: "routine-r004",
    request_id: "request-issue",
  }, { logPath, now: new Date("2026-07-24T12:00:01Z") }), true);
  assert.equal(appendWorkerBlockerEvent({
    ...base,
    session_key: "routine-other",
    request_id: "request-other",
  }, { logPath, now: new Date("2026-07-24T12:00:02Z") }), true);

  assert.deepEqual(resolveWorkerBlockersForSession({
    repo_slug: "OWNER/REPO",
    session_key: "routine-r004",
    event: "headless_session_terminal_reconciled",
    reason: "success",
    source: "headless-runtime-worker",
  }, { logPath, now: new Date("2026-07-24T12:00:03Z") }), { ok: true, resolvedCount: 2 });

  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const terminal = events.filter((event) => event.event === "headless_session_terminal_reconciled");
  assert.equal(terminal.length, 2);
  assert.equal(terminal.every((event) => event.issue_number === null), true);
  assert.equal(terminal.every((event) => event.repo_slug === "owner/repo"), true);
  assert.equal(terminal.every((event) => event.session_key === "routine-r004"), true);
  assert.deepEqual(
    new Set(terminal.map((event) => event.request_id)),
    new Set(["request-routine", "request-routine-b"]),
  );
  assert.equal(terminal.every((event) => event.blocking === false), true);
  assert.deepEqual(resolveWorkerBlockersForSession({
    repo_slug: "owner/repo",
    session_key: "routine-r004",
  }, { logPath, now: new Date("2026-07-24T12:00:04Z") }), { ok: true, resolvedCount: 0 });
  assert.deepEqual(listActiveWorkerBlockerIssues({ repo_slug: "owner/repo" }, { logPath }).issues, [404]);
  rmSync(root, { recursive: true, force: true });
});

test("resolve-session CLI appends a terminal event for a null-issue identity", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-session-cli-"));
  const logPath = join(root, "events.jsonl");
  assert.equal(appendWorkerBlockerEvent({
    event: "permission_request_captured",
    reason: "permission_required",
    source: "test",
    issue_number: null,
    repo_slug: "owner/repo",
    session_key: "routine-r005",
    request_id: "request-cli",
  }, { logPath, now: new Date("2026-07-24T12:00:00Z") }), true);

  const result = spawnSync(process.execPath, [
    LOGGER_PATH,
    "resolve-session",
    "--log-file", logPath,
    "--repo-slug", "owner/repo",
    "--issue-number", "",
    "--session-key", "routine-r005",
    "--event", "headless_session_terminal_reconciled",
    "--reason", "success",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "1");

  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const terminal = events.at(-1);
  assert.equal(terminal.event, "headless_session_terminal_reconciled");
  assert.equal(terminal.issue_number, null);
  assert.equal(terminal.session_key, "routine-r005");
  assert.equal(terminal.request_id, "request-cli");
  assert.equal(terminal.blocking, false);
  rmSync(root, { recursive: true, force: true });
});

test("stale supervisor reconciliation preserves evidence and fails closed for current or scoped records", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-stale-supervisor-"));
  const logPath = join(root, "events.jsonl");
  const base = {
    event: "permission_request_captured",
    reason: "permission_required",
    source: "opencode-permission-broker",
    issue_number: null,
    repo_slug: " ",
    session_key: "supervisor-pulse",
  };
  assert.equal(appendWorkerBlockerEvent({ ...base, request_id: "stale" }, {
    logPath,
    now: new Date("2026-07-24T12:00:00Z"),
  }), true);
  assert.equal(appendWorkerBlockerEvent({ ...base, request_id: "current" }, {
    logPath,
    now: new Date("2026-07-24T12:01:00Z"),
  }), true);
  assert.equal(appendWorkerBlockerEvent({ ...base, repo_slug: "owner/repo", request_id: "scoped" }, {
    logPath,
    now: new Date("2026-07-24T12:00:00Z"),
  }), true);
  assert.equal(appendWorkerBlockerEvent({ ...base, session_key: "supervisor-pulse-retry", request_id: "other-session" }, {
    logPath,
    now: new Date("2026-07-24T12:00:00Z"),
  }), true);

  const result = spawnSync(process.execPath, [
    CLI_PATH,
    "resolve-stale-supervisor-session",
    "--log-file", logPath,
    "--repo-slug", "",
    "--session-key", "supervisor-pulse",
    "--stale-before", "1784894400",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "1");

  const events = readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const terminal = events.at(-1);
  assert.equal(events.length, 5);
  assert.equal(terminal.event, "stale_supervisor_session_terminal_reconciled");
  assert.equal(terminal.request_id, "stale");
  assert.equal(terminal.repo_slug, "");
  assert.equal(terminal.blocking, false);
  assert.equal(events.some((event) => event.request_id === "other-session" && event.blocking === false), false);
  assert.deepEqual(resolveStaleSupervisorWorkerBlockers({
    repo_slug: "",
    session_key: "supervisor-pulse",
    stale_before: "1784894400",
  }, { logPath, now: new Date("2026-07-24T12:02:01Z") }), { ok: true, resolvedCount: 0 });
  assert.deepEqual(resolveStaleSupervisorWorkerBlockers({
    repo_slug: "owner/repo",
    session_key: "supervisor-pulse",
    stale_before: "1784894460",
  }, { logPath }), { ok: false, resolvedCount: 0 });
  rmSync(root, { recursive: true, force: true });
});

test("worker-blocker CLI runs directly and rejects unknown commands", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-worker-blocker-direct-cli-"));
  const logPath = join(root, "events.jsonl");
  assert.equal(appendWorkerBlockerEvent({
    event: "permission_request_captured",
    reason: "permission_required",
    issue_number: 701,
    repo_slug: "owner/repo",
    session_key: "issue-701",
  }, { logPath }), true);

  const listed = spawnSync(process.execPath, [
    CLI_PATH,
    "list-active-issues",
    "--log-file", logPath,
    "--repo-slug", "owner/repo",
  ], { encoding: "utf8" });
  assert.equal(listed.status, 0);
  assert.equal(listed.stdout.trim(), "701");

  const invalid = spawnSync(process.execPath, [CLI_PATH, "unknown-command"], { encoding: "utf8" });
  assert.equal(invalid.status, 2);
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
