#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#3894 / t2769 no_work false trips.
#
# _is_stale_assignment must paginate and slurp issue comments. Without --slurp,
# `gh api --paginate --jq ...` runs jq per page; long issue threads can leave the
# first page of old dispatch comments before newer page-2 activity, causing stale
# recovery to record stale_timeout/no_work fast-fails that trip t2769.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_HOME="$(mktemp -d -t stale-pagination.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
SCRIPT_DIR="$SCRIPTS_DIR"

# shellcheck source=../dispatch-dedup-stale.sh
source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"

RECOVERY_CALLED=0
GH_CALL_LOG="${TMP_HOME}/gh-calls.log"
: >"$GH_CALL_LOG"

_resolve_stale_threshold() {
	local _issue_number="$1"
	local _repo_slug="$2"
	: "$_issue_number" "$_repo_slug"
	printf 'false\n600\n2020-01-01T00:00:00Z\n'
	return 0
}

_recover_stale_assignment() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _stale_assignees="$3"
	local _reason="$4"
	: "$_issue_number" "$_repo_slug" "$_stale_assignees" "$_reason"
	RECOVERY_CALLED=1
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	if [[ "$cmd" != "api" ]]; then
		printf '{}\n'
		return 0
	fi

	local path="${1:-}"
	shift || true
	if [[ "$path" != "repos/owner/repo/issues/123/comments" ]]; then
		printf '[]\n'
		return 0
	fi

	local has_paginate=0
	local has_slurp=0
	local jq_filter=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--paginate)
			has_paginate=1
			shift
			;;
		--slurp)
			has_slurp=1
			shift
			;;
		--jq)
			jq_filter="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local recent_ts
	recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local response
	if [[ "$has_paginate" -eq 1 && "$has_slurp" -eq 1 ]]; then
		printf 'comments_slurped\n' >>"$GH_CALL_LOG"
		response=$(printf '[[{"created_at":"2020-01-01T00:00:00Z","user":{"login":"runner"},"body":"Dispatching worker (deterministic)."}],[{"created_at":"%s","user":{"login":"runner"},"body":"CLAIM_RELEASED reason=clean runner=runner exit=0 session_count=1"}]]\n' "$recent_ts")
	elif [[ "$has_paginate" -eq 1 ]]; then
		printf 'comments_paginated_per_page\n' >>"$GH_CALL_LOG"
		response=$(printf '[{"created_at":"2020-01-01T00:00:00Z","author":"runner","body_start":"Dispatching worker (deterministic)."}]\n[{"created_at":"%s","author":"runner","body_start":"CLAIM_RELEASED reason=clean runner=runner exit=0 session_count=1"}]\n' "$recent_ts")
	else
		printf 'comments_unpaginated\n' >>"$GH_CALL_LOG"
		response='[{"created_at":"2020-01-01T00:00:00Z","user":{"login":"runner"},"body":"Dispatching worker (deterministic)."}]'
	fi

	if [[ -n "$jq_filter" ]]; then
		printf '%s' "$response" | jq -r "$jq_filter"
	else
		printf '%s\n' "$response"
	fi
	return 0
}

if _is_stale_assignment "123" "owner/repo" "runner"; then
	fail "recent paginated activity prevents stale recovery" "_is_stale_assignment returned stale; RECOVERY_CALLED=${RECOVERY_CALLED}"
else
	if [[ "$RECOVERY_CALLED" -eq 0 ]]; then
		pass "recent paginated activity prevents stale recovery"
	else
		fail "recent paginated activity prevents stale recovery" "recovery hook was called"
	fi
fi

if grep -q '^comments_slurped$' "$GH_CALL_LOG" 2>/dev/null; then
	pass "comments API is called with --paginate --slurp"
else
	fail "comments API is called with --paginate --slurp" "mock did not observe a slurped comments request"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
