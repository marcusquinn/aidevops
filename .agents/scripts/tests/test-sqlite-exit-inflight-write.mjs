// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Regression (GH#39202): an in-flight INSERT larger than the pipe capacity,
// with an empty queue, must be inserted exactly once when the process exits.
// Usage: node test-sqlite-exit-inflight-write.mjs [child|<dir>]
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Writable } from "node:stream";
import assert from "node:assert/strict";
import { drainQueue } from "../sqlite-transport.mjs";
import { flushTransportOnExit } from "../sqlite-child.mjs";

const here = fileURLToPath(import.meta.url);

if (["child", "small", "ordered", "ordered-large"].includes(process.argv[2])) {
  const { setDbPath, sqliteExecSync, sqliteExec } = await import("../sqlite-process.mjs");
  setDbPath(process.argv[3]);
  sqliteExecSync("CREATE TABLE IF NOT EXISTS t(v TEXT);");
  if (process.argv[2].startsWith("ordered")) {
    sqliteExec("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<200000) INSERT INTO t SELECT '1' FROM n WHERE x=200000;");
    if (process.argv[2] === "ordered-large") {
      sqliteExec(`UPDATE t SET v = '${"x".repeat(1_000_000)}';`);
    }
    sqliteExec("UPDATE t SET v = '2';");
  } else {
    const size = process.argv[2] === "small" ? 1 : 1_000_000;
    sqliteExec(`INSERT INTO t VALUES ('${"x".repeat(size)}');`);
  }
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "sqlite-exit-"));
const db = join(dir, "t.db");
try {
  execFileSync(process.execPath, [here, "child", db], { stdio: "inherit" });
  const rows = execFileSync("sqlite3", [db, "SELECT count(*) FROM t;"], { encoding: "utf8" }).trim();
  if (rows !== "1") throw new Error(`expected exactly 1 row, got ${rows}`);
  console.log("PASS: in-flight oversized write inserted exactly once");
  for (const mode of ["small", "ordered", "ordered-large"]) {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      execFileSync("sqlite3", [db, "DELETE FROM t;"]);
      execFileSync(process.execPath, [here, mode, db], { stdio: "inherit" });
      // The handed-off child finishes independently after the parent exits.
      const expected = mode === "small" ? "1:x" : "1:2";
      let result;
      const deadline = Date.now() + 5000;
      do {
        result = execFileSync("sqlite3", ["-cmd", ".timeout 5000", db, "SELECT count(*) || ':' || max(v) FROM t;"], { encoding: "utf8" }).trim();
        if (result === expected) break;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      } while (Date.now() < deadline);
      assert.equal(result, expected);
    }
    console.log(`PASS: ${mode} immediate-exit writes (10 runs)`);
  }
  execFileSync("sqlite3", [db, "DELETE FROM t;"]);
  const stdin = new Writable({ write(_chunk, _encoding, callback) { callback(new Error("pipe failed")); } });
  stdin.on("error", () => {});
  const transport = {
    dbPath: db,
    proc: { stdin, kill() {} },
    queue: [{ sql: "INSERT INTO t VALUES ('replayed');", callback() {} }],
  };
  drainQueue(transport);
  assert.equal(transport.inflightFlushed, false, "synchronous failure must not count as handoff");
  await new Promise((resolve) => process.nextTick(resolve));
  assert.equal(transport.inflightFlushed, false, "error callback must not count as handoff");
  flushTransportOnExit(transport);
  assert.equal(execFileSync("sqlite3", [db, "SELECT v FROM t;"], { encoding: "utf8" }).trim(), "replayed");
  console.log("PASS: failed pipe write remains eligible for exit replay");
  // Model a child that committed and exited before its stdout sentinel was
  // consumed. Destruction of its stdin is not evidence that delivery failed.
  execFileSync("sqlite3", [db, "DELETE FROM t; INSERT INTO t VALUES ('committed');"]);
  const delivered = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
  const committed = {
    dbPath: db,
    proc: { stdin: delivered, kill() { throw new Error("must not kill a delivered query"); } },
    queue: [{ sql: "INSERT INTO t VALUES ('committed');", callback() {} }],
  };
  drainQueue(committed);
  assert.equal(committed.inflightFlushed, true);
  delivered.destroy();
  await new Promise((resolve) => process.nextTick(resolve));
  assert.equal(committed.inflightFlushed, true, "late destruction must not undo successful delivery");
  flushTransportOnExit(committed);
  assert.equal(execFileSync("sqlite3", [db, "SELECT count(*) FROM t;"], { encoding: "utf8" }).trim(), "1");
  console.log("PASS: destroyed stdin does not replay an already committed query");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
