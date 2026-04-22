#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-default-branch-detection.sh — GH#20487 regression guard.
#
# Asserts that pulse-canonical-maintenance.sh and pulse-dirty-pr-sweep.sh
# suppress `fatal: ambiguous argument 'origin/main'` errors and behave
# correctly when operating on:
#
#   1. A repo with origin/HEAD pointing to "main" (standard case, unchanged).
#   2. A repo with origin/HEAD pointing to "master" (non-main default branch).
#   3. A repo without origin/HEAD set at all (no symbolic ref).
#
# Coverage:
#   - _get_default_branch_for_repo detects "main" and "master" correctly.
#   - _get_default_branch_for_repo returns 1 (failure) when no origin/HEAD set.
#   - _canonical_ff_should_skip_repo skips repos with no origin/HEAD (logs reason).
#   - _canonical_ff_single_repo skips repos with no origin/HEAD (logs reason).
#   - _dps_get_default_branch detects branches correctly and fails gracefully.
#   - _canonical_fast_forward produces no `fatal:` lines in stderr for
#     repos without origin/HEAD.
#   - _canonical_fast_forward successfully fast-forwards a "master"-branch repo.

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

# Sandbox
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace" \
	"${HOME}/.config/aidevops"

# Minimal LOGFILE for the module
export LOGFILE="${TEST_ROOT}/test.log"
touch "$LOGFILE"

# SCRIPT_DIR expected by the module
export SCRIPT_DIR="$TEST_SCRIPTS_DIR"

# Disable commit signing for test repos (avoids SSH passphrase prompts)
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"
git config --global commit.gpgsign false 2>/dev/null || true
git config --global tag.gpgsign false 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helper: create a bare origin + working clone on a given default branch name.
# Args: $1 - default_branch_name (e.g. "main", "master")
#       $2 - set_head ("1" to run git remote set-head, "0" to skip)
# Output: clone directory path
# ---------------------------------------------------------------------------
_setup_repo_with_branch() {
	local branch_name="$1"
	local set_head="${2:-1}"
	local bare_dir="${TEST_ROOT}/origin-${branch_name}.git"
	local clone_dir="${TEST_ROOT}/repo-${branch_name}"

	rm -rf "$bare_dir" "$clone_dir" 2>/dev/null || true

	git init --bare "$bare_dir" >/dev/null 2>&1
	git clone "$bare_dir" "$clone_dir" >/dev/null 2>&1
	(
		cd "$clone_dir" || exit 1
		git checkout -b "$branch_name" >/dev/null 2>&1
		echo "initial" >file.txt
		git add file.txt
		git commit -m "initial commit" >/dev/null 2>&1
		git push -u origin "$branch_name" >/dev/null 2>&1
		if [[ "$set_head" == "1" ]]; then
			git remote set-head origin "$branch_name" >/dev/null 2>&1
		fi
	)

	echo "$clone_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Helper: push a new commit to the bare origin.
# Args: $1 - branch_name, $2 - clone_dir
# ---------------------------------------------------------------------------
_push_new_commit() {
	local branch_name="$1"
	local clone_dir="$2"
	local tmp_clone="${TEST_ROOT}/tmp-push-${branch_name}"

	rm -rf "$tmp_clone" 2>/dev/null || true
	local bare_dir="${TEST_ROOT}/origin-${branch_name}.git"
	git clone "$bare_dir" "$tmp_clone" >/dev/null 2>&1
	(
		cd "$tmp_clone" || exit 1
		git checkout "$branch_name" >/dev/null 2>&1
		echo "new content $(date +%s)" >newfile.txt
		git add newfile.txt
		git commit -m "new commit from origin" >/dev/null 2>&1
		git push origin "$branch_name" >/dev/null 2>&1
	)
	rm -rf "$tmp_clone" 2>/dev/null || true
	return 0
}

# Source shared-constants.sh then the modules under test.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true
set +e

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-canonical-maintenance.sh" 2>/dev/null || true

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-dirty-pr-sweep.sh" 2>/dev/null || true

# =============================================================================
# Test 1: _get_default_branch_for_repo detects "main"
# =============================================================================
test_detect_main_branch() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "1")

	local detected
	detected=$(_get_default_branch_for_repo "$clone_dir")
	if [[ "$detected" == "main" ]]; then
		print_result "get-default-branch-main" 0
	else
		print_result "get-default-branch-main" 1 "(expected 'main', got '${detected}')"
	fi
	return 0
}

# =============================================================================
# Test 2: _get_default_branch_for_repo detects "master"
# =============================================================================
test_detect_master_branch() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "master" "1")

	local detected
	detected=$(_get_default_branch_for_repo "$clone_dir")
	if [[ "$detected" == "master" ]]; then
		print_result "get-default-branch-master" 0
	else
		print_result "get-default-branch-master" 1 "(expected 'master', got '${detected}')"
	fi
	return 0
}

# =============================================================================
# Test 3: _get_default_branch_for_repo returns 1 when no origin/HEAD set
# =============================================================================
test_no_origin_head_returns_failure() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "0")  # skip set-head

	if _get_default_branch_for_repo "$clone_dir" 2>/dev/null; then
		print_result "get-default-branch-no-head" 1 "(expected return 1, got 0)"
	else
		print_result "get-default-branch-no-head" 0
	fi
	return 0
}

# =============================================================================
# Test 4: _canonical_ff_should_skip_repo skips when no origin/HEAD
# =============================================================================
test_canonical_skip_no_origin_head() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "0")  # skip set-head

	true >"$LOGFILE"
	_canonical_ff_should_skip_repo "$clone_dir"
	local rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q "no origin/HEAD set" "$LOGFILE"; then
		print_result "canonical-skip-no-origin-head" 0
	else
		print_result "canonical-skip-no-origin-head" 1 "(rc=${rc}, log: $(cat "$LOGFILE"))"
	fi
	return 0
}

# =============================================================================
# Test 5: _canonical_ff_single_repo skips when no origin/HEAD
# =============================================================================
test_canonical_ff_single_skip_no_origin_head() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "0")  # skip set-head

	true >"$LOGFILE"
	_canonical_ff_single_repo "$clone_dir" "0"
	local rc=$?

	# Should return 1 (skip/failure) with a log message about no origin/HEAD
	if [[ "$rc" -eq 1 ]] && grep -q "no origin/HEAD set" "$LOGFILE"; then
		print_result "canonical-ff-single-skip-no-head" 0
	else
		print_result "canonical-ff-single-skip-no-head" 1 "(rc=${rc}, log: $(cat "$LOGFILE"))"
	fi
	return 0
}

# =============================================================================
# Test 6: No `fatal:` lines in stderr when _canonical_fast_forward encounters
#         a repo without origin/HEAD set (GH#20487 regression guard)
# =============================================================================
test_no_fatal_errors_without_origin_head() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "0")  # skip set-head

	# Point repos.json at this repo
	cat >"${HOME}/.config/aidevops/repos.json" <<EOF
{"initialized_repos": [{"slug": "test/repo", "path": "${clone_dir}", "pulse": true}]}
EOF
	export REPOS_JSON="${HOME}/.config/aidevops/repos.json"

	# Capture stderr separately to check for fatal errors
	local stderr_file="${TEST_ROOT}/stderr.txt"
	true >"$LOGFILE"
	_canonical_fast_forward "0" 2>"$stderr_file"

	if ! grep -q "^fatal:" "$stderr_file" 2>/dev/null; then
		print_result "no-fatal-errors-without-origin-head" 0
	else
		print_result "no-fatal-errors-without-origin-head" 1 \
			"(unexpected fatal errors: $(cat "$stderr_file"))"
	fi
	return 0
}

# =============================================================================
# Test 7: _canonical_fast_forward succeeds for a "master"-branch repo
# =============================================================================
test_canonical_ff_master_branch() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "master" "1")

	# Push a new commit to origin
	_push_new_commit "master" "$clone_dir"

	# Point repos.json at this repo
	cat >"${HOME}/.config/aidevops/repos.json" <<EOF
{"initialized_repos": [{"slug": "test/repo", "path": "${clone_dir}", "pulse": true}]}
EOF
	export REPOS_JSON="${HOME}/.config/aidevops/repos.json"

	# Reset cadence so it runs
	export CANONICAL_MAINTENANCE_LAST_RUN="${TEST_ROOT}/last-run"
	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"

	true >"$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "Fast-forwarded" "$LOGFILE"; then
		print_result "canonical-ff-master-branch" 0
	else
		print_result "canonical-ff-master-branch" 1 "(expected 'Fast-forwarded' in log, got: $(cat "$LOGFILE"))"
	fi
	return 0
}

# =============================================================================
# Test 8: _dps_get_default_branch detects "main"
# =============================================================================
test_dps_detect_main() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "1")

	local detected
	detected=$(_dps_get_default_branch "$clone_dir")
	if [[ "$detected" == "main" ]]; then
		print_result "dps-get-default-branch-main" 0
	else
		print_result "dps-get-default-branch-main" 1 "(expected 'main', got '${detected}')"
	fi
	return 0
}

# =============================================================================
# Test 9: _dps_get_default_branch detects "master"
# =============================================================================
test_dps_detect_master() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "master" "1")

	local detected
	detected=$(_dps_get_default_branch "$clone_dir")
	if [[ "$detected" == "master" ]]; then
		print_result "dps-get-default-branch-master" 0
	else
		print_result "dps-get-default-branch-master" 1 "(expected 'master', got '${detected}')"
	fi
	return 0
}

# =============================================================================
# Test 10: _dps_get_default_branch returns 1 when no origin/HEAD set
# =============================================================================
test_dps_no_origin_head_returns_failure() {
	local clone_dir
	clone_dir=$(_setup_repo_with_branch "main" "0")  # skip set-head

	if _dps_get_default_branch "$clone_dir" 2>/dev/null; then
		print_result "dps-get-default-branch-no-head" 1 "(expected return 1, got 0)"
	else
		print_result "dps-get-default-branch-no-head" 0
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_detect_main_branch
test_detect_master_branch
test_no_origin_head_returns_failure
test_canonical_skip_no_origin_head
test_canonical_ff_single_skip_no_origin_head
test_no_fatal_errors_without_origin_head
test_canonical_ff_master_branch
test_dps_detect_main
test_dps_detect_master
test_dps_no_origin_head_returns_failure

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================="
echo "Tests run: ${TESTS_RUN}"
echo "Tests failed: ${TESTS_FAILED}"
echo "============================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
