#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-delta-prefetch.sh
#
# Smoke tests for the delta prefetch cache helpers (GH#15286).
# Verifies:
#   1. _prefetch_cache_get returns {} when cache file is absent
#   2. _prefetch_cache_set writes and reads back a cache entry
#   3. _prefetch_cache_set preserves multiple repo entries
#   4. _prefetch_needs_full_sweep returns true for empty entry
#   5. _prefetch_needs_full_sweep returns true when sweep is stale (>24h)
#   6. _prefetch_needs_full_sweep returns false when sweep is recent (<24h)
#   7. Cache file is valid JSON after concurrent writes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	export PULSE_PREFETCH_CACHE_FILE="${HOME}/.aidevops/logs/pulse-prefetch-cache.json"
	export PULSE_PREFETCH_FULL_SWEEP_INTERVAL="86400"
	export LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT}" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
	return 0
}

# Inline the three cache helper functions (extracted from pulse-wrapper.sh lines 606-681)
# This avoids sourcing the full 8000-line script with its side effects.

_prefetch_cache_get() {
	local slug="$1"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	if [[ ! -f "$cache_file" ]]; then
		echo "{}"
		return 0
	fi
	local entry
	entry=$(jq -r --arg slug "$slug" '.[$slug] // {}' "$cache_file" 2>/dev/null) || entry="{}"
	[[ -n "$entry" ]] || entry="{}"
	echo "$entry"
	return 0
}

_prefetch_cache_set() {
	local slug="$1"
	local entry="$2"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	local cache_dir
	cache_dir=$(dirname "$cache_file")
	mkdir -p "$cache_dir" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$cache_file" ]]; then
		existing=$(cat "$cache_file" 2>/dev/null) || existing="{}"
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "${cache_dir}/.pulse-prefetch-cache.XXXXXX")
	echo "$existing" | jq --arg slug "$slug" --argjson entry "$entry" \
		'.[$slug] = $entry' >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _prefetch_cache_set: failed to write cache for ${slug}" >>"$LOGFILE"
	}
	return 0
}

_prefetch_needs_full_sweep() {
	local entry="$1"
	local last_full_sweep
	last_full_sweep=$(echo "$entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
	if [[ -z "$last_full_sweep" || "$last_full_sweep" == "null" ]]; then
		return 0
	fi
	local last_epoch now_epoch
	# GH#17699: TZ=UTC required — macOS date interprets input as local time
	# Cross-platform: try macOS date -j first, then GNU date -d
	last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_full_sweep" "+%s" 2>/dev/null) \
		|| last_epoch=$(TZ=UTC date -d "${last_full_sweep/T/ }" "+%s" 2>/dev/null) \
		|| last_epoch=0
	now_epoch=$(date -u +%s)
	local age=$((now_epoch - last_epoch))
	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		return 0
	fi
	return 1
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_cache_get_missing_file() {
	rm -f "$PULSE_PREFETCH_CACHE_FILE"
	local result
	result=$(_prefetch_cache_get "owner/repo")
	if [[ "$result" == "{}" ]]; then
		print_result "cache_get returns {} when file absent" 0
	else
		print_result "cache_get returns {} when file absent" 1 "got: $result"
	fi
	return 0
}

test_cache_set_and_get() {
	rm -f "$PULSE_PREFETCH_CACHE_FILE"
	local entry='{"last_prefetch":"2026-04-01T12:00:00Z","last_full_sweep":"2026-04-01T00:00:00Z","prs":[],"issues":[]}'
	_prefetch_cache_set "owner/repo" "$entry"
	local got_ts
	got_ts=$(_prefetch_cache_get "owner/repo" | jq -r '.last_prefetch // ""' 2>/dev/null)
	if [[ "$got_ts" == "2026-04-01T12:00:00Z" ]]; then
		print_result "cache_set writes and cache_get reads back entry" 0
	else
		print_result "cache_set writes and cache_get reads back entry" 1 "got last_prefetch: $got_ts"
	fi
	return 0
}

test_cache_set_multiple_repos() {
	rm -f "$PULSE_PREFETCH_CACHE_FILE"
	_prefetch_cache_set "owner/repo1" '{"last_prefetch":"2026-04-01T10:00:00Z","last_full_sweep":"2026-04-01T00:00:00Z","prs":[],"issues":[]}'
	_prefetch_cache_set "owner/repo2" '{"last_prefetch":"2026-04-01T11:00:00Z","last_full_sweep":"2026-04-01T00:00:00Z","prs":[],"issues":[]}'
	local ts1 ts2
	ts1=$(_prefetch_cache_get "owner/repo1" | jq -r '.last_prefetch // ""' 2>/dev/null)
	ts2=$(_prefetch_cache_get "owner/repo2" | jq -r '.last_prefetch // ""' 2>/dev/null)
	if [[ "$ts1" == "2026-04-01T10:00:00Z" && "$ts2" == "2026-04-01T11:00:00Z" ]]; then
		print_result "cache_set preserves multiple repo entries" 0
	else
		print_result "cache_set preserves multiple repo entries" 1 "repo1=$ts1 repo2=$ts2"
	fi
	return 0
}

test_needs_full_sweep_no_entry() {
	if _prefetch_needs_full_sweep "{}"; then
		print_result "needs_full_sweep returns true for empty entry" 0
	else
		print_result "needs_full_sweep returns true for empty entry" 1 "returned false"
	fi
	return 0
}

test_needs_full_sweep_stale() {
	# 25 hours ago — try macOS date -v first, then GNU date -d, then fixed fallback
	local stale_ts
	stale_ts=$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
		|| stale_ts=$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
		|| stale_ts="2026-03-31T11:00:00Z"
	local entry
	entry=$(jq -n --arg ts "$stale_ts" '{last_full_sweep: $ts}')
	if _prefetch_needs_full_sweep "$entry"; then
		print_result "needs_full_sweep returns true when sweep is stale (>24h)" 0
	else
		print_result "needs_full_sweep returns true when sweep is stale (>24h)" 1 "returned false for ts=$stale_ts"
	fi
	return 0
}

test_needs_full_sweep_recent() {
	# 1 hour ago — should NOT need full sweep
	# Try macOS date -v first, then GNU date -d; never fall back to current time
	# (current time would make last_epoch=0 on Linux when date -j also fails, causing false positive)
	local recent_ts
	recent_ts=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
		|| recent_ts=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
		|| recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local entry
	entry=$(jq -n --arg ts "$recent_ts" '{last_full_sweep: $ts}')
	if _prefetch_needs_full_sweep "$entry"; then
		print_result "needs_full_sweep returns false when sweep is recent (<24h)" 1 "returned true for ts=$recent_ts"
	else
		print_result "needs_full_sweep returns false when sweep is recent (<24h)" 0
	fi
	return 0
}

test_cache_atomic_write() {
	rm -f "$PULSE_PREFETCH_CACHE_FILE"
	# Write two entries concurrently (simulate parallel repo fetches)
	_prefetch_cache_set "owner/repo-a" '{"last_prefetch":"2026-04-01T10:00:00Z","last_full_sweep":"2026-04-01T00:00:00Z","prs":[],"issues":[]}' &
	_prefetch_cache_set "owner/repo-b" '{"last_prefetch":"2026-04-01T10:00:00Z","last_full_sweep":"2026-04-01T00:00:00Z","prs":[],"issues":[]}' &
	wait
	if jq empty "$PULSE_PREFETCH_CACHE_FILE" 2>/dev/null; then
		print_result "cache file is valid JSON after concurrent writes" 0
	else
		print_result "cache file is valid JSON after concurrent writes" 1 "JSON parse failed"
	fi
	return 0
}

# ─── GH#19966 regression: ${N:-{}} expansion bug fix ─────────────────────────
# Bash expansion grammar: "${2:-{}}" reads the expansion as "${2:-{}" (default="{")
# and treats the trailing "}" as a literal — appending "}" to every non-empty arg.
# The fix uses the explicit-fallback idiom: "${2:-}" then [[ -n "$x" ]] || x="{}".

# Simulate the OLD (buggy) pattern for documentation purposes
_gh19966_old_wrapper() {
	local slug="$1"
	local cache_entry="${2:-{}}"
	echo "$cache_entry"
	return 0
}

# Simulate the NEW (fixed) explicit-fallback idiom
_gh19966_fixed_wrapper() {
	local slug="$1"
	local cache_entry="${2:-}"
	[[ -n "$cache_entry" ]] || cache_entry="{}"
	echo "$cache_entry"
	return 0
}

test_gh19966_bug_corrupts_nonempty_json() {
	# Document the root cause: ${2:-{}} appends a trailing } to non-empty args.
	# When $2 is non-empty the default is never used, but the closing } of {}
	# is consumed as part of the expansion syntax, leaving a bare } literal.
	local input='{"last_prefetch":"2026-04-12T08:00:00Z","prs":[]}'
	local output
	output=$(_gh19966_old_wrapper "owner/repo" "$input")
	# The bug: jq cannot parse the output because of the trailing }
	local last_prefetch
	last_prefetch=$(echo "$output" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""
	if [[ -z "$last_prefetch" ]]; then
		print_result "bug-doc: \${2:-{}} corrupts non-empty JSON — jq parse fails (GH#19966 root cause)" 0
	else
		# Shell may have fixed parsing in a future version — still record the outcome
		print_result "bug-doc: \${2:-{}} corrupts non-empty JSON — jq parse fails (GH#19966 root cause)" 1 \
			"unexpected: jq succeeded with last_prefetch=${last_prefetch} (shell behaviour changed?)"
	fi
	return 0
}

test_gh19966_fix_preserves_nonempty_json() {
	# The fix: explicit-fallback idiom passes non-empty cache_entry through intact.
	local input='{"last_prefetch":"2026-04-12T08:00:00Z","prs":[]}'
	local output
	output=$(_gh19966_fixed_wrapper "owner/repo" "$input")
	local last_prefetch
	last_prefetch=$(echo "$output" | jq -r '.last_prefetch // ""' 2>/dev/null)
	if [[ "$last_prefetch" == "2026-04-12T08:00:00Z" ]]; then
		print_result "fix: explicit-fallback idiom preserves non-empty cache_entry (GH#19966)" 0
	else
		print_result "fix: explicit-fallback idiom preserves non-empty cache_entry (GH#19966)" 1 \
			"got last_prefetch='${last_prefetch}' from output='${output}'"
	fi
	return 0
}

test_gh19966_fix_defaults_empty_to_object() {
	# The fix must still default to {} when arg is absent or empty.
	local output_absent output_empty
	output_absent=$(_gh19966_fixed_wrapper "owner/repo")
	output_empty=$(_gh19966_fixed_wrapper "owner/repo" "")
	local ok=0
	[[ "$output_absent" == "{}" ]] || ok=1
	[[ "$output_empty" == "{}" ]] || ok=1
	if [[ "$ok" -eq 0 ]]; then
		print_result "fix: empty/absent arg defaults to {} (GH#19966)" 0
	else
		print_result "fix: empty/absent arg defaults to {} (GH#19966)" 1 \
			"absent='${output_absent}' empty='${output_empty}'"
	fi
	return 0
}

test_gh19966_delta_path_extracts_timestamp() {
	# Regression: when cache_entry (from _prefetch_cache_get) contains last_prefetch,
	# the delta path must be able to extract the timestamp.
	# Before the fix, the trailing } made cache_entry invalid JSON so jq returned "".
	# The [[ -z "$last_prefetch" ]] guard then fell back to a full sweep every cycle.
	local cache_entry='{"last_prefetch":"2026-04-12T10:00:00Z","last_full_sweep":"2026-04-12T00:00:00Z","prs":[],"issues":[]}'
	# Simulate the fixed wrapper receiving cache_entry as $2
	local received
	received=$(_gh19966_fixed_wrapper "owner/repo" "$cache_entry")
	local last_prefetch
	last_prefetch=$(echo "$received" | jq -r '.last_prefetch // ""' 2>/dev/null)
	if [[ "$last_prefetch" == "2026-04-12T10:00:00Z" ]]; then
		print_result "delta path: last_prefetch extractable from non-empty cache_entry (GH#19966)" 0
	else
		print_result "delta path: last_prefetch extractable from non-empty cache_entry (GH#19966)" 1 \
			"last_prefetch='${last_prefetch}' (delta would fall back to full sweep)"
	fi
	return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
	setup_test_env

	test_cache_get_missing_file
	test_cache_set_and_get
	test_cache_set_multiple_repos
	test_needs_full_sweep_no_entry
	test_needs_full_sweep_stale
	test_needs_full_sweep_recent
	test_cache_atomic_write

	# GH#19966 regression tests for ${N:-{}} bash expansion bug
	test_gh19966_bug_corrupts_nonempty_json
	test_gh19966_fix_preserves_nonempty_json
	test_gh19966_fix_defaults_empty_to_object
	test_gh19966_delta_path_extracts_timestamp

	teardown_test_env

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
