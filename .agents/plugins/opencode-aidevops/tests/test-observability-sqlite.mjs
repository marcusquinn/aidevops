// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { isSqliteBusyError } from "../observability-sqlite.mjs";

describe("observability SQLite fail-open helpers", () => {
  test("detects common SQLite busy/locked errors", () => {
    assert.equal(isSqliteBusyError("Runtime error near line 42: database is locked (5)"), true);
    assert.equal(isSqliteBusyError("SQLITE_BUSY: database table is locked"), true);
  });

  test("does not suppress unrelated SQLite errors", () => {
    assert.equal(isSqliteBusyError("no such table: tool_calls"), false);
    assert.equal(isSqliteBusyError("disk I/O error"), false);
  });
});
