#!/usr/bin/env bun
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// =============================================================================
// Tests for .opencode/tool/session-rename.ts guard functions (t2252)
//
// These exercise the TypeScript-side mirrors of session-rename-helper.sh's
// _is_meaningful_branch_title and _is_title_overwritable. The OpenCode
// MCP tool path bypasses the shell helper entirely, so it needs its own
// regression coverage to prevent auto-compaction from clobbering the
// session title with "main".
// =============================================================================

import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Import from the extracted guards module — it has no runtime-injected
// dependencies so it loads cleanly under `bun run` without the OpenCode
// plugin runtime. session-rename.ts re-exports these symbols for callers
// that already import from it.
const { isDefaultBranchTitle, isTitleOverwritable } = await import(
  "../../../.opencode/lib/session-rename-guards.ts"
);

let pass = 0;
let fail = 0;

function assertEq(name, expected, actual) {
  if (expected === actual) {
    console.log(`  PASS: ${name}`);
    pass++;
  } else {
    console.log(`  FAIL: ${name}`);
    console.log(`    expected: ${JSON.stringify(expected)}`);
    console.log(`    actual:   ${JSON.stringify(actual)}`);
    fail++;
  }
}

console.log("=== session-rename.ts guard tests (t2252) ===\n");

// --- isDefaultBranchTitle ---------------------------------------------------
console.log("Group 1: isDefaultBranchTitle");
assertEq("empty string is default", true, isDefaultBranchTitle(""));
assertEq("'HEAD' is default", true, isDefaultBranchTitle("HEAD"));
assertEq("'main' is default", true, isDefaultBranchTitle("main"));
assertEq("'master' is default", true, isDefaultBranchTitle("master"));
assertEq("'feature/x' is NOT default", false, isDefaultBranchTitle("feature/x"));
assertEq("'bugfix/t2252-foo' is NOT default", false, isDefaultBranchTitle("bugfix/t2252-foo"));
assertEq("'develop' is NOT default", false, isDefaultBranchTitle("develop"));
assertEq("'mainline' is NOT default (exact match only)", false, isDefaultBranchTitle("mainline"));
assertEq("' main' is NOT default (whitespace-sensitive)", false, isDefaultBranchTitle(" main"));

// --- isTitleOverwritable ----------------------------------------------------
console.log("\nGroup 2: isTitleOverwritable");

const tmp = mkdtempSync(join(tmpdir(), "t2252-"));
const dbPath = join(tmp, "test.db");

try {
  const db = new Database(dbPath);
  db.run(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY,
      title TEXT,
      directory TEXT,
      time_created INTEGER,
      time_updated INTEGER
    )
  `);

  function seed(id, title) {
    db.run(
      "INSERT OR REPLACE INTO session (id, title, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
      [id, title, "/tmp", 1000, 1000],
    );
  }

  // Missing row — safe to write (session not yet persisted).
  assertEq("missing row is overwritable", true, isTitleOverwritable(db, "ses_missing"));

  // NULL / empty titles.
  seed("ses_empty", "");
  assertEq("empty string title is overwritable", true, isTitleOverwritable(db, "ses_empty"));

  // Default placeholder titles.
  seed("ses_default", "New Session");
  assertEq("'New Session' is overwritable", true, isTitleOverwritable(db, "ses_default"));

  // Stuck-on-default titles (recovery path).
  seed("ses_stuck_main", "main");
  assertEq("'main' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_main"));

  seed("ses_stuck_master", "master");
  assertEq("'master' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_master"));

  seed("ses_stuck_head", "HEAD");
  assertEq("'HEAD' title is overwritable (recovery)", true, isTitleOverwritable(db, "ses_stuck_head"));

  // Meaningful titles — must be preserved.
  seed("ses_feature", "feature/cool-thing");
  assertEq("feature branch title is PRESERVED", false, isTitleOverwritable(db, "ses_feature"));

  seed("ses_llm", "Investigating auto-compaction bug");
  assertEq("LLM-generated title is PRESERVED", false, isTitleOverwritable(db, "ses_llm"));

  seed("ses_bugfix", "bugfix/t2252-session-title-compaction");
  assertEq("bugfix branch title is PRESERVED", false, isTitleOverwritable(db, "ses_bugfix"));

  seed("ses_weird", "mainline");
  assertEq("'mainline' (close to default) is PRESERVED", false, isTitleOverwritable(db, "ses_weird"));

  db.close();
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

console.log("\n=== Results ===");
console.log(`PASS: ${pass}`);
console.log(`FAIL: ${fail}`);
process.exit(fail > 0 ? 1 : 0);
