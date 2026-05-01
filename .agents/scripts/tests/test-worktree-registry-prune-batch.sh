#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-registry-prune-batch.sh — GH#22131 regression guard.
#
# Verifies that prune_worktree_registry removes large missing-directory
# backlogs while preserving existing worktrees, without calling sqlite once per
# stale row through unregister_worktree.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT="${PWD}/.agents/tmp/test-worktree-registry-prune-batch.$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
mkdir -p "$WORKTREE_REGISTRY_DIR" "${HOME}/.aidevops/logs"

# shellcheck source=../shared-worktree-registry.sh
source "${TEST_SCRIPTS_DIR}/shared-worktree-registry.sh"

sqlite3 "$WORKTREE_REGISTRY_DB" "
CREATE TABLE worktree_owners (
    worktree_path TEXT PRIMARY KEY,
    branch TEXT,
    owner_pid INTEGER,
    owner_session TEXT,
    owner_batch TEXT,
    task_id TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
"

live_path="${TEST_ROOT}/live-worktree"
mkdir -p "$live_path"
sqlite3 "$WORKTREE_REGISTRY_DB" "
INSERT INTO worktree_owners (worktree_path, branch, owner_pid) VALUES ('$(_wt_sql_escape "$live_path")', 'feature/live', 999999);
"

stale_total=150
i=1
while [[ "$i" -le "$stale_total" ]]; do
	stale_path="${TEST_ROOT}/missing-${i}"
	sqlite3 "$WORKTREE_REGISTRY_DB" "
INSERT INTO worktree_owners (worktree_path, branch, owner_pid) VALUES ('$(_wt_sql_escape "$stale_path")', 'feature/missing-${i}', 999999);
"
	i=$((i + 1))
done

quoted_stale_path="${TEST_ROOT}/missing-o'clock"
sqlite3 "$WORKTREE_REGISTRY_DB" "
INSERT INTO worktree_owners (worktree_path, branch, owner_pid) VALUES ('$(_wt_sql_escape "$quoted_stale_path")', 'feature/quoted', 999999);
"

start_s=$(date +%s)
VERBOSE=1 prune_output=$(prune_worktree_registry 2>&1)
prune_rc=$?
end_s=$(date +%s)
duration=$((end_s - start_s))

print_result "prune exits successfully" "$prune_rc" "$prune_output"

remaining=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;")
if [[ "$remaining" == "1" ]]; then
	print_result "prune removes stale missing directories" 0
else
	print_result "prune removes stale missing directories" 1 "remaining=$remaining"
fi

live_remaining=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$(_wt_sql_escape "$live_path")';")
if [[ "$live_remaining" == "1" ]]; then
	print_result "prune preserves existing worktree rows" 0
else
	print_result "prune preserves existing worktree rows" 1 "live_remaining=$live_remaining"
fi

quoted_remaining=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$(_wt_sql_escape "$quoted_stale_path")';")
if [[ "$quoted_remaining" == "0" ]]; then
	print_result "prune deletes quoted stale paths" 0
else
	print_result "prune deletes quoted stale paths" 1 "quoted_remaining=$quoted_remaining"
fi

if [[ "$duration" -le 10 ]]; then
	print_result "prune completes within normal tool budget" 0
else
	print_result "prune completes within normal tool budget" 1 "duration=${duration}s"
fi

printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
