#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../pulse-merge-required-checks.sh
source "${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

TEST_ROOT="$(mktemp -d -t pulse-preflight-snapshot.XXXXXX)"
LOGFILE="${TEST_ROOT}/pulse.log"
PULSE_MERGE_QUIET_PERIOD_SECONDS=30
PULSE_MERGE_NOW_EPOCH="$(_pmrc_iso_to_epoch '2026-01-01T00:10:00Z')"
SNAPSHOT_MODE="happy_advisory"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

_required_contexts_for_default_branch() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	printf 'required-a\n'
	return 0
}

gh() {
	local command="$1"
	local endpoint="${2:-}"
	[[ "$command" == "api" ]] || return 1

	if [[ "$endpoint" == "graphql" ]]; then
		if [[ "$SNAPSHOT_MODE" == "unresolved" ]]; then
			printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"}}]}}]}}}}}'
		else
			printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
		fi
		return 0
	fi

	case "$endpoint" in
	repos/owner/repo/pulls/7)
		if [[ "$SNAPSHOT_MODE" == "new_head" ]]; then
			printf '%s\n' '{"head":{"sha":"sha-new"}}'
		else
			printf '%s\n' '{"head":{"sha":"sha-reviewed"}}'
		fi
		;;
	*check-runs*)
		local required_conclusion="success" broad_status="completed" broad_conclusion="success"
		local broad_completed_at="2026-01-01T00:01:00Z" extra_check=""
		[[ "$SNAPSHOT_MODE" == "required_fail" ]] && required_conclusion="failure"
		if [[ "$SNAPSHOT_MODE" == "pending" ]]; then
			broad_status="in_progress"
			broad_conclusion="null"
		fi
		[[ "$SNAPSHOT_MODE" == "recent" ]] && broad_completed_at="2026-01-01T00:09:50Z"
		if [[ "$SNAPSHOT_MODE" == "unclassified_fail" ]]; then
			extra_check=',{"name":"CodeFactor","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}'
		fi
		printf '[{"check_runs":[{"name":"required-a","status":"completed","conclusion":"%s","completed_at":"2026-01-01T00:01:00Z"},{"name":"Framework Validation","status":"%s","conclusion":%s,"completed_at":"%s"},{"name":"Qlty Smell Regression","status":"completed","conclusion":"success","completed_at":"2026-01-01T00:01:00Z"},{"name":"Qlty Smell Threshold","status":"completed","conclusion":"failure","completed_at":"2026-01-01T00:01:00Z"}%s]}]\n' \
			"$required_conclusion" "$broad_status" "$([[ "$broad_conclusion" == "null" ]] && printf 'null' || printf '"%s"' "$broad_conclusion")" "$broad_completed_at" "$extra_check"
		;;
	*commits/sha-reviewed/status*)
		local gate_at="2026-01-01T00:01:10Z"
		[[ "$SNAPSHOT_MODE" == "stale_gate" ]] && gate_at="2026-01-01T00:00:20Z"
		if [[ "$SNAPSHOT_MODE" == "no_status_gate" ]]; then
			printf '%s\n' '{"statuses":[]}'
		else
			printf '{"statuses":[{"context":"review-bot-gate","state":"success","updated_at":"%s"}]}\n' "$gate_at"
		fi
		;;
	*pulls/7/reviews*)
		printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"submitted_at":"2026-01-01T00:00:30Z"}]]'
		;;
	*issues/7/comments*)
		printf '%s\n' '[[]]'
		;;
	*pulls/7/comments*)
		if [[ "$SNAPSHOT_MODE" == "stale_gate" || "$SNAPSHOT_MODE" == "unresolved" ]]; then
			printf '%s\n' '[[{"user":{"login":"gemini-code-assist[bot]"},"created_at":"2026-01-01T00:00:40Z","updated_at":"2026-01-01T00:00:40Z"}]]'
		else
			printf '%s\n' '[[]]'
		fi
		;;
	*)
		printf 'Unhandled gh endpoint: %s\n' "$endpoint" >&2
		return 1
		;;
	esac
	return 0
}

assert_gate() {
	local description="$1"
	local mode="$2"
	local expected_rc="$3"
	local rc=0
	SNAPSHOT_MODE="$mode"
	: >"$LOGFILE"
	_pulse_merge_preflight_snapshot_gate owner/repo 7 sha-reviewed || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq "$expected_rc" ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (expected rc=%s, actual rc=%s)\n' "$description" "$expected_rc" "$rc"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

main() {
	assert_gate "terminal checks with explicit baseline advisory pass" happy_advisory 0
	if grep -q "IGNORED non-required baseline advisory failure 'Qlty Smell Threshold'" "$LOGFILE"; then
		printf 'PASS ignored advisory failure is audited\n'
	else
		printf 'FAIL ignored advisory failure is audited\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	assert_gate "active broad check blocks merge" pending 1
	assert_gate "terminal failed required check blocks merge" required_fail 1
	assert_gate "unclassified non-required failure blocks merge" unclassified_fail 1
	assert_gate "unresolved late inline finding blocks merge" unresolved 1
	assert_gate "late review activity invalidates stale gate success" stale_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "missing status gate fails closed without live evidence" no_status_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE="owner/repo#7@sha-reviewed"
	assert_gate "live gate evidence permits repositories without a status context" no_status_gate 0
	_PULSE_REVIEW_GATE_EVIDENCE="owner/repo#7@sha-other"
	assert_gate "live gate evidence for another head fails closed" no_status_gate 1
	_PULSE_REVIEW_GATE_EVIDENCE=""
	assert_gate "new commit invalidates reviewed head" new_head 1
	assert_gate "bounded quiet period blocks recent check completion" recent 1
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
