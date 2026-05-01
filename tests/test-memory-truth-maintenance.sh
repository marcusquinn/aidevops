#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-memory-truth-maintenance.sh — Tests for memory debunk/truth workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	echo -e "${GREEN}PASS${NC} $name"
	return 0
}

fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo -e "${RED}FAIL${NC} $name${reason:+ — $reason}"
	return 0
}

setup_memory_dir() {
	local test_dir
	test_dir=$(mktemp -d)
	printf '%s\n' "$test_dir"
	return 0
}

run_memory() {
	local memory_dir="$1"
	shift
	AIDEVOPS_MEMORY_DIR="$memory_dir" "$MEMORY_HELPER" "$@"
	return $?
}

store_memory_id() {
	local memory_dir="$1"
	shift
	local output=""
	output=$(run_memory "$memory_dir" store "$@")
	local line=""
	local memory_id=""
	while IFS= read -r line; do
		if [[ "$line" == mem_* ]]; then
			memory_id="$line"
		fi
	done <<<"$output"
	printf '%s\n' "$memory_id"
	return 0
}

test_debunk_suppresses_recall() {
	TESTS_RUN=$((TESTS_RUN + 1))
	local test_dir
	test_dir=$(setup_memory_dir)

	local myth_id live_id debunk_id results
	myth_id=$(store_memory_id "$test_dir" --content "mythical pulse bug alpha marker causes false outage" --type FAILURE_PATTERN --confidence high --tags "truth-test")
	live_id=$(store_memory_id "$test_dir" --content "verified pulse alpha marker current source shows healthy dispatch" --type WORKING_SOLUTION --confidence high --tags "truth-test")
	debunk_id=$(store_memory_id "$test_dir" --content "Evidence: current deployed source disproves the mythical alpha marker outage" --type ERROR_FIX --confidence high --debunks "$myth_id" --replacement "$live_id" --evidence "Verified current source and runtime evidence")

	run_memory "$test_dir" feedback "$myth_id" --signal false >/dev/null
	results=$(run_memory "$test_dir" recall --query "alpha marker" --json)

	if echo "$results" | jq -e --arg myth_id "$myth_id" 'map(.id) | index($myth_id) | not' >/dev/null && \
		echo "$results" | jq -e --arg live_id "$live_id" 'map(.id) | index($live_id) != null' >/dev/null; then
		pass "debunked memory suppressed while live replacement remains discoverable"
	else
		fail "debunked memory suppressed while live replacement remains discoverable" "results=$results debunk=$debunk_id"
	fi

	rm -rf "$test_dir"
	return 0
}

test_debunk_relation_and_truth_event() {
	TESTS_RUN=$((TESTS_RUN + 1))
	local test_dir
	test_dir=$(setup_memory_dir)

	local myth_id debunk_id relation_count event_count
	myth_id=$(store_memory_id "$test_dir" --content "obsolete claim beta marker is always broken" --type FAILURE_PATTERN --confidence medium)
	debunk_id=$(store_memory_id "$test_dir" --content "Evidence: beta marker claim is false" --type ERROR_FIX --debunks "$myth_id" --evidence "Regression test passed")

	relation_count=$(sqlite3 "$test_dir/memory.db" "SELECT COUNT(*) FROM learning_relations WHERE id = '$debunk_id' AND supersedes_id = '$myth_id' AND relation_type = 'debunks';")
	event_count=$(sqlite3 "$test_dir/memory.db" "SELECT COUNT(*) FROM learning_truth_events WHERE memory_id = '$myth_id' AND status = 'debunked' AND debunked_by = '$debunk_id';")

	if [[ "$relation_count" == "1" && "$event_count" == "1" ]]; then
		pass "debunk relation and truth event recorded"
	else
		fail "debunk relation and truth event recorded" "relations=$relation_count events=$event_count"
	fi

	rm -rf "$test_dir"
	return 0
}

test_updates_hide_superseded_memory() {
	TESTS_RUN=$((TESTS_RUN + 1))
	local test_dir
	test_dir=$(setup_memory_dir)

	local old_id new_id results
	old_id=$(store_memory_id "$test_dir" --content "gamma deployment command uses old flag" --type TOOL_CONFIG --confidence medium)
	new_id=$(store_memory_id "$test_dir" --content "gamma deployment command uses new flag" --type TOOL_CONFIG --confidence high --supersedes "$old_id" --relation updates)
	results=$(run_memory "$test_dir" recall --query "gamma deployment command flag" --json)

	if echo "$results" | jq -e --arg old_id "$old_id" --arg new_id "$new_id" 'map(.id) as $ids | ($ids | index($old_id) | not) and ($ids | index($new_id) != null)' >/dev/null; then
		pass "superseded memory hidden while update remains discoverable"
	else
		fail "superseded memory hidden while update remains discoverable" "results=$results"
	fi

	rm -rf "$test_dir"
	return 0
}

test_validate_reports_truth_state() {
	TESTS_RUN=$((TESTS_RUN + 1))
	local test_dir
	test_dir=$(setup_memory_dir)

	local myth_id output
	myth_id=$(store_memory_id "$test_dir" --content "delta myth should be debunked" --type FAILURE_PATTERN)
	store_memory_id "$test_dir" --content "delta myth evidence" --type ERROR_FIX --debunks "$myth_id" >/dev/null
	output=$(run_memory "$test_dir" validate)

	if [[ "$output" == *"Truth maintenance:"* && "$output" == *"debunked"* ]]; then
		pass "validate reports truth-maintenance counts"
	else
		fail "validate reports truth-maintenance counts" "output=$output"
	fi

	rm -rf "$test_dir"
	return 0
}

main() {
	echo ""
	echo "=== Memory Truth Maintenance Tests ==="
	echo ""

	test_debunk_suppresses_recall
	test_debunk_relation_and_truth_event
	test_updates_hide_superseded_memory
	test_validate_reports_truth_state

	echo ""
	echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="
	echo ""

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
