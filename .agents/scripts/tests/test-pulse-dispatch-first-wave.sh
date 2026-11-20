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
jq -n '{initialized_repos:[range(1;41) | {slug:("owner/repo" + tostring),path:"/tmp",pulse:true}]}' >"$REPOS_JSON"

# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=../pulse-wrapper-cycle-gates.sh
source "${SCRIPT_DIR}/pulse-wrapper-cycle-gates.sh"
# Cases below share one simulated clock file that concurrent scans cannot
# advance consistently, so they pin the serial census; the GH#38730 case
# exercises bounded-parallel full censuses in real time.
PULSE_CENSUS_MAX_PARALLEL=1

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
# GH#38098 native macOS verification is Darwin-only; keep event order host-independent.
_preflight_start_macos_verification() { return 0; }
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

# A global scan that fits its budget keeps all repositories eligible.
: >"$EVENTS"
full=$(PULSE_CENSUS_ENUMERATION_BUDGET_S=300 build_ranked_dispatch_candidates_json 50 normalize)
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
# A normal round ignores the first-wave target, but has its own census budget.
: >"$EVENTS"
PULSE_CENSUS_ENUMERATION_BUDGET_S=300 PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=0 _PULSE_FIRST_WAVE_CANDIDATE_TARGET=1 build_ranked_dispatch_candidates_json 50 normalize >/dev/null
[[ "$(wc -l <"$EVENTS")" -eq 40 ]]
printf 'PASS first-wave target is isolated from normal census bounds\n'

# GH#38226: even an all-empty census stops at its deadline, and the next
# census resumes after the last polled repository rather than repeating it.
(
	pulse_campaign_shadow_candidates_json() {
		local slug="$1"
		printf 'scan:%s\n' "$slug" >>"$EVENTS"
		advance_clock 5
		printf '[]\n'
		return 0
	}
	printf 'owner/repo40\n' >"${HOME}/.aidevops/cache/pulse-census-cursor"
	: >"$EVENTS"
	PULSE_CENSUS_ENUMERATION_BUDGET_S=10 build_ranked_dispatch_candidates_json 50 skip >/dev/null
	[[ "$(tr '\n' ';' <"$EVENTS")" == "$(scan_events 1 2)" ]]
	: >"$EVENTS"
	PULSE_CENSUS_ENUMERATION_BUDGET_S=10 build_ranked_dispatch_candidates_json 50 skip >/dev/null
	[[ "$(tr '\n' ';' <"$EVENTS")" == "$(scan_events 3 4)" ]]
	# Exercise actual process-tree timeout, not a simulated deadline. The
	# child must not retain stdout or write its delayed completion marker.
	pulse_campaign_shadow_candidates_json() {
		sleep 3
		printf 'leaked\n' >>"$EVENTS"
		return 0
	}
	: >"$EVENTS"
	rc=0
	_dispatch_enumerate_repo_bounded 1 owner/repo /fixture 50 skip "" >/dev/null || rc=$?
	[[ "$rc" == 124 && ! -s "$EVENTS" ]]
	pulse_campaign_shadow_candidates_json() {
		sleep 3 &
		return 0
	}
	rc=0
	_dispatch_enumerate_repo_bounded 1 owner/repo /fixture 50 skip "" >/dev/null || rc=$?
	[[ "$rc" == 124 ]]
)
printf 'PASS empty censuses rotate at the total deadline and repository timeout drains descendants\n'

# GH#38274: a timed-out repository escalates to the cap for the next census;
# a completed scan decays to 1.5x its cost and the base clears the override.
(
	budget_file=$(_dispatch_repo_enumeration_budget_file owner/big)
	[[ "$(_dispatch_repo_enumeration_budget owner/big 15)" == 15 ]]
	_dispatch_record_repo_enumeration_outcome owner/big 15 15 124 15
	[[ "$(_dispatch_repo_enumeration_budget owner/big 15)" == 60 ]]
	grep -q 'enumeration budget raised: repo=owner/big from=15s to=60s' "$LOGFILE"
	# Other failures leave the stored budget unchanged.
	_dispatch_record_repo_enumeration_outcome owner/big 15 60 1 2
	[[ "$(_dispatch_repo_enumeration_budget owner/big 15)" == 60 ]]
	# GH#38483: a timeout clamped below the base is no evidence of slowness.
	_dispatch_record_repo_enumeration_outcome owner/clamped 15 3 124 3
	[[ ! -e "$(_dispatch_repo_enumeration_budget_file owner/clamped)" ]]
	if grep -q 'budget raised: repo=owner/clamped' "$LOGFILE"; then exit 1; fi
	_dispatch_record_repo_enumeration_outcome owner/big 15 60 0 32
	[[ "$(_dispatch_repo_enumeration_budget owner/big 15)" == 48 ]]
	PULSE_REPO_ENUMERATION_BUDGET_MAX_S=40
	[[ "$(_dispatch_repo_enumeration_budget owner/big 15)" == 40 ]]
	unset PULSE_REPO_ENUMERATION_BUDGET_MAX_S
	_dispatch_record_repo_enumeration_outcome owner/big 15 48 0 6
	[[ ! -e "$budget_file" && "$(_dispatch_repo_enumeration_budget owner/big 15)" == 15 ]]
	# The census grants the escalated budget to that repository only.
	printf '60\n' >"$budget_file"
	_dispatch_enumerate_repo_bounded() {
		printf 'budget:%s:%s\n' "$2" "$1" >>"$EVENTS"
		printf '[]\n'
		return 0
	}
	jq -n '{initialized_repos:[{slug:"owner/big",path:"/tmp",pulse:true},{slug:"owner/small",path:"/tmp",pulse:true}]}' >"$REPOS_JSON"
	rm -f "${HOME}/.aidevops/cache/pulse-census-cursor"
	: >"$EVENTS"
	PULSE_CENSUS_ENUMERATION_BUDGET_S=300 build_ranked_dispatch_candidates_json 50 skip >/dev/null || true
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'budget:owner/big:60;budget:owner/small:15;' ]]
)
printf 'PASS slow repositories get an adaptive per-repository census budget\n'

# GH#38543: a repository whose scans sit at the cap escalates above it after a
# timeout at the cap, keeps that budget through clamped timeouts and near-cap
# completions, and decays back under the cap once its scans are faster.
(
	budget_file=$(_dispatch_repo_enumeration_budget_file owner/slow)
	mkdir -p "${budget_file%/*}"
	printf '60\n' >"$budget_file"
	_dispatch_record_repo_enumeration_outcome owner/slow 15 60 124 60
	[[ "$(_dispatch_repo_enumeration_budget owner/slow 15)" == 120 && "$(<"$budget_file")" == '120 escalated' ]]
	grep -q 'budget raised: repo=owner/slow from=60s to=120s reason=timeout_at_cap' "$LOGFILE"
	# A timeout clamped by the census remainder never lowers it.
	_dispatch_record_repo_enumeration_outcome owner/slow 15 50 124 50
	[[ "$(_dispatch_repo_enumeration_budget owner/slow 15)" == 120 ]]
	# A completion under the escalated budget keeps 1.5x its cost above the cap.
	_dispatch_record_repo_enumeration_outcome owner/slow 15 120 0 75
	[[ "$(<"$budget_file")" == '113 escalated' ]]
	_dispatch_record_repo_enumeration_outcome owner/slow 15 113 0 30
	[[ "$(<"$budget_file")" == 45 && "$(_dispatch_repo_enumeration_budget owner/slow 15)" == 45 ]]
	# A completion within 5s of the cap escalates; an ordinary one stays capped.
	printf '60\n' >"$budget_file"
	_dispatch_record_repo_enumeration_outcome owner/slow 15 60 0 58
	[[ "$(_dispatch_repo_enumeration_budget owner/slow 15)" == 87 ]]
	printf '60\n' >"$budget_file"
	_dispatch_record_repo_enumeration_outcome owner/slow 15 60 0 45
	[[ "$(<"$budget_file")" == 60 ]]
	# A ceiling at or below the cap disables escalation.
	PULSE_REPO_ENUMERATION_BUDGET_ESCALATED_MAX_S=60 _dispatch_record_repo_enumeration_outcome owner/slow 15 60 124 60
	[[ "$(<"$budget_file")" == 60 ]]
	# GH#38548: a real capped timeout halves source work, not just raises time.
	# A census-remainder timeout must not lower that limit again.
	pulse_campaign_shadow_candidates_json() {
		local limit="$3" completeness="$5"
		if ((limit > 25)); then sleep 2; fi
		[[ -z "$completeness" ]] || printf '1\n' >"$completeness"
		printf '[{"number":9,"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]\n'
		return 0
	}
	export PULSE_REPO_ENUMERATION_BUDGET_MAX_S=1 PULSE_REPO_ENUMERATION_BUDGET_ESCALATED_MAX_S=4
	sleepy_file=$(_dispatch_repo_enumeration_budget_file owner/sleepy)
	limit_file=$(_dispatch_repo_enumeration_limit_file owner/sleepy)
	rc=0
	_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null || rc=$?
	[[ "$rc" == 124 && "$(<"$sleepy_file")" == '4 escalated' ]]
	[[ "$(<"$limit_file")" == 25 ]]
	# Census admission sees the same normal cap as the reduced-work scan.
	[[ "$(_dispatch_repo_enumeration_budget owner/sleepy 1)" == 1 ]]
	rc=0
	clamped=$(
		_dispatch_enumerate_repo_bounded() { return 124; }
		_dispatch_census_enumerate_repo owner/sleepy /tmp 1 0 50 skip ""
	) || rc=$?
	[[ "$rc" == 124 && "$clamped" == '[]' && "$(<"$sleepy_file")" == '4 escalated' ]]
	[[ "$(<"$limit_file")" == 25 ]]
	grep -q 'enumeration unavailable: repo=owner/sleepy rc=124 budget=1s' "$LOGFILE"
	completeness_file="${TEST_ROOT}/reduced-completeness"
	recovered=$(_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "$completeness_file")
	jq -e 'length == 1 and .[0].number == 9' <<<"$recovered" >/dev/null
	[[ "$(<"$completeness_file")" == 0 && "$(<"$limit_file")" == '25 1' ]]
	[[ "$(_dispatch_repo_enumeration_limit owner/other 50)" == 50 ]]
	[[ "$(_dispatch_repo_enumeration_limit owner/sleepy 10)" == 10 ]]
	# Seven more completed reduced scans permit a larger, still-capped probe.
	for scan in 2 3 4 5 6 7 8; do
		_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null
	done
	[[ "$(<"$limit_file")" == '50 0' ]]
	[[ "$(_dispatch_repo_enumeration_budget owner/sleepy 1)" == 1 ]]
	rc=0
	_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null || rc=$?
	[[ "$rc" == 124 && "$(<"$limit_file")" == 25 ]]
	# Reduced scans cannot use the old above-cap budget. GH#38690: a full-cap
	# timeout at the floor (max(limit/8, 25)) retains the snapshot.
	_dispatch_enumerate_repo_bounded() {
		printf '%s:%s\n' "$1" "$4" >>"$EVENTS"
		return 124
	}
	printf '4 escalated\n' >"$sleepy_file"
	: >"$EVENTS"
	_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null || true
	[[ "$(<"$EVENTS")" == '1:25' && "$(<"$limit_file")" == '25 0 retained' ]]
	grep -q 'limit retained: repo=owner/sleepy limit=25 floor=25 reason=at_floor (GH#38690)' "$LOGFILE"
	# A retained snapshot is not newly reduced work: its budget may escalate.
	[[ "$(_dispatch_repo_enumeration_budget owner/sleepy 1)" == 4 ]]
	[[ "$(_dispatch_repo_enumeration_limit_floor 400)" == 50 && "$(_dispatch_repo_enumeration_limit_floor 10)" == 10 ]]
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 400 400
	[[ "$(<"$limit_file")" == 200 ]]
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 60 400
	[[ "$(<"$limit_file")" == 50 ]]
	grep -q 'limit reduced: repo=owner/sleepy from=60 to=50 reason=timeout_at_cap (GH#38548)' "$LOGFILE"
	PULSE_REPO_ENUMERATION_LIMIT_FLOOR=1 _dispatch_reduce_repo_enumeration_limit owner/sleepy 2 2
	[[ "$(<"$limit_file")" == 1 ]]
	# A limit collapsed before the floor existed scans at the floor and
	# recovers from it.
	printf '2 0\n' >"$limit_file"
	[[ "$(_dispatch_repo_enumeration_limit owner/sleepy 50)" == 25 ]]
	_dispatch_enumerate_repo_bounded() {
		printf '%s:%s\n' "$1" "$4" >>"$EVENTS"
		printf '[{"number":9}]\n'
		return 0
	}
	: >"$EVENTS"
	_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null
	[[ "$(<"$EVENTS")" == '1:25' && "$(<"$limit_file")" == '25 1' ]]
	# A completed reduced scan with no candidates exhausted its prefix and
	# probes a larger snapshot immediately.
	_dispatch_enumerate_repo_bounded() {
		printf '[]\n'
		return 0
	}
	_dispatch_census_enumerate_repo owner/sleepy /tmp 1 100 50 skip "" >/dev/null
	[[ "$(<"$limit_file")" == '50 0' ]]
	grep -q 'limit probed: repo=owner/sleepy from=25 to=50 reason=empty_prefix (GH#38690)' "$LOGFILE"
	# Completed scans record cost per limit. A timeout keeps the snapshot when
	# a completed scan at that limit or larger shows it is not size-driven.
	cost_file=$(_dispatch_repo_enumeration_cost_file owner/sleepy)
	now=$(_dispatch_first_wave_now_s)
	[[ "$(head -n 1 "$cost_file")" == "25 0 ${now}" ]]
	# Fixed cost: 200 took 16s and half of it took 15s; a 20s budget expired.
	printf '200 16 %s\n100 15 %s\n' "$now" "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 20
	[[ "$(<"$limit_file")" == '200 0 retained' ]]
	grep -q 'limit retained: repo=owner/sleepy limit=200 floor=50 reason=fixed_cost (GH#38690)' "$LOGFILE"
	# Variance: the same snapshot completed in 10s, far inside a 60s budget.
	printf '200 10 %s\n' "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 60
	[[ "$(<"$limit_file")" == '200 0 retained' ]]
	# Flat cost below the timed-out limit does not block its reduction.
	printf '100 16 %s\n50 15 %s\n' "$now" "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 60
	[[ "$(<"$limit_file")" == 100 ]]
	# Proportional, unmeasurably small or stale costs still halve.
	printf '200 16 %s\n100 6 %s\n' "$now" "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 20
	[[ "$(<"$limit_file")" == 100 ]]
	printf '200 3 %s\n100 3 %s\n' "$now" "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 4
	[[ "$(<"$limit_file")" == 100 ]]
	printf '200 16 %s\n100 15 %s\n' "$now" "$now" >"$cost_file"
	printf '200\n' >"$limit_file"
	advance_clock 90000
	_dispatch_reduce_repo_enumeration_limit owner/sleepy 200 400 20
	[[ "$(<"$limit_file")" == 100 ]]
	printf '%s\n' "$now" >"$CLOCK"
	# Recording keeps one sample per limit, newest first, four limits at most.
	_dispatch_record_repo_enumeration_cost owner/sleepy 25 4
	_dispatch_record_repo_enumeration_cost owner/sleepy 12 3
	_dispatch_record_repo_enumeration_cost owner/sleepy 25 5
	[[ "$(awk '{print $1 ":" $2}' "$cost_file" | tr '\n' ';')" == '25:5;12:3;200:16;100:15;' ]]
	# A completed scan at a retained limit keeps the marker; a probe clears it.
	printf '25 6 retained\n' >"$limit_file"
	_dispatch_recover_repo_enumeration_limit owner/sleepy 25 50 3
	[[ "$(<"$limit_file")" == '25 7 retained' ]]
	_dispatch_recover_repo_enumeration_limit owner/sleepy 25 50 3
	[[ "$(<"$limit_file")" == '50 0' ]]
	printf 'malformed\n' >"$limit_file"
	[[ "$(_dispatch_repo_enumeration_limit owner/sleepy 50)" == 50 ]]
)
printf 'PASS capped timeouts reduce repository work and recover candidates (GH#38543, GH#38548, GH#38690)\n'

# GH#38483: a known-slow repository the census cannot afford is deferred, not
# scanned with a clamped budget; it leads the next census with its full budget.
# The first repository of a census is never deferred. A timed-out scan reuses
# the repository's fresh last-good candidates; other failures and expired
# lists stay empty.
(
	jq -n '{initialized_repos:[{slug:"owner/small1",path:"/tmp",pulse:true},{slug:"owner/big",path:"/tmp",pulse:true},{slug:"owner/small2",path:"/tmp",pulse:true}]}' >"$REPOS_JSON"
	budget_file=$(_dispatch_repo_enumeration_budget_file owner/big)
	mkdir -p "${budget_file%/*}"
	printf '60\n' >"$budget_file"
	big_rc_file="${TEST_ROOT}/big-rc"
	printf '0\n' >"$big_rc_file"
	_dispatch_enumerate_repo_bounded() {
		local big_rc=0
		printf 'budget:%s:%s\n' "$2" "$1" >>"$EVENTS"
		if [[ "$2" == owner/big ]]; then
			advance_clock 30
			read -r big_rc <"$big_rc_file"
			((big_rc == 0)) || return "$big_rc"
			printf '[{"number":7,"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]\n'
			return 0
		fi
		advance_clock 5
		printf '[]\n'
		return 0
	}
	rm -f "${HOME}/.aidevops/cache/pulse-census-cursor"
	: >"$EVENTS"
	PULSE_CENSUS_ENUMERATION_BUDGET_S=50 build_ranked_dispatch_candidates_json 50 skip >/dev/null || true
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'budget:owner/small1:15;' ]]
	grep -q 'deferred slow repository to the next census: repo=owner/big budget=60s remaining=45s (GH#38483)' "$LOGFILE"
	[[ "$(<"${HOME}/.aidevops/cache/pulse-census-cursor")" == owner/small1 ]]
	: >"$EVENTS"
	led=$(PULSE_CENSUS_ENUMERATION_BUDGET_S=70 build_ranked_dispatch_candidates_json 50 skip)
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'budget:owner/big:60;budget:owner/small2:15;budget:owner/small1:15;' ]]
	jq -e 'length == 1 and .[0].repo_slug == "owner/big" and .[0].number == 7' <<<"$led" >/dev/null
	# Only full censuses defer: first waves order leads ahead of the cursor.
	admit_rc=0
	_dispatch_census_admit_repo owner/big tooling "" "" "" "" 15 10 1 || admit_rc=$?
	[[ "$admit_rc" == 3 ]]
	_PULSE_FIRST_DISPATCH_WAVE=1 _dispatch_census_admit_repo owner/big tooling "" "" "" "" 15 10 1
	# The first repository is scanned even when its learned budget (45s after
	# the 30s completion) exceeds the whole census budget.
	: >"$EVENTS"
	PULSE_CENSUS_ENUMERATION_BUDGET_S=20 build_ranked_dispatch_candidates_json 50 skip >/dev/null || true
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'budget:owner/big:20;' ]]
	# A timeout reuses the last completed list and still reports the failure.
	printf '124\n' >"$big_rc_file"
	rc=0
	reused=$(_dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "") || rc=$?
	[[ "$rc" == 124 ]]
	jq -e 'length == 1 and .[0].number == 7' <<<"$reused" >/dev/null
	grep -q 'reused last-good candidates: repo=owner/big count=1 filtered=0 age=30s (GH#38483)' "$LOGFILE"
	# GH#39517: an issue launched after the list was stored is not re-offered.
	(
		AIDEVOPS_DISPATCH_LEDGER_FILE="${TEST_ROOT}/reuse-ledger.jsonl"
		jq -nc --argjson at "$(($(_dispatch_first_wave_now_s) + 1))" \
			'{repo_slug:"owner/big",issue_number:"7",dispatched_at:($at | todate)}' >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
		launched=$(_dispatch_census_last_good_candidates owner/big)
		[[ "$launched" == '[]' ]]
		grep -q 'reused last-good candidates: repo=owner/big count=0 filtered=1 age=30s (GH#38483)' "$LOGFILE"
	)
	# The PR-backlog guardrail is reapplied to the reused list.
	(
		_dispatch_filter_repo_pr_backlog_candidates() { printf '[]\n'; return 0; }
		capped=$(_dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "") || true
		[[ "$capped" == '[]' ]]
	)
	# A timeout keeps the stored list; a non-timeout failure never reuses it.
	printf '1\n' >"$big_rc_file"
	rc=0
	failed=$(_dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "") || rc=$?
	[[ "$rc" == 1 && "$failed" == '[]' ]]
	printf '124\n' >"$big_rc_file"
	advance_clock 3600
	rc=0
	expired=$(_dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "") || rc=$?
	[[ "$rc" == 124 && "$expired" == '[]' ]]
	# 0 disables reuse even for a fresh list.
	rm -f "$budget_file"
	printf '0\n' >"$big_rc_file"
	_dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "" >/dev/null
	printf '124\n' >"$big_rc_file"
	disabled=$(PULSE_CENSUS_LAST_GOOD_MAX_AGE_S=0 _dispatch_census_enumerate_repo owner/big /tmp 15 60 50 skip "") || true
	[[ "$disabled" == '[]' ]]
)
printf 'PASS slow repositories defer instead of clamped scans; timeouts reuse fresh last-good candidates\n'

# GH#38727: a full census stopped by its deadline or a slow-repository deferral
# offers unreached repositories' fresh last-good candidates without polling or
# stamping them. Issues launched after the snapshot, expired lists, a disabled
# max age and first waves carry nothing; product discovery stays incomplete.
(
	registry=$(<"$REPOS_JSON")
	jq -n '{initialized_repos:[{slug:"owner/a",path:"/tmp",pulse:true},{slug:"owner/b",path:"/tmp",pulse:true},{slug:"owner/c",path:"/tmp",pulse:true}]}' >"$REPOS_JSON"
	AIDEVOPS_DISPATCH_LEDGER_FILE="${TEST_ROOT}/carry-ledger.jsonl"
	update_repo_pulse_timestamp() { printf 'stamp:%s\n' "$1" >>"$EVENTS"; return 0; }
	_dispatch_enumerate_repo_bounded() {
		printf 'scan:%s\n' "$2" >>"$EVENTS"
		advance_clock 10
		printf '[]\n'
		return 0
	}
	advance_clock 5000
	now=$(_dispatch_first_wave_now_s)
	_dispatch_census_store_last_good owner/b '[{"number":5,"labels":[{"name":"auto-dispatch"}]},{"number":6,"labels":[{"name":"auto-dispatch"}]}]'
	jq -nc --argjson at "$((now - 4000))" '{stored_at:$at,candidates:[{number:9,labels:[]}]}' >"$(_dispatch_census_last_good_file owner/c)"
	# #6 launched after the snapshot was stored; #5 only before it.
	{
		jq -nc --argjson at "$((now + 1))" '{repo_slug:"owner/b",issue_number:"6",dispatched_at:($at | todate)}'
		jq -nc --argjson at "$((now - 100))" '{repo_slug:"owner/b",issue_number:"5",dispatched_at:($at | todate)}'
		printf 'not-json\n'
	} >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
	census_cursor="${HOME}/.aidevops/cache/pulse-census-cursor"
	rm -f "$census_cursor"
	: >"$EVENTS"
	carried=$(PULSE_CENSUS_ENUMERATION_BUDGET_S=5 build_ranked_dispatch_candidates_json 50 skip)
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'stamp:owner/a;scan:owner/a;' ]]
	jq -e 'length == 1 and .[0].repo_slug == "owner/b" and .[0].number == 5
		and .[0].product_discovery_complete == false' <<<"$carried" >/dev/null
	grep -q 'carried last-good candidates: repos=1 count=1 from=owner/b (GH#38727)' "$LOGFILE"
	[[ "$(<"$census_cursor")" == owner/a ]]
	# A deferred slow repository is carried, not scanned with a clamped budget.
	budget_file=$(_dispatch_repo_enumeration_budget_file owner/b)
	mkdir -p "${budget_file%/*}"
	printf '60\n' >"$budget_file"
	rm -f "$census_cursor"
	: >"$EVENTS"
	deferred=$(PULSE_CENSUS_ENUMERATION_BUDGET_S=50 build_ranked_dispatch_candidates_json 50 skip)
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'stamp:owner/a;scan:owner/a;' ]]
	jq -e 'length == 1 and .[0].number == 5 and .[0].product_discovery_complete == false' <<<"$deferred" >/dev/null
	[[ "$(grep -c 'carried last-good candidates: repos=1 count=1 from=owner/b (GH#38727)' "$LOGFILE")" == 2 ]]
	# 0 disables carrying, as it disables timeout reuse.
	rm -f "$census_cursor"
	disabled=$(PULSE_CENSUS_LAST_GOOD_MAX_AGE_S=0 PULSE_CENSUS_ENUMERATION_BUDGET_S=50 build_ranked_dispatch_candidates_json 50 skip)
	[[ "$disabled" == '[]' ]]
	# First waves keep their own bounds and never carry.
	rm -f "$budget_file"
	carries=$(grep -c '(GH#38727)' "$LOGFILE" || true)
	first=$(_PULSE_FIRST_DISPATCH_WAVE=1 PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=5 build_ranked_dispatch_candidates_json 50 skip)
	[[ "$first" == '[]' ]]
	[[ "$(grep -c '(GH#38727)' "$LOGFILE")" == "$carries" ]]
	printf '%s\n' "$registry" >"$REPOS_JSON"
)
printf 'PASS stopped censuses carry fresh last-good candidates of unreached repositories without polling them (GH#38727)\n'

# GH#38730: a full census overlaps up to PULSE_CENSUS_MAX_PARALLEL scans in
# real time, absorbs every scan in launch order (same ranking as the serial
# census), keeps scan-failure and product-completeness semantics, clamps
# every scan to the census deadline, and drains real timed-out scans.
(
	registry=$(<"$REPOS_JSON")
	jq -n '{initialized_repos:[range(1;9) | {slug:("owner/p" + tostring),path:"/tmp",pulse:true,
		priority:(if . == 3 then "product" else "tooling" end)}]}' >"$REPOS_JSON"
	_dispatch_now_ms() { printf '%s\n' "$(($(date +%s) * 1000))"; return 0; }
	# Real process-group timeouts drain under concurrency: eight 3s adapters
	# with a 1s budget, four at a time. Separate HOME: the timeouts escalate
	# per-repository budgets that the cases below must not inherit.
	(
		HOME="${TEST_ROOT}/parallel-drain-home"
		pulse_campaign_shadow_candidates_json() {
			sleep 3
			printf 'leaked\n' >>"$EVENTS"
			return 0
		}
		: >"$EVENTS"
		started=$SECONDS
		rc=0
		drained=$(PULSE_CENSUS_MAX_PARALLEL=4 PULSE_REPO_ENUMERATION_BUDGET_S=1 \
			build_ranked_dispatch_candidates_json 50 skip) || rc=$?
		elapsed=$((SECONDS - started))
		[[ "$rc" == 1 && "$drained" == '[]' && ! -s "$EVENTS" ]]
		((elapsed <= 5)) || { printf 'FAIL timed-out parallel census took %ss\n' "$elapsed" >&2; exit 1; }
	)
	_dispatch_enumerate_repo_bounded() {
		local slug="$2" completeness="$6" n="${2#owner/p}"
		printf 'scan:%s:%s\n' "$slug" "$1" >>"$EVENTS"
		sleep "${SCAN_SECONDS:-1}"
		[[ "$slug" != owner/p5 ]] || return 1
		[[ -z "$completeness" ]] || printf '1\n' >"$completeness"
		printf '[{"number":%s,"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}]\n' "$n"
		return 0
	}
	census_cursor="${HOME}/.aidevops/cache/pulse-census-cursor"
	rm -f "$census_cursor"
	: >"$EVENTS"
	started=$SECONDS
	parallel=$(PULSE_CENSUS_MAX_PARALLEL=4 PULSE_CENSUS_ENUMERATION_BUDGET_S=60 build_ranked_dispatch_candidates_json 50 skip)
	elapsed=$((SECONDS - started))
	# Eight one-second scans: serial takes 8s; four at a time about 2-3s.
	((elapsed <= 5)) || { printf 'FAIL parallel census took %ss\n' "$elapsed" >&2; exit 1; }
	[[ "$(wc -l <"$EVENTS")" -eq 8 && "$(<"$census_cursor")" == owner/p8 ]]
	jq -e 'length == 7 and ([.[].repo_slug] | index("owner/p5")) == null
		and all(.[]; .product_discovery_complete == true)' <<<"$parallel" >/dev/null
	grep -q 'Candidate census parallel scans: repos=8 max_parallel=4 (GH#38730)' "$LOGFILE"
	rm -f "$census_cursor"
	serial=$(SCAN_SECONDS=0 PULSE_CENSUS_MAX_PARALLEL=1 PULSE_CENSUS_ENUMERATION_BUDGET_S=60 \
		build_ranked_dispatch_candidates_json 50 skip)
	[[ "$serial" == "$parallel" ]] || { printf 'FAIL parallel ranking differs from serial\n' >&2; exit 1; }
	# An incomplete product scan still marks product discovery incomplete.
	rm -f "$census_cursor"
	incomplete=$(
		_dispatch_enumerate_repo_bounded() {
			printf '[{"number":%s,"labels":[{"name":"auto-dispatch"}]}]\n' "${2#owner/p}"
			return 0
		}
		PULSE_CENSUS_MAX_PARALLEL=4 build_ranked_dispatch_candidates_json 50 skip
	)
	jq -e 'length == 8 and all(.[]; .product_discovery_complete == false)' <<<"$incomplete" >/dev/null
	# Scans that use their whole budget never outlive the census deadline:
	# each launch waits for a slot, then is clamped to the remainder, and the
	# census stops at the deadline before reaching the tail.
	_dispatch_enumerate_repo_bounded() {
		printf 'scan:%s:%s\n' "$2" "$1" >>"$EVENTS"
		sleep "$1"
		printf '[]\n'
		return 0
	}
	rm -f "$census_cursor"
	: >"$EVENTS"
	started=$SECONDS
	PULSE_CENSUS_MAX_PARALLEL=2 PULSE_CENSUS_ENUMERATION_BUDGET_S=2 build_ranked_dispatch_candidates_json 50 skip >/dev/null || true
	elapsed=$((SECONDS - started))
	((elapsed <= 4)) || { printf 'FAIL clamped parallel census took %ss\n' "$elapsed" >&2; exit 1; }
	awk -F: '$3 > 2 { exit 1 }' "$EVENTS"
	if grep -q 'scan:owner/p8:' "$EVENTS"; then exit 1; fi
	grep -q 'Candidate census deadline reached' "$LOGFILE"
	printf '%s\n' "$registry" >"$REPOS_JSON"
)
printf 'PASS full censuses overlap bounded scans, absorb them in launch order and stay clamped to the deadline (GH#38730)\n'

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
		path:"/tmp",pulse:true,priority:(if . == 4 then "product" else "tooling" end)}]}' >"$REPOS_JSON"
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

# GH#38200: the product backlog of a census-fresh first-wave snapshot is fully
# attempted and the cursor is past the product repository. Fifteen issues that
# arrived after the census last polled it are visible only in the prefetch
# cache. They must lead the next first wave without any API read, and a short
# remainder elsewhere must not hide them for a census-length window.
(
	PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
	_PULSE_FIRST_DISPATCH_WAVE=1
	PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S=3600
	PULSE_PREFETCH_CACHE_FILE="${TEST_ROOT}/prefetch-cache.json"
	PULSE_LAST_PER_REPO_FILE="${TEST_ROOT}/last-per-repo.json"
	stats="${TEST_ROOT}/arrival-stats"
	: >"$stats"
	_dispatch_stats_increment() { printf '%s\n' "$1" >>"$stats"; return 0; }
	jq -n '{initialized_repos:[range(1;71) | {slug:("owner/repo" + tostring),
		path:"/tmp",pulse:true,priority:(if . == 4 then "product" else "tooling" end)}]}' >"$REPOS_JSON"
	pulse_campaign_shadow_candidates_json() {
		local slug="$1"
		printf 'scan:%s\n' "$slug" >>"$EVENTS"
		advance_clock 5
		case "$slug" in
		owner/repo4) jq -nc '[range(21;36) | {number:.,labels:["auto-dispatch","status:available"]}]' ;;
		*) printf '[]\n' ;;
		esac
		return 0
	}
	now=$(date +%s)
	launchable='[{name:"auto-dispatch"},{name:"status:available"}]'
	# repo4: 20 launched (assigned) plus 15 arrivals. repo30: nothing
	# launchable. repo40: stale prefetch. repo50: census polled after the
	# prefetch. repo55: arrival already attempted on this runner.
	jq -n --argjson now "$now" "($launchable) as \$ok | (\$now | todate) as \$at | {
		\"owner/repo4\": {last_prefetch:\$at, issues:(
			[range(1;21) | {number:., state:\"OPEN\", labels:[{name:\"auto-dispatch\"},{name:\"status:queued\"}], assignees:[{login:\"runner\"}]}] +
			[range(21;36) | {number:., state:\"OPEN\", labels:\$ok, assignees:[]}])},
		\"owner/repo30\": {last_prefetch:\$at, issues:[{number:5, labels:[{name:\"status:available\"}], assignees:[]},
			{number:6, labels:\$ok, assignees:[{login:\"other\"}]}, {number:7, state:\"CLOSED\", labels:\$ok, assignees:[]}]},
		\"owner/repo40\": {last_prefetch:\"2020-01-01T00:00:00Z\", issues:[{number:8, labels:\$ok, assignees:[]}]},
		\"owner/repo50\": {last_prefetch:\$at, issues:[{number:9, labels:\$ok, assignees:[]}]},
		\"owner/repo55\": {last_prefetch:\$at, issues:[{number:10, labels:[\"auto-dispatch\",\"status:available\"], assignees:[]}]}
	}" >"$PULSE_PREFETCH_CACHE_FILE"
	jq -n --argjson now "$now" '{last_pulsed:{"owner/repo4":($now - 600),"owner/repo50":$now}}' >"$PULSE_LAST_PER_REPO_FILE"
	_dispatch_attempt_recency_stamp 10 owner/repo55 "$now"
	snapshot=$(_dispatch_candidate_snapshot_path 50 skip)
	seed_snapshot() {
		local extra="$1"
		jq -nc --arg schema "$_DISPATCH_CANDIDATE_SNAPSHOT_SCHEMA" --argjson now "$now" --argjson extra "$extra" \
			'{schema:$schema,captured_at:($now - 60),census_seconds:739,
			candidates:([range(1;21) | {number:.,repo_slug:"owner/repo4",repo_path:"/tmp",product_discovery_complete:false}] + $extra)}' >"$snapshot"
		jq -nc 'range(1;21) | ["owner/repo4", .]' >"${snapshot}.consumed"
		printf 'owner/repo61\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
		: >"$EVENTS"
		: >"$stats"
		return 0
	}
	seed_snapshot '[]'
	[[ "$(_dispatch_first_wave_arrival_repos)" == $'owner/repo4\t15' ]]
	[[ -z "$(PULSE_FIRST_WAVE_ARRIVAL_HINT_MAX_AGE_S=0 _dispatch_first_wave_arrival_repos)" ]]

	# Exhausted snapshot: the arrival repository is scanned first, out of
	# rotation, and the cursor stays where the plain rotation reached.
	exhausted=$(_PULSE_FIRST_WAVE_CANDIDATE_TARGET=15 _dispatch_ranked_candidates_json 50 skip)
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo4;' ]]
	jq -e 'length == 15 and all(.[]; .repo_slug == "owner/repo4" and .number > 20)' <<<"$exhausted" >/dev/null
	[[ "$(<"${HOME}/.aidevops/cache/pulse-first-wave-cursor")" == owner/repo61 ]]
	grep -qx 'first_wave_new_arrival_lead' "$stats"
	grep -qF 'First-wave new-arrival lead: repo=owner/repo4 launchable=15 (GH#38200)' "$LOGFILE"
	# The re-scan keeps the ledger expiry but is timed as a scan, not a read.
	jq -e --argjson now "$now" '.captured_at == ($now - 60) and .enumerated_at >= $now' "$snapshot" >/dev/null
	if _dispatch_enumeration_served_snapshot 50 skip "$((now * 1000))"; then exit 1; fi

	# A fresh remainder smaller than the free slots is stale while arrivals
	# wait outside it: re-enumerate with arrivals ahead of the remainder's
	# repository and rotation, and merge the remainder back without a rescan.
	remainder207='[{"number":207,"repo_slug":"owner/repo61","repo_path":"/tmp","product_discovery_complete":false}]'
	seed_snapshot "$remainder207"
	# An expired opposite-mode ledger must not hide arrivals from the fresh
	# skip remainder, even when it records every currently launchable issue.
	opposite_snapshot=$(_dispatch_candidate_snapshot_path 50 normalize)
	jq -nc --argjson now "$now" \
		'{captured_at:($now - 86400),census_seconds:739,candidates:[]}' >"$opposite_snapshot"
	jq -nc 'range(21;36) | ["owner/repo4", .]' >"${opposite_snapshot}.consumed"
	[[ "$(_dispatch_first_wave_arrival_repos)" == $'owner/repo4\t15' ]]
	short=$(_PULSE_FIRST_WAVE_CANDIDATE_TARGET=15 _dispatch_ranked_candidates_json 50 skip)
	[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo4;' ]]
	jq -e 'length == 16 and any(.[]; .number == 207) and ([.[] | select(.repo_slug == "owner/repo4")] | length) == 15' <<<"$short" >/dev/null
	jq -e '[.candidates[] | select(.number == 207)] | length == 1' "$snapshot" >/dev/null
	grep -qx 'first_wave_new_arrival_refresh' "$stats"
	grep -qx 'first_wave_new_arrival_lead' "$stats"
	rm -f "$opposite_snapshot" "${opposite_snapshot}.consumed"
	# A failed refresh still serves the fresh remainder without rewriting it.
	seed_snapshot "$remainder207"
	fallback=$(build_ranked_dispatch_candidates_json() { return 1; }
		_PULSE_FIRST_WAVE_CANDIDATE_TARGET=15 _dispatch_ranked_candidates_json 50 skip)
	jq -e 'length == 1 and .[0].number == 207' <<<"$fallback" >/dev/null
	# An arrival repository the census may not poll (interval-throttled) never
	# forces a re-census: its hint could not clear.
	seed_snapshot "$remainder207"
	throttled=$(check_repo_pulse_interval() { return 1; }
		_PULSE_FIRST_WAVE_CANDIDATE_TARGET=15 _dispatch_ranked_candidates_json 50 skip)
	[[ ! -s "$EVENTS" ]]
	jq -e 'length == 1 and .[0].number == 207' <<<"$throttled" >/dev/null
	if grep -qx 'first_wave_new_arrival_refresh' "$stats"; then exit 1; fi
	# A remainder that fills the slots is still served without a scan.
	seed_snapshot "$remainder207"
	served=$(_PULSE_FIRST_WAVE_CANDIDATE_TARGET=1 _dispatch_ranked_candidates_json 50 skip)
	[[ ! -s "$EVENTS" ]]
	jq -e 'length == 1 and .[0].number == 207' <<<"$served" >/dev/null

	# Inverse: once the arrivals are attempted, no repository holds launchable
	# work the snapshot lacks, and plain rotation resumes after the cursor.
	seed_snapshot '[]'
	jq -nc 'range(21;36) | ["owner/repo4", .]' >>"${snapshot}.consumed"
	[[ -z "$(_dispatch_first_wave_arrival_repos)" ]]
	rows=$(_dispatch_repository_rows owner/repo61)
	[[ "${rows%%|*}" == owner/repo62 ]]
	_dispatch_attempt_recency_clear 10 owner/repo55
	_dispatch_invalidate_candidate_snapshot fixture_complete 50
)
printf 'PASS new product arrivals lead the next first wave from the prefetch cache; short remainders re-enumerate; quiet repositories keep rotation\n'

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
jq -n '{initialized_repos:["owner/urgent","owner/small"] | map({slug:.,path:"/tmp",pulse:true})}' >"$REPOS_JSON"
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

# GH#38333: claimed candidates (assignee or in-progress/in-review/claimed)
# follow unclaimed work in a stable partition; nothing is dropped.
claims=$(jq -nc '[
	{number:1, repo_slug:"owner/a", priority_rank:0, labels:["auto-dispatch"], assignees:[]},
	{number:2, repo_slug:"owner/a", priority_rank:0, labels:["auto-dispatch"], assignees:["runner"]},
	{number:3, repo_slug:"owner/a", priority_rank:0, labels:["auto-dispatch","status:in-review"], assignees:[]},
	{number:4, repo_slug:"owner/a", priority_rank:0, labels:["auto-dispatch"]},
	{number:5, repo_slug:"owner/a", priority_rank:0, labels:[{name:"status:claimed"}]},
	{number:6, repo_slug:"owner/a", priority_rank:0, labels:["auto-dispatch","status:available"]}]')
ordered=$(_DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=0 _dispatch_order_round_candidates "$claims" 20)
jq -e '[.[].number] == [1,4,6,2,3,5]' <<<"$ordered" >/dev/null
[[ "$(_dispatch_order_claim_state_candidates "$backlog")" == "$backlog" ]]
[[ "$(_dispatch_order_claim_state_candidates 'not-json')" == 'not-json' ]]
printf 'PASS fresh-first lane orders claimed candidates after unclaimed work, no-op otherwise\n'
