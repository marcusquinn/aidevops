// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for buildToolCallInsertSql (t2184)
// ---------------------------------------------------------------------------
// Runs under the built-in `node:test` runner. No external deps.
//
//   node --test .agents/plugins/opencode-aidevops/tests/
//
// Scope: pure SQL-builder coverage. The function has no DB access, no
// global state — we can exhaustively verify:
//   * duration_ms renders as a plain integer when supplied
//   * duration_ms renders as the SQL NULL keyword (unquoted) when absent
//   * metadata renders as a JSON-stringified, SQL-escaped literal
//   * metadata renders as SQL NULL when absent
//   * column-count / value-count schema alignment
//
// The live INSERT path (recordToolCall → buildToolCallInsertSql → sqliteExec)
// is exercised end-to-end by the manual Jaeger run-book after deploy.
// ---------------------------------------------------------------------------

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { buildToolCallInsertSql } from "../observability.mjs";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Extract the column list from `INSERT INTO tool_calls ( <cols> )`.
 * Returns an array of trimmed column names.
 */
function extractColumns(sql) {
  const m = sql.match(/INSERT INTO tool_calls \(([^)]+)\) VALUES/);
  assert.ok(m, "INSERT column list not found in SQL");
  return m[1].split(",").map((c) => c.trim()).filter(Boolean);
}

/**
 * Extract the VALUES list — crude but deterministic, because sqlEscape
 * doubles inner single quotes so no value can contain a bare `,` outside
 * quotes that would break this split.
 */
function extractValues(sql) {
  const m = sql.match(/VALUES \(\s*([\s\S]+?)\s*\);/);
  assert.ok(m, "VALUES list not found in SQL");
  // Split on commas that are NOT inside single-quoted strings.
  const values = [];
  let buf = "";
  let inQuote = false;
  for (let i = 0; i < m[1].length; i++) {
    const c = m[1][i];
    if (c === "'") {
      // sqlEscape doubles inner quotes as '', so pairs are literal.
      if (inQuote && m[1][i + 1] === "'") {
        buf += "''";
        i++;
        continue;
      }
      inQuote = !inQuote;
      buf += c;
    } else if (c === "," && !inQuote) {
      values.push(buf.trim());
      buf = "";
    } else {
      buf += c;
    }
  }
  if (buf.trim()) values.push(buf.trim());
  return values;
}

// ---------------------------------------------------------------------------
// Schema alignment
// ---------------------------------------------------------------------------

describe("buildToolCallInsertSql — column/value alignment", () => {
  test("column count matches value count", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 42,
      metadata: null,
    });
    const cols = extractColumns(sql);
    const vals = extractValues(sql);
    assert.equal(cols.length, vals.length,
      `cols=${cols.length} vs vals=${vals.length}`);
  });

  test("column list matches tool_calls schema (regression guard)", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: "reading the file",
      isSuccess: 1,
      durationMs: 10,
      metadata: { filePath: "/tmp/x" },
    });
    const cols = extractColumns(sql);
    // Order must match the CREATE TABLE in observability.mjs:initDatabase.
    // Any drift breaks SQLite positional binding in the live path.
    assert.deepEqual(cols, [
      "session_id",
      "call_id",
      "tool_name",
      "intent",
      "success",
      "duration_ms",
      "metadata",
    ]);
  });
});

// ---------------------------------------------------------------------------
// duration_ms rendering
// ---------------------------------------------------------------------------

describe("buildToolCallInsertSql — duration_ms rendering", () => {
  test("numeric durationMs renders as unquoted integer", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 123,
      metadata: null,
    });
    const vals = extractValues(sql);
    // Column index 5 = duration_ms
    assert.equal(vals[5], "123");
  });

  test("durationMs=0 is a legitimate value, not falsy-coerced to NULL", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 0,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[5], "0");
  });

  test("durationMs=null renders as SQL NULL keyword (unquoted)", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: null,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[5], "NULL");
  });

  test("durationMs=undefined renders as SQL NULL keyword (unquoted)", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: undefined,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[5], "NULL");
  });
});

// ---------------------------------------------------------------------------
// metadata rendering
// ---------------------------------------------------------------------------

describe("buildToolCallInsertSql — metadata rendering", () => {
  test("object metadata renders as JSON-stringified, SQL-escaped literal", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Write",
      intent: null,
      isSuccess: 1,
      durationMs: 5,
      metadata: { filePath: "/tmp/hello.txt", bytes: 42 },
    });
    const vals = extractValues(sql);
    // Column index 6 = metadata
    assert.ok(vals[6].startsWith("'"), `expected quoted string, got ${vals[6]}`);
    // Unescape the SQL string and parse the JSON.
    const inner = vals[6].slice(1, -1).replace(/''/g, "'");
    const parsed = JSON.parse(inner);
    assert.deepEqual(parsed, { filePath: "/tmp/hello.txt", bytes: 42 });
  });

  test("metadata=null renders as SQL NULL keyword", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 5,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[6], "NULL");
  });

  test("metadata=undefined renders as SQL NULL keyword", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 5,
      metadata: undefined,
    });
    const vals = extractValues(sql);
    assert.equal(vals[6], "NULL");
  });

  test("metadata containing single quotes is safely escaped", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Bash",
      intent: null,
      isSuccess: 1,
      durationMs: 5,
      // A metadata value with an embedded apostrophe — must round-trip.
      metadata: { note: "o'reilly" },
    });
    const vals = extractValues(sql);
    const inner = vals[6].slice(1, -1).replace(/''/g, "'");
    const parsed = JSON.parse(inner);
    assert.equal(parsed.note, "o'reilly");
  });
});

// ---------------------------------------------------------------------------
// Intent rendering (regression guard — intent was already correct pre-t2184)
// ---------------------------------------------------------------------------

describe("buildToolCallInsertSql — intent rendering", () => {
  test("intent=string renders as quoted literal", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: "reading the file",
      isSuccess: 1,
      durationMs: 5,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[3], "'reading the file'");
  });

  test("intent=null renders as SQL NULL", () => {
    const sql = buildToolCallInsertSql({
      sessionID: "s1",
      callID: "c1",
      toolName: "Read",
      intent: null,
      isSuccess: 1,
      durationMs: 5,
      metadata: null,
    });
    const vals = extractValues(sql);
    assert.equal(vals[3], "NULL");
  });
});
