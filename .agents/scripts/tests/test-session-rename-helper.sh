#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for session-rename-helper.sh
#
# Covers the t2039 guards that prevent session titles from being clobbered
# with default branch names (main/master/HEAD) or overwritten when a
# meaningful title already exists.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../session-rename-helper.sh"

PASS=0
FAIL=0

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name (exit=$actual)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected exit: $expected"
		echo "    actual exit:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test fixture helpers
# -----------------------------------------------------------------------------

TMPDIR_ROOT=""
REPO_DIR=""
DB_PATH=""
SESSION_ID="ses_test_t2039"

setup_fixture() {
	TMPDIR_ROOT="$(mktemp -d)"
	REPO_DIR="${TMPDIR_ROOT}/fake-repo"
	DB_PATH="${TMPDIR_ROOT}/opencode.db"

	# Create a minimal git repo so `git rev-parse --abbrev-ref HEAD` works.
	mkdir -p "$REPO_DIR"
	git -C "$REPO_DIR" init -q -b main
	git -C "$REPO_DIR" config user.email "test@aidevops.sh"
	git -C "$REPO_DIR" config user.name "Test"
	git -C "$REPO_DIR" commit --allow-empty -q -m "init"

	# Create a session table matching the OpenCode schema subset the helper touches.
	sqlite3 "$DB_PATH" <<-'SQL'
		CREATE TABLE session (
		  id TEXT PRIMARY KEY,
		  title TEXT,
		  directory TEXT,
		  time_created INTEGER,
		  time_updated INTEGER
		);
	SQL
	return 0
}

teardown_fixture() {
	if [[ -n "$TMPDIR_ROOT" && -d "$TMPDIR_ROOT" ]]; then
		rm -rf "$TMPDIR_ROOT"
	fi
	return 0
}

# Seed the session row with a title and directory.
# Args: $1 = title, $2 = directory (default: REPO_DIR)
seed_session() {
	local title="$1"
	local directory="${2:-$REPO_DIR}"
	sqlite3 "$DB_PATH" \
		"DELETE FROM session WHERE id = '${SESSION_ID}'; \
		 INSERT INTO session (id, title, directory, time_created, time_updated) \
		 VALUES ('${SESSION_ID}', '${title}', '${directory}', 1000, 1000);"
	return 0
}

get_title() {
	sqlite3 "$DB_PATH" "SELECT title FROM session WHERE id = '${SESSION_ID}';"
	return 0
}

# Run sync-branch in a subshell with OPENCODE_DB + PWD = fake repo.
# Arg: $1 = branch name to check out before running
run_sync_on_branch() {
	local branch="$1"
	(
		cd "$REPO_DIR"
		git checkout -q -B "$branch"
		OPENCODE_DB="$DB_PATH" "$HELPER" sync-branch "$SESSION_ID" >/dev/null 2>&1
	)
	return $?
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

echo "=== session-rename-helper.sh tests ==="
echo ""

trap teardown_fixture EXIT
setup_fixture

# Test 1: sync to main must NOT rename
echo "Test 1: sync on 'main' branch skips rename (no clobber)"
seed_session "New Session"
run_sync_on_branch "main"
rc=$?
assert_exit "exit 0 on main skip" "0" "$rc"
assert_eq "title untouched on main" "New Session" "$(get_title)"

# Test 2: sync to master must NOT rename
echo ""
echo "Test 2: sync on 'master' branch skips rename"
seed_session "New Session"
run_sync_on_branch "master"
rc=$?
assert_exit "exit 0 on master skip" "0" "$rc"
assert_eq "title untouched on master" "New Session" "$(get_title)"

# Test 3: sync to feature/* renames as before
echo ""
echo "Test 3: sync on 'feature/x' renames session"
seed_session "New Session"
run_sync_on_branch "feature/cool-thing"
rc=$?
assert_exit "exit 0 on feature branch" "0" "$rc"
assert_eq "title renamed to feature branch" "feature/cool-thing" "$(get_title)"

# Test 4: do not clobber a meaningful existing title with a feature branch sync
echo ""
echo "Test 4: sync preserves existing meaningful title"
seed_session "investigating the session rename bug"
run_sync_on_branch "feature/auto-20260413-025423"
rc=$?
assert_exit "exit 0 preserve branch" "0" "$rc"
assert_eq "meaningful title preserved" "investigating the session rename bug" "$(get_title)"

# Test 5: empty title gets renamed (initial sync still works)
echo ""
echo "Test 5: empty title is overwritten on feature branch sync"
seed_session ""
run_sync_on_branch "feature/empty-title"
rc=$?
assert_exit "exit 0 on empty title sync" "0" "$rc"
assert_eq "empty title filled in" "feature/empty-title" "$(get_title)"

# Test 6: existing 'main' title is overwritten on feature branch sync
# (recovery path: sessions that already got stuck as 'main' by the old code
# should heal on the first sync from a real feature branch)
echo ""
echo "Test 6: stuck-on-main title heals when syncing from feature branch"
seed_session "main"
run_sync_on_branch "feature/heal-me"
rc=$?
assert_exit "exit 0 heal" "0" "$rc"
assert_eq "main title healed to feature" "feature/heal-me" "$(get_title)"

# Test 7: existing 'master' title is overwritten too
echo ""
echo "Test 7: stuck-on-master title heals when syncing from feature branch"
seed_session "master"
run_sync_on_branch "feature/heal-master"
rc=$?
assert_exit "exit 0 heal master" "0" "$rc"
assert_eq "master title healed" "feature/heal-master" "$(get_title)"

# Test 8: explicit rename still works for main (direct rename command is unguarded)
# The guards apply only to sync-branch (automatic, driven by cwd branch).
# Direct `rename` is a manual user action and should remain unrestricted.
echo ""
echo "Test 8: explicit 'rename' command ignores guards (manual override)"
seed_session "New Session"
OPENCODE_DB="$DB_PATH" "$HELPER" rename "$SESSION_ID" "main" >/dev/null 2>&1
rc=$?
assert_exit "exit 0 explicit rename" "0" "$rc"
assert_eq "explicit rename to main allowed" "main" "$(get_title)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
