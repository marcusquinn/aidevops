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
_pulse_cycle_remaining_seconds() {
	local reserve="${1:-0}" now=0
	read -r now <"$CLOCK"
	printf '%s\n' "$((1800 - now - reserve))"
	return 0
}
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
	jq -e 'length == 1 and .[0].product_discovery_complete == false' <<<"$candidates" >/dev/null
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
_log_substage_timing() { return 0; }
_pulse_start_post_dispatch_housekeeping() { return 0; }
_pulse_should_defer_budget_priority_stage() { return 0; }
_pulse_defer_budget_priority_stage() { return 0; }
_PULSE_HEALTH_PREFETCH_THROTTLED=0

_run_preflight_stages
actual=$(tr '\n' ';' <"$EVENTS")
[[ "$actual" == 'host-capacity;scan:owner/repo1;scan:owner/repo2;launch;cleanup;host-capacity;' ]] || {
	printf 'FAIL first-wave ordering: %s\n' "$actual" >&2
	exit 1
}
[[ "$(_pulse_capture_dispatch_total)" == 1 ]]
[[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 0 ]]
[[ "${PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED:-1}" == 1 ]]
[[ "$(<"${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds")" == 2476 ]]
[[ "$(<"${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds-first-wave")" == 300 ]]
printf 'PASS first wave registers dispatch before paced housekeeping; timing/snapshot scope stays isolated\n'

# The later global scan remains complete and keeps all repositories eligible.
: >"$EVENTS"
full=$(build_ranked_dispatch_candidates_json 50 normalize)
[[ "$(wc -l <"$EVENTS")" -eq 40 ]]
jq -e 'length == 39 and all(.[]; .product_discovery_complete == true)' <<<"$full" >/dev/null
printf 'PASS normal refill retains full repository discovery and product completeness\n'

# Partial first waves rotate across repositories even when a backlog persists.
: >"$EVENTS"
rotated=$(_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip)
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo3;' ]]
jq -e 'length == 1 and .[0].repo_slug == "owner/repo3" and .[0].product_discovery_complete == false' <<<"$rotated" >/dev/null
printf 'owner/repo40\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
: >"$EVENTS"
_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip >/dev/null
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo1;scan:owner/repo2;' ]]
printf 'removed/repo\n' >"${HOME}/.aidevops/cache/pulse-first-wave-cursor"
: >"$EVENTS"
_PULSE_FIRST_DISPATCH_WAVE=1 build_ranked_dispatch_candidates_json 50 skip >/dev/null
[[ "$(tr '\n' ';' <"$EVENTS")" == 'scan:owner/repo1;scan:owner/repo2;' ]]
printf 'PASS first-wave cursor rotates, wraps and tolerates removed repositories\n'

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
