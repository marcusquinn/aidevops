#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[[ "$actual" == "$expected" ]] || fail "$message (expected $expected, got $actual)"
	return 0
}

run_memory() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" "$MEMORY_HELPER" "$@"
	return $?
}

db_query() {
	local sql="$1"
	sqlite3 "$TEST_DIR/memory.db" "$sql"
	return $?
}

# Seed a pre-observation database and verify lossless additive migration.
sqlite3 "$TEST_DIR/memory.db" <<'EOF'
CREATE VIRTUAL TABLE learnings USING fts5(id UNINDEXED, session_id UNINDEXED, content, type, tags, confidence UNINDEXED, created_at UNINDEXED, event_date UNINDEXED, project_path UNINDEXED, source UNINDEXED, tokenize='porter unicode61');
CREATE TABLE learning_access (id TEXT PRIMARY KEY, last_accessed_at TEXT, access_count INTEGER DEFAULT 0, auto_captured INTEGER DEFAULT 0, usefulness_score REAL DEFAULT 0.0, graduated_at TEXT);
CREATE TABLE learning_relations (id TEXT NOT NULL, supersedes_id TEXT, relation_type TEXT CHECK(relation_type IN ('updates','extends','derives','debunks')), created_at TEXT, PRIMARY KEY(id,supersedes_id,relation_type));
INSERT INTO learnings VALUES ('mem_old','session_stable','Prefers terse output','USER_PREFERENCE','preference','high','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','/project/a','manual');
INSERT INTO learnings VALUES ('mem_new','session_stable','Prefers detailed output for audits','USER_PREFERENCE','preference','high','2026-02-01T00:00:00Z','2026-02-01T00:00:00Z','/project/b','manual');
INSERT INTO learning_access VALUES ('mem_new','2026-02-02T00:00:00Z',3,0,1.5,'2026-02-03T00:00:00Z');
INSERT INTO learning_relations VALUES ('mem_new','mem_old','updates','2026-02-01T00:00:00Z');
EOF

run_memory stats >/dev/null
assert_eq 2 "$(db_query 'SELECT COUNT(*) FROM observations WHERE observation_id LIKE "obs_learning_%";')" "old schema rows migrate"
assert_eq session_stable "$(db_query 'SELECT session_id FROM observations WHERE observation_id="obs_learning_mem_old";')" "stable session ID retained"
assert_eq 2 "$(db_query 'SELECT COUNT(DISTINCT project_scope) FROM observations WHERE kind="preference";')" "cross-project preferences remain scoped"
assert_eq superseded "$(db_query 'SELECT status FROM observations WHERE observation_id="obs_learning_mem_old";')" "supersession state maps"
assert_eq unspecified "$(db_query 'SELECT consent FROM observations WHERE observation_id="obs_learning_mem_new";')" "privacy consent is explicit"
assert_eq internal "$(db_query 'SELECT sensitivity FROM observations WHERE observation_id="obs_learning_mem_new";')" "privacy sensitivity is explicit"
assert_eq 1 "$(db_query 'SELECT COUNT(*) FROM observation_outcomes WHERE observation_id="obs_learning_mem_new" AND outcome_kind="graduated";')" "graduation history maps"

run_memory stats >/dev/null
assert_eq 2 "$(db_query 'SELECT COUNT(*) FROM observation_sources WHERE source_kind="learning";')" "repeat migration does not fabricate evidence"
assert_eq 1 "$(db_query 'SELECT COUNT(*) FROM observation_relations WHERE relation_type="supersedes";')" "repeat migration keeps one relation"

if run_memory feedback mem_new --value "0); DROP TABLE learnings; --" >/dev/null 2>&1; then
	fail "feedback accepted a non-numeric custom reward"
fi
if run_memory feedback mem_new --value 1.0 --signal "'; DROP TABLE learnings; --" >/dev/null 2>&1; then
	fail "feedback accepted a malicious signal with custom value"
fi
if run_memory feedback mem_new --value >/dev/null 2>&1; then
	fail "feedback accepted a missing custom reward"
fi
assert_eq 2 "$(db_query 'SELECT COUNT(*) FROM learnings;')" "invalid custom reward cannot alter the database"
run_memory feedback mem_new --value -0.25 >/dev/null
assert_eq 1.25 "$(db_query 'SELECT usefulness_score FROM learning_access WHERE id="mem_new";')" "numeric custom reward remains supported"

printf 'PASS: canonical observation migration, idempotency, scope, supersession, and privacy metadata\n'
