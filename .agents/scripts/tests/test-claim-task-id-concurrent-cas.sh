#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-concurrent-cas.sh — Regression test for GH#19689
#
# Verifies that N concurrent claim-task-id.sh invocations produce N
# distinct task IDs with the counter advancing by exactly N.
#
# Approach: creates a local bare repo as a "remote", seeds .task-counter,
# then launches N concurrent claim processes. Asserts:
#   1. All N IDs are distinct
#   2. Counter advances by exactly N
#   3. No two commit messages share the same task ID
#
# Requires: bash 4+, git

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# ---------------------------------------------------------------------------
# Setup: create a local bare repo as the "remote" and a working clone
# ---------------------------------------------------------------------------
setup_test_repos() {
	local base_dir="$1"

	# Create bare repo (acts as "origin")
	local bare_dir="${base_dir}/remote.git"
	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || {
		# Fallback for older git without --initial-branch
		git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	}

	# Create working clone
	local work_dir="${base_dir}/work"
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || return 1

	# Disable commit signing in the test repo (avoids SSH passphrase prompts)
	git -C "$work_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	git -C "$work_dir" config tag.gpgsign false >/dev/null 2>&1 || true
	# Set required identity for commits
	git -C "$work_dir" config user.email "test@test.local" >/dev/null 2>&1 || true
	git -C "$work_dir" config user.name "Test" >/dev/null 2>&1 || true

	# Seed .task-counter with a known value
	local seed_value=1000
	printf '%s\n' "$seed_value" >"${work_dir}/.task-counter"

	# Create a minimal TODO.md (required by collision check)
	printf '# Tasks\n\n- [x] t999 seed task\n' >"${work_dir}/TODO.md"

	# Initial commit + push
	git -C "$work_dir" checkout -b main >/dev/null 2>&1 || true
	git -C "$work_dir" add .task-counter TODO.md >/dev/null 2>&1
	git -C "$work_dir" commit -m "chore: seed counter at ${seed_value}" >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1

	echo "$work_dir"
	return 0
}

# ---------------------------------------------------------------------------
# Test: N concurrent claims produce N distinct IDs
# ---------------------------------------------------------------------------
# Launch N concurrent claim-task-id processes, collect results into results_dir.
# Returns: claimed IDs in result-{1..N}.txt files under results_dir.
_launch_concurrent_claims() {
	local num_concurrent="$1"
	local work_dir="$2"
	local results_dir="$3"

	mkdir -p "$results_dir"
	local pids=()
	local i
	for ((i = 1; i <= num_concurrent; i++)); do
		(
			local output
			output=$("$CLAIM_SCRIPT" \
				--title "concurrent test $i" \
				--no-issue \
				--repo-path "$work_dir" \
				--counter-branch main 2>/dev/null) || true
			local task_id
			task_id=$(printf '%s' "$output" | grep '^task_id=' | head -1 | sed 's/^task_id=//')
			printf '%s\n' "$task_id" >"${results_dir}/result-${i}.txt"
		) &
		pids+=($!)
	done
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

# Verify concurrent claim results: all IDs distinct, counter correct, no dup commits.
_verify_claim_results() {
	local name="$1"
	local num_concurrent="$2"
	local work_dir="$3"
	local results_dir="$4"
	local initial_counter="$5"

	# Collect results
	local -a claimed_ids=()
	local result_count=0 i
	for ((i = 1; i <= num_concurrent; i++)); do
		local result_file="${results_dir}/result-${i}.txt"
		if [[ -f "$result_file" ]]; then
			local tid
			tid=$(tr -d '[:space:]' < "$result_file")
			[[ -n "$tid" ]] && { claimed_ids+=("$tid"); result_count=$((result_count + 1)); }
		fi
	done
	if [[ $result_count -ne $num_concurrent ]]; then
		fail "$name" "expected ${num_concurrent} results, got ${result_count}"; return 0
	fi

	# All IDs distinct
	local unique_count
	unique_count=$(printf '%s\n' "${claimed_ids[@]}" | sort -u | wc -l | tr -d '[:space:]')
	if [[ "$unique_count" -ne "$num_concurrent" ]]; then
		local dups
		dups=$(printf '%s\n' "${claimed_ids[@]}" | sort | uniq -d | tr '\n' ' ')
		fail "$name" "expected ${num_concurrent} distinct IDs, got ${unique_count} (duplicates: ${dups})"; return 0
	fi

	# Counter advanced by exactly N
	git -C "$work_dir" fetch origin main >/dev/null 2>&1 || true
	local final_counter expected_counter
	final_counter=$(git -C "$work_dir" show "origin/main:.task-counter" 2>/dev/null | tr -d '[:space:]')
	expected_counter=$((initial_counter + num_concurrent))
	if [[ "$final_counter" -ne "$expected_counter" ]]; then
		fail "$name" "expected counter=${expected_counter}, got ${final_counter}"; return 0
	fi

	# No duplicate task IDs in commit messages
	local claim_commits
	claim_commits=$(git -C "$work_dir" log origin/main --oneline --grep="chore: claim" | grep -oE 't[0-9]+' | sort)
	local uniq_commits total_commits
	uniq_commits=$(printf '%s\n' "$claim_commits" | sort -u | wc -l | tr -d '[:space:]')
	total_commits=$(printf '%s\n' "$claim_commits" | wc -l | tr -d '[:space:]')
	if [[ "$uniq_commits" -ne "$total_commits" ]]; then
		local dup_commits
		dup_commits=$(printf '%s\n' "$claim_commits" | sort | uniq -d | tr '\n' ' ')
		fail "$name" "duplicate task IDs in commit messages: ${dup_commits}"; return 0
	fi

	pass "$name"
	return 0
}

test_concurrent_claims() {
	local num_concurrent="${1:-10}"
	local name="concurrent CAS: ${num_concurrent} parallel claims produce ${num_concurrent} distinct IDs"

	local tmpdir
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local work_dir
	work_dir=$(setup_test_repos "$tmpdir") || { fail "$name" "repo setup failed"; return 0; }

	local initial_counter
	initial_counter=$(git -C "$work_dir" show "origin/main:.task-counter" 2>/dev/null | tr -d '[:space:]')
	if [[ -z "$initial_counter" ]]; then
		fail "$name" "could not read initial counter"; return 0
	fi

	_launch_concurrent_claims "$num_concurrent" "$work_dir" "${tmpdir}/results"
	_verify_claim_results "$name" "$num_concurrent" "$work_dir" "${tmpdir}/results" "$initial_counter"
	return 0
}

# ---------------------------------------------------------------------------
# Test: verify pinned SHA prevents stale-parent race
#
# This is a unit-style test that sources the script and verifies that
# allocate_counter_cas uses the pinned SHA for tree reads, not the ref.
# We do this by checking that git ls-tree is called with a SHA pattern
# (40+ hex chars) rather than "origin/main" in the fixed code.
# ---------------------------------------------------------------------------
test_pinned_sha_in_source() {
	local name="source check: CAS helpers use pinned_sha for ls-tree and commit-tree"

	# After refactoring (GH#19689), the git plumbing lives in _cas_build_and_push.
	# Verify it uses the pinned_sha parameter, not the ref name.
	local build_body
	build_body=$(sed -n '/^_cas_build_and_push()/,/^}/p' "$CLAIM_SCRIPT")

	# Check that git ls-tree uses the first parameter (pinned_sha)
	if echo "$build_body" | grep -q 'git ls-tree.*pinned_sha'; then
		: # good
	else
		fail "$name" "git ls-tree in _cas_build_and_push does not use pinned_sha"
		return 0
	fi

	# Check that git commit-tree uses pinned_sha as parent
	if echo "$build_body" | grep -q '\-p.*pinned_sha'; then
		: # good
	else
		fail "$name" "git commit-tree does not use pinned_sha as parent"
		return 0
	fi

	# Verify _cas_fetch_and_pin exists and does the pinning
	local fetch_body
	fetch_body=$(sed -n '/^_cas_fetch_and_pin()/,/^}/p' "$CLAIM_SCRIPT")
	if [[ -z "$fetch_body" ]]; then
		fail "$name" "_cas_fetch_and_pin function not found"
		return 0
	fi

	# Verify allocate_counter_cas does NOT contain git ls-tree or rev-parse
	# (all plumbing delegated to helpers)
	local cas_body
	cas_body=$(sed -n '/^allocate_counter_cas()/,/^}/p' "$CLAIM_SCRIPT")
	if echo "$cas_body" | grep -q 'git ls-tree'; then
		fail "$name" "allocate_counter_cas still contains git ls-tree — should be in helper"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running claim-task-id concurrent CAS tests (GH#19689)...\n\n'

	test_pinned_sha_in_source
	test_concurrent_claims 10

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
