// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDbActivityHeartbeat, installDbActivityHeartbeat } from "../db-activity-heartbeat.mjs";
import { processStartToken } from "../process-liveness.mjs";

function event(type, properties = {}) {
  return { event: { type, properties } };
}

function fixture() {
  const parent = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(parent, { recursive: true });
  const dir = mkdtempSync(join(parent, "db-activity-heartbeat-"));
  let currentTime = 1_000_000;
  const heartbeat = createDbActivityHeartbeat({
    dir,
    pid: 4242,
    instance: "test",
    now: () => currentTime,
    throttleMs: 30_000,
  });
  return {
    dir,
    heartbeat,
    advance: (ms) => { currentTime += ms; },
    read: () => JSON.parse(readFileSync(heartbeat.file, "utf8")),
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

test("busy and idle transitions write immediately with session IDs", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    f.advance(5_000);
    f.heartbeat.handleEvent(event("session.status", { sessionID: "ses_a", status: { type: "busy" } }));
    assert.equal(f.read().busy_sessions, 1);
    assert.deepEqual(f.read().sessions, ["ses_a"]);
    assert.equal(f.read().pid, 4242);
    f.advance(1_000);
    f.heartbeat.handleEvent(event("session.idle", { sessionID: "ses_a" }));
    const state = f.read();
    assert.equal(state.busy_sessions, 0);
    assert.equal(state.last_activity_epoch, 1006);
  } finally {
    f.cleanup();
  }
});

test("activity refreshes last_activity but writes are throttled", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    f.advance(1_000);
    f.heartbeat.handleEvent(event("message.part.updated", { part: { sessionID: "ses_b", type: "text" } }));
    assert.equal(f.read().last_activity_epoch, 1000, "throttled write must not land yet");
    f.advance(30_000);
    f.heartbeat.handleEvent(event("message.updated", { info: { sessionID: "ses_b", role: "assistant" } }));
    assert.equal(f.read().last_activity_epoch, 1031);
    assert.deepEqual(f.read().sessions, ["ses_b"]);
  } finally {
    f.heartbeat.remove();
    f.cleanup();
  }
});

test("metadata-only events do not count as activity and unsafe IDs are dropped", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    f.advance(60_000);
    f.heartbeat.handleEvent(event("session.updated", { info: { id: "ses_c" } }));
    f.heartbeat.write();
    let state = f.read();
    assert.equal(state.last_activity_epoch, 1000, "session metadata is not activity");
    assert.deepEqual(state.sessions, ["ses_c"], "sessions seen by this process are still protected");
    f.heartbeat.handleEvent(event("session.status", { sessionID: "x'); DROP TABLE session;--", status: { type: "busy" } }));
    state = f.read();
    assert.deepEqual(state.sessions, ["ses_c"]);
    assert.equal(state.busy_sessions, 1, "an unsafe ID is not exported but still counts as busy");
  } finally {
    f.cleanup();
  }
});

// GH#35898: OpenCode 2.x events carry `data` (verified @opencode/schema 2.2.0).
function v2Event(type, data = {}) {
  return { event: { type, data, created: 1 } };
}

test("V2 session.status tracks busy sessions per session ID", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    f.heartbeat.handleEvent(v2Event("session.status", { sessionID: "ses_v2a", status: { type: "busy" } }));
    f.heartbeat.handleEvent(v2Event("session.status", { sessionID: "ses_v2b", status: { type: "busy" } }));
    assert.equal(f.read().busy_sessions, 2);
    f.heartbeat.handleEvent(v2Event("session.status", { sessionID: "ses_v2b", status: { type: "idle" } }));
    const state = f.read();
    assert.equal(state.busy_sessions, 1, "one session's idle must not clear another's busy state");
    assert.deepEqual(state.sessions, ["ses_v2a", "ses_v2b"]);
  } finally {
    f.cleanup();
  }
});

test("V2 execution events back up session.status and step events count as activity", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    f.heartbeat.handleEvent(v2Event("session.execution.started", { sessionID: "ses_v2c" }));
    assert.equal(f.read().busy_sessions, 1);
    f.advance(31_000);
    f.heartbeat.handleEvent(v2Event("session.step.ended", { sessionID: "ses_v2c", assistantMessageID: "msg_1" }));
    assert.equal(f.read().last_activity_epoch, 1031);
    f.heartbeat.handleEvent(v2Event("session.execution.interrupted", { sessionID: "ses_v2c" }));
    assert.equal(f.read().busy_sessions, 0);
    f.heartbeat.handleEvent(v2Event("session.deleted", { sessionID: "ses_v2c" }));
    assert.deepEqual(f.read().sessions, []);
  } finally {
    f.cleanup();
  }
});

test("remove deletes the heartbeat file", () => {
  const f = fixture();
  try {
    f.heartbeat.write();
    assert.ok(existsSync(f.heartbeat.file));
    f.heartbeat.remove();
    assert.ok(!existsSync(f.heartbeat.file));
  } finally {
    f.cleanup();
  }
});

test("startup prunes dead and recycled PIDs but preserves live and unknown identities", async () => {
  const f = fixture();
  const token = processStartToken(process.pid);
  assert.ok(token);
  const file = (name) => join(f.dir, name);
  const dead = file("2147483647-dead.json");
  const stale = file(`${process.pid}-stale.json`);
  const live = file(`${process.pid}-live.json`);
  const legacy = file(`${process.pid}-legacy.json`);
  const malformed = file(`${process.pid}-malformed.json`);
  writeFileSync(dead, "{}");
  writeFileSync(stale, JSON.stringify({ process_start_token: `${token}-old` }));
  writeFileSync(live, JSON.stringify({ process_start_token: token }));
  writeFileSync(legacy, "{}");
  writeFileSync(malformed, "{");
  const heartbeat = installDbActivityHeartbeat({ dir: f.dir, instance: "own" });
  try {
    for (let i = 0; i < 100 && (existsSync(dead) || existsSync(stale)); i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(existsSync(dead), false);
    assert.equal(existsSync(stale), false);
    assert.equal(existsSync(live), true);
    assert.equal(existsSync(legacy), true);
    assert.equal(existsSync(malformed), true);
    assert.equal(JSON.parse(readFileSync(heartbeat.file, "utf8")).process_start_token, token);
  } finally {
    heartbeat.remove();
    f.cleanup();
  }
});
