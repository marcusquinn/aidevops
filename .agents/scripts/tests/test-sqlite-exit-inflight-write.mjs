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

const here = fileURLToPath(import.meta.url);

if (process.argv[2] === "child") {
  const { setDbPath, sqliteExecSync, sqliteExec } = await import("../sqlite-process.mjs");
  setDbPath(process.argv[3]);
  sqliteExecSync("CREATE TABLE IF NOT EXISTS t(v TEXT);");
  sqliteExec(`INSERT INTO t VALUES ('${"x".repeat(1_000_000)}');`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "sqlite-exit-"));
const db = join(dir, "t.db");
try {
  execFileSync(process.execPath, [here, "child", db], { stdio: "inherit" });
  const rows = execFileSync("sqlite3", [db, "SELECT count(*) FROM t;"], { encoding: "utf8" }).trim();
  if (rows !== "1") throw new Error(`expected exactly 1 row, got ${rows}`);
  console.log("PASS: in-flight oversized write inserted exactly once");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
