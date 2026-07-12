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

memory() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" AIDEVOPS_VAULT_DIR="$TEST_DIR/no-vault" "$MEMORY_HELPER" "$@"
	return $?
}

store_id() {
	memory store "$@" | sed -n '$p'
	return "${PIPESTATUS[0]}"
}

query() {
	local sql="$1"
	sqlite3 "$TEST_DIR/memory.db" "$sql"
	return $?
}

id_a=$(store_id --content "Prefers compact audit output" --type USER_PREFERENCE --project /project/a)
id_b=$(store_id --content "Prefers compact audit output" --type USER_PREFERENCE --project /project/b)
id_a_repeat=$(store_id --content "Prefers compact audit output" --type USER_PREFERENCE --project /project/a)
assert_eq "$id_a" "$id_a_repeat" "exact dedup stays within project scope"
[[ "$id_a" != "$id_b" ]] || fail "cross-project preferences must not deduplicate"
assert_eq 2 "$(query 'SELECT COUNT(*) FROM observations WHERE kind="preference" AND status="active";')" "both scoped preferences remain live"
assert_eq 0 "$(query "SELECT COALESCE(access_count, 0) FROM learning_access WHERE id='$id_a' UNION ALL SELECT 0 LIMIT 1;")" "reprocessing one source does not add evidence"

query "UPDATE observations SET status='debunked' WHERE observation_id='obs_learning_$id_a';"
recent=$(memory recall --recent --project /project/a --json | sed -n '/^\[/,$p')
assert_eq "" "$recent" "recent recall hides non-live observations"
keyword=$(memory recall compact --project /project/a --json | sed -n '/^\[/,$p')
assert_eq "" "$keyword" "keyword recall hides non-live observations"

# Seed an independently sourced duplicate in one scope and verify provenance is retained.
id_c=$(store_id --content "Scoped duplicate evidence" --type CONTEXT --project /project/c)
query "INSERT INTO learnings VALUES ('mem_seed','session_seed','Scoped duplicate evidence','CONTEXT','','medium','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','/project/c','fixture');"
query "INSERT INTO observations SELECT 'obs_learning_mem_seed',kind,owner_id,subject_id,'session_seed',user_scope,project_scope,organization_scope,framework_scope,state,statement,confidence,sensitivity,consent,effective_at,review_at,expires_at,destination,status,'2026-01-01T00:00:00Z' FROM observations WHERE observation_id='obs_learning_$id_c';"
query "INSERT INTO observation_sources VALUES ('src_learning_mem_seed','obs_learning_mem_seed','learning','mem_seed','session_seed','Scoped duplicate evidence','fixture','2026-01-01T00:00:00Z');"
memory dedup --exact-only >/dev/null
assert_eq 1 "$(query 'SELECT COUNT(*) FROM learnings WHERE content="Scoped duplicate evidence";')" "same-scope exact duplicates merge"
assert_eq 2 "$(query 'SELECT COUNT(*) FROM observation_sources WHERE evidence="Scoped duplicate evidence";')" "independent source evidence survives merge"
assert_eq 1 "$(query 'SELECT COUNT(DISTINCT observation_id) FROM observation_sources WHERE evidence="Scoped duplicate evidence";')" "merged evidence points to one observation"

printf 'PASS: observation scope, live retrieval, dedup partitioning, and source evidence\n'
