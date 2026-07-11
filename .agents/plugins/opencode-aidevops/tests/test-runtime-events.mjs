// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  RUNTIME_EVENT_PAYLOAD_MAX_BYTES,
  RUNTIME_EVENTS_SCHEMA_SQL,
  appendRuntimeEvent,
  appendStateSnapshot,
  applyMergePatch,
  buildRuntimeEventInsertSql,
  buildStateEventInsertSql,
  createRuntimeEventEnvelope,
  prepareRuntimePayload,
  reconstructRuntimeState,
} from "../../../scripts/runtime-events.mjs";

const execFileAsync = promisify(execFile);

function sqliteAvailable() {
  try {
    execFileSync("sqlite3", ["-version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

describe("runtime-event envelopes", () => {
  test("redacts credentials, bounds payloads, and canonicalises keys", () => {
    const prepared = prepareRuntimePayload({
      z: "Bearer test-token-value",
      password: "not-for-storage",
      apiKey: "camel-case-secret",
      token: "generic-secret",
      a: `prefix ghp_${"x".repeat(32)}`,
      large: "x".repeat(RUNTIME_EVENT_PAYLOAD_MAX_BYTES * 2),
    });

    assert.ok(prepared.bytes <= RUNTIME_EVENT_PAYLOAD_MAX_BYTES);
    assert.ok(prepared.redactionCount >= 5);
    assert.equal(prepared.value.password, "[redacted]");
    assert.doesNotMatch(
      prepared.json,
      /test-token-value|not-for-storage|camel-case-secret|generic-secret|ghp_/,
    );
    assert.deepEqual(Object.keys(prepared.value), ["a", "apiKey", "large", "password", "token", "z"]);
  });

  test("state payloads remove private path evidence", () => {
    const built = buildStateEventInsertSql({
      subjectId: "worker:42",
      state: {
        cwd: "/Users/example/private-repo",
        note: "read /home/example/private.txt next",
        status: "running",
      },
    }, "state.snapshot");

    assert.doesNotMatch(built.envelope.payload.json, /Users|private-repo|private\.txt/);
    assert.match(built.envelope.payload.json, /redacted-path/);
    assert.equal(built.envelope.eventType, "state.snapshot");
  });

  test("oversized state remains a reconstructable bounded marker", () => {
    const built = buildStateEventInsertSql({
      subjectId: "worker:large",
      state: { items: Array.from({ length: 128 }, () => "x".repeat(2048)) },
    }, "state.snapshot");
    const row = {
      event_type: "state.snapshot",
      state_version: 1,
      subject_id: "worker:large",
      payload_json: built.envelope.payload.json,
    };

    assert.ok(built.envelope.payload.bytes <= RUNTIME_EVENT_PAYLOAD_MAX_BYTES);
    assert.equal(built.envelope.payload.value.state._truncated, true);
    assert.deepEqual(reconstructRuntimeState([row]), {
      state: built.envelope.payload.value.state,
      stateVersion: 1,
    });
  });

  test("unsafe identifiers are deterministically hashed", () => {
    const first = createRuntimeEventEnvelope({
      eventId: "event 1 with whitespace",
      eventType: "worker.started",
      subjectId: "subject with whitespace",
    });
    const second = createRuntimeEventEnvelope({
      eventId: "event 1 with whitespace",
      eventType: "worker.started",
      subjectId: "subject with whitespace",
    });

    assert.match(first.eventId, /^sha256:[a-f0-9]{64}$/);
    assert.equal(first.eventId, second.eventId);
    assert.equal(first.subjectId, second.subjectId);

    const privatePathId = createRuntimeEventEnvelope({
      eventType: "worker.started",
      subjectId: "/Users/example/private-repo",
    });
    assert.match(privatePathId.subjectId, /^sha256:[a-f0-9]{64}$/);
  });

  test("ordinary and state writes fail open", () => {
    assert.equal(appendRuntimeEvent({
      eventType: "worker.started",
      subjectId: "worker:42",
    }, { execute: () => { throw new Error("disk unavailable"); } }), null);

    assert.equal(appendStateSnapshot({
      subjectId: "worker:42",
      state: { status: "running" },
    }, { executeSync: () => { throw new Error("database locked"); } }), null);
  });

  test("state SQL allocates versions inside an immediate transaction", () => {
    const { sql } = buildStateEventInsertSql({
      subjectId: "worker:42",
      patch: { status: "done" },
    }, "state.delta");

    assert.match(sql, /^BEGIN IMMEDIATE;/);
    assert.match(sql, /COALESCE\(MAX\(state_version\), 0\) \+ 1/);
    assert.match(sql, /RETURNING state_version;/);
    assert.match(sql, /COMMIT;$/);
  });

  test("ordinary event SQL preserves the versioned causal envelope", () => {
    const { sql } = buildRuntimeEventInsertSql({
      eventId: "evt-2",
      eventType: "worker.completed",
      correlationId: "corr-1",
      causationId: "evt-1",
      subjectId: "worker:42",
      sessionId: "session:1",
      workerId: "worker:42",
      rootEventId: "evt-1",
      parentEventId: "evt-1",
      payload: { result: "success" },
    });

    for (const value of ["evt-2", "corr-1", "evt-1", "worker:42", "session:1"]) {
      assert.match(sql, new RegExp(value));
    }
  });
});

describe("deterministic state reconstruction", () => {
  test("applies RFC 7396 object deletion and array replacement", () => {
    const result = applyMergePatch(
      { z: 1, nested: { keep: true, remove: true }, list: [1, 2] },
      { nested: { remove: null, add: "yes" }, list: [3], a: 2 },
    );

    assert.deepEqual(result, {
      a: 2,
      list: [3],
      nested: { add: "yes", keep: true },
      z: 1,
    });
    assert.deepEqual(Object.keys(result), ["a", "list", "nested", "z"]);
  });

  test("uses the latest snapshot and ordered contiguous deltas", () => {
    const rows = [
      { subject_id: "w", event_type: "state.delta", state_version: 4, payload_json: '{"patch":{"done":true}}' },
      { subject_id: "w", event_type: "state.snapshot", state_version: 1, payload_json: '{"state":{"old":true}}' },
      { subject_id: "w", event_type: "state.snapshot", state_version: 3, payload_json: '{"state":{"count":2}}' },
      { subject_id: "w", event_type: "state.delta", state_version: 2, payload_json: '{"patch":{"old":false}}' },
    ];

    assert.deepEqual(reconstructRuntimeState(rows, { subjectId: "w" }), {
      state: { count: 2, done: true },
      stateVersion: 4,
    });
    assert.deepEqual(reconstructRuntimeState(rows, { subjectId: "w", targetVersion: 2 }), {
      state: { old: false },
      stateVersion: 2,
    });
  });

  test("rejects gaps after the reconstruction snapshot", () => {
    assert.throws(() => reconstructRuntimeState([
      { subject_id: "w", event_type: "state.snapshot", state_version: 1, payload_json: '{"state":{}}' },
      { subject_id: "w", event_type: "state.delta", state_version: 3, payload_json: '{"patch":{"x":1}}' },
    ]), /not contiguous/);
  });
});

test("SQLite enforces append-only rows and concurrent state versions", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-events-"));
  const dbPath = join(tempDir, "observability.db");
  try {
    execFileSync("sqlite3", [dbPath], { input: `PRAGMA journal_mode=WAL;\n${RUNTIME_EVENTS_SCHEMA_SQL}` });
    const ordinary = buildRuntimeEventInsertSql({
      eventType: "session.started",
      subjectId: "session:1",
      payload: { source: "test" },
    });
    execFileSync("sqlite3", [dbPath], { input: ordinary.sql });

    assert.throws(() => execFileSync(
      "sqlite3",
      [dbPath, "UPDATE runtime_events SET event_type='changed';"],
      { stdio: "pipe" },
    ));
    assert.throws(() => execFileSync(
      "sqlite3",
      [dbPath, "DELETE FROM runtime_events;"],
      { stdio: "pipe" },
    ));

    const snapshot = buildStateEventInsertSql({
      subjectId: "worker:42",
      state: { count: 0 },
    }, "state.snapshot");
    execFileSync("sqlite3", ["-cmd", ".timeout 5000", dbPath, snapshot.sql]);

    const writes = Array.from({ length: 8 }, (_unused, index) => {
      const delta = buildStateEventInsertSql({
        subjectId: "worker:42",
        patch: { count: index + 1 },
      }, "state.delta");
      return execFileAsync("sqlite3", ["-cmd", ".timeout 5000", dbPath, delta.sql]);
    });
    await Promise.all(writes);

    const versions = execFileSync("sqlite3", [
      dbPath,
      "SELECT group_concat(state_version, ',') FROM (SELECT state_version FROM runtime_events WHERE subject_id='worker:42' ORDER BY state_version);",
    ], { encoding: "utf8" }).trim();
    assert.equal(versions, "1,2,3,4,5,6,7,8,9");
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});

test("OpenCode observability emits runtime evidence without changing legacy tables", {
  skip: !sqliteAvailable() && "sqlite3 is unavailable",
}, () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-runtime-events-plugin-"));
  const dbPath = join(tempDir, "llm-requests.db");
  const observabilityUrl = new URL("../observability.mjs", import.meta.url).href;
  const driver = `
    const observability = await import(${JSON.stringify(observabilityUrl)});
    if (!observability.initObservability()) process.exit(2);
    observability.handleEvent({ event: {
      type: "session.created",
      properties: { info: { id: "session:1", sessionID: "session:1" } },
    } });
    observability.handleEvent({ event: {
      type: "message.updated",
      properties: { info: {
        id: "message:1", sessionID: "session:1", role: "assistant",
        providerID: "test", modelID: "test-model", finish: "stop",
        time: { created: 1, completed: 11 },
        tokens: { input: 2, output: 3, total: 5, cache: { read: 0, write: 0 } },
      } },
    } });
    observability.recordToolCall(
      { tool: "Read", sessionID: "session:1", callID: "call:1" },
      { output: "ok", metadata: { bytes: 1 } },
      "reading a fixture",
      5,
    );
    await new Promise((resolve) => setTimeout(resolve, 500));
    process.exit(0);
  `;

  try {
    execFileSync(process.execPath, ["--input-type=module", "-e", driver], {
      env: { ...process.env, AIDEVOPS_OBS_DB_OVERRIDE: dbPath },
      stdio: "pipe",
      timeout: 5000,
    });
    const counts = execFileSync("sqlite3", [dbPath, `
      SELECT
        (SELECT COUNT(*) FROM llm_requests),
        (SELECT COUNT(*) FROM tool_calls),
        (SELECT COUNT(*) FROM runtime_events),
        (SELECT group_concat(event_type, ',') FROM (
          SELECT event_type FROM runtime_events ORDER BY id
        ));
    `], { encoding: "utf8" }).trim();
    assert.equal(counts, "1|1|3|session.created,message.completed,tool.completed");
  } finally {
    rmSync(tempDir, { force: true, recursive: true });
  }
});
