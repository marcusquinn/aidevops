#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SCRIPT_DIR
export HOME="${TMPDIR:-/tmp}/aidevops-idle-debt-borrowing.$$"
mkdir -p "$HOME/.aidevops/logs"
trap 'rm -rf "$HOME"' EXIT

# shellcheck source=../pulse-dispatch-engine.sh
source "$SCRIPT_DIR/pulse-dispatch-engine.sh"

failures=0

assert_order() {
	local name="$1"
	local slots="$2"
	local expected="$3"
	local actual=""

	actual=$(_dispatch_order_idle_borrowing_candidates "$CANDIDATES" "$slots" | jq -r '[.[].number] | join(",")')
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
	failures=$((failures + 1))
	return 0
}

CANDIDATES='[
  {"number":1,"labels":["quality-debt","source:review-feedback"]},
  {"number":2,"labels":["quality-debt","source:review-feedback"]},
  {"number":3,"labels":["quality-debt","source:review-feedback"]},
  {"number":4,"labels":["bug"]},
  {"number":5,"labels":["enhancement"]},
  {"number":6,"labels":["quality-debt","source:quality-sweep"]}
]'

QUALITY_DEBT_CAP_PCT=30
assert_order "caps trusted review debt while ordinary candidates wait" 10 "1,2,3,4,5,6"
assert_order "moves excess trusted review debt behind ordinary candidates" 6 "1,4,5,6,2,3"
assert_order "retains excess debt for idle-capacity borrowing" 1 "4,5,6,1,2,3"

QUALITY_DEBT_CAP_PCT=100
assert_order "honours an explicit full debt share" 2 "1,2,4,5,6,3"

# GH#39976: runner-salted tie-break separates runners inside equal
# (priority_rank, score) groups without changing priority or score order.
salted_order() {
	local login="$1" rollback="${2:-1}"
	_DISPATCH_SELF_LOGIN="$login" HOSTNAME=fixture-host AIDEVOPS_DISPATCH_RUNNER_SALTED_ORDER="$rollback" \
		_dispatch_order_runner_salted_candidates "$SALTED" | jq -r '[.[].number] | join(",")'
	return 0
}
assert_salted() {
	local name="$1" condition="$2"
	if [[ "$condition" == 1 ]]; then
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	printf 'FAIL: %s\n' "$name" >&2
	failures=$((failures + 1))
	return 0
}
SALTED=$(jq -nc '[{number:50, repo_slug:"owner/a", priority_rank:1, score:11500},
	{number:60, repo_slug:"owner/a", priority_rank:0, score:9000}]
	+ [range(1;13) | {number:., repo_slug:"owner/a", priority_rank:0, score:5500}]')
salted_a=$(salted_order runner-a)
salted_b=$(salted_order runner-b)
tied_sorted=$(tr ',' '\n' <<<"${salted_a#50,60,}" | sort -n | paste -sd, -)
assert_salted "salted order keeps priority and score leaders" "$([[ "$salted_a" == 50,60,* && "$salted_b" == 50,60,* ]] && echo 1)"
assert_salted "salted order permutes only the tied group" "$([[ "$tied_sorted" == "1,2,3,4,5,6,7,8,9,10,11,12" ]] && echo 1)"
assert_salted "salted order is stable for one runner" "$([[ "$(salted_order runner-a)" == "$salted_a" ]] && echo 1)"
assert_salted "different runners order tied candidates differently" "$([[ "$salted_a" != "$salted_b" ]] && echo 1)"
assert_salted "empty login keeps the input byte-for-byte" \
	"$([[ "$(_DISPATCH_SELF_LOGIN='' _dispatch_order_runner_salted_candidates "$SALTED")" == "$SALTED" ]] && echo 1)"
assert_salted "rollback flag keeps the input byte-for-byte" \
	"$([[ "$(_DISPATCH_SELF_LOGIN=runner-a AIDEVOPS_DISPATCH_RUNNER_SALTED_ORDER=0 _dispatch_order_runner_salted_candidates "$SALTED")" == "$SALTED" ]] && echo 1)"
assert_salted "invalid JSON is returned unchanged" \
	"$([[ "$(_DISPATCH_SELF_LOGIN=runner-a _dispatch_order_runner_salted_candidates 'not-json')" == 'not-json' ]] && echo 1)"

assert_product_reservation_outcome() {
	local mode="$1" expected_result="$2" expected_attempts="$3" expected_launches="$4" expected_log="$5"
	local candidate_file="" outcomes_file="" attempts_file="" launches_file="" result="" budget=2
	local _DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=86400
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	attempts_file=$(mktemp)
	launches_file=$(mktemp)
	jq -nc --arg mode "$mode" '
		{number:101,repo_slug:"example/product",repo_priority:"product",labels:[]},
		(if $mode == "floor-blocked" then
			{number:102,repo_slug:"example/product",repo_priority:"product",labels:[]} else empty end),
		{number:201,repo_slug:"example/tooling",repo_priority:"tooling",labels:[]},
		{number:202,repo_slug:"example/tooling",repo_priority:"tooling",labels:[]}
	' >"$candidate_file"
	rm -rf "$HOME/.aidevops/cache/dispatch-attempt-recency"
	if [[ "$mode" == floor-blocked ]]; then
		# GH#37478: the floor path has one slot. #102 was attempted earlier
		# without launch, so it is a retry outside the reserved product pool.
		budget=1
		mkdir -p "$HOME/.aidevops/cache/dispatch-attempt-recency"
		printf '%s\n' "$(($(date +%s) - 60))" >"$HOME/.aidevops/cache/dispatch-attempt-recency/example--product--102"
	fi

	# Every product candidate carries a current cross-cycle block in floor-blocked mode.
	_dispatch_negative_cache_reason() {
		[[ "$mode" == floor-blocked && "$(jq -r '.repo_priority' <<<"$1")" == product ]] || return 1
		printf 'terminal_blocker_circuit\n'
		return 0
	}
	_dispatch_process_candidate() {
		local candidate_json="$1" issue_number="" repo_slug=""
		issue_number=$(jq -r '.number' <<<"$candidate_json")
		repo_slug=$(jq -r '.repo_slug' <<<"$candidate_json")
		printf '%s\n' "$issue_number" >>"$attempts_file"
		_DISPATCH_CANDIDATE_ELIGIBILITY="unknown"
		if [[ "$mode" == floor-blocked ]] &&
			_dispatch_prefilter_owned_candidate "$candidate_json" "$issue_number" "$repo_slug"; then
			return 1
		fi
		if [[ "$issue_number" == 101 ]]; then
			if [[ "$mode" == policy-held ]]; then
				printf '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=policy_gate signal=HOLD_FOR_REVIEW_BLOCKED issue=#%s repo=%s\n' \
					"$issue_number" "$repo_slug" >>"$LOGFILE"
				_dispatch_record_nonzero_dispatch_result "$issue_number" "$repo_slug" 3
			else
				_DISPATCH_CANDIDATE_ELIGIBILITY="unknown"
			fi
			return 1
		fi
		printf '%s\n' "$issue_number" >>"$launches_file"
		_DISPATCH_CANDIDATE_ELIGIBILITY="eligible"
		return 0
	}
	_dispatch_graphql_budget_allows_next() { return 0; }
	_dispatch_rest_core_progress_allows_next() { return 0; }
	unset STOP_FLAG || true

	result=$(_dispatch_priority_loop "$candidate_file" "$budget" test-user 1 "$outcomes_file" "$budget" true)
	if [[ "$result" == "$expected_result" && "$(paste -sd, "$attempts_file")" == "$expected_attempts" &&
	"$(paste -sd, "$launches_file")" == "$expected_launches" ]] && grep -q "$expected_log" "$LOGFILE"; then
		printf 'PASS: %s product reservation outcome is safe\n' "$mode"
	else
		printf 'FAIL: %s product reservation outcome (result=%s attempts=%s launches=%s)\n' \
			"$mode" "$result" "$(paste -sd, "$attempts_file")" "$(paste -sd, "$launches_file")" >&2
		failures=$((failures + 1))
	fi
	rm -f "$candidate_file" "$outcomes_file" "$attempts_file" "$launches_file"
	return 0
}

assert_product_reservation_outcome policy-held "2 3" "101,201,202" "201,202" \
	'PRIORITY_RESERVATION requested=2 product_launched=0 held=0 discovery_complete=true launched=2'
assert_product_reservation_outcome unknown "0 1" "101" "" \
	'PRIORITY_RESERVATION requested=2 product_launched=0 held=2 discovery_complete=true launched=0'
# GH#37478: floor path (budget 1, reserved 1) with only cross-cycle-blocked
# product candidates, one of them a retry outside the reserved pool.
assert_product_reservation_outcome floor-blocked "1 3" "101,102,201" "201" \
	'PRIORITY_RESERVATION requested=1 product_launched=0 held=0 discovery_complete=true launched=1'

if [[ "$failures" -ne 0 ]]; then
	exit 1
fi
printf 'All idle debt borrowing tests passed.\n'
exit 0
