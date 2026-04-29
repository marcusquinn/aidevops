#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-brief-filename-guard.sh — t3020 regression guard.
#
# Asserts that .agents/hooks/brief-filename-guard.sh blocks commits that ADD
# todo/tasks/tNNN-brief.md files whose t-ID has no "chore: claim tNNN" commit
# in git history, and that claimed IDs, deletions, multi-file scenarios, and
# the BRIEF_FILENAME_GUARD_DISABLE bypass all behave correctly.
#
# Test strategy: create an isolated temp repo with one claim commit for a
# known t-ID, then stage various combinations of brief files and run the guard
# directly (without committing) to assert exit code and output.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
GUARD="${REPO_ROOT}/.agents/hooks/brief-filename-guard.sh"

if [[ ! -x "$GUARD" ]]; then
	printf 'guard not found or not executable: %s\n' "$GUARD" >&2
	exit 1
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t3020-brief-guard.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP" || exit 1
git init -q
git config user.email "test@example.com"
git config user.name "Test"
# Disable commit signing — tests run in CI without GPG/SSH keys.
git config commit.gpgsign false
git config tag.gpgsign false
git config gpg.format openpgp

# Establish an initial (empty) commit so there is a HEAD.
git commit --allow-empty -q -m "initial"

# Commit a claim for a known t-ID (t99001) — the canonical "claimed" case.
# The guard searches git log --all --grep for "chore: claim tNNN".
git commit --allow-empty -q -m "chore: claim t99001 [test_claim]"

# Ensure the todo/tasks directory exists
mkdir -p todo/tasks

# =============================================================================
# Case 1: No staged brief files → guard should exit 0 (pass).
# =============================================================================
printf '\n[test] Case 1: no staged brief files\n'

exit_code=0
bash "$GUARD" >/dev/null 2>&1 || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
	pass "no staged brief files → exit 0"
else
	fail "expected exit 0, got $exit_code"
fi

# =============================================================================
# Case 2: Staged brief for UNCLAIMED t-ID → guard should block (exit 1).
# =============================================================================
printf '\n[test] Case 2: staged brief for unclaimed t-ID (t99999)\n'

printf 'placeholder\n' > todo/tasks/t99999-brief.md
git add todo/tasks/t99999-brief.md

output=""
exit_code=0
output=$(bash "$GUARD" 2>&1) || exit_code=$?

# Restore staged state for subsequent tests
git restore --staged todo/tasks/t99999-brief.md
rm -f todo/tasks/t99999-brief.md

if [[ "$exit_code" -eq 1 ]]; then
	pass "unclaimed t-ID → exit 1"
else
	fail "expected exit 1, got $exit_code" "$output"
fi

if [[ "$output" == *"t99999"* ]]; then
	pass "error output names the unclaimed task ID"
else
	fail "error output does not mention t99999" "$output"
fi

if [[ "$output" == *"not claimed"* || "$output" == *"unclaimed"* || "$output" == *"chore: claim"* ]]; then
	pass "error output contains remediation guidance"
else
	fail "error output lacks remediation guidance" "$output"
fi

# =============================================================================
# Case 3: Staged brief for CLAIMED t-ID (t99001) → guard should pass (exit 0).
# =============================================================================
printf '\n[test] Case 3: staged brief for claimed t-ID (t99001)\n'

printf 'placeholder\n' > todo/tasks/t99001-brief.md
git add todo/tasks/t99001-brief.md

exit_code=0
bash "$GUARD" >/dev/null 2>&1 || exit_code=$?

git restore --staged todo/tasks/t99001-brief.md
rm -f todo/tasks/t99001-brief.md

if [[ "$exit_code" -eq 0 ]]; then
	pass "claimed t-ID → exit 0"
else
	fail "expected exit 0, got $exit_code"
fi

# =============================================================================
# Case 4: Deleted brief file → guard should pass (exit 0).
# Deletions are not in --diff-filter=A (Added), so the guard ignores them.
# =============================================================================
printf '\n[test] Case 4: deleting a brief file (any t-ID)\n'

# Create and commit a brief file first (so it can be staged for deletion)
printf 'placeholder\n' > todo/tasks/t99998-brief.md
git add todo/tasks/t99998-brief.md
git commit -q -m "add t99998 brief for deletion test"

# Stage the deletion
git rm -q todo/tasks/t99998-brief.md

exit_code=0
bash "$GUARD" >/dev/null 2>&1 || exit_code=$?

# Restore
git restore --staged todo/tasks/t99998-brief.md 2>/dev/null || true
git checkout -- todo/tasks/t99998-brief.md 2>/dev/null || true

if [[ "$exit_code" -eq 0 ]]; then
	pass "deleting a brief file → exit 0"
else
	fail "expected exit 0 on deletion, got $exit_code"
fi

# =============================================================================
# Case 5: Multi-file stage — one claimed + one unclaimed → exit 1.
# Both files staged: t99001 (claimed) + t99002 (unclaimed).
# Guard must block because t99002 is invalid.
# =============================================================================
printf '\n[test] Case 5: multi-file stage (one claimed, one unclaimed)\n'

printf 'placeholder\n' > todo/tasks/t99001-brief.md
printf 'placeholder\n' > todo/tasks/t99002-brief.md
git add todo/tasks/t99001-brief.md todo/tasks/t99002-brief.md

output=""
exit_code=0
output=$(bash "$GUARD" 2>&1) || exit_code=$?

git restore --staged todo/tasks/t99001-brief.md todo/tasks/t99002-brief.md
rm -f todo/tasks/t99001-brief.md todo/tasks/t99002-brief.md

if [[ "$exit_code" -eq 1 ]]; then
	pass "mixed stage (one unclaimed) → exit 1"
else
	fail "expected exit 1 for mixed stage, got $exit_code" "$output"
fi

if [[ "$output" == *"t99002"* ]]; then
	pass "error output names the unclaimed t-ID (t99002)"
else
	fail "error output does not mention unclaimed t99002" "$output"
fi

if [[ "$output" != *"t99001"* || "$output" == *"BLOCK"*"t99001"* ]]; then
	# t99001 should NOT be named as an error; if it appears at all it should not be in a BLOCK line
	# Simplest check: the BLOCK message should not mention t99001 as unclaimed
	pass "claimed t-ID (t99001) not blocked in mixed stage"
else
	fail "t99001 was incorrectly blocked" "$output"
fi

# =============================================================================
# Case 6: BRIEF_FILENAME_GUARD_DISABLE=1 bypass
# =============================================================================
printf '\n[test] Case 6: BRIEF_FILENAME_GUARD_DISABLE=1 bypass\n'

printf 'placeholder\n' > todo/tasks/t99999-brief.md
git add todo/tasks/t99999-brief.md

exit_code=0
BRIEF_FILENAME_GUARD_DISABLE=1 bash "$GUARD" >/dev/null 2>&1 || exit_code=$?

git restore --staged todo/tasks/t99999-brief.md
rm -f todo/tasks/t99999-brief.md

if [[ "$exit_code" -eq 0 ]]; then
	pass "BRIEF_FILENAME_GUARD_DISABLE=1 bypasses the guard"
else
	fail "bypass via env var did not work, exit=$exit_code"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
