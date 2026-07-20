#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_FIXTURE=""
CACHE_GET_MODE="value"
NMR_LIVE_JSON="[]"
NI_LIVE_JSON="[]"
LIVE_CALLS_FILE=""

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)
	LIVE_CALLS_FILE="$TEST_ROOT/live-calls.log"
	export LOGFILE="$TEST_ROOT/pulse.log"
	export PULSE_PREFETCH_CACHE_FILE="$TEST_ROOT/prefetch-cache.json"
	: >"$LIVE_CALLS_FILE"
	: >"$LOGFILE"
	return 0
}

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup
trap cleanup EXIT

SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck source=../pulse-prefetch-infra.sh
source "$SCRIPTS_DIR/pulse-prefetch-infra.sh"
# shellcheck source=../pulse-prefetch-workers.sh
source "$SCRIPTS_DIR/pulse-prefetch-workers.sh"
# shellcheck source=../pulse-prefetch-secondary.sh
source "$SCRIPTS_DIR/pulse-prefetch-secondary.sh"

_prefetch_cache_get() {
	local slug="$1"
	[[ -n "$slug" ]] || return 1
	[[ "$CACHE_GET_MODE" != "error" ]] || return 1
	printf '%s\n' "$CACHE_FIXTURE"
	return 0
}

gh_issue_list() {
	printf 'nmr\n' >>"$LIVE_CALLS_FILE"
	printf '%s\n' "$NMR_LIVE_JSON"
	return 0
}

gh() {
	local command="$1"
	shift
	if [[ "$command" == "api" ]]; then
		printf '0\n'
		return 0
	fi
	: "$@"
	return 1
}

_prefetch_ni_fetch_issues() {
	local slug="$1"
	[[ -n "$slug" ]] || return 1
	printf 'needs-info\n' >>"$LIVE_CALLS_FILE"
	printf '%s\n' "$NI_LIVE_JSON"
	return 0
}

_prefetch_ni_get_label_date() {
	local slug="$1"
	local number="$2"
	local ni_json="$3"
	local index="$4"
	: "$slug" "$number" "$ni_json" "$index"
	printf '2026-07-20T00:00:00Z\n'
	return 0
}

_prefetch_ni_check_author_replied() {
	local slug="$1"
	local number="$2"
	local author="$3"
	local label_date="$4"
	: "$slug" "$number" "$author" "$label_date"
	printf 'false\n'
	return 0
}

expect_predicate_status() {
	local name="$1"
	local fixture="$2"
	local label="$3"
	local expected_status="$4"
	local mode="${5:-value}"
	local actual_status=1
	CACHE_FIXTURE="$fixture"
	CACHE_GET_MODE="$mode"
	if _prefetch_cached_label_count_is_zero owner/repo "$label"; then
		actual_status=0
	fi
	if [[ "$actual_status" -eq "$expected_status" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1
	fi
	return 0
}

test_predicate_contract() {
	expect_predicate_status "complete zero cache returns success" \
		'{"snapshot_complete":true,"issues":[]}' "needs-maintainer-review" 0
	expect_predicate_status "complete nonmatching cache returns success" \
		'{"snapshot_complete":true,"issues":[{"labels":[{"name":"bug"}]}]}' \
		"needs-maintainer-review" 0
	expect_predicate_status "positive NMR cache returns failure" \
		'{"snapshot_complete":true,"issues":[{"labels":[{"name":"needs-maintainer-review"}]}]}' \
		"needs-maintainer-review" 1
	expect_predicate_status "positive needs-info cache returns failure" \
		'{"snapshot_complete":true,"issues":[{"labels":[{"name":"status:needs-info"}]}]}' \
		"status:needs-info" 1
	expect_predicate_status "missing cache returns failure" '{}' "needs-maintainer-review" 1
	expect_predicate_status "incomplete cache returns failure" \
		'{"snapshot_complete":false,"issues":[]}' "needs-maintainer-review" 1
	expect_predicate_status "missing issues array returns failure" \
		'{"snapshot_complete":true}' "needs-maintainer-review" 1
	expect_predicate_status "invalid issues type returns failure" \
		'{"snapshot_complete":true,"issues":{}}' "needs-maintainer-review" 1
	expect_predicate_status "malformed issue labels return failure" \
		'{"snapshot_complete":true,"issues":[{"labels":"invalid"}]}' \
		"needs-maintainer-review" 1
	expect_predicate_status "partially written cache returns failure" \
		'{"snapshot_complete":true,"issues":[' "needs-maintainer-review" 1
	expect_predicate_status "cache lookup failure returns failure" \
		'' "needs-maintainer-review" 1 error
	return 0
}

test_nmr_consumer() {
	local output=""
	local passed=0
	CACHE_GET_MODE="value"
	CACHE_FIXTURE='{"snapshot_complete":true,"issues":[]}'
	: >"$LIVE_CALLS_FILE"
	: >"$LOGFILE"
	output=$(prefetch_triage_review_status 'owner/repo|/repo')
	if [[ -s "$LIVE_CALLS_FILE" || -n "$output" ]] ||
		! grep -q '0 NMR issues in cache' "$LOGFILE"; then
		passed=1
	fi
	print_result "zero NMR cache skips live query" "$passed"

	passed=0
	CACHE_FIXTURE='{"snapshot_complete":true,"issues":[{"labels":[{"name":"needs-maintainer-review"}]}]}'
	NMR_LIVE_JSON='[{"number":42,"title":"Review me","createdAt":"2026-07-20T00:00:00Z","updatedAt":"2026-07-20T00:00:00Z"}]'
	: >"$LIVE_CALLS_FILE"
	: >"$LOGFILE"
	output=$(prefetch_triage_review_status 'owner/repo|/repo')
	if [[ ! -s "$LIVE_CALLS_FILE" || "$output" != *"Issue #42: Review me"* ]] ||
		grep -q '0 NMR issues in cache' "$LOGFILE"; then
		passed=1
	fi
	print_result "positive NMR cache reaches generated triage output" "$passed"
	return 0
}

test_untrusted_cache_falls_through_live_query() {
	local fixture=""
	local passed=0
	NMR_LIVE_JSON="[]"
	for fixture in \
		'{}' \
		'{"snapshot_complete":false,"issues":[]}' \
		'{"snapshot_complete":true,"issues":['; do
		CACHE_FIXTURE="$fixture"
		CACHE_GET_MODE="value"
		: >"$LIVE_CALLS_FILE"
		: >"$LOGFILE"
		prefetch_triage_review_status 'owner/repo|/repo' >/dev/null
		[[ -s "$LIVE_CALLS_FILE" ]] || passed=1
		grep -q '0 NMR issues in cache' "$LOGFILE" && passed=1
	done
	print_result "missing incomplete and malformed caches use live query" "$passed"
	return 0
}

test_needs_info_consumer() {
	local output=""
	local passed=0
	CACHE_GET_MODE="value"
	CACHE_FIXTURE='{"snapshot_complete":true,"issues":[]}'
	: >"$LIVE_CALLS_FILE"
	: >"$LOGFILE"
	output=$(prefetch_needs_info_replies 'owner/repo|/repo')
	if [[ -s "$LIVE_CALLS_FILE" || -n "$output" ]] ||
		! grep -q '0 needs-info issues in cache' "$LOGFILE"; then
		passed=1
	fi
	print_result "zero needs-info cache skips live query" "$passed"

	passed=0
	CACHE_FIXTURE='{"snapshot_complete":true,"issues":[{"labels":[{"name":"status:needs-info"}]}]}'
	NI_LIVE_JSON='[{"number":84,"title":"Reply needed","author":{"login":"contributor"}}]'
	: >"$LIVE_CALLS_FILE"
	: >"$LOGFILE"
	output=$(prefetch_needs_info_replies 'owner/repo|/repo')
	if [[ ! -s "$LIVE_CALLS_FILE" || "$output" != *"Issue #84: Reply needed"* ]] ||
		grep -q '0 needs-info issues in cache' "$LOGFILE"; then
		passed=1
	fi
	print_result "positive needs-info cache reaches live reply scan" "$passed"
	return 0
}

printf '=== test-pulse-prefetch-label-count.sh ===\n'
test_predicate_contract
test_nmr_consumer
test_untrusted_cache_falls_through_live_query
test_needs_info_consumer
printf '\nResults: %s run, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
