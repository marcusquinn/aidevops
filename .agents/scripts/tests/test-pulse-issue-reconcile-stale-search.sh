#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#40231: the per-repo stale sweep shared one stage budget with four other
# listing passes and was killed before it reached most repos, so dead
# workers' claims stayed status:in-progress for hours. One search per
# normalize run now discovers this runner's stale active claims; each goes
# through the same gate and audited reset. The per-repo pass stays as the
# fallback when search cannot cover every claim, and as a slow backstop.
#
# Not using `set -e`: negative assertions capture non-zero exits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_TMP="$(mktemp -d -t pulse-stale-search.XXXXXX)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_TMP"
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local passed="$2"
	local details="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -z "$details" ]] || printf '     %s\n' "$details"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

export HOME="${TEST_TMP}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache"
export LOGFILE="${TEST_TMP}/pulse.log"
export PULSE_QUEUED_SCAN_LIMIT=50
export WORKER_MAX_RUNTIME=10800
export AIDEVOPS_DEVICE_ID=device-local
CALLS="${TEST_TMP}/calls"
: >"$LOGFILE"
: >"$CALLS"

export REPOS_JSON="${TEST_TMP}/repos.json"
cat >"$REPOS_JSON" <<'EOF'
{"initialized_repos":[
 {"slug":"Owner/Repo","pulse":true},
 {"slug":"owner/denied","pulse":true},
 {"slug":"owner/local","pulse":true,"local_only":true}
]}
EOF

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" >/dev/null 2>&1
unset _PULSE_ISSUE_RECONCILE_LOADED
# shellcheck source=../pulse-issue-reconcile.sh
source "${SCRIPT_DIR}/pulse-issue-reconcile.sh" >/dev/null 2>&1
set +e

NOW_EPOCH=$(jq -n '"2026-11-25T00:00:00Z" | fromdateiso8601')
OLD_TS="2026-11-24T20:00:00Z"
NEW_TS="2026-11-24T21:00:00Z"

# --- stubs -------------------------------------------------------------------
SEARCH_FIXTURE=""
SEARCH_FAIL=0
gh() {
	printf '%s\n' "$*" >>"$CALLS"
	case "$*" in
	"api -X GET search/issues "*)
		[[ "$SEARCH_FAIL" -eq 0 ]] || return 1
		printf '%s' "$SEARCH_FIXTURE"
		return 0
		;;
	"api repos/Owner/Repo/issues/"*"/comments --method POST"*)
		printf '%s' '{}'
		return 0
		;;
	"api repos/Owner/Repo/issues/"*)
		local path="$2"
		local num="${path##*/}"
		[[ -f "${TEST_TMP}/live-${num}.json" ]] || return 1
		cat "${TEST_TMP}/live-${num}.json"
		return 0
		;;
	esac
	return 1
}
set_issue_status() {
	printf 'set_issue_status %s\n' "$*" >>"$CALLS"
	return 0
}
repo_allows_pulse_write_actions() {
	[[ "$1" == "Owner/Repo" ]]
	return $?
}
_normalize_stale_find_open_pr() {
	printf '%s' ''
	return 0
}
_normalize_stale_get_dispatch_info() {
	printf '4242\n2026-11-24T19:00:00Z\nrunner-bot\ndevice-local\n'
	return 0
}
aidevops_pulse_worker_log_path() {
	printf '%s\n' "${TEST_TMP}/missing-worker.log"
	return 0
}
pgrep() { return 1; }
ps() { return 1; }

# Search item / live issue JSON. Args: number, repo slug, updated, labels CSV,
# state (live issue only)
item_json() {
	local num="$1" repo="$2" updated="$3" label="${4:-status:in-progress}" state="${5:-open}"
	printf '{"number":%s,"state":"%s","repository_url":"https://api.github.com/repos/%s","labels":[{"name":"%s"}],"assignees":[{"login":"runner-bot"}],"updated_at":"%s"}' \
		"$num" "$state" "$repo" "$label" "$updated"
	return 0
}
search_json() {
	local total="$1" incomplete="$2"
	shift 2
	local items="" item=""
	for item in "$@"; do
		items="${items:+${items},}${item}"
	done
	printf '{"total_count":%s,"incomplete_results":%s,"items":[%s]}' "$total" "$incomplete" "$items"
	return 0
}

reset_case() {
	: >"$LOGFILE"
	: >"$CALLS"
	rm -f "${TEST_TMP}"/live-*.json
	SEARCH_FAIL=0
	unset AIDEVOPS_STALE_SEARCH_MAX_CANDIDATES
	pgrep() { return 1; }
	ps() { return 1; }
	return 0
}

search_calls() {
	grep -c '^api -X GET search/issues ' "$CALLS"
	return 0
}

run_sweep() {
	_normalize_unassign_stale_search runner-bot "$REPOS_JSON" "$NOW_EPOCH" 10800 ""
	return $?
}

# --- search sweep --------------------------------------------------------------
test_search_resets_dead_claim() {
	reset_case
	SEARCH_FIXTURE=$(search_json 1 false "$(item_json 7 owner/repo "$OLD_TS")")
	item_json 7 Owner/Repo "$OLD_TS" >"${TEST_TMP}/live-7.json"
	local rc=0
	run_sweep || rc=$?
	if [[ "$rc" -eq 0 && "$(search_calls)" -eq 1 ]] &&
		grep -q '^api repos/Owner/Repo/issues/7/comments --method POST ' "$CALLS" &&
		grep -q '^CLAIM_RELEASED reason=stale_assignment_reset runner=runner-bot .*device=device-local' "$CALLS" &&
		grep -qx 'set_issue_status 7 Owner/Repo available --remove-assignee runner-bot' "$CALLS" &&
		grep -q 'Stale assignment scan (search): .*candidates=1 .*reset=1 .*coverage=complete' "$LOGFILE"; then
		print_result "one search finds a dead claim; gate and audited reset release it" 0
	else
		print_result "one search finds a dead claim; gate and audited reset release it" 1 "rc=${rc} $(tr '\n' ';' <"$CALLS") $(<"$LOGFILE")"
	fi
	return 0
}

test_search_query_shape() {
	reset_case
	SEARCH_FIXTURE=$(search_json 0 false)
	run_sweep
	if grep -q 'q=is:issue is:open assignee:runner-bot label:"status:in-progress","status:queued" updated:<2026-11-24T23:50:00Z' "$CALLS" &&
		grep -q 'sort=updated -f order=asc -f per_page=100' "$CALLS"; then
		print_result "search asks for this runner's active claims older than the threshold" 0
	else
		print_result "search asks for this runner's active claims older than the threshold" 1 "$(<"$CALLS")"
	fi
	return 0
}

test_live_session_leader_skips_without_api() {
	reset_case
	SEARCH_FIXTURE=$(search_json 1 false "$(item_json 7 Owner/Repo "$OLD_TS")")
	item_json 7 Owner/Repo "$OLD_TS" >"${TEST_TMP}/live-7.json"
	pgrep() {
		[[ "$*" == *"session-key"* ]] && printf '%s\n' 5151 && return 0
		return 1
	}
	ps() {
		[[ "$*" == *"pgid="* ]] && printf '%s\n' ' 5151'
		return 0
	}
	run_sweep
	if [[ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 1 && "$(search_calls)" -eq 1 ]] &&
		grep -q 'candidates=0 live_local=1 .*reset=0' "$LOGFILE"; then
		print_result "live same-device session leader is skipped before any issue read" 0
	else
		print_result "live same-device session leader is skipped before any issue read" 1 "$(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_recheck_drops_changed_issue() {
	reset_case
	SEARCH_FIXTURE=$(search_json 2 false "$(item_json 7 Owner/Repo "$OLD_TS")" "$(item_json 8 Owner/Repo "$OLD_TS")")
	item_json 7 Owner/Repo "$OLD_TS" status:in-progress closed >"${TEST_TMP}/live-7.json"
	item_json 8 Owner/Repo "$OLD_TS" status:available >"${TEST_TMP}/live-8.json"
	run_sweep
	if ! grep -q 'comments --method POST' "$CALLS" && ! grep -q '^set_issue_status' "$CALLS" &&
		grep -q 'candidates=2 .*recheck_dropped=2 reset=0' "$LOGFILE"; then
		print_result "lagging search results are re-read; closed or relabelled issues are left alone" 0
	else
		print_result "lagging search results are re-read; closed or relabelled issues are left alone" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_unlisted_local_and_denied_repos_ignored() {
	reset_case
	SEARCH_FIXTURE=$(search_json 3 false "$(item_json 7 other/unlisted "$OLD_TS")" \
		"$(item_json 8 owner/local "$OLD_TS")" "$(item_json 9 owner/denied "$OLD_TS")")
	run_sweep
	if [[ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 1 ]] && grep -q 'results=3 total=3 candidates=0 ' "$LOGFILE"; then
		print_result "unlisted, local-only and write-denied repos are never touched" 0
	else
		print_result "unlisted, local-only and write-denied repos are never touched" 1 "$(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_cap_processes_oldest_first() {
	reset_case
	export AIDEVOPS_STALE_SEARCH_MAX_CANDIDATES=1
	SEARCH_FIXTURE=$(search_json 2 false "$(item_json 8 Owner/Repo "$NEW_TS")" "$(item_json 7 Owner/Repo "$OLD_TS")")
	item_json 7 Owner/Repo "$OLD_TS" >"${TEST_TMP}/live-7.json"
	item_json 8 Owner/Repo "$NEW_TS" >"${TEST_TMP}/live-8.json"
	local rc=0
	run_sweep || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -qx 'api repos/Owner/Repo/issues/7' "$CALLS" &&
		! grep -qx 'api repos/Owner/Repo/issues/8' "$CALLS" &&
		grep -q 'candidates=1 .*reset=1 deferred=1 ' "$LOGFILE"; then
		print_result "per-run cap checks the oldest claims first and defers the rest" 0
	else
		print_result "per-run cap checks the oldest claims first and defers the rest" 1 "rc=${rc} $(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_search_failure_keeps_fallback() {
	reset_case
	SEARCH_FAIL=1
	local rc=0
	run_sweep || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -q 'unavailable: reason=search_failed' "$LOGFILE"; then
		print_result "search failure returns non-zero so the per-repo pass runs" 0
	else
		print_result "search failure returns non-zero so the per-repo pass runs" 1 "rc=${rc} $(<"$LOGFILE")"
	fi
	return 0
}

test_incomplete_results_keep_fallback() {
	reset_case
	SEARCH_FIXTURE=$(search_json 1 true "$(item_json 7 Owner/Repo "$OLD_TS")")
	local rc=0
	run_sweep || rc=$?
	if [[ "$rc" -eq 1 && "$(wc -l <"$CALLS" | tr -d ' ')" -eq 1 ]] &&
		grep -q 'unavailable: reason=incomplete' "$LOGFILE"; then
		print_result "incomplete search results act on nothing and keep the per-repo pass" 0
	else
		print_result "incomplete search results act on nothing and keep the per-repo pass" 1 "rc=${rc} $(<"$LOGFILE")"
	fi
	return 0
}

test_page_limit_is_partial_coverage() {
	reset_case
	SEARCH_FIXTURE=$(search_json 150 false "$(item_json 7 Owner/Repo "$OLD_TS")")
	item_json 7 Owner/Repo "$OLD_TS" >"${TEST_TMP}/live-7.json"
	local rc=0
	run_sweep || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -q 'reset=1 .*coverage=partial' "$LOGFILE"; then
		print_result "more matches than one page: results are processed and the per-repo pass is kept" 0
	else
		print_result "more matches than one page: results are processed and the per-repo pass is kept" 1 "rc=${rc} $(<"$LOGFILE")"
	fi
	return 0
}

test_search_resets_dead_claim
test_search_query_shape
test_live_session_leader_skips_without_api
test_recheck_drops_changed_issue
test_unlisted_local_and_denied_repos_ignored
test_cap_processes_oldest_first
test_search_failure_keeps_fallback
test_incomplete_results_keep_fallback
test_page_limit_is_partial_coverage

# --- coordinator ---------------------------------------------------------------
# Stub every pass so only the coordinator's ordering and skip logic runs.
SEARCH_RC=0
_normalize_reap_dead_stamps() { return 0; }
_pulse_resolve_runner_login() {
	printf '%s\n' runner-bot
	return 0
}
_normalize_unassign_stale_search() {
	printf 'search\n' >>"$CALLS"
	return "$SEARCH_RC"
}
_normalize_stale_close_pending_checkpoint_leases() {
	printf 'lease_drain\n' >>"$CALLS"
	return 0
}
_normalize_deferred_claim_releases() {
	printf 'deferred_drain\n' >>"$CALLS"
	return 0
}
_normalize_reassign_self() {
	printf 'reassign_self\n' >>"$CALLS"
	return 0
}
_normalize_unassign_stale() {
	printf 'per_repo_stale\n' >>"$CALLS"
	return 0
}
_normalize_unassign_available_stale() { return 0; }
_normalize_unassign_stampless_interactive() { return 0; }
_normalize_label_invariants() { return 0; }

PASS_STATE_DIR="${HOME}/.aidevops/cache/normalize-pass-started"
run_coordinator() {
	local stale_started_ago="$1"
	: >"$CALLS"
	mkdir -p "$PASS_STATE_DIR"
	printf '%s\n' "$(($(date +%s) - stale_started_ago))" >"${PASS_STATE_DIR}/unassign_stale"
	normalize_active_issue_assignments
	return 0
}

test_coordinator_runs_search_and_drains_every_run() {
	SEARCH_RC=0
	run_coordinator 60
	local first_three=""
	first_three=$(head -n 3 "$CALLS" | tr '\n' ' ')
	if [[ "$first_three" == "search lease_drain deferred_drain " ]] &&
		! grep -qx per_repo_stale "$CALLS" && grep -qx reassign_self "$CALLS"; then
		print_result "search and claim-release drains run first; recent per-repo pass is skipped" 0
	else
		print_result "search and claim-release drains run first; recent per-repo pass is skipped" 1 "$(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_coordinator_falls_back_when_search_fails() {
	SEARCH_RC=1
	run_coordinator 60
	if grep -qx per_repo_stale "$CALLS" && [[ "$(grep -cx lease_drain "$CALLS")" -eq 1 ]]; then
		print_result "failed search keeps the per-repo pass; drains still run once" 0
	else
		print_result "failed search keeps the per-repo pass; drains still run once" 1 "$(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_coordinator_backstop_runs_when_due() {
	SEARCH_RC=0
	run_coordinator 25000
	if grep -qx per_repo_stale "$CALLS"; then
		print_result "per-repo backstop runs when it has not started for 6h" 0
	else
		print_result "per-repo backstop runs when it has not started for 6h" 1 "$(tr '\n' ';' <"$CALLS")"
	fi
	return 0
}

test_coordinator_runs_search_and_drains_every_run
test_coordinator_falls_back_when_search_fails
test_coordinator_backstop_runs_when_due

printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
