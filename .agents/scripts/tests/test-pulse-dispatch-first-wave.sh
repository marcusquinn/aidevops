#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#33647: exercise real orchestration/ranking/admission with isolated I/O.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/cache" "${HOME}/.aidevops/logs"
LOGFILE="${TEST_ROOT}/pulse.log"
REPOS_JSON="${TEST_ROOT}/repos.json"
EVENTS="${TEST_ROOT}/events"
CLOCK="${TEST_ROOT}/clock"
PIDFILE="${TEST_ROOT}/pulse.pid"
AIDEVOPS_DISPATCH_LEDGER_FILE="${TEST_ROOT}/ledger.jsonl"
STOP_FLAG="${TEST_ROOT}/stop"
printf '0\n' >"$CLOCK"
: >"$EVENTS"
: >"$LOGFILE"
printf '2476\n' >"${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds"
jq -n '{initialized_repos:[range(1;41) | {slug:("owner/repo" + tostring),path:"/fixture",pulse:true}]}' >"$REPOS_JSON"

# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=../pulse-wrapper-cycle-gates.sh
source "${SCRIPT_DIR}/pulse-wrapper-cycle-gates.sh"

# Transport I/O is simulated as five seconds per read at 540/5000 core.
# Real ranking, enumeration reserve, first-wave scope and orchestration run.
advance_clock() {
	local seconds="$1" now=0
	read -r now <"$CLOCK"
	printf '%s\n' "$((now + seconds))" >"$CLOCK"
	return 0
}
# Clock/timing stubs are installed by a function so they can be restored
# after sourcing production libraries that define the same names.
_install_fixture_clock_stubs() {
	_pulse_cycle_remaining_seconds() {
		local reserve="${1:-0}" now=0
		read -r now <"$CLOCK"
		printf '%s\n' "$((1800 - now - reserve))"
		return 0
	}
	_log_substage_timing() { return 0; }
	return 0
}
_install_fixture_clock_stubs
_dispatch_now_ms() {
	local now=0
	read -r now <"$CLOCK"
	printf '%s\n' "$((now * 1000))"
	return 0
}
check_repo_pulse_schedule() { return 0; }
check_repo_pulse_interval() { return 0; }
update_repo_pulse_timestamp() { return 0; }
pulse_campaign_shadow_candidates_json() {
	local slug="$1"
	printf 'scan:%s\n' "$slug" >>"$EVENTS"
	advance_clock 5
	if [[ "$slug" == "owner/repo1" ]]; then
		printf '[]\n'
	else
		printf '[{"number":42,"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]\n'
	fi
	return 0
}
_dispatch_compute_capacity() { printf '20 1 19\n'; return 0; }
_dispatch_rest_core_progress_allows_next() {
	if _cb_rest_core_priority_decision_allows progress 'reserve 540 5000 750 750 100 9999999999'; then
		return 0
	fi
	return 1
}
_dispatch_stats_increment() { return 0; }
_dispatch_run_prepasses() {
	local slots="$1"
	printf 'ancillary\n' >>"$EVENTS"
	advance_clock 900
	printf '%s 0 0\n' "$slots"
	return 0
}
gh() { printf 'fixture-login\n'; return 0; }
_dispatch_prepare_round() { _dispatch_max_parallel=1; return 0; }
_dispatch_execute_candidate_loop() {
	local candidate_file="$1" candidates="$2"
	[[ -s "$candidate_file" ]] || return 1
	# GH#34331: the first wave fills its 19 free slots from consecutive
	# repositories instead of stopping at the first nonempty one.
	jq -e 'length == 19 and all(.[]; .product_discovery_complete == false)
		and ([.[].repo_slug] | unique | length) == 19' <<<"$candidates" >/dev/null
	printf 'launch\n' >>"$EVENTS"
	printf '{"lease_phase":"prelaunch","dispatched_at":"fixture"}\n' >>"$AIDEVOPS_DISPATCH_LEDGER_FILE"
	dispatched_count=1
	processed_count=1
	return 0
}
_dispatch_maybe_engage_throttle() { return 0; }
apply_dispatch_max() {
	local mode="$1" count=""
	count=$(dispatch_max "$mode")
	[[ "$count" == "1" ]] || return 1
	return 0
}
pulse_rest_core_priority_allows_next() {
	local priority="$1"
	# Exercise the real priority decision with observed quota supplied locally.
	if _cb_rest_core_priority_decision_allows "$priority" 'reserve 540 5000 750 750 100 9999999999'; then
		return 0
	fi
	return 1
}
_preflight_start_merge_first() { return 0; }
# GH#37218: the real launcher selection runs; only process spawning is isolated.
_preflight_launch_async_cleanup() {
	local helper="$1" log_file="$2" cleanup_name="$3"
	: "$helper" "$log_file"
	printf 'async:%s\n' "$cleanup_name" >>"$EVENTS"
	return 0
}
# GH#36026 preflight stage: keep hermetic (no PULSE_DIR stamp, no live rearm helper).
_pulse_rearm_blocker_holds() { return 0; }
calculate_max_workers() { printf 'host-capacity\n' >>"$EVENTS"; return 0; }
calculate_priority_allocations() { printf 'allocation\n' >>"$EVENTS"; advance_clock 900; return 0; }
check_session_count() { printf '0\n'; return 0; }
SESSION_COUNT_WARN=100
_preflight_cleanup_and_ledger() { printf 'cleanup\n' >>"$EVENTS"; advance_clock 900; return 0; }
run_stage_with_timeout() {
	local stage="$1" timeout="$2"
	: "$stage" "$timeout"
	shift 2
	"$@"
	return $?
}
_pulse_run_budget_priority_stage() {
	local stage="$1"
	shift
	_PULSE_BUDGET_STAGE_DEFERRED=0
	[[ "$stage" == preflight_early_dispatch ]] || return 0
	"$@"
	return $?
}
_pulse_run_budget_priority_stage_with_timeout() { return 0; }
_pulse_start_post_dispatch_housekeeping() { return 0; }
_pulse_should_defer_budget_priority_stage() { return 0; }
_pulse_defer_budget_priority_stage() { return 0; }
_PULSE_HEALTH_PREFETCH_THROTTLED=0

scan_events() {
	local first="$1" last="$2" index=0
	for ((index = first; index <= last; index++)); do
		printf 'scan:owner/repo%s;' "$index"
	done
	return 0
}

_run_preflight_stages
actual=$(tr '\n' ';' <"$EVENTS")
# t18911: the steering relay starts with the async cleanups, outside the budget.
async_events='async:worktrees;async:stashes;async:remote-branches;async:worker-bus-relay;'
[[ "$actual" == "${async_events}host-capacity;$(scan_events 1 20)launch;cleanup;host-capacity;" ]] || {
	printf 'FAIL first-wave ordering: %s\n' "$actual" >&2
	exit 1
}
[[ "$(<"${HOME}/.aidevops/cache/pulse-first-wave-cursor")" == owner/repo20 ]]
[[ "$(_pulse_capture_dispatch_total)" == 1 ]]
[[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 0 ]]
[[ "${PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED:-1}" == 1 ]]
[[ "$(<"${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds")" == 2476 ]]
[[ "$(<"${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds-first-wave")" == 300 ]]
printf 'PASS first wave registers dispatch before paced housekeeping; timing/snapshot scope stays isolated\n'

# GH#37218: an early dispatch that spends the whole cycle budget defers the
# budgeted cleanup stage, yet the async cleanup helpers were already started.
(
	printf '0\n' >"$CLOCK"
	: >"$EVENTS"
	# Use the production deferral gate while keeping the fixture clock/timings.
	# shellcheck source=../pulse-watchdog.sh
	source "${SCRIPT_DIR}/pulse-watchdog.sh"
	_install_fixture_clock_stubs
	_preflight_early_dispatch() { printf 'long-dispatch\n' >>"$EVENTS"; advance_clock 1800; return 0; }
	run_stage_with_timeout() {
		local stage="$1" timeout="$2"
		shift 2
		_pulse_stage_cycle_timeout "$stage" "$timeout" >/dev/null || return $?
		"$@"
		return $?
	}
	_run_preflight_stages
	starved=$(tr '\n' ';' <"$EVENTS")
	[[ "$starved" == "${async_events}host-capacity;long-dispatch;" ]] || {
		printf 'FAIL budget-starved cycle skipped async cleanup: %s\n' "$starved" >&2
		exit 1
	}
	grep -qF 'Stage deferred: preflight_cleanup_and_ledger cycle budget exhausted' "$LOGFILE"
)
printf 'PASS async cleanup helpers start even when early dispatch exhausts the cycle budget\n'

# The launch stub above deliberately stops after one attempt. Isolate the
# rotation-only cases below from that retained interrupted-wave remainder.
# shellcheck disable=SC2218 # Production definition is sourced above; later stub is unrelated.
_dispatch_invalidate_candidate_snapshot fixture_reset 1000

# The later global scan remains complete and keeps all repositories eligible.
: >"$EVENTS"
full=$(build_ranked_dispatch_candidates_json 50 normalize)
[[ "$(wc -l <"$EVENTS")" -eq 40 ]]
jq -e 'length == 39 and all(.[]; .product_discovery_complete == true)' <<<"$full" >/dev/null
printf 'PASS normal refill retains full repository discovery and product completeness\n'

# Partial first waves rotate across repositories even when a backlog persists.
# Without a slot target (direct callers) a first wave keeps the GH#33647 scope.
: >"$EVENTS"
rotated=$(_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip)
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo21;' ]]
jq -e 'length == 1 and .[0].repo_slug == "owner/repo21" and .[0].product_discovery_complete == false' <<<"$rotated" >/dev/null
printf 'owner/repo40\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
: >"$EVENTS"
_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip >/dev/null
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo1;scan:owner/repo2;' ]]
printf 'removed/repo\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
: >"$EVENTS"
_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip >/dev/null
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo1;scan:owner/repo2;' ]]
printf 'PASS first-wave cursor rotates, wraps and tolerates removed repositories\n'

# GH#34331: a slot target keeps polling later repositories (wrapping past the
# cursor) until the wave holds enough candidates, then stops and rotates.
printf 'owner/repo39\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
: >"$EVENTS"
filled=$(_PULSE_FIRST_DISPATCH_WAVE=1 _PULSE_FIRST_WAVE_CANDIDATE_TARGET=3 build_ranked_dispatch_candidates_json 50 skip)
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo40;scan:owner/repo1;scan:owner/repo2;scan:owner/repo3;' ]]
jq -e 'length == 3 and ([.[].repo_slug] | sort) == ["owner/repo2","owner/repo3","owner/repo40"]
	and all(.[]; .product_discovery_complete == false)' <<<"$filled" >/dev/null
[[ "$(<"${HOME}/.aidevops/cache/pulse-first-wave-cursor")" == owner/repo3 ]]
printf 'PASS first wave fills its slot target across repositories, then stops and rotates\n'

# GH#34331: the enumeration budget stops an unfilled wave between repositories
# (each simulated scan costs five seconds; the 12s budget allows three).
: >"$EVENTS"
PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=12 _PULSE_FIRST_DISPATCH_WAVE=1 _PULSE_FIRST_WAVE_CANDIDATE_TARGET=19 \
	build_ranked_dispatch_candidates_json 50 skip >/dev/null
[[ "$(tr '\n' ';' <"$EVENTS")" == "$(scan_events 4 6)" ]]
[[ "$(<"${HOME}/.aidevops/cache/pulse-first-wave-cursor")" == owner/repo6 ]]
# A normal (non-first-wave) round ignores the slot target and budget entirely.
: >"$EVENTS"
PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=0 _PULSE_FIRST_WAVE_CANDIDATE_TARGET=1 build_ranked_dispatch_candidates_json 50 normalize >/dev/null
[[ "$(wc -l <"$EVENTS")" -eq 40 ]]
printf 'PASS first-wave enumeration budget bounds an unfilled wave; normal rounds stay unbounded\n'

# A stop flag prevents the first-wave path from invoking dispatch at all.
: >"$STOP_FLAG"
_preflight_early_dispatch
[[ "$(_pulse_capture_dispatch_total)" == 1 ]]
printf 'PASS first wave preserves the stop flag\n'

# A first wave still refuses to enter enumeration without the ceremony reserve.
printf '1500\n' >"$CLOCK"
_PULSE_FIRST_DISPATCH_WAVE=1
if _dispatch_cycle_budget_admits_round fixture before; then
	printf 'FAIL first wave bypassed wall-clock reserve\n' >&2
	exit 1
fi
printf 'PASS first wave preserves the per-candidate ceremony reserve\n'

(
	# GH#37874: an expired fixed cycle is not a dispatch deadline while
	# this wrapper owns a fresh lease. Standalone calls above remain bounded.
	source "${SCRIPT_DIR}/pulse-watchdog.sh"
	source "${SCRIPT_DIR}/pulse-instance-lock.sh"
	LOCKDIR="${TEST_ROOT}/elastic-first-wave"
	mkdir "$LOCKDIR"
	printf '%s\n' "$$" >"${LOCKDIR}/pid"
	printf '1\n' >"${LOCKDIR}/supervisor_heartbeat_epoch"
	_pulse_instance_lock_heartbeat
	PULSE_START_EPOCH=1 PULSE_STALE_THRESHOLD=3600 PULSE_LOCK_MAX_AGE_S=1800
	_PULSE_ELASTIC_DISPATCH=1
	[[ "$(_dispatch_round_budget_plan before)" == 'full 0' ]]
	if _pulse_cycle_remaining_seconds 0; then exit 1; fi
	# A child must never refresh another owner's lease.
	printf '99999999\n' >"${LOCKDIR}/pid"
	if _pulse_instance_lock_heartbeat; then exit 1; fi
	if _pulse_dispatch_lease_active; then exit 1; fi
)
printf 'PASS first-wave dispatch extends only a fresh, matching owner lease\n'

# GH#38022: 70 repositories, twenty product candidates and one blocked tooling
# candidate. An interrupted wave must outlive both floor refill and rollover.
(
	PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
	_PULSE_FIRST_DISPATCH_WAVE=1
	_PULSE_FIRST_WAVE_CANDIDATE_TARGET=21
	PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=3600
	jq -n '{initialized_repos:[range(1;71) | {slug:("owner/repo" + tostring),
		path:"/fixture",pulse:true,priority:(if . == 4 then "product" else "tooling" end)}]}' >"$REPOS_JSON"
	printf '0\n' >"$CLOCK"
	printf 'owner/repo70\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
	pulse_campaign_shadow_candidates_json() {
		local slug="$1"
		printf 'scan:%s\n' "$slug" >>"$EVENTS"
		advance_clock 5
		case "$slug" in
		owner/repo4) jq -nc '[range(1;21) | {number:.,labels:["auto-dispatch","status:available"]}]' ;;
		owner/repo5) printf '[{"number":99,"labels":["auto-dispatch","status:available"]}]\n' ;;
		*) printf '[]\n' ;;
		esac
		return 0
	}
	seed=$(_dispatch_ranked_candidates_json 50 skip)
	jq -e 'length == 21' <<<"$seed" >/dev/null
	partial=$(_dispatch_candidate_snapshot_path 50 skip)
	full=$(_PULSE_FIRST_DISPATCH_WAVE=0 _dispatch_candidate_snapshot_path 50 skip)
	[[ "$partial" != "$full" && ! -f "$full" ]]
	# A blocked attempt is consumed too, even outside the bounded-call scope.
	_PULSE_FIRST_DISPATCH_WAVE=0 _dispatch_ranked_candidate_consumed '{"number":99,"repo_slug":"owner/repo5"}'
	for issue in 1 2 3; do
		_PULSE_FIRST_DISPATCH_WAVE=0 _dispatch_ranked_candidate_consumed "{\"number\":$issue,\"repo_slug\":\"owner/repo4\"}"
	done
	_PULSE_CYCLE_ID="after-cooperative-drain"
	_dispatch_cleanup_cycle_cache 50
	[[ -f "$partial" ]]
	printf 'owner/repo42\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
	: >"$EVENTS"
	remainder=$(_dispatch_bounded_ranked_candidates_json 50 skip 180)
	jq -e 'length == 17 and all(.[]; .repo_slug == "owner/repo4" and .number > 3
		and .product_discovery_complete == false)' <<<"$remainder" >/dev/null
	[[ ! -s "$EVENTS" ]]
	# Once TTL requires re-enumeration, known unattempted product work leads
	# every wave, regardless of the round-robin cursor or a blocked neighbour.
	for cursor in owner/repo42 owner/repo69; do
		printf '%s\n' "$cursor" >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
		: >"$EVENTS"
		_PULSE_FIRST_WAVE_CANDIDATE_TARGET=20 build_ranked_dispatch_candidates_json 50 skip >/dev/null
		[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo4;' ]]
	done
	while IFS= read -r candidate; do
		_dispatch_ranked_candidate_consumed "$candidate"
	done < <(jq -c '.[]' <<<"$remainder")
	[[ -z "$(_dispatch_first_wave_backlog_repos)" ]]
	printf 'owner/repo42\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
	rows=$(_dispatch_repository_rows owner/repo42)
	[[ "${rows%%|*}" == owner/repo43 ]]
	_dispatch_invalidate_candidate_snapshot fixture_complete 50
)
printf 'PASS 70-repository waves retain interrupted product backlog, reuse floor remainder and restore cursor fairness after attempts\n'

# GH#33944: post-label refill must not spend its admission budget normalizing
# the entire blocked backlog before already-available candidates can launch.
rm -f "$STOP_FLAG"
unset _PULSE_FIRST_DISPATCH_WAVE
printf '200\n' >"$CLOCK"
: >"$EVENTS"
_dispatch_invalidate_candidate_snapshot() {
	local reason="$1"
	printf 'invalidate:%s\n' "$reason" >>"$EVENTS"
	return 0
}
apply_dispatch_max() {
	local mode="${1:-normalize}"
	printf 'refill:%s\n' "$mode" >>"$EVENTS"
	[[ "$mode" == skip ]] || return 1
	return 0
}
_preflight_post_label_refill
[[ "$(tr '\n' ';' <"$EVENTS")" == 'invalidate:label_maintenance_complete;refill:skip;' ]]
[[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 0 ]]
printf 'PASS post-label refill invalidates stale candidates and defers backlog normalization without partial first-wave discovery\n'

# GH#36712: run the production round ordering with real recency stamps. Thirty
# blocked urgent candidates must not hide fresh work behind the attempt budget.
# shellcheck source=../pulse-dispatch-lib-candidates.sh
source "${SCRIPT_DIR}/pulse-dispatch-lib-candidates.sh"
_DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=86400
now=$(date +%s)
for ((issue = 1; issue <= 30; issue++)); do
	_dispatch_attempt_recency_stamp "$issue" owner/urgent "$((now - 100 + issue))"
done
# Exercise the real census: urgent retries fill the numerical target in the
# first repository, but must not stop discovery of fresh work in the next one.
jq -n '{initialized_repos:["owner/urgent","owner/small"] | map({slug:.,path:"/fixture",pulse:true})}' >"$REPOS_JSON"
rm -f "${HOME}/.aidevops/cache/pulse-first-wave-cursor"
pulse_campaign_shadow_candidates_json() {
	local slug="$1"
	printf 'scan:%s\n' "$slug" >>"$EVENTS"
	advance_clock 5
	if [[ "$slug" == owner/urgent ]]; then
		jq -nc '[range(1;31) | {number:.,labels:["priority:high","auto-dispatch","status:available"]}]'
	else
		printf '[{"number":100,"labels":["auto-dispatch","status:available"]}]\n'
	fi
	return 0
}
: >"$EVENTS"
backlog=$(_PULSE_FIRST_DISPATCH_WAVE=1 _PULSE_FIRST_WAVE_CANDIDATE_TARGET=6 build_ranked_dispatch_candidates_json 50 skip)
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/urgent;scan:owner/small;' ]]
jq -e 'length == 31 and any(.[]; .repo_slug == "owner/small" and .priority_rank == 0)' <<<"$backlog" >/dev/null
ordered=$(_dispatch_order_round_candidates "$backlog" 6)
jq -e 'length == 31 and .[0].repo_slug == "owner/small"
	and ([.[] | select(.priority_rank == 1) | .number] == [range(1;31)])' <<<"$ordered" >/dev/null
[[ "$(jq -c 'sort_by(.repo_slug, .number)' <<<"$ordered")" == "$(jq -c 'sort_by(.repo_slug, .number)' <<<"$backlog")" ]]
printf 'PASS census discovers fresh rank-0 work beyond thirty urgent retries; fresh work leads shared attempts\n'

# Drive the production serial loop with isolated candidate I/O and a three-
# attempt budget, smaller than one four-attempt sharing slot.
# shellcheck source=../pulse-dispatch-lib.sh
source "${SCRIPT_DIR}/pulse-dispatch-lib.sh"
_DISPATCH_THROTTLE_CLEARED=0
_dispatch_graphql_budget_allows_next() {
	if [[ "$(wc -l <"$EVENTS")" -lt 3 ]]; then return 0; fi
	return 1
}
_dispatch_process_candidate() {
	local candidate="$1" number=""
	number=$(jq -r '.number' <<<"$candidate")
	printf 'attempt:%s\n' "$number" >>"$EVENTS"
	[[ "$number" == 100 ]] || return 1
	return 0
}
jq -c '.[]' <<<"$ordered" >"${TEST_ROOT}/ordered.jsonl"
: >"$EVENTS"
result=$(_dispatch_floor_loop "${TEST_ROOT}/ordered.jsonl" 6 6 fixture-login)
[[ "$result" == '1 4' ]]
[[ "$(tr '\n' ';' <"$EVENTS")" == 'attempt:100;attempt:1;attempt:2;' ]]
printf 'PASS first-wave serial dispatch attempts fresh work with only three attempts available\n'

# Fresh urgent work still strictly leads, including across urgent tiers. More
# fresh ordinary work receives one in four attempts after that urgent prefix.
mixed=$(jq -c '. + [range(101;105) | {number:., repo_slug:"owner/small", priority_rank:0}]
	+ [{number:200, repo_slug:"owner/high", priority_rank:1},
	   {number:201, repo_slug:"owner/critical", priority_rank:2}]' <<<"$backlog")
ordered=$(_dispatch_order_round_candidates "$mixed" 20)
jq -e '[.[0:2][].number] == [201,200]
	and ([.[2:22][] | select(.priority_rank == 0) | .number] == [100,101,102,103,104])
	and ([.[2:6][].number] == [100,1,2,3])' <<<"$ordered" >/dev/null
printf 'PASS fresh urgent tiers lead strictly, then fresh rank-0 work gets a quarter of attempts\n'

# Debt fairness is an intentional outer policy, not a recency exemption.
debt=$(jq -c 'map(if .number == 1 or .number == 100 then
	.labels = ["quality-debt","source:review-feedback"] else . end)' <<<"$backlog")
ordered=$(QUALITY_DEBT_CAP_PCT=30 _dispatch_order_round_candidates "$debt" 6)
jq -e '.[0].number == 100 and .[-1].number == 1
	and ([.[0:6][] | select((.labels // [] | index("quality-debt")) != null)] | length) == 1' <<<"$ordered" >/dev/null
debt=$(jq -c '. + [{number:200,repo_slug:"owner/high",priority_rank:1,
	labels:["quality-debt","source:review-feedback"]}]' <<<"$debt")
ordered=$(QUALITY_DEBT_CAP_PCT=30 _dispatch_order_round_candidates "$debt" 6)
jq -e '.[0].number == 200 and .[-2].number == 100 and .[-1].number == 1
	and ([.[0:6][] | select((.labels // [] | index("quality-debt")) != null)] | length) == 1' <<<"$ordered" >/dev/null
printf 'PASS debt cap still governs fresh rank-0 review debt after recency sharing\n'

# Preserve soft-state behavior: attempted ordinary work remains behind fresh
# ordinary work, confirmed launch clears a stamp, expiry and disable fail open.
_dispatch_attempt_recency_stamp 100 owner/small "$((now - 20))"
ordered=$(_dispatch_order_round_candidates "$mixed" 20)
jq -e '.[2].number == 101 and .[-1].number == 100' <<<"$ordered" >/dev/null
_dispatch_attempt_recency_clear 100 owner/small
_dispatch_attempt_recency_clear 1 owner/urgent
ordered=$(_dispatch_order_round_candidates "$backlog" 6)
jq -e '.[0].number == 1 and .[1].number == 100' <<<"$ordered" >/dev/null
[[ "$(_DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=0 _dispatch_order_round_candidates "$backlog" 6)" == "$backlog" ]]
[[ "$(_DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=1 _dispatch_order_round_candidates "$backlog" 6)" == "$backlog" ]]
printf 'PASS ordinary retries, launch clearing, disabled rotation and expired stamps preserve recency semantics\n'
