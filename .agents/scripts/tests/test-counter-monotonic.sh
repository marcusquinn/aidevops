#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-counter-monotonic.sh — Regression tests for .task-counter monotonicity guard (t2229)
#
# Verifies the three-layer defence against .task-counter silent regression:
#   1. .gitattributes contains `merge=ours` for .task-counter
#   2. CI workflow counter-monotonic.yml exists and checks for regression
#   3. full-loop-helper.sh _rebase_and_push auto-resets drifted counter
#
# Usage:
#   test-counter-monotonic.sh           # Run all tests
#   test-counter-monotonic.sh --verbose # Verbose output
#
# Requires: bash, git (for simulated repo tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="${SCRIPT_DIR}/../../.."

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
VERBOSE=0
TEST_ROOT=""

[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT:-}" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────
# Layer 1 tests: .gitattributes
# ──────────────────────────────────────────────────────────────

test_gitattributes_has_merge_ours() {
	local gitattr="${REPO_ROOT}/.gitattributes"
	if [[ ! -f "$gitattr" ]]; then
		print_result "gitattributes: file exists" 1 ".gitattributes not found at ${gitattr}"
		return 0
	fi
	if grep -q '^\.task-counter.*merge=ours' "$gitattr"; then
		print_result "gitattributes: .task-counter merge=ours present" 0
	else
		print_result "gitattributes: .task-counter merge=ours present" 1 \
			"Expected '.task-counter merge=ours' in .gitattributes"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────
# Layer 2 tests: CI workflow
# ──────────────────────────────────────────────────────────────

test_workflow_exists() {
	local workflow="${REPO_ROOT}/.github/workflows/counter-monotonic.yml"
	if [[ -f "$workflow" ]]; then
		print_result "workflow: counter-monotonic.yml exists" 0
	else
		print_result "workflow: counter-monotonic.yml exists" 1 \
			"Expected workflow at ${workflow}"
	fi
	return 0
}

test_workflow_triggers_on_task_counter() {
	local workflow="${REPO_ROOT}/.github/workflows/counter-monotonic.yml"
	[[ ! -f "$workflow" ]] && { print_result "workflow: triggers on .task-counter" 1 "workflow missing"; return 0; }
	if grep -q "'.task-counter'" "$workflow" || grep -q '".task-counter"' "$workflow"; then
		print_result "workflow: triggers on .task-counter path" 0
	else
		print_result "workflow: triggers on .task-counter path" 1 \
			"Workflow should trigger on paths: ['.task-counter']"
	fi
	return 0
}

test_workflow_compares_base_and_head() {
	local workflow="${REPO_ROOT}/.github/workflows/counter-monotonic.yml"
	[[ ! -f "$workflow" ]] && { print_result "workflow: compares counters" 1 "workflow missing"; return 0; }
	# Check that the workflow reads both base and head counters
	if grep -q 'git show.*\.task-counter' "$workflow" && grep -q 'cat .task-counter' "$workflow"; then
		print_result "workflow: reads base and head counter values" 0
	else
		print_result "workflow: reads base and head counter values" 1 \
			"Workflow should read both base (git show) and head (cat) counter values"
	fi
	return 0
}

test_workflow_fails_on_regression() {
	local workflow="${REPO_ROOT}/.github/workflows/counter-monotonic.yml"
	[[ ! -f "$workflow" ]] && { print_result "workflow: fails on regression" 1 "workflow missing"; return 0; }
	# Check that the workflow exits 1 when HEAD < BASE
	if grep -q 'exit 1' "$workflow" && grep -q 'regress' "$workflow"; then
		print_result "workflow: exits non-zero on regression" 0
	else
		print_result "workflow: exits non-zero on regression" 1 \
			"Workflow should 'exit 1' when counter regresses"
	fi
	return 0
}

test_workflow_uses_base10() {
	local workflow="${REPO_ROOT}/.github/workflows/counter-monotonic.yml"
	[[ ! -f "$workflow" ]] && { print_result "workflow: uses base-10" 1 "workflow missing"; return 0; }
	# Check for the 10# prefix to force base-10 (octal trap prevention)
	if grep -q '10#' "$workflow"; then
		print_result "workflow: forces base-10 comparison (octal trap prevention)" 0
	else
		print_result "workflow: forces base-10 comparison (octal trap prevention)" 1 \
			"Workflow should use 10# prefix for numeric comparison"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────
# Layer 3 tests: full-loop-helper.sh auto-reset
# ──────────────────────────────────────────────────────────────

test_full_loop_has_counter_reset() {
	local helper="${REPO_ROOT}/.agents/scripts/full-loop-helper.sh"
	if [[ ! -f "$helper" ]]; then
		print_result "full-loop: helper exists" 1 "full-loop-helper.sh not found"
		return 0
	fi
	# Check that _rebase_and_push contains the t2229 auto-reset block
	if grep -q 't2229' "$helper" && grep -q 'Auto-resetting .task-counter' "$helper"; then
		print_result "full-loop: _rebase_and_push has t2229 counter auto-reset" 0
	else
		print_result "full-loop: _rebase_and_push has t2229 counter auto-reset" 1 \
			"Expected t2229 counter drift reset in _rebase_and_push"
	fi
	return 0
}

test_full_loop_reset_uses_base10() {
	local helper="${REPO_ROOT}/.agents/scripts/full-loop-helper.sh"
	[[ ! -f "$helper" ]] && { print_result "full-loop: uses base-10" 1 "helper missing"; return 0; }
	# The reset comparison should use 10# for octal safety
	if grep -A5 'Auto-resetting' "$helper" | grep -q '10#' || \
	   grep -B5 'Auto-resetting' "$helper" | grep -q '10#'; then
		print_result "full-loop: counter reset uses base-10 comparison" 0
	else
		print_result "full-loop: counter reset uses base-10 comparison" 1 \
			"Counter comparison should use 10# prefix"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────
# Layer 3 simulation: test auto-reset logic in a temp git repo
# ──────────────────────────────────────────────────────────────

test_simulated_counter_drift_reset() {
	# Simulate the post-rebase state where the working tree has a stale
	# .task-counter value lower than origin/main. This is the exact state
	# that the Layer 3 logic in _rebase_and_push is designed to catch.
	TEST_ROOT=$(mktemp -d)
	local origin="${TEST_ROOT}/origin.git"
	local work="${TEST_ROOT}/work"

	# Set up a repo with origin/main at counter=2225
	git init --bare --initial-branch=main "$origin" >/dev/null 2>&1 || \
		git init --bare "$origin" >/dev/null 2>&1
	git clone "$origin" "$work" >/dev/null 2>&1 || true

	(
		set +e
		cd "$work" || exit 1
		git config user.email "test@test.com"
		git config user.name "Test"
		git config commit.gpgsign false
		git config tag.gpgsign false
		git checkout -b main >/dev/null 2>&1 || true

		# Seed counter at 2225 on main (simulates main having advanced)
		echo "2225" > .task-counter
		echo "hello" > file.txt
		git add -A >/dev/null 2>&1
		git commit -m "initial with counter 2225" >/dev/null 2>&1
		git push origin main >/dev/null 2>&1

		# Create feature branch, then manually set a stale counter
		# (simulates post-rebase state where branch carries stale value)
		git checkout -b feature/test >/dev/null 2>&1
		echo "2215" > .task-counter
		git add .task-counter >/dev/null 2>&1
		git commit -m "stale counter" >/dev/null 2>&1

		# Now simulate the Layer 3 logic (same as _rebase_and_push):
		local branch_counter="" base_counter=""
		branch_counter=$(cat .task-counter 2>/dev/null | tr -d '[:space:]')
		base_counter=$(git show origin/main:.task-counter 2>/dev/null | tr -d '[:space:]')

		if [[ -n "$branch_counter" && -n "$base_counter" ]] \
			&& [[ "$branch_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$base_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$((10#$branch_counter))" -lt "$((10#$base_counter))" ]]; then
			echo "$base_counter" > .task-counter
			echo "RESET_FIRED"
		else
			echo "NO_RESET"
		fi
	) > "${TEST_ROOT}/result.txt" 2>/dev/null

	local result=""
	result=$(tail -1 "${TEST_ROOT}/result.txt")

	if [[ "$result" == "RESET_FIRED" ]]; then
		print_result "simulation: counter drift detected and reset fires" 0
	else
		print_result "simulation: counter drift detected and reset fires" 1 \
			"Expected RESET_FIRED but got: ${result}"
	fi

	# Verify the counter value was corrected
	local final_counter=""
	final_counter=$(cat "${TEST_ROOT}/work/.task-counter" 2>/dev/null | tr -d '[:space:]')
	if [[ "$final_counter" == "2225" ]]; then
		print_result "simulation: counter value corrected to base (2225)" 0
	else
		print_result "simulation: counter value corrected to base (2225)" 1 \
			"Expected 2225, got: ${final_counter}"
	fi

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

test_simulated_no_false_positive() {
	TEST_ROOT=$(mktemp -d)
	local origin="${TEST_ROOT}/origin.git"
	local work="${TEST_ROOT}/work"

	# Create a bare origin repo
	git init --bare --initial-branch=main "$origin" >/dev/null 2>&1 || \
		git init --bare "$origin" >/dev/null 2>&1
	git clone "$origin" "$work" >/dev/null 2>&1 || true

	(
		set +e
		cd "$work" || exit 1
		git config user.email "test@test.com"
		git config user.name "Test"
		git config commit.gpgsign false
		git config tag.gpgsign false
		git checkout -b main >/dev/null 2>&1 || true

		# Seed counter at 2218 on main
		echo "2218" > .task-counter
		echo "hello" > file.txt
		git add -A >/dev/null 2>&1
		git commit -m "initial" >/dev/null 2>&1
		git push origin main >/dev/null 2>&1

		# Feature branch with counter HIGHER than main (normal: we claimed an ID)
		git checkout -b feature/test >/dev/null 2>&1
		echo "2219" > .task-counter
		git add .task-counter >/dev/null 2>&1
		git commit -m "claimed ID" >/dev/null 2>&1

		git fetch origin main --quiet >/dev/null 2>&1

		local branch_counter="" base_counter=""
		branch_counter=$(cat .task-counter 2>/dev/null | tr -d '[:space:]')
		base_counter=$(git show origin/main:.task-counter 2>/dev/null | tr -d '[:space:]')

		if [[ -n "$branch_counter" && -n "$base_counter" ]] \
			&& [[ "$branch_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$base_counter" =~ ^[0-9]+$ ]] \
			&& [[ "$((10#$branch_counter))" -lt "$((10#$base_counter))" ]]; then
			echo "RESET_FIRED"
		else
			echo "NO_RESET"
		fi
	) > "${TEST_ROOT}/result.txt" 2>/dev/null

	local result=""
	result=$(tail -1 "${TEST_ROOT}/result.txt")

	if [[ "$result" == "NO_RESET" ]]; then
		print_result "simulation: no false positive when counter >= base" 0
	else
		print_result "simulation: no false positive when counter >= base" 1 \
			"Expected NO_RESET but got: ${result}"
	fi

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

# ──────────────────────────────────────────────────────────────
# Docstring test: claim-task-id.sh mentions t2229
# ──────────────────────────────────────────────────────────────

test_claim_task_id_documents_rebase() {
	local script="${REPO_ROOT}/.agents/scripts/claim-task-id.sh"
	if [[ ! -f "$script" ]]; then
		print_result "claim-task-id: docs reference t2229" 1 "script not found"
		return 0
	fi
	if grep -q 't2229' "$script" && grep -q 'rebase' "$script"; then
		print_result "claim-task-id: documents rebase safety (t2229)" 0
	else
		print_result "claim-task-id: documents rebase safety (t2229)" 1 \
			"Expected t2229 rebase documentation in claim-task-id.sh header"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────────────────────

echo "=== t2229: .task-counter monotonicity guard regression tests ==="
echo ""

echo "--- Layer 1: .gitattributes ---"
test_gitattributes_has_merge_ours

echo ""
echo "--- Layer 2: CI workflow ---"
test_workflow_exists
test_workflow_triggers_on_task_counter
test_workflow_compares_base_and_head
test_workflow_fails_on_regression
test_workflow_uses_base10

echo ""
echo "--- Layer 3: full-loop-helper.sh auto-reset ---"
test_full_loop_has_counter_reset
test_full_loop_reset_uses_base10

echo ""
echo "--- Layer 3: simulated counter drift ---"
test_simulated_counter_drift_reset
test_simulated_no_false_positive

echo ""
echo "--- Documentation ---"
test_claim_task_id_documents_rebase

echo ""
echo "=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
