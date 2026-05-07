#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t3570 / GH#23102 dispatch-side handling of the
# comment-based transient rate-limit release circuit breaker.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)"
TMP="$(mktemp -d -t t3570-dispatch.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export HOME="${TMP}/home"
mkdir -p "${HOME}/.aidevops/logs"

COMMENTS_JSON="${TMP}/comments.json"
FIXTURE_METRICS="${TMP}/headless-runtime-metrics.jsonl"
STATS_COUNTER_FILE="${TMP}/stats-counter.log"
printf '[]\n' >"$COMMENTS_JSON"
: >"$FIXTURE_METRICS"
: >"$STATS_COUNTER_FILE"
export DISPATCH_BACKOFF_METRICS_FILE="$FIXTURE_METRICS"

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
export -f pulse_stats_increment

gh() {
	local cmd="${1:-}"
	shift || true
	if [[ "$cmd" == "api" ]]; then
		jq -c '.' "$COMMENTS_JSON"
	fi
	return 0
}
export -f gh

# shellcheck source=../dispatch-backoff-helper.sh
source "${SCRIPTS_DIR}/dispatch-backoff-helper.sh"

# Re-override after sourcing the real pulse-stats helper.
# shellcheck disable=SC2317
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}

iso_offset() {
	local seconds_delta="$1"
	local epoch
	epoch=$(($(date +%s) + seconds_delta))
	date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

epoch_offset() {
	local seconds_delta="$1"
	printf '%s\n' "$(($(date +%s) + seconds_delta))"
	return 0
}

append_comment_fixture() {
	local created_at="$1"
	local body="$2"
	local tmp="${COMMENTS_JSON}.tmp"
	jq --arg created_at "$created_at" --arg body "$body" \
		'. + [{created_at: $created_at, body: $body}]' \
		"$COMMENTS_JSON" >"$tmp"
	mv "$tmp" "$COMMENTS_JSON"
	return 0
}

reset_case() {
	printf '[]\n' >"$COMMENTS_JSON"
	: >"$FIXTURE_METRICS"
	: >"$STATS_COUNTER_FILE"
	: >"$LOGFILE"
	unset AIDEVOPS_SKIP_DISPATCH_BACKOFF 2>/dev/null || true
	export AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE=0
	export DISPATCH_PROVIDER_BACKOFF_THRESHOLD=999
	return 0
}

test_active_marker_blocks_dispatch() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset 600)
	append_comment_fixture "$(iso_offset -60)" "<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->"

	local output="" rc=0
	output=$(check_dispatch_backoff 12345 owner/repo 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]] && printf '%s' "$output" | grep -q 'BACKOFF_ACTIVE reason=rate_limit_release_circuit' && \
		grep -q '^dispatch_backoff_skipped$' "$STATS_COUNTER_FILE"; then
		printf 'PASS active release circuit blocks dispatch\n'
		return 0
	fi
	printf 'FAIL active release circuit did not block dispatch (rc=%s output=%s)\n' "$rc" "$output"
	return 1
}

test_expired_marker_allows_dispatch() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset -60)
	append_comment_fixture "$(iso_offset -900)" "<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->"

	local output="" rc=0
	output=$(check_dispatch_backoff 12345 owner/repo 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 0 ]] && ! printf '%s' "$output" | grep -q 'BACKOFF_ACTIVE'; then
		printf 'PASS expired release circuit allows dispatch\n'
		return 0
	fi
	printf 'FAIL expired release circuit blocked dispatch (rc=%s output=%s)\n' "$rc" "$output"
	return 1
}

test_override_comment_allows_dispatch() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset 600)
	append_comment_fixture "$(iso_offset -60)" "<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->"
	append_comment_fixture "$(iso_offset -30)" 'rate-limit-release-circuit-breaker:override'

	local output="" rc=0
	output=$(check_dispatch_backoff 12345 owner/repo 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 0 ]] && ! printf '%s' "$output" | grep -q 'BACKOFF_ACTIVE'; then
		printf 'PASS override comment allows dispatch\n'
		return 0
	fi
	printf 'FAIL override comment did not allow dispatch (rc=%s output=%s)\n' "$rc" "$output"
	return 1
}

test_no_marker_allows_dispatch() {
	reset_case
	local output="" rc=0
	output=$(check_dispatch_backoff 12345 owner/repo 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 0 ]] && ! printf '%s' "$output" | grep -q 'BACKOFF_ACTIVE'; then
		printf 'PASS no release circuit marker allows dispatch\n'
		return 0
	fi
	printf 'FAIL missing release circuit marker blocked dispatch (rc=%s output=%s)\n' "$rc" "$output"
	return 1
}

test_active_marker_blocks_dispatch
test_expired_marker_allows_dispatch
test_override_comment_allows_dispatch
test_no_marker_allows_dispatch
