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

if (["child", "small"].includes(process.argv[2])) {
  const { setDbPath, sqliteExecSync, sqliteExec } = await import("../sqlite-process.mjs");
  setDbPath(process.argv[3]);
  sqliteExecSync("CREATE TABLE IF NOT EXISTS t(v TEXT);");
  const size = process.argv[2] === "small" ? 1 : 1_000_000;
  sqliteExec(`INSERT INTO t VALUES ('${"x".repeat(size)}');`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "sqlite-exit-"));
const db = join(dir, "t.db");
try {
  execFileSync(process.execPath, [here, "child", db], { stdio: "inherit" });
  const rows = execFileSync("sqlite3", [db, "SELECT count(*) FROM t;"], { encoding: "utf8" }).trim();
  if (rows !== "1") throw new Error(`expected exactly 1 row, got ${rows}`);
  console.log("PASS: in-flight oversized write inserted exactly once");
  for (const mode of ["small"]) {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      execFileSync("sqlite3", [db, "DELETE FROM t;"]);
      execFileSync(process.execPath, [here, mode, db], { stdio: "inherit" });
      // The handed-off child finishes independently after the parent exits.
      let result;
      const deadline = Date.now() + 5000;
      do {
        result = execFileSync("sqlite3", ["-cmd", ".timeout 5000", db, "SELECT count(*) || ':' || max(v) FROM t;"], { encoding: "utf8" }).trim();
        if (result === "1:x") break;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      } while (Date.now() < deadline);
      assert.equal(result, "1:x");
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
} finally {
  rmSync(dir, { recursive: true, force: true });
}
