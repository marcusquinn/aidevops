#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pulse-candidate-snapshot-XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$AIDEVOPS_TEMP_DIR" "${HOME}/.aidevops/logs"
: >"$LOGFILE"

# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

# GH#32703: priority:critical/high lead ranking strictly; tier and age bonuses
# must not lift ordinary work above them. Runs the real ranking function before
# the builder is stubbed below; the subshell contains the repo-fetch stubs.
ranking_order=$(
	REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"priority":"tooling"}]}' >"$REPOS_JSON"
	check_repo_pulse_schedule() { return 0; }
	check_repo_pulse_interval() { return 0; }
	update_repo_pulse_timestamp() { return 0; }
	pulse_campaign_shadow_candidates_json() {
		printf '%s\n' '[
			{"number":1,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"tier:simple"},{"name":"bug"},{"name":"auto-dispatch"},{"name":"status:available"}]},
			{"number":2,"createdAt":"2026-09-28T00:00:00Z","labels":[{"name":"priority:high"},{"name":"tier:thinking"},{"name":"auto-dispatch"}]},
			{"number":3,"createdAt":"2026-09-28T00:00:00Z","labels":[{"name":"priority:critical"},{"name":"tier:thinking"}]},
			{"number":4,"createdAt":"2026-09-28T00:00:00Z","labels":[{"name":"priority:high"},{"name":"tier:standard"},{"name":"auto-dispatch"},{"name":"status:available"}]}
		]'
		return 0
	}
	build_ranked_dispatch_candidates_json 50 skip | jq -r '[.[].number] | join(",")'
)
[[ "$ranking_order" == "3,4,2,1" ]] || {
	printf 'FAIL priority labels do not lead dispatch ranking: %s\n' "$ranking_order" >&2
	exit 1
}
printf 'PASS priority:critical/high candidates lead ranking regardless of tier and age\n'

BUILD_COUNT_FILE="${TEST_ROOT}/build-count"
BUILD_MODE_FILE="${TEST_ROOT}/build-mode"
: >"$BUILD_COUNT_FILE"
: >"$BUILD_MODE_FILE"
_PULSE_CYCLE_ID="test-cycle-candidate-snapshot"

build_ranked_dispatch_candidates_json() {
	local per_repo_limit="$1"
	local dependency_normalization_mode="${2:-normalize}"
	local call_count=0
	: "$per_repo_limit"
	call_count=$(wc -l <"$BUILD_COUNT_FILE" 2>/dev/null || printf '0')
	printf 'call\n' >>"$BUILD_COUNT_FILE"
	printf '%s\n' "$dependency_normalization_mode" >>"$BUILD_MODE_FILE"
	printf '[{"number":%s}]\n' "$((call_count + 1))"
	return 0
}

first=$(_dispatch_ranked_candidates_json 50 "skip")
second=$(_dispatch_ranked_candidates_json 50 "skip")
[[ "$first" == '[{"number":1}]' && "$second" == "$first" ]] || {
	printf 'FAIL candidate snapshot was not reused: first=%s second=%s\n' "$first" "$second" >&2
	exit 1
}
normalized_before_invalidation=$(_dispatch_ranked_candidates_json 50)
skip_after_normalize=$(_dispatch_ranked_candidates_json 50 "skip")
[[ "$normalized_before_invalidation" == '[{"number":2}]' && "$skip_after_normalize" == "$first" ]] || {
	printf 'FAIL candidate snapshots collided across normalization modes\n' >&2
	exit 1
}
[[ "$(wc -l <"$BUILD_COUNT_FILE" | tr -d ' ')" == "2" ]] || {
	printf 'FAIL candidate builder did not build once per normalization mode\n' >&2
	exit 1
}
normalize_snapshot_file=$(_dispatch_candidate_snapshot_path 50)
skip_snapshot_file=$(_dispatch_candidate_snapshot_path 50 "skip")
[[ "$normalize_snapshot_file" != "$skip_snapshot_file" && -f "$normalize_snapshot_file" && -f "$skip_snapshot_file" ]] || {
	printf 'FAIL candidate snapshot paths are not mode-specific\n' >&2
	exit 1
}

_dispatch_invalidate_candidate_snapshot "test_state_mutation" 50
third=$(_dispatch_ranked_candidates_json 50)
[[ "$third" == '[{"number":3}]' ]] || {
	printf 'FAIL candidate snapshot did not rebuild after invalidation: %s\n' "$third" >&2
	exit 1
}

# Cleanup follows the census key, not the runnable-count sample size.
triage_marker=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done")
printf 'done\n' >"$triage_marker"
PULSE_RUNNABLE_ISSUE_LIMIT=7 PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50 _dispatch_cleanup_cycle_cache
[[ ! -e "$normalize_snapshot_file" && ! -e "$skip_snapshot_file" && ! -e "$triage_marker" ]] || {
	printf 'FAIL cycle cache cleanup left candidate or triage artifacts behind\n' >&2
	exit 1
}

export PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED=0
fourth=$(_dispatch_ranked_candidates_json 50 "skip")
fifth=$(_dispatch_ranked_candidates_json 50)
[[ "$fourth" == '[{"number":4}]' && "$fifth" == '[{"number":5}]' ]] || {
	printf 'FAIL candidate snapshot escape hatch did not bypass cache\n' >&2
	exit 1
}
[[ "$(<"$BUILD_MODE_FILE")" == $'skip\nnormalize\nnormalize\nskip\nnormalize' ]] || {
	printf 'FAIL candidate builder did not receive normalization modes: %s\n' "$(<"$BUILD_MODE_FILE")" >&2
	exit 1
}

# A small runnable-count diagnostic sample must not limit dispatch scanning.
# Three benignly blocked candidates must not hide a later eligible candidate.
unset PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED
(
	_PULSE_CYCLE_ID="ranked-continuation"
	PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
	dependency_normalization_mode=normalize
	snapshot=$(_dispatch_candidate_snapshot_path 50)
	now=$(date +%s)
	jq -nc --argjson now "$now" '{captured_at:($now-180),census_seconds:300,candidates:[{number:1,repo_slug:"o/r"},{number:2,repo_slug:"o/r"},{number:3,repo_slug:"o/r"}]}' >"$snapshot"
	_dispatch_ranked_candidate_consumed '{"number":1,"repo_slug":"o/r"}'
	remaining=$(_dispatch_ranked_candidates_json 50)
	[[ "$(jq -r '[.[].number]|join(",")' <<<"$remaining")" == '2,3' ]]
	_dispatch_ranked_candidate_consumed '{"number":2,"repo_slug":"o/r"}'
	_dispatch_ranked_candidate_consumed '{"number":3,"repo_slug":"o/r"}'
	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[{"number":1,"repo_slug":"o/r"},{"number":4,"repo_slug":"o/r"}]'
		return 0
	}
	refreshed=$(_dispatch_ranked_candidates_json 50)
	[[ "$(jq -r '[.[].number]|join(",")' <<<"$refreshed")" == 4 && -f "${snapshot}.consumed" ]]
	_dispatch_cleanup_cycle_cache 50
)
printf 'PASS ranked refills continue beyond 120 seconds, consume once, and re-census on exhaustion\n'

(
	_PULSE_FIRST_DISPATCH_WAVE=1
	PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
	REPOS_JSON="${TEST_ROOT}/partial-repos.json"
	printf '{"initialized_repos":[{"slug":"o/product","path":"/fixture","pulse":true}]}\n' >"$REPOS_JSON"
	scheduled=1
	check_repo_pulse_schedule() {
		[[ "$scheduled" == 1 ]] && return 0
		return 1
	}
	_dispatch_enumeration_expected_seconds() { printf '300\n'; return 0; }
	build_ranked_dispatch_candidates_json() {
		jq -nc '[range(1;3) | {number:.,repo_slug:"o/product",repo_path:"/fixture",product_discovery_complete:false}]'
		return 0
	}
	initial=$(_dispatch_ranked_candidates_json 50 skip)
	[[ "$(scheduled=0 _dispatch_filter_partial_snapshot_candidates "$initial")" == '[]' ]]
	jq '.initialized_repos[0].maintenance = false' "$REPOS_JSON" >"${REPOS_JSON}.test"
	[[ "$(REPOS_JSON="${REPOS_JSON}.test" _dispatch_filter_partial_snapshot_candidates "$initial")" == '[]' ]]
	jq '.initialized_repos[0].path = "/moved"' "$REPOS_JSON" >"${REPOS_JSON}.test"
	[[ "$(REPOS_JSON="${REPOS_JSON}.test" _dispatch_filter_partial_snapshot_candidates "$initial")" == '[]' ]]
	partial=$(_dispatch_candidate_snapshot_path 50 skip)
	_dispatch_ranked_candidate_consumed '{"number":1,"repo_slug":"o/product"}'
	# Refill-only invalidation precedes dispatch admission. It must clear the
	# ordinary cache without losing the durable queue or its attempt ledger.
	for mode in normalize skip; do
		normal=$(_PULSE_FIRST_DISPATCH_WAVE=0 _dispatch_candidate_snapshot_path 50 "$mode")
		cp "$partial" "$normal"
		cp "${partial}.consumed" "${normal}.consumed"
	done
	_dispatch_invalidate_candidate_snapshot event_refill 50
	for mode in normalize skip; do
		normal=$(_PULSE_FIRST_DISPATCH_WAVE=0 _dispatch_candidate_snapshot_path 50 "$mode")
		[[ ! -f "$normal" && ! -f "${normal}.consumed" ]]
	done
	[[ -f "$partial" && -f "${partial}.consumed" ]]
	remaining=$(_dispatch_ranked_candidates_json 50 skip)
	jq -e 'length == 1 and .[0].number == 2' <<<"$remaining" >/dev/null
	_dispatch_cleanup_cycle_cache 50
	_PULSE_CYCLE_ID="partial-next-cycle"
	remaining=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
	jq -e 'length == 1 and .[0].number == 2 and .[0].product_discovery_complete == false' <<<"$remaining" >/dev/null
	_dispatch_ranked_candidate_consumed '{"number":2,"repo_slug":"o/product"}'
	# Rebuilding an exhausted queue retains its original attempt-ledger expiry.
	jq '.captured_at -= 10' "$partial" >"${partial}.test"
	mv "${partial}.test" "$partial"
	captured=$(jq -r '.captured_at' "$partial")
	[[ "$(_dispatch_ranked_candidates_json 50 skip)" == '[]' ]]
	[[ "$(jq -r '.captured_at' "$partial")" == "$captured" ]]
	jq '.captured_at = 0' "$partial" >"${partial}.test"
	mv "${partial}.test" "$partial"
	refreshed=$(_dispatch_ranked_candidates_json 50 skip)
	[[ "$refreshed" == "$initial" && ! -f "${partial}.consumed" ]]
	_dispatch_ranked_candidate_consumed '{"number":1,"repo_slug":"o/product"}'
	_dispatch_invalidate_candidate_snapshot partial_state_changed 50
	[[ ! -f "$partial" && ! -f "${partial}.consumed" ]]
)
printf 'PASS durable partial snapshots preserve attempts across cycles, expire without renewing consumed work, and invalidate on mutation\n'

# GH#38048: a cooperatively drained cycle hands its full census and attempt
# ledger to the activated bundle's first wave instead of deleting them.
(
	PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
	LOCKDIR="${TEST_ROOT}/drain-lock"
	REPOS_JSON="${TEST_ROOT}/handoff-repos.json"
	builds="${TEST_ROOT}/handoff-builds"
	stats="${TEST_ROOT}/handoff-stats"
	printf '{"initialized_repos":[{"slug":"o/product","path":"/fixture","pulse":true}]}\n' >"$REPOS_JSON"
	check_repo_pulse_schedule() { return 0; }
	_dispatch_enumeration_expected_seconds() { printf '300\n'; return 0; }
	pulse_stats_increment() {
		local counter="$1"
		printf '%s\n' "$counter" >>"$stats"
		return 0
	}
	build_ranked_dispatch_candidates_json() {
		printf 'scan\n' >>"$builds"
		jq -nc '[range(1;4) | {number:.,repo_slug:"o/product",repo_path:"/fixture"}]'
		return 0
	}
	request_drain() {
		local owner="$1"
		mkdir -p "$LOCKDIR"
		printf 'owner=%s\nbundle=bundle-next\n' "$owner" >"${LOCKDIR}/drain_requested"
		return 0
	}
	write_handoff() {
		local target="$1" schema="$2" age="$3" issues="$4" now=""
		now=$(date +%s)
		jq -nc --arg schema "$schema" --argjson captured "$((now - age))" --arg issues "$issues" \
			'{schema:$schema,captured_at:$captured,census_seconds:300,candidates:[$issues | split(",")[] | {number:tonumber,repo_slug:"o/product",repo_path:"/fixture"}]}' >"$target"
		return 0
	}
	numbers() {
		local candidates="$1"
		jq -r '[.[].number] | join(",")' <<<"$candidates"
		return 0
	}
	handoff=$(_dispatch_candidate_handoff_path 50)
	skip_handoff=$(_dispatch_candidate_handoff_path 50 skip)
	partial=$(_PULSE_FIRST_DISPATCH_WAVE=1 _dispatch_candidate_snapshot_path 50 skip)

	# A marker naming another lock owner is not this cycle's drain.
	_PULSE_CYCLE_ID="undrained-cycle"
	_dispatch_ranked_candidates_json 50 >/dev/null
	full=$(_dispatch_candidate_snapshot_path 50)
	request_drain 1
	_dispatch_cleanup_cycle_cache 50
	[[ ! -e "$full" && ! -e "$handoff" ]]

	_PULSE_CYCLE_ID="drained-cycle"
	_dispatch_ranked_candidates_json 50 >/dev/null
	full=$(_dispatch_candidate_snapshot_path 50)
	_dispatch_ranked_candidate_consumed '{"number":1,"repo_slug":"o/product"}'
	request_drain "$$"
	_dispatch_cleanup_cycle_cache 50
	[[ ! -e "$full" && ! -e "${full}.consumed" && -f "$handoff" && -f "${handoff}.consumed" ]]
	[[ "$(jq -r '.schema' "$handoff")" == "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" ]]
	rm -rf "$LOCKDIR"

	# A full round of the activated bundle scans for itself; a freed slot
	# keeps the handoff for the first wave.
	_PULSE_CYCLE_ID="activated-cycle"
	: >"$builds"
	_dispatch_ranked_candidates_json 50 >/dev/null
	_dispatch_invalidate_candidate_snapshot event_refill 50
	[[ -s "$builds" && -f "$handoff" ]]

	# The first wave serves the unattempted remainder without a scan.
	: >"$builds"
	: >"$stats"
	remainder=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
	[[ "$(numbers "$remainder")" == '2,3' && ! -s "$builds" ]]
	[[ ! -e "$handoff" && ! -e "${handoff}.consumed" && -f "$partial" && -f "${partial}.consumed" ]]
	grep -qx 'dispatch_candidate_handoff_adopted' "$stats"
	grep -qx 'dispatch_candidate_snapshot_hit' "$stats"

	# Past its reuse window, or in another snapshot format, a handoff is
	# removed unserved and the wave scans.
	for fixture in "${_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA}|301" 'other/v0|0'; do
		_dispatch_invalidate_candidate_snapshot handoff_fixture_reset 50
		write_handoff "$handoff" "${fixture%%|*}" "${fixture##*|}" 9
		: >"$builds"
		scanned=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
		[[ "$(numbers "$scanned")" == '1,2,3' && -s "$builds" && ! -e "$handoff" ]]
	done

	# A normalize round never takes a census that skipped dependency
	# normalization; a skip round does. A mutation discards an unadopted one.
	_dispatch_invalidate_candidate_snapshot handoff_fixture_reset 50
	write_handoff "$skip_handoff" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" 0 7
	normalized=$(_dispatch_bounded_ranked_candidates_json 50 normalize 180)
	[[ "$(numbers "$normalized")" == '1,2,3' && -f "$skip_handoff" ]]
	skipped=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
	[[ "$(numbers "$skipped")" == '7' && ! -e "$skip_handoff" ]]
	# Production callers pass no limit: the default is the census key.
	write_handoff "$handoff" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" 0 8
	PULSE_RUNNABLE_ISSUE_LIMIT=7 _dispatch_invalidate_candidate_snapshot label_maintenance_complete
	[[ ! -e "$handoff" && ! -e "$partial" ]]

	# Attempts the drained cycle's first wave recorded in a still-fresh durable
	# snapshot stay consumed after adoption; an expired snapshot's lapse.
	for fixture in '0|8' '301|7,8'; do
		_dispatch_invalidate_candidate_snapshot handoff_fixture_reset 50
		write_handoff "$partial" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" "${fixture%%|*}" 7
		_dispatch_ranked_candidate_consumed '{"number":7,"repo_slug":"o/product"}'
		write_handoff "$handoff" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" 0 7,8
		: >"$builds"
		merged=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
		[[ "$(numbers "$merged")" == "${fixture##*|}" && ! -s "$builds" && ! -e "$handoff" ]]
	done

	# A census whose attempt ledger cannot be installed is not adopted.
	_dispatch_invalidate_candidate_snapshot handoff_fixture_reset 50
	write_handoff "$handoff" "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" 0 9
	printf '["o/product",9]\n' >"${handoff}.consumed"
	mv() {
		local target="${!#}"
		[[ "$target" != "${partial}.consumed" ]] || return 1
		command mv "$@"
		return $?
	}
	: >"$builds"
	scanned=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
	unset -f mv
	[[ "$(numbers "$scanned")" == '1,2,3' && -s "$builds" && ! -e "$handoff" && ! -e "${handoff}.consumed" ]]
	grep -q 'handoff discarded: reason=transfer_failed' "$LOGFILE"
)
printf 'PASS drained cycles hand a full census and its attempt ledger to the next first wave; stale, foreign-format, wrong-mode and untransferable handoffs are not served\n'

(
	claim_comments='[{"id":41,"author_association":"OWNER","created_at":"2026-11-12T05:00:00Z","updated_at":"2026-11-12T05:00:00Z","body":"Dispatching worker"}]'
	gh() {
		local query="" arg=""
		while (($#)); do
			arg="$1"; shift
			if [[ "$arg" == --jq ]]; then query="$1"; shift; fi
		done
		jq -c "$query" <<<"$claim_comments"
		return 0
	}
	_dispatch_claim_cache_record 41 o/r 'TTL: 100s remaining'
	_dispatch_claim_cache_hit 41 o/r
	# A different cycle can use the persisted evidence, not the cycle ledger.
	_PULSE_CYCLE_ID="claim-cache-next-cycle"
	_dispatch_claim_cache_hit 41 o/r
	claim_comments=$(jq '.[0].updated_at="2026-11-12T05:01:00Z"' <<<"$claim_comments")
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	claim_comments=$(jq '.[0].id=42' <<<"$claim_comments")
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	_dispatch_claim_cache_record 41 o/r 'TTL: 100s remaining'
	claim_comments=$(jq '. + [{id:43,author_association:"OWNER",created_at:"2026-11-12T05:02:00Z",body:"CLAIM_RELEASED"}]' <<<"$claim_comments")
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	claim_comments='[{"id":44,"author_association":"NONE","body":"Dispatching worker"}]'
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	claim_comments='[]'
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	cache_path=$(_dispatch_negative_cache_path 41 o/r)
	jq '.expires=1' "${cache_path}.claim" >"${cache_path}.test"
	mv "${cache_path}.test" "${cache_path}.claim"
	if _dispatch_claim_cache_hit 41 o/r; then exit 1; fi
	_dispatch_claim_cache_record 42 o/r 'no verifiable expiry'
	cache_path=$(_dispatch_negative_cache_path 42 o/r)
	[[ ! -f "${cache_path}.claim" ]]
)
printf 'PASS durable claim cache expires and wakes on changed, released, missing or untrusted evidence\n'

_PULSE_CYCLE_ID="test-cycle-stale-candidate-snapshot"
fresh=$(_dispatch_ranked_candidates_json 50)
snapshot=$(_dispatch_candidate_snapshot_path 50)
jq '.captured_at = 0' "$snapshot" >"${snapshot}.test"
mv "${snapshot}.test" "$snapshot"
refreshed=$(_dispatch_ranked_candidates_json 50)
[[ "$fresh" != "$refreshed" ]] || { printf 'FAIL expired snapshot hides new work\n' >&2; exit 1; }
jq '.captured_at = 9999999999' "$snapshot" >"${snapshot}.test"
mv "${snapshot}.test" "$snapshot"
future_refreshed=$(_dispatch_ranked_candidates_json 50)
[[ "$refreshed" != "$future_refreshed" ]] || { printf 'FAIL future snapshot accepted\n' >&2; exit 1; }
_dispatch_invalidate_candidate_snapshot "test_failure" 50
build_ranked_dispatch_candidates_json() { return 1; }
if _dispatch_ranked_candidates_json 50; then
	printf 'FAIL failed enumeration became successful empty queue\n' >&2
	exit 1
fi
[[ ! -f "$snapshot" ]] || { printf 'FAIL failed enumeration cached\n' >&2; exit 1; }

dispatch_log="${TEST_ROOT}/dispatch-scan.log"
: >"$dispatch_log"
_dispatch_compute_capacity() { printf '2 0 2\n'; return 0; }
_dispatch_ranked_candidates_json() {
	printf 'scan_limit=%s\n' "$1" >>"$dispatch_log"
	printf '%s\n' '[
		{"number":9101}, {"number":9102}, {"number":9103}, {"number":9104}
	]'
	return 0
}
_dispatch_run_prepasses() { printf '%s 0 0\n' "$1"; return 0; }
_dispatch_order_idle_borrowing_candidates() { printf '%s\n' "$1"; return 0; }
_dispatch_max_compute_parallel() { printf '1\n'; return 0; }
_dispatch_graphql_budget_allows_next() { return 0; }
_dispatch_rest_core_progress_allows_next() { return 0; }
_dispatch_maybe_engage_throttle() { return 0; }
_dispatch_process_candidate() {
	printf '%s\n' "$1" >>"$dispatch_log"
	case "$1" in
	*'"number":9101'* | *'"number":9102'* | *'"number":9103'*) return 3 ;;
	esac
	return 0
}
gh() {
	if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
		printf 'testuser\n'
	fi
	return 0
}
PULSE_RUNNABLE_ISSUE_LIMIT=3
dispatch_count=$(dispatch_max)
scan_limit=$(grep -o 'scan_limit=[0-9]*' "$dispatch_log" | cut -d= -f2)
grep -q '"number":9104' "$dispatch_log" && [[ "$dispatch_count" == "1" && "$scan_limit" == "1000" ]] || {
	printf 'FAIL dispatch did not scan past benign head blocks: count=%s scan_limit=%s log=%s\n' "$dispatch_count" "$scan_limit" "$(tr '\n' ',' <"$dispatch_log")" >&2
	exit 1
}

_dispatch_ranked_candidates_json() { return 1; }
LOGFILE="${TEST_ROOT}/enumeration-failure.log"
if dispatch_max; then
	printf 'FAIL dispatch_max swallowed enumeration failure\n' >&2
	exit 1
fi
grep -q 'candidate enumeration unavailable' "$LOGFILE" || exit 1
if grep -q 'skipped: no ranked candidates' "$LOGFILE"; then
	printf 'FAIL unavailable queue was reported empty\n' >&2
	exit 1
fi

printf 'PASS dispatch candidate snapshots reuse enumeration, preserve modes, and invalidate on state mutation\n'
