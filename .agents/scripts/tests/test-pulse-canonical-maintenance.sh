#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-canonical-maintenance.sh — GH#19949 regression guard.
#
# Asserts the canonical-repo fast-forward and stale worktree sweep
# pulse stage works end-to-end:
#
#   1. Cadence gate: skips when last run is recent, proceeds when stale.
#   2. Skip-on-dirty: repos with uncommitted changes are skipped.
#   3. Skip-on-session-active: repos with an active claim stamp are skipped.
#   4. Fast-forward: repos behind origin are fast-forwarded.
#   5. Dry-run mode: lists actions without mutating state.
#
# Uses a sandboxed git repo pair (bare origin + working clone) to test
# fast-forward behaviour without touching real repos.

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
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace" "${HOME}/.config/aidevops"

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
git config --global init.defaultBranch main 2>/dev/null || true

# Create a bare "origin" repo and a working clone for testing
_setup_test_repos() {
	local bare_dir="${TEST_ROOT}/origin.git"
	local clone_dir="${TEST_ROOT}/testrepo"

	# Clean up from previous tests to avoid stale state
	rm -rf "$bare_dir" "$clone_dir" "${TEST_ROOT}/tmp_clone" 2>/dev/null

	git init --bare "$bare_dir" >/dev/null 2>&1
	git clone "$bare_dir" "$clone_dir" >/dev/null 2>&1

	# Make an initial commit so main exists
	(
		cd "$clone_dir" || exit 1
		git checkout -b main >/dev/null 2>&1
		echo "initial" >file.txt
		git add file.txt
		git commit -m "initial commit" >/dev/null 2>&1
		git push -u origin main >/dev/null 2>&1
		# Set HEAD for symbolic-ref resolution
		git remote set-head origin main >/dev/null 2>&1
	)

	# Write repos.json pointing at the clone
	cat >"${HOME}/.config/aidevops/repos.json" <<EOF
{"initialized_repos": [{"slug": "test/repo", "path": "${clone_dir}", "pulse": true}]}
EOF
	export REPOS_JSON="${HOME}/.config/aidevops/repos.json"

	echo "$clone_dir"
	return 0
}

# Add a commit to origin (to make clone fall behind)
_push_new_commit_to_origin() {
	local bare_dir="${TEST_ROOT}/origin.git"
	local tmp_clone="${TEST_ROOT}/tmp_clone"

	git clone "$bare_dir" "$tmp_clone" >/dev/null 2>&1
	(
		cd "$tmp_clone" || exit 1
		echo "new content $(date +%s)" >newfile.txt
		git add newfile.txt
		git commit -m "new commit from origin" >/dev/null 2>&1
		git push origin main >/dev/null 2>&1
	)
	rm -rf "$tmp_clone"
	return 0
}

# Source shared-constants.sh to get basic utilities, then source the module
# Some functions from shared-constants.sh may not be available in test,
# so source with error suppression
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true
set +e

# Source the module under test
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-canonical-maintenance.sh" 2>/dev/null || true

# =============================================================================
# Test 1: Cadence gate — skip when last run is recent
# =============================================================================
test_cadence_skip_recent() {
	local now_epoch
	now_epoch=$(date +%s)
	# Set last run to 5 minutes ago (300s, well under 1800s cadence)
	local recent=$((now_epoch - 300))
	echo "$recent" >"$CANONICAL_MAINTENANCE_LAST_RUN"

	if _canonical_maintenance_check_cadence "$now_epoch"; then
		print_result "cadence-skip-recent" 1 "(expected skip, got proceed)"
	else
		print_result "cadence-skip-recent" 0
	fi
	return 0
}

# =============================================================================
# Test 2: Cadence gate — proceed when last run is old
# =============================================================================
test_cadence_proceed_old() {
	local now_epoch
	now_epoch=$(date +%s)
	# Set last run to 2 hours ago (7200s, well over 1800s cadence)
	local old=$((now_epoch - 7200))
	echo "$old" >"$CANONICAL_MAINTENANCE_LAST_RUN"

	if _canonical_maintenance_check_cadence "$now_epoch"; then
		print_result "cadence-proceed-old" 0
	else
		print_result "cadence-proceed-old" 1 "(expected proceed, got skip)"
	fi
	return 0
}

# =============================================================================
# Test 3: Cadence gate — proceed when state file missing
# =============================================================================
test_cadence_proceed_missing() {
	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"
	local now_epoch
	now_epoch=$(date +%s)

	if _canonical_maintenance_check_cadence "$now_epoch"; then
		print_result "cadence-proceed-missing" 0
	else
		print_result "cadence-proceed-missing" 1 "(expected proceed, got skip)"
	fi
	return 0
}

# =============================================================================
# Test 4: Skip-on-dirty — repos with uncommitted changes are skipped
# =============================================================================
test_skip_on_dirty() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	# Make the tree dirty
	echo "dirty" >"${clone_dir}/untracked_dirty.txt"
	(cd "$clone_dir" && git add untracked_dirty.txt) >/dev/null 2>&1

	# Reset cadence so it runs
	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"

	# Capture log output
	true > "$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "dirty tree" "$LOGFILE"; then
		print_result "skip-on-dirty" 0
	else
		print_result "skip-on-dirty" 1 "(expected 'dirty tree' in log)"
	fi
	return 0
}

# =============================================================================
# Test 5: Skip-on-session-active — repos with an active claim stamp are skipped
# =============================================================================
test_skip_on_session_active() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	# Create a fake claim stamp pointing at this repo with our PID
	local stamp_dir="${CANONICAL_MAINTENANCE_CLAIM_STAMP_DIR}"
	mkdir -p "$stamp_dir"
	cat >"${stamp_dir}/test-repo-123.json" <<EOF
{"worktree": "${clone_dir}", "pid": $$, "issue": 123}
EOF

	# Reset cadence
	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"

	true > "$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "active session" "$LOGFILE"; then
		print_result "skip-on-session-active" 0
	else
		print_result "skip-on-session-active" 1 "(expected 'active session' in log)"
	fi

	# Cleanup stamp
	rm -f "${stamp_dir}/test-repo-123.json"
	return 0
}

# =============================================================================
# Test 6: Successful fast-forward
# =============================================================================
test_fast_forward_success() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	# Push a new commit to origin so clone is behind
	_push_new_commit_to_origin

	# Reset cadence
	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"

	true > "$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "Fast-forwarded" "$LOGFILE"; then
		print_result "fast-forward-success" 0
	else
		print_result "fast-forward-success" 1 "(expected 'Fast-forwarded' in log, got: $(cat "$LOGFILE"))"
	fi
	return 0
}

# =============================================================================
# Test 7: Already up to date — no fast-forward needed
# =============================================================================
test_already_up_to_date() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	# No new commits, repo is already up to date
	# Fetch so origin ref is current
	(cd "$clone_dir" && git fetch origin --quiet) >/dev/null 2>&1

	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"
	true > "$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "already up to date" "$LOGFILE"; then
		print_result "already-up-to-date" 0
	else
		print_result "already-up-to-date" 1 "(expected 'already up to date' in log)"
	fi
	return 0
}

# =============================================================================
# Test 8: Dry-run mode — no mutations
# =============================================================================
test_dry_run() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	_push_new_commit_to_origin

	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"

	local output
	output=$(run_canonical_maintenance --dry-run 2>&1)

	if echo "$output" | grep -q "DRY_RUN"; then
		print_result "dry-run-output" 0
	else
		print_result "dry-run-output" 1 "(expected DRY_RUN in output)"
	fi

	# Verify clone was NOT actually fast-forwarded
	local behind
	behind=$(cd "$clone_dir" && git fetch origin --quiet 2>/dev/null && git rev-list --count "HEAD..origin/main" 2>/dev/null) || behind=0
	if [[ "$behind" -gt 0 ]]; then
		print_result "dry-run-no-mutation" 0
	else
		print_result "dry-run-no-mutation" 1 "(repo was mutated during dry-run)"
	fi
	return 0
}

# =============================================================================
# Test 9: Skip when not on default branch
# =============================================================================
test_skip_not_on_main() {
	local clone_dir
	clone_dir=$(_setup_test_repos)

	# Switch to a feature branch
	(cd "$clone_dir" && git checkout -b feature/test) >/dev/null 2>&1

	rm -f "$CANONICAL_MAINTENANCE_LAST_RUN"
	true > "$LOGFILE"
	_canonical_fast_forward "0"

	if grep -q "not on main" "$LOGFILE"; then
		print_result "skip-not-on-main" 0
	else
		print_result "skip-not-on-main" 1 "(expected 'not on main' in log)"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_cadence_skip_recent
test_cadence_proceed_old
test_cadence_proceed_missing
test_skip_on_dirty
test_skip_on_session_active
test_fast_forward_success
test_already_up_to_date
test_dry_run
test_skip_not_on_main

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
