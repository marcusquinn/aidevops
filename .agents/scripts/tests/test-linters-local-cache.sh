#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-cache.sh — cache/time-budget coverage for local linter gates.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

source_gate_helpers() {
	# shellcheck disable=SC1091  # test intentionally sources helper under test
	source "${SCRIPT_DIR}/linters-local-gates.sh"
	return 0
}

cache_counter_gate() {
	local counter_file="${LINTERS_LOCAL_TEST_COUNTER_FILE}"
	local count=0
	if [ -f "$counter_file" ]; then
		count=$(cat "$counter_file")
	fi
	count=$((count + 1))
	printf '%s\n' "$count" >"$counter_file"
	printf 'counter gate run %s\n' "$count"
	return 0
}

slow_cache_gate() {
	sleep 3
	printf 'slow gate finished\n'
	return 0
}

test_cache_hit_reuses_gate_output() {
	source_gate_helpers
	local tmp_dir counter_file out1 out2 ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="true"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export TMPDIR="$tmp_dir"

	out1=$(_linters_local_run_cached_gate "unit-cache" "cache_counter_gate" 2>&1) || ret=$?
	out2=$(_linters_local_run_cached_gate "unit-cache" "cache_counter_gate" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && grep -q 'cache hit' <<<"$out2" && [ "$(cat "$counter_file")" -eq 1 ]; then
		print_result "linter cache: second unchanged gate call reuses cached result" 0
	else
		print_result "linter cache: second unchanged gate call reuses cached result" 1 \
			"out1=[$out1] out2=[$out2] count=[$(cat "$counter_file" 2>/dev/null || printf '?')] ret=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_no_cache_reruns_gate() {
	source_gate_helpers
	local tmp_dir counter_file ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export TMPDIR="$tmp_dir"

	_linters_local_run_cached_gate "unit-nocache" "cache_counter_gate" >/dev/null 2>&1 || ret=$?
	_linters_local_run_cached_gate "unit-nocache" "cache_counter_gate" >/dev/null 2>&1 || ret=$?

	if [ "$ret" -eq 0 ] && [ "$(cat "$counter_file")" -eq 2 ]; then
		print_result "linter cache: --no-cache path reruns eligible broad gates" 0
	else
		print_result "linter cache: --no-cache path reruns eligible broad gates" 1 \
			"count=[$(cat "$counter_file" 2>/dev/null || printf '?')] ret=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_timeout_fails_closed_by_default() {
	source_gate_helpers
	local tmp_dir out ret=0
	tmp_dir=$(mktemp -d)
	export LINTERS_LOCAL_CACHE_ENABLED="true"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_BROAD_GATE_TIMEOUT_SECONDS="1"
	export LINTERS_LOCAL_STRICT_BROAD_GATES="false"
	export TMPDIR="$tmp_dir"

	out=$(_linters_local_run_cached_gate "unit-timeout" "slow_cache_gate" 2>&1) || ret=$?

	local cache_written=false
	local cache_file=""
	for cache_file in "${tmp_dir}"/cache/unit-timeout-*.status; do
		[ -e "$cache_file" ] && cache_written=true
	done
	if [ "$ret" -eq 124 ] && grep -q 'result is incomplete' <<<"$out" && [ "$cache_written" = false ]; then
		print_result "linter cache: broad gate timeout fails closed" 0
	else
		print_result "linter cache: broad gate timeout fails closed" 1 \
			"expected status 124 and incomplete diagnostic, got exit=$ret output=[$out]"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_cache_key_invalidates_on_untracked_content_change() {
	source_gate_helpers
	local tmp_dir original_dir first_key second_key
	tmp_dir=$(mktemp -d)
	original_dir="$PWD"
	git -C "$tmp_dir" init -q
	printf 'first\n' >"${tmp_dir}/untracked.sh"
	cd "$tmp_dir" || return 1
	LINT_CHANGED_FILES_READY=false
	lint_changed_files
	first_key=$(_linters_local_gate_key "unit-content")
	printf 'second\n' >"${tmp_dir}/untracked.sh"
	LINT_CHANGED_FILES_READY=false
	lint_changed_files
	second_key=$(_linters_local_gate_key "unit-content")
	cd "$original_dir" || return 1

	if [ -n "$first_key" ] && [ "$first_key" != "$second_key" ]; then
		print_result "linter cache: untracked content invalidates fingerprint" 0
	else
		print_result "linter cache: untracked content invalidates fingerprint" 1 \
			"first=[$first_key] second=[$second_key]"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_changed_inventory_snapshot_avoids_repeat_git_scans() {
	source_gate_helpers
	local tmp_dir counter_file output count=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/git-calls"
	LINT_CHANGED_FILES="untracked.sh"
	LINT_CHANGED_FILES_FINGERPRINT="fixture"
	LINT_CHANGED_FILES_READY=true
	git() {
		printf 'git\n' >>"$counter_file"
		return 1
	}
	output=$(_linters_local_changed_files_key)
	unset -f git
	[[ -f "$counter_file" ]] && count=$(wc -l <"$counter_file" | tr -d '[:space:]')
	if [ "$output" = "untracked.sh" ] && [ "$count" -eq 0 ]; then
		print_result "linter cache: prepared inventory avoids repeated git scans" 0
	else
		print_result "linter cache: prepared inventory avoids repeated git scans" 1 \
			"output=[$output] git_calls=$count"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_common_git_dir_hosts_cross_worktree_cache() {
	source_gate_helpers
	local cache_dir common_dir
	unset LINTERS_LOCAL_CACHE_DIR_OVERRIDE
	cache_dir=$(_linters_local_cache_dir)
	common_dir=$(git rev-parse --git-common-dir)
	common_dir=$(cd "$common_dir" && pwd -P)
	if [ "$cache_dir" = "${common_dir}/aidevops-linters-cache" ]; then
		print_result "linter cache: linked worktrees share the common git cache" 0
	else
		print_result "linter cache: linked worktrees share the common git cache" 1 \
			"cache=[$cache_dir] expected=[${common_dir}/aidevops-linters-cache]"
	fi
	return 0
}

test_concurrent_gate_reuses_first_result() {
	source_gate_helpers
	local tmp_dir counter_file first_output second_output first_pid second_pid ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="true"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_GATE_LOCK_TIMEOUT_SECONDS="10"
	export TMPDIR="$tmp_dir"

	(_linters_local_run_cached_gate "unit-concurrent" "cache_counter_gate" >"${tmp_dir}/first.out" 2>&1) &
	first_pid=$!
	(_linters_local_run_cached_gate "unit-concurrent" "cache_counter_gate" >"${tmp_dir}/second.out" 2>&1) &
	second_pid=$!
	wait "$first_pid" || ret=1
	wait "$second_pid" || ret=1
	first_output=$(cat "${tmp_dir}/first.out")
	second_output=$(cat "${tmp_dir}/second.out")

	if [ "$ret" -eq 0 ] && [ "$(cat "$counter_file")" -eq 1 ] &&
		printf '%s\n%s\n' "$first_output" "$second_output" | grep -q 'shared cache hit'; then
		print_result "linter cache: concurrent identical gate runs execute once" 0
	else
		print_result "linter cache: concurrent identical gate runs execute once" 1 \
			"count=[$(cat "$counter_file" 2>/dev/null || printf '?')] first=[$first_output] second=[$second_output]"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_ownerless_lock_is_recovered() {
	source_gate_helpers
	local tmp_dir counter_file ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_GATE_LOCK_TIMEOUT_SECONDS="5"
	mkdir -p "${tmp_dir}/cache/broad-gate.lock"

	_linters_local_run_cached_gate "unit-ownerless" "cache_counter_gate" >/dev/null 2>&1 || ret=$?
	if [[ "$ret" -eq 0 && "$(cat "$counter_file")" -eq 1 && ! -d "${tmp_dir}/cache/broad-gate.lock" ]]; then
		print_result "linter cache: ownerless broad-gate locks recover" 0
	else
		print_result "linter cache: ownerless broad-gate locks recover" 1 "exit=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_malformed_lock_is_recovered() {
	source_gate_helpers
	local tmp_dir counter_file ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_GATE_LOCK_TIMEOUT_SECONDS="5"
	mkdir -p "${tmp_dir}/cache"
	printf 'invalid\n' >"${tmp_dir}/cache/broad-gate.lock"

	_linters_local_run_cached_gate "unit-malformed" "cache_counter_gate" >/dev/null 2>&1 || ret=$?
	if [[ "$ret" -eq 0 && "$(cat "$counter_file")" -eq 1 && ! -e "${tmp_dir}/cache/broad-gate.lock" ]]; then
		print_result "linter cache: malformed broad-gate locks recover" 0
	else
		print_result "linter cache: malformed broad-gate locks recover" 1 "exit=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_reused_pid_lock_is_recovered_by_age() {
	source_gate_helpers
	local tmp_dir counter_file ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_GATE_LOCK_TIMEOUT_SECONDS="5"
	export LINTERS_LOCAL_GATE_LOCK_MAX_AGE_SECONDS="1"
	mkdir -p "${tmp_dir}/cache"
	printf '%s:1:123\n' "$$" >"${tmp_dir}/cache/broad-gate.lock"

	_linters_local_run_cached_gate "unit-reused-pid" "cache_counter_gate" >/dev/null 2>&1 || ret=$?
	if [[ "$ret" -eq 0 && "$(cat "$counter_file")" -eq 1 ]]; then
		print_result "linter cache: old locks survive PID reuse safely" 0
	else
		print_result "linter cache: old locks survive PID reuse safely" 1 "exit=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_file_checksum_ignores_worktree_path() {
	source_gate_helpers
	local tmp_dir first second
	tmp_dir=$(mktemp -d)
	mkdir -p "${tmp_dir}/one" "${tmp_dir}/two"
	printf 'same content\n' >"${tmp_dir}/one/input.sh"
	printf 'same content\n' >"${tmp_dir}/two/input.sh"
	first=$(_linters_local_file_checksum "${tmp_dir}/one/input.sh")
	second=$(_linters_local_file_checksum "${tmp_dir}/two/input.sh")
	if [[ "$first" == "$second" ]]; then
		print_result "linter cache: file checksums ignore absolute worktree paths" 0
	else
		print_result "linter cache: file checksums ignore absolute worktree paths" 1 "first=$first second=$second"
	fi
	rm -rf "$tmp_dir"
	return 0
}

main() {
	test_cache_hit_reuses_gate_output
	test_no_cache_reruns_gate
	test_timeout_fails_closed_by_default
	test_cache_key_invalidates_on_untracked_content_change
	test_changed_inventory_snapshot_avoids_repeat_git_scans
	test_common_git_dir_hosts_cross_worktree_cache
	test_concurrent_gate_reuses_first_result
	test_ownerless_lock_is_recovered
	test_malformed_lock_is_recovered
	test_reused_pid_lock_is_recovered_by_age
	test_file_checksum_ignores_worktree_path

	printf '\n'
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi

	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
