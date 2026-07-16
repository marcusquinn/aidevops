#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import {
  CAMPAIGN_SCHEMA_VERSION,
  campaignCheckpointPath,
  planCampaign,
  repositoryScope,
  runnerIdentity,
  writeCampaignCheckpoint,
} from "../pulse-campaign-coordinator.mjs";
import { hash } from "../pulse-campaign-values.mjs";

const NOW = "2026-07-16T12:00:00.000Z";
const SCOPE_KEY = "0123456789abcdef";
const COORDINATOR_PATH = resolve(import.meta.dirname, "../pulse-campaign-coordinator.mjs");
const execFileAsync = promisify(execFile);

function issue(number, labels = [], assignees = []) {
  return {
    number,
    createdAt: new Date(Date.UTC(2026, 0, number, 0, 0, 0)).toISOString(),
    updatedAt: new Date(Date.UTC(2026, 5, number, 0, 0, 0)).toISOString(),
    labels,
    assignees,
  };
}

function input(overrides = {}) {
  const readyIssues = Array.from({ length: 12 }, (_, index) => issue(index + 1)).reverse();
  return {
    repositorySlug: "example/repository",
    scopeKey: SCOPE_KEY,
    issues: [
      ...readyIssues,
      issue(20, [{ name: "status:blocked" }]),
      issue(21, [], [{ login: "assigned-user" }]),
    ],
    readyIssues,
    runners: [
      { login: "SharedLogin", device_id: "device-a", fitness: 100, capacity: 1 },
      { login: "sharedlogin", device_id: "device-b", fitness: 50, capacity: 1 },
      { login: "sharedlogin", device_id: "device-zero", fitness: 0, capacity: 1 },
    ],
    now: NOW,
    ...overrides,
  };
}

function testTempRoot() {
  const root = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(root, { recursive: true, mode: 0o700 });
  return mkdtempSync(join(root, "pulse-campaign-test-"));
}

test("builds a deterministic oldest-ready frontier with semantic categories", () => {
  const first = planCampaign(input());
  const second = planCampaign(input());

  assert.deepEqual(first, second);
  assert.equal(first.schemaVersion, CAMPAIGN_SCHEMA_VERSION);
  assert.equal(first.canonicalAuthority, "github+git");
  assert.equal(first.source.complete, true);
  assert.deepEqual(first.frontier.map(({ issueNumber }) => issueNumber), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.deepEqual(first.remaining.map(({ issueNumber }) => issueNumber), [11, 12]);
  assert.deepEqual(first.blocked.map(({ issueNumber }) => issueNumber), [20]);
  assert.deepEqual(first.active.map(({ issueNumber }) => issueNumber), [21]);
  assert.equal(first.discoveries.length, 14);
  assert.equal(first.generation, 1);
  assert.equal(first.renewAfter, "2026-07-16T12:30:00.000Z");
  assert.equal(first.expiresAt, "2026-07-16T13:00:00.000Z");
});

test("hashes nested objects with canonical key ordering", () => {
  const first = { z: 3, nested: { b: true, a: [1, "two"] } };
  const second = { nested: { a: [1, "two"], b: true }, z: 3 };
  assert.equal(hash(first), hash(second));
});

test("keeps same-login devices distinct and lane assignments non-overlapping", () => {
  const checkpoint = planCampaign(input());
  const runnerKeys = checkpoint.runners.map(({ runnerKey }) => runnerKey);
  assert.ok(runnerKeys.includes("sharedlogin:device-a"));
  assert.ok(runnerKeys.includes("sharedlogin:device-b"));
  assert.ok(runnerKeys.includes("sharedlogin:device-zero"));

  const assigned = checkpoint.lanes.flatMap(({ issueNumbers }) => issueNumbers);
  assert.equal(new Set(assigned).size, assigned.length);
  assert.deepEqual([...assigned].sort((left, right) => left - right), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal(checkpoint.lanes.some(({ runnerKey }) => runnerKey === "sharedlogin:device-zero"), false);
});

test("intersects and deduplicates ready issues against the open snapshot", () => {
  const checkpoint = planCampaign(input({
    issues: [issue(1), issue(2)],
    readyIssues: [issue(2), issue(2), issue(99)],
  }));

  assert.deepEqual(checkpoint.frontier.map(({ issueNumber }) => issueNumber), [2]);
  assert.equal(checkpoint.source.openIssueCount, 2);
  assert.equal(checkpoint.source.readyIssueCount, 1);
  assert.deepEqual(checkpoint.lanes.flatMap(({ issueNumbers }) => issueNumbers), [2]);
});

test("retains higher-priority configured runners before applying the runner bound", () => {
  const peers = Array.from({ length: 130 }, (_, index) => ({
    login: `peer${String(index).padStart(3, "0")}`,
    device_id: "device",
    fitness: 100,
    capacity: 1,
    source: "peer-observation",
  }));
  const checkpoint = planCampaign(input({
    runners: [
      ...peers,
      { login: "configured", device_id: "device", fitness: 1, capacity: 1, source: "repository-config" },
    ],
  }));

  assert.equal(checkpoint.runners.length, 128);
  assert.equal(checkpoint.runners.some(({ runnerKey }) => runnerKey === "configured:device"), true);
});

test("uses ASCII ordering at the bounded runner-retention edge", () => {
  const runners = [
    ...Array.from({ length: 129 }, (_, index) => ({
      login: "peer",
      device_id: `d${String(index).padStart(3, "0")}`,
      fitness: 50,
      capacity: 1,
    })),
    { login: "peer", device_id: "d-A", fitness: 50, capacity: 1 },
    { login: "peer", device_id: "d_A", fitness: 50, capacity: 1 },
    { login: "peer", device_id: "dA", fitness: 50, capacity: 1 },
    { login: "peer", device_id: "da", fitness: 50, capacity: 1 },
  ];
  const expectedKeys = runners.map(({ login, device_id: deviceId }) => runnerIdentity(login, deviceId)).sort().slice(0, 128);
  const checkpoint = planCampaign(input({ runners }));

  assert.deepEqual(checkpoint.runners.map(({ runnerKey }) => runnerKey), expectedKeys);
});

test("renews a valid checkpoint and retains bounded discoveries and completion evidence", () => {
  const previous = planCampaign(input({
    issues: [issue(1), issue(2)],
    readyIssues: [issue(1), issue(2)],
  }));
  const next = planCampaign(input({
    issues: [issue(2), issue(3)],
    readyIssues: [issue(2), issue(3)],
    now: "2026-07-16T13:00:00.000Z",
  }), previous);

  assert.equal(next.generation, 2);
  assert.deepEqual(next.completedEvidence, [{
    issueNumber: 1,
    kind: "left-open-snapshot",
    observedAt: "2026-07-16T13:00:00.000Z",
  }]);
  assert.deepEqual(next.discoveries.map(({ issueNumber }) => issueNumber), [1, 2, 3]);
});

test("does not infer completion from an incomplete source snapshot", () => {
  const previous = planCampaign(input({
    issues: [issue(1)],
    readyIssues: [issue(1)],
    sourceLimit: 2,
  }));
  const next = planCampaign(input({
    issues: [issue(2)],
    readyIssues: [issue(2)],
    sourceLimit: 1,
    now: "2026-07-16T13:00:00.000Z",
  }), previous);

  assert.equal(next.source.complete, false);
  assert.deepEqual(next.completedEvidence, []);
});

test("does not infer completion after a failed source fetch", () => {
  const previous = planCampaign(input({
    issues: [issue(1)],
    readyIssues: [issue(1)],
  }));
  const next = planCampaign(input({
    issues: [],
    readyIssues: [],
    sourceSucceeded: false,
    now: "2026-07-16T13:00:00.000Z",
  }), previous);

  assert.equal(next.source.succeeded, false);
  assert.equal(next.source.complete, false);
  assert.deepEqual(next.completedEvidence, []);
});

test("does not infer completion when a source snapshot contains malformed entries", () => {
  const previous = planCampaign(input({
    issues: [issue(1)],
    readyIssues: [issue(1)],
  }));
  for (const sourceLimit of [100, 2]) {
    const next = planCampaign(input({
      issues: [issue(2), { number: "invalid" }],
      readyIssues: [issue(2)],
      sourceLimit,
      now: "2026-07-16T13:00:00.000Z",
    }), previous);

    assert.equal(next.source.succeeded, false);
    assert.equal(next.source.complete, false);
    assert.deepEqual(next.completedEvidence, []);
  }
});

test("rejects malformed issue fields and conflicting duplicate source entries", () => {
  const malformedFields = planCampaign(input({
    issues: [{ ...issue(1), labels: "bug" }],
    readyIssues: [issue(1)],
  }));
  assert.equal(malformedFields.source.succeeded, false);
  assert.equal(malformedFields.source.complete, false);
  assert.deepEqual(malformedFields.frontier, []);

  for (const duplicateIssues of [
    [issue(1), issue(1, ["status:blocked"])],
    [issue(1, ["status:blocked"]), issue(1)],
  ]) {
    const duplicate = planCampaign(input({ issues: duplicateIssues, readyIssues: [issue(1)] }));
    assert.equal(duplicate.source.succeeded, false);
    assert.equal(duplicate.source.complete, false);
    assert.deepEqual(duplicate.frontier, []);
  }
});

test("preserves known issues across failed cycles for later complete evidence", () => {
  const first = planCampaign(input({ issues: [issue(1)], readyIssues: [issue(1)] }));
  const failed = planCampaign(input({
    issues: [],
    readyIssues: [],
    sourceSucceeded: false,
    now: "2026-07-16T13:00:00.000Z",
  }), first);
  const recovered = planCampaign(input({
    issues: [issue(2)],
    readyIssues: [issue(2)],
    now: "2026-07-16T14:00:00.000Z",
  }), failed);

  assert.deepEqual(failed.knownIssueNumbers, [1]);
  assert.deepEqual(recovered.completedEvidence, [{
    issueNumber: 1,
    kind: "left-open-snapshot",
    observedAt: "2026-07-16T14:00:00.000Z",
  }]);
});

test("bounds retained semantic history", () => {
  const manyIssues = Array.from({ length: 150 }, (_, index) => issue(index + 1));
  const checkpoint = planCampaign(input({ issues: manyIssues, readyIssues: manyIssues }));
  assert.equal(checkpoint.discoveries.length, 100);
  assert.equal(checkpoint.frontier.length, 10);
  assert.equal(checkpoint.remaining.length, 140);
});

test("writes one private atomic checkpoint path per repository scope", () => {
  const directory = testTempRoot();
  try {
    const filepath = campaignCheckpointPath(directory, SCOPE_KEY);
    const checkpoint = planCampaign(input());
    writeCampaignCheckpoint(filepath, checkpoint);

    assert.equal(filepath, join(directory, `repo-${SCOPE_KEY}.json`));
    assert.deepEqual(JSON.parse(readFileSync(filepath, "utf8")), checkpoint);
    assert.equal(statSync(filepath).mode & 0o777, 0o600);
    assert.equal(statSync(directory).mode & 0o777, 0o700);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects a symlinked checkpoint root before changing target permissions", () => {
  const directory = testTempRoot();
  try {
    const target = join(directory, "target");
    const symlink = join(directory, "checkpoint-link");
    mkdirSync(target, { mode: 0o755 });
    symlinkSync(target, symlink, "dir");

    assert.throws(
      () => writeCampaignCheckpoint(campaignCheckpointPath(symlink, SCOPE_KEY), planCampaign(input())),
      /symbolic links|real directory/,
    );
    assert.equal(statSync(target).mode & 0o777, 0o755);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects a checkpoint root beneath a symlinked parent", () => {
  const directory = testTempRoot();
  try {
    const target = join(directory, "target-parent");
    const symlink = join(directory, "parent-link");
    mkdirSync(target, { mode: 0o755 });
    symlinkSync(target, symlink, "dir");

    const checkpointRoot = join(symlink, "nested-root");
    assert.throws(
      () => writeCampaignCheckpoint(campaignCheckpointPath(checkpointRoot, SCOPE_KEY), planCampaign(input())),
      /must not traverse symbolic links/,
    );
    assert.equal(existsSync(join(target, "nested-root")), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("reclaims only dead stale checkpoint locks and preserves live owners", () => {
  const directory = testTempRoot();
  try {
    const filepath = campaignCheckpointPath(directory, SCOPE_KEY);
    const lockPath = `${filepath}.lock`;
    const oldTime = new Date(Date.now() - 120_000);
    writeFileSync(lockPath, '{"pid":2147483647,"token":"dead-owner"}\n', { mode: 0o600 });
    utimesSync(lockPath, oldTime, oldTime);

    writeCampaignCheckpoint(filepath, planCampaign(input()));
    assert.equal(existsSync(lockPath), false);

    writeFileSync(lockPath, '{"partial":', { mode: 0o600 });
    utimesSync(lockPath, oldTime, oldTime);
    writeCampaignCheckpoint(filepath, planCampaign(input()));
    assert.equal(existsSync(lockPath), false);

    const processStartedAt = execFileSync("ps", ["-p", String(process.pid), "-o", "lstart="], {
      encoding: "utf8",
    }).trim();
    writeFileSync(lockPath, `${JSON.stringify({
      host: hostname(),
      pid: process.pid,
      processStartedAt,
      token: "live-owner",
    })}\n`, { mode: 0o600 });
    utimesSync(lockPath, oldTime, oldTime);
    assert.throws(
      () => writeCampaignCheckpoint(filepath, planCampaign(input()), { lockTimeoutMs: 50 }),
      /checkpoint lock timed out/,
    );
    assert.equal(JSON.parse(readFileSync(lockPath, "utf8")).token, "live-owner");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("derives the same scope from paths in one Git common directory", () => {
  const repositoryRoot = resolve(import.meta.dirname, "../../..");
  const rootScope = repositoryScope(repositoryRoot);
  const nestedScope = repositoryScope(join(repositoryRoot, ".agents"));
  assert.deepEqual(rootScope, nestedScope);
  assert.match(rootScope.scopeKey, /^[0-9a-f]{16}$/);
});

test("CLI creates and renews exactly one checkpoint for one repository scope", () => {
  const directory = testTempRoot();
  try {
    const repositoryRoot = resolve(import.meta.dirname, "../../..");
    const checkpointRoot = join(directory, "checkpoints");
    const issuesFile = join(directory, "issues.json");
    const readyFile = join(directory, "ready.json");
    const reposFile = join(directory, "repos.json");
    const peerFile = join(directory, "peers.json");
    writeFileSync(issuesFile, JSON.stringify([issue(1), issue(2)]));
    writeFileSync(readyFile, JSON.stringify([issue(2), issue(1)]));
    writeFileSync(reposFile, JSON.stringify({
      initialized_repos: [{
        slug: "example/repository",
        path: repositoryRoot,
        pulse_campaign: {
          runners: [{ login: "configured", device_id: "device", fitness: 80, capacity: 1 }],
        },
      }],
    }));
    writeFileSync(peerFile, JSON.stringify({}));

    const baseArgs = [
      COORDINATOR_PATH,
      "plan",
      "--repo", "example/repository",
      "--repo-path", repositoryRoot,
      "--issues-file", issuesFile,
      "--ready-file", readyFile,
      "--repos-file", reposFile,
      "--peer-state-file", peerFile,
      "--checkpoint-root", checkpointRoot,
      "--source-limit", "100",
    ];
    const first = JSON.parse(execFileSync(process.execPath, [...baseArgs, "--now", NOW], { encoding: "utf8" }));
    const second = JSON.parse(execFileSync(process.execPath, [
      ...baseArgs,
      "--now", "2026-07-16T13:00:00.000Z",
    ], { encoding: "utf8" }));

    assert.equal(first.generation, 1);
    assert.equal(second.generation, 2);
    assert.equal(first.runners.some(({ runnerKey }) => runnerKey === "configured:device"), true);
    assert.equal(first.checkpointPath, second.checkpointPath);
    assert.equal(readdirSync(checkpointRoot).length, 1);
    assert.deepEqual(JSON.parse(readFileSync(second.checkpointPath, "utf8")).frontier
      .map(({ issueNumber }) => issueNumber), [1, 2]);

    const persisted = readFileSync(second.checkpointPath, "utf8");
    writeFileSync(reposFile, JSON.stringify({
      initialized_repos: [{ slug: "different/repository", path: repositoryRoot }],
    }));
    assert.throws(() => execFileSync(process.execPath, [...baseArgs, "--now", "2026-07-16T14:00:00.000Z"]));
    assert.equal(readFileSync(second.checkpointPath, "utf8"), persisted);

    writeFileSync(reposFile, JSON.stringify({
      initialized_repos: [
        { slug: "example/repository", path: repositoryRoot },
        { slug: "example/repository", path: repositoryRoot },
      ],
    }));
    assert.throws(() => execFileSync(process.execPath, [...baseArgs, "--now", "2026-07-16T15:00:00.000Z"]));
    assert.equal(readFileSync(second.checkpointPath, "utf8"), persisted);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("serializes concurrent CLI renewals into consecutive generations", async () => {
  const directory = testTempRoot();
  try {
    const repositoryRoot = resolve(import.meta.dirname, "../../..");
    const checkpointRoot = join(directory, "checkpoints");
    const issuesFile = join(directory, "issues.json");
    const readyFile = join(directory, "ready.json");
    const reposFile = join(directory, "repos.json");
    const peerFile = join(directory, "peers.json");
    writeFileSync(issuesFile, JSON.stringify([issue(1), issue(2)]));
    writeFileSync(readyFile, JSON.stringify([issue(1), issue(2)]));
    writeFileSync(reposFile, JSON.stringify({
      initialized_repos: [{ slug: "example/repository", path: repositoryRoot }],
    }));
    writeFileSync(peerFile, JSON.stringify({}));
    const args = [
      COORDINATOR_PATH,
      "plan",
      "--repo", "example/repository",
      "--repo-path", repositoryRoot,
      "--issues-file", issuesFile,
      "--ready-file", readyFile,
      "--repos-file", reposFile,
      "--peer-state-file", peerFile,
      "--checkpoint-root", checkpointRoot,
      "--source-limit", "100",
    ];

    const results = await Promise.all([
      execFileAsync(process.execPath, args, { encoding: "utf8" }),
      execFileAsync(process.execPath, args, { encoding: "utf8" }),
    ]);
    const generations = results.map(({ stdout }) => JSON.parse(stdout).generation).sort((left, right) => left - right);
    const [checkpointFile] = readdirSync(checkpointRoot).filter((entry) => entry.endsWith(".json"));
    const persisted = JSON.parse(readFileSync(join(checkpointRoot, checkpointFile), "utf8"));

    assert.deepEqual(generations, [1, 2]);
    assert.equal(persisted.generation, 2);
    assert.deepEqual(readdirSync(checkpointRoot), [checkpointFile]);

    const persistedBeforeStaleInput = readFileSync(join(checkpointRoot, checkpointFile), "utf8");
    writeFileSync(issuesFile, JSON.stringify([issue(3)]));
    writeFileSync(readyFile, JSON.stringify([issue(3)]));
    const staleResult = await execFileAsync(process.execPath, [
      ...args,
      "--source-observed-at", "2020-01-01T00:00:00.000Z",
    ], { encoding: "utf8" });
    assert.equal(JSON.parse(staleResult.stdout).generation, 2);
    assert.equal(readFileSync(join(checkpointRoot, checkpointFile), "utf8"), persistedBeforeStaleInput);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("validates public identity and repository inputs", () => {
  assert.equal(runnerIdentity("Example-User", "device.1"), "example-user:device.1");
  assert.throws(() => runnerIdentity("invalid user", "device.1"), /login is invalid/);
  assert.throws(() => runnerIdentity("-invalid", "device.1"), /login is invalid/);
  assert.throws(() => runnerIdentity("valid-user", "invalid device"), /device_id is invalid/);
  assert.throws(() => runnerIdentity("valid-user", `d${"x".repeat(64)}`), /device_id is invalid/);
  assert.throws(() => planCampaign(input({ repositorySlug: "invalid" })), /repository slug is invalid/);
  assert.throws(() => campaignCheckpointPath("relative", SCOPE_KEY), /root must be absolute/);
});
