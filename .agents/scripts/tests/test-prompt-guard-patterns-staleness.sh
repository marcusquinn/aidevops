#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# =============================================================================
# Test Script for check_prompt_guard_patterns staleness fix (GH#20312)
# =============================================================================
# Tests the three-level fallback chain in check_prompt_guard_patterns:
#   1. ~/.aidevops/.deployed-sha mtime  (Option B, level 1)
#   2. upstream git commit date          (Option B, level 2)
#   3. deployed yaml file mtime          (fallback, preserves prior behaviour)
#
# Each test is run in a fresh bash subprocess with an isolated HOME so that
# readonly variables (AGENTS_DIR) do not conflict between runs.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../security-posture-helper.sh"

# Colors
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp working dir
TEST_TMPDIR=""

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

#######################################
# Run check_prompt_guard_patterns in an isolated subshell
# with controlled HOME and AGENTS_DIR.
# Arguments:
#   $1 - fake HOME directory
#   $2 - fake AGENTS_DIR (directory that has configs/ under it)
# Prints:
#   "PASS:<CHECK_LABEL>" on return 0
#   "FAIL:<CHECK_LABEL>" on return 1
# Returns:
#   0 always (result is in printed output)
#######################################
run_check_in_env() {
	local fake_home="$1"
	local fake_agents_dir="$2"
	local helper="$3"

	# Run in a fresh bash process to avoid readonly variable conflicts.
	# Redirect stdout from 'source' to /dev/null because the helper script has
	# an unconditional 'main "$@"' at EOF — sourcing without args prints usage.
	# The function definitions are still made available; we re-enable set +e
	# after source because the helper applies set -euo pipefail on source.
	HOME="$fake_home" AIDEVOPS_AGENTS_DIR="$fake_agents_dir" bash -c "
set +e
source '${helper}' >/dev/null 2>&1 || true
set +e
CHECK_LABEL=''
CHECK_FIX=''
if check_prompt_guard_patterns 2>/dev/null; then
    echo 'PASS:'\"\${CHECK_LABEL}\"
else
    echo 'FAIL:'\"\${CHECK_LABEL}\"
fi
"
	return 0
}

#######################################
# Create a fake yaml file and agents dir structure
# Arguments:
#   $1 - base directory to create agents structure in
# Returns:
#   0 always
#######################################
make_agents_dir() {
	local base="$1"
	mkdir -p "${base}/configs"
	printf "patterns: []\n" >"${base}/configs/prompt-injection-patterns.yaml"
	return 0
}

#######################################
# Set mtime of a file to N days ago
# Arguments:
#   $1 - file path
#   $2 - days ago
# Returns:
#   0 always
#######################################
set_mtime_days_ago() {
	local file="$1"
	local days="$2"
	local timestamp
	# Use epoch math to avoid DST skew (calendar days ≠ exactly N*86400 seconds).
	# touch -t format: [[CC]YY]MMDDhhmm[.ss]
	local old_epoch=$(( $(date +%s) - days * 86400 ))
	timestamp=$(date -d "@${old_epoch}" '+%Y%m%d%H%M' 2>/dev/null \
		|| date -r "${old_epoch}" '+%Y%m%d%H%M' 2>/dev/null \
		|| echo "")
	if [[ -n "$timestamp" ]]; then
		touch -t "$timestamp" "$file" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Setup: create TEST_TMPDIR
#######################################
setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

#######################################
# Teardown: remove TEST_TMPDIR
#######################################
teardown() {
	if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
		rm -rf "$TEST_TMPDIR"
	fi
	return 0
}

# =============================================================================
# TESTS
# =============================================================================

test_helper_exists() {
	if [[ -x "$HELPER" ]]; then
		print_result "helper script exists and is executable" 0
	else
		print_result "helper script exists and is executable" 1 "Not found or not executable: $HELPER"
	fi
	return 0
}

#
# Test 1: fresh .deployed-sha (today) → check passes
# Level 1 path: stamp exists and is fresh
#
test_fresh_deployed_sha_passes() {
	setup
	local fake_home="${TEST_TMPDIR}/home1"
	local agents_dir="${TEST_TMPDIR}/agents1"
	make_agents_dir "$agents_dir"
	mkdir -p "${fake_home}/.aidevops"
	printf 'abc123\n' >"${fake_home}/.aidevops/.deployed-sha"
	# stamp mtime = now (0 days ago) → age=0 → pass

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == PASS:* ]]; then
		print_result "fresh .deployed-sha (today) → check passes" 0
	else
		print_result "fresh .deployed-sha (today) → check passes" 1 "Got: $result"
	fi
	teardown
	return 0
}

#
# Test 2: 31-day-old .deployed-sha → check fails with actionable label
# Level 1 path: stamp exists but is stale
#
test_stale_deployed_sha_fails() {
	setup
	local fake_home="${TEST_TMPDIR}/home2"
	local agents_dir="${TEST_TMPDIR}/agents2"
	make_agents_dir "$agents_dir"
	mkdir -p "${fake_home}/.aidevops"
	printf 'abc123\n' >"${fake_home}/.aidevops/.deployed-sha"
	set_mtime_days_ago "${fake_home}/.aidevops/.deployed-sha" 31

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == FAIL:* ]]; then
		print_result "31d-old .deployed-sha → check fails" 0
		# Also verify the label mentions the deploy stamp ref source
		if [[ "$result" == *"deploy stamp"* ]]; then
			print_result "31d-old .deployed-sha → label names 'deploy stamp' source" 0
		else
			print_result "31d-old .deployed-sha → label names 'deploy stamp' source" 1 "Got: $result"
		fi
	else
		print_result "31d-old .deployed-sha → check fails" 1 "Got: $result (expected FAIL:...)"
	fi
	teardown
	return 0
}

#
# Test 3: no stamp + fresh yaml file → check passes (level 3 fallback)
# Regression: without stamp and without git repo, should still pass if yaml is fresh
#
test_no_stamp_fresh_yaml_passes() {
	setup
	local fake_home="${TEST_TMPDIR}/home3"
	local agents_dir="${TEST_TMPDIR}/agents3"
	make_agents_dir "$agents_dir"
	# No .deployed-sha, no Git/aidevops — yaml file has today's mtime

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == PASS:* ]]; then
		print_result "no stamp + no git + fresh yaml → check passes (level 3 fallback)" 0
	else
		print_result "no stamp + no git + fresh yaml → check passes (level 3 fallback)" 1 "Got: $result"
	fi
	teardown
	return 0
}

#
# Test 4: no stamp + 31-day-old yaml file + no git → check fails (level 3 fallback)
# Regression: prior behaviour preserved when no stamp and no git repo
#
test_no_stamp_stale_yaml_fails() {
	setup
	local fake_home="${TEST_TMPDIR}/home4"
	local agents_dir="${TEST_TMPDIR}/agents4"
	make_agents_dir "$agents_dir"
	set_mtime_days_ago "${agents_dir}/configs/prompt-injection-patterns.yaml" 31
	# No .deployed-sha, no Git/aidevops

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == FAIL:* ]]; then
		print_result "no stamp + no git + 31d-old yaml → check fails (level 3 fallback)" 0
	else
		print_result "no stamp + no git + 31d-old yaml → check fails (level 3 fallback)" 1 "Got: $result"
	fi
	teardown
	return 0
}

#
# Test 5: fresh stamp takes priority over stale yaml
# stamp mtime = today; yaml mtime = 31 days ago → check PASSES (stamp wins)
# This is the exact scenario reported in GH#20312:
#   rsync -a preserves yaml mtime from upstream commit → yaml is "stale"
#   but stamp is fresh (update just ran) → should pass
#
test_fresh_stamp_beats_stale_yaml() {
	setup
	local fake_home="${TEST_TMPDIR}/home5"
	local agents_dir="${TEST_TMPDIR}/agents5"
	make_agents_dir "$agents_dir"
	set_mtime_days_ago "${agents_dir}/configs/prompt-injection-patterns.yaml" 36
	mkdir -p "${fake_home}/.aidevops"
	printf 'abc123\n' >"${fake_home}/.aidevops/.deployed-sha"
	# stamp mtime = now (fresh deploy) → age=0 → pass despite stale yaml

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == PASS:* ]]; then
		print_result "fresh stamp beats stale yaml (GH#20312 core fix)" 0
	else
		print_result "fresh stamp beats stale yaml (GH#20312 core fix)" 1 "Got: $result (expected PASS:...)"
	fi
	teardown
	return 0
}

#
# Test 6: yaml file missing → check fails with missing-file message
# Ensure we didn't break the missing-yaml path
#
test_missing_yaml_fails() {
	setup
	local fake_home="${TEST_TMPDIR}/home6"
	local agents_dir="${TEST_TMPDIR}/agents6"
	mkdir -p "${agents_dir}/configs"
	# No yaml file created
	mkdir -p "${fake_home}/.aidevops"
	printf 'abc123\n' >"${fake_home}/.aidevops/.deployed-sha"

	local result
	result=$(run_check_in_env "$fake_home" "$agents_dir" "$HELPER")

	if [[ "$result" == FAIL:* ]]; then
		print_result "missing yaml → check fails with YAML missing message" 0
	else
		print_result "missing yaml → check fails with YAML missing message" 1 "Got: $result"
	fi
	teardown
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	echo "=== test-prompt-guard-patterns-staleness.sh ==="
	echo

	test_helper_exists
	test_fresh_deployed_sha_passes
	test_stale_deployed_sha_fails
	test_no_stamp_fresh_yaml_passes
	test_no_stamp_stale_yaml_fails
	test_fresh_stamp_beats_stale_yaml
	test_missing_yaml_fails

	echo
	echo "=== Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
