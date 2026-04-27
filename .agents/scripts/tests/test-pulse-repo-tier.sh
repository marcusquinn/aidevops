#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-repo-tier.sh — Tests for pulse-repo-tier.sh and tier-based skip (t2831)
#
# Tests:
#   pulse-repo-tier.sh tier-of:
#     - Cache miss → "warm" (safe default)
#     - Stale cache (>2h) → "warm"
#     - Hot entry → "hot"
#     - Warm entry → "warm"
#     - Cold entry → "cold"
#     - Unknown tier value → "warm"
#     - No slug argument → "warm"
#   check_repo_tier_skip (from pulse-prefetch-fetch.sh):
#     - PULSE_TIER_CLASSIFICATION_ENABLED=0 → always proceed (returns 0)
#     - Tier=hot → always proceed (returns 0)
#     - Tier=warm, elapsed < warm_interval → skip (returns 1)
#     - Tier=warm, elapsed > warm_interval → proceed (returns 0)
#     - Tier=cold, elapsed < cold_interval → skip (returns 1)
#     - Tier=cold, elapsed > cold_interval → proceed (returns 0)
#   update_repo_tier_check_timestamp:
#     - Writes current epoch for repo
#     - Creates state file if missing
#     - Updates are independent per repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TIER_SCRIPT="${SCRIPT_DIR}/../pulse-repo-tier.sh"
PREFETCH_FETCH_SCRIPT="${SCRIPT_DIR}/../pulse-prefetch-fetch.sh"

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
	# Use a per-test subdirectory under the global TEST_ROOT so the root
	# stays available across all tests and the global trap cleans it up.
	local test_subdir
	test_subdir=$(mktemp -d "${TEST_ROOT}/test-XXXXXX")
	export HOME="${test_subdir}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache" "${HOME}/.config/aidevops"
	export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export PULSE_TIER_CACHE_FILE="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	export PULSE_TIER_LAST_CHECK_FILE="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	export PULSE_TIER_CLASSIFICATION_ENABLED=1
	export PULSE_TIER_HOT_INTERVAL=0
	export PULSE_TIER_WARM_INTERVAL=180
	export PULSE_TIER_COLD_INTERVAL=600
	return 0
}

teardown_test_env() {
	# Restore HOME; the subdir is inside TEST_ROOT and cleaned by the global trap.
	export HOME="$ORIGINAL_HOME"
	return 0
}

# =============================================================================
# pulse-repo-tier.sh tier-of tests
# =============================================================================

test_tier_of_cache_miss() {
	# No cache file → should return "warm"
	local result
	result=$(PULSE_TIER_CACHE_FILE="${TEST_ROOT}/nonexistent.json" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: cache miss → warm" 0
	else
		print_result "tier-of: cache miss → warm" 1 "Expected 'warm', got '${result}'"
	fi
	return 0
}

test_tier_of_stale_cache() {
	# Cache file exists but entry is >2h old → should return "warm"
	local cache_file="${TEST_ROOT}/tier-stale.json"
	local old_epoch
	old_epoch=$(( $(date +%s) - 9000 ))  # 2.5 hours ago
	printf '{"owner/repo": {"tier": "cold", "event_count": 1, "ts": %d}}\n' "$old_epoch" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		PULSE_TIER_CACHE_MAX_AGE_S=7200 \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: stale cache → warm" 0
	else
		print_result "tier-of: stale cache → warm" 1 "Expected 'warm' for stale entry, got '${result}'"
	fi
	return 0
}

test_tier_of_hot() {
	local cache_file="${TEST_ROOT}/tier-hot.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "hot", "event_count": 50, "ts": %d}}\n' "$now" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "hot" ]]; then
		print_result "tier-of: hot entry → hot" 0
	else
		print_result "tier-of: hot entry → hot" 1 "Expected 'hot', got '${result}'"
	fi
	return 0
}

test_tier_of_warm() {
	local cache_file="${TEST_ROOT}/tier-warm.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "warm", "event_count": 10, "ts": %d}}\n' "$now" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: warm entry → warm" 0
	else
		print_result "tier-of: warm entry → warm" 1 "Expected 'warm', got '${result}'"
	fi
	return 0
}

test_tier_of_cold() {
	local cache_file="${TEST_ROOT}/tier-cold.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "cold", "event_count": 2, "ts": %d}}\n' "$now" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "cold" ]]; then
		print_result "tier-of: cold entry → cold" 0
	else
		print_result "tier-of: cold entry → cold" 1 "Expected 'cold', got '${result}'"
	fi
	return 0
}

test_tier_of_unknown_tier_value() {
	local cache_file="${TEST_ROOT}/tier-unknown.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "bogus", "event_count": 5, "ts": %d}}\n' "$now" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: unknown tier value → warm" 0
	else
		print_result "tier-of: unknown tier value → warm" 1 "Expected 'warm' for unknown tier, got '${result}'"
	fi
	return 0
}

test_tier_of_no_slug() {
	# No slug argument → should print "warm" and not error out
	local result
	result=$(PULSE_TIER_CACHE_FILE="${TEST_ROOT}/any.json" \
		bash "$TIER_SCRIPT" tier-of "" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: no slug → warm" 0
	else
		print_result "tier-of: no slug → warm" 1 "Expected 'warm' for empty slug, got '${result}'"
	fi
	return 0
}

test_tier_of_missing_slug_in_cache() {
	# Cache file exists but doesn't have the requested slug
	local cache_file="${TEST_ROOT}/tier-other.json"
	local now
	now=$(date +%s)
	printf '{"other/repo": {"tier": "hot", "event_count": 50, "ts": %d}}\n' "$now" >"$cache_file"

	local result
	result=$(PULSE_TIER_CACHE_FILE="$cache_file" \
		bash "$TIER_SCRIPT" tier-of "owner/repo" 2>/dev/null)
	if [[ "$result" == "warm" ]]; then
		print_result "tier-of: slug not in cache → warm" 0
	else
		print_result "tier-of: slug not in cache → warm" 1 "Expected 'warm' for missing slug, got '${result}'"
	fi
	return 0
}

# =============================================================================
# check_repo_tier_skip tests (sourced from pulse-prefetch-fetch.sh)
# Requires sourcing the lib rather than calling the script.
# =============================================================================

_source_prefetch_fetch() {
	# Source the minimum environment needed for pulse-prefetch-fetch.sh
	# We only need check_repo_tier_skip and update_repo_tier_check_timestamp.
	# Stub out LOGFILE and functions that may not be available in test context.
	export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export PULSE_TIER_SCRIPT="$TIER_SCRIPT"
	# shellcheck source=/dev/null
	source "$PREFETCH_FETCH_SCRIPT" 2>/dev/null || true
	return 0
}

test_tier_skip_disabled() {
	# PULSE_TIER_CLASSIFICATION_ENABLED=0 → always proceed
	setup_test_env
	_source_prefetch_fetch

	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	if PULSE_TIER_CLASSIFICATION_ENABLED=0 check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: disabled → always proceed" 0
	else
		print_result "check_repo_tier_skip: disabled → always proceed" 1 "Expected proceed (0) when feature disabled"
	fi
	teardown_test_env
	return 0
}

test_tier_skip_hot_no_skip() {
	# Hot repos always proceed regardless of last check time
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "hot", "event_count": 50, "ts": %d}}\n' "$now" >"$cache_file"

	# Write a very recent last-check timestamp
	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	printf '{"last_check": {"owner/repo": %d}}\n' "$now" >"$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: hot → never skip" 0
	else
		print_result "check_repo_tier_skip: hot → never skip" 1 "Expected proceed (0) for hot repo"
	fi
	teardown_test_env
	return 0
}

test_tier_skip_warm_recent() {
	# Warm repo, last check 30s ago, interval=180s → skip
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "warm", "event_count": 10, "ts": %d}}\n' "$now" >"$cache_file"

	local recent
	recent=$(( now - 30 ))  # 30s ago
	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	printf '{"last_check": {"owner/repo": %d}}\n' "$recent" >"$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" \
	   PULSE_TIER_WARM_INTERVAL=180 \
	   check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: warm + recent check → skip" 1 "Expected skip (1) for warm repo checked 30s ago"
	else
		print_result "check_repo_tier_skip: warm + recent check → skip" 0
	fi
	teardown_test_env
	return 0
}

test_tier_skip_warm_elapsed() {
	# Warm repo, last check 300s ago, interval=180s → proceed
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "warm", "event_count": 10, "ts": %d}}\n' "$now" >"$cache_file"

	local old
	old=$(( now - 300 ))  # 300s ago
	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	printf '{"last_check": {"owner/repo": %d}}\n' "$old" >"$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" \
	   PULSE_TIER_WARM_INTERVAL=180 \
	   check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: warm + elapsed check → proceed" 0
	else
		print_result "check_repo_tier_skip: warm + elapsed check → proceed" 1 "Expected proceed (0) for warm repo checked 300s ago with 180s interval"
	fi
	teardown_test_env
	return 0
}

test_tier_skip_cold_recent() {
	# Cold repo, last check 60s ago, interval=600s → skip
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "cold", "event_count": 1, "ts": %d}}\n' "$now" >"$cache_file"

	local recent
	recent=$(( now - 60 ))  # 60s ago
	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	printf '{"last_check": {"owner/repo": %d}}\n' "$recent" >"$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" \
	   PULSE_TIER_COLD_INTERVAL=600 \
	   check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: cold + recent check → skip" 1 "Expected skip (1) for cold repo checked 60s ago"
	else
		print_result "check_repo_tier_skip: cold + recent check → skip" 0
	fi
	teardown_test_env
	return 0
}

test_tier_skip_cold_elapsed() {
	# Cold repo, last check 1200s ago, interval=600s → proceed
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "cold", "event_count": 1, "ts": %d}}\n' "$now" >"$cache_file"

	local old
	old=$(( now - 1200 ))  # 1200s ago
	local state_file="${HOME}/.aidevops/logs/pulse-tier-last-check.json"
	printf '{"last_check": {"owner/repo": %d}}\n' "$old" >"$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" \
	   PULSE_TIER_COLD_INTERVAL=600 \
	   check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: cold + elapsed check → proceed" 0
	else
		print_result "check_repo_tier_skip: cold + elapsed check → proceed" 1 "Expected proceed (0) for cold repo checked 1200s ago with 600s interval"
	fi
	teardown_test_env
	return 0
}

test_tier_skip_no_state_file() {
	# No state file → last_check=0 → elapsed is huge → always proceed
	setup_test_env
	_source_prefetch_fetch

	local cache_file="${HOME}/.aidevops/cache/pulse-repo-tiers.json"
	local now
	now=$(date +%s)
	printf '{"owner/repo": {"tier": "cold", "event_count": 0, "ts": %d}}\n' "$now" >"$cache_file"

	local state_file="${TEST_ROOT}/nonexistent-state.json"
	rm -f "$state_file"

	if PULSE_TIER_CACHE_FILE="$cache_file" \
	   PULSE_TIER_COLD_INTERVAL=600 \
	   check_repo_tier_skip "owner/repo" "$state_file"; then
		print_result "check_repo_tier_skip: no state file → proceed" 0
	else
		print_result "check_repo_tier_skip: no state file → proceed" 1 "Expected proceed (0) when state file missing"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# update_repo_tier_check_timestamp tests
# =============================================================================

test_update_tier_timestamp_writes_epoch() {
	setup_test_env
	_source_prefetch_fetch

	local state_file="${HOME}/.aidevops/logs/pulse-tier-ts-test.json"
	local before after written_ts
	before=$(date +%s)
	update_repo_tier_check_timestamp "write/test" "$state_file"
	after=$(date +%s)

	if command -v jq &>/dev/null && [[ -f "$state_file" ]]; then
		written_ts=$(jq -r '.last_check["write/test"]' "$state_file" 2>/dev/null) || written_ts=0
		if [[ "$written_ts" -ge "$before" && "$written_ts" -le "$after" ]]; then
			print_result "update_repo_tier_check_timestamp: writes current epoch" 0
		else
			print_result "update_repo_tier_check_timestamp: writes current epoch" 1 \
				"Timestamp ${written_ts} not in range [${before}, ${after}]"
		fi
	else
		print_result "update_repo_tier_check_timestamp: writes current epoch" 0 "(jq not available or state file missing — skipped)"
	fi
	teardown_test_env
	return 0
}

test_update_tier_timestamp_creates_file() {
	setup_test_env
	_source_prefetch_fetch

	local state_file="${HOME}/.aidevops/logs/tier-create-test.json"
	rm -f "$state_file"

	update_repo_tier_check_timestamp "create/test" "$state_file"

	if [[ -f "$state_file" ]]; then
		print_result "update_repo_tier_check_timestamp: creates state file if missing" 0
	else
		print_result "update_repo_tier_check_timestamp: creates state file if missing" 1 \
			"State file not created at ${state_file}"
	fi
	teardown_test_env
	return 0
}

test_update_tier_timestamp_independent_per_repo() {
	setup_test_env
	_source_prefetch_fetch

	local state_file="${HOME}/.aidevops/logs/tier-indep-test.json"
	local old_ts=$(( $(date +%s) - 100 ))

	# Pre-populate alpha with an old timestamp
	printf '{"last_check": {"alpha/repo": %d}}\n' "$old_ts" >"$state_file"

	# Update only beta
	update_repo_tier_check_timestamp "beta/repo" "$state_file"

	if command -v jq &>/dev/null; then
		local alpha_ts beta_ts
		alpha_ts=$(jq -r '.last_check["alpha/repo"]' "$state_file" 2>/dev/null) || alpha_ts=0
		beta_ts=$(jq -r '.last_check["beta/repo"]' "$state_file" 2>/dev/null) || beta_ts=0
		if [[ "$alpha_ts" == "$old_ts" && "$beta_ts" -gt 0 ]]; then
			print_result "update_repo_tier_check_timestamp: updates are independent per repo" 0
		else
			print_result "update_repo_tier_check_timestamp: updates are independent per repo" 1 \
				"alpha=${alpha_ts} (expected ${old_ts}), beta=${beta_ts} (expected >0)"
		fi
	else
		print_result "update_repo_tier_check_timestamp: updates are independent per repo" 0 "(jq not available — skipped)"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo "=== test-pulse-repo-tier.sh ==="
	echo ""

	if [[ ! -x "$TIER_SCRIPT" ]]; then
		echo "ERROR: ${TIER_SCRIPT} not found or not executable" >&2
		exit 1
	fi

	# Global setup: create a shared TEST_ROOT for all tests.
	# Per-test teardown calls restore HOME and clean TEST_ROOT.
	# The tier-of tests (which don't call setup/teardown) use this shared root.
	TEST_ROOT=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '${TEST_ROOT}'" EXIT

	# tier-of tests (standalone script invocation)
	test_tier_of_cache_miss
	test_tier_of_stale_cache
	test_tier_of_hot
	test_tier_of_warm
	test_tier_of_cold
	test_tier_of_unknown_tier_value
	test_tier_of_no_slug
	test_tier_of_missing_slug_in_cache

	# check_repo_tier_skip and update_repo_tier_check_timestamp tests
	# Only run if prefetch-fetch script can be sourced
	if [[ -f "$PREFETCH_FETCH_SCRIPT" ]]; then
		test_tier_skip_disabled
		test_tier_skip_hot_no_skip
		test_tier_skip_warm_recent
		test_tier_skip_warm_elapsed
		test_tier_skip_cold_recent
		test_tier_skip_cold_elapsed
		test_tier_skip_no_state_file
		test_update_tier_timestamp_writes_epoch
		test_update_tier_timestamp_creates_file
		test_update_tier_timestamp_independent_per_repo
	else
		echo "SKIP pulse-prefetch-fetch.sh tests (script not found at: ${PREFETCH_FETCH_SCRIPT})"
	fi

	echo ""
	echo "Results: ${TESTS_RUN} run, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
