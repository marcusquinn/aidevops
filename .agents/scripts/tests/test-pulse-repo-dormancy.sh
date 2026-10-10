#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise real candidate/prefetch paths with isolated scheduling state.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export PULSE_DORMANCY_DIR="$TEST_DIR/state"
export AIDEVOPS_DISPATCH_LEDGER_DIR="$TEST_DIR"
export PULSE_REPO_DORMANCY_ENABLED=1
LOGFILE="$TEST_DIR/pulse.log"
PULSE_TIER_LAST_CHECK_FILE="$TEST_DIR/tier.json"
# shellcheck source=../pulse-repo-meta.sh
source "$SCRIPT_DIR/pulse-repo-meta.sh"
# shellcheck source=../pulse-prefetch-orchestration.sh
source "$SCRIPT_DIR/pulse-prefetch-orchestration.sh"
# shellcheck source=../pulse-prefetch-repo.sh
source "$SCRIPT_DIR/pulse-prefetch-repo.sh"

NOW=$(command date +%s)
ISSUES_ETAG='"issues-1"'
COMMITS_ETAG='"commits-1"'
PRS='[]'
ISSUES='[{"number":1,"labels":[{"name":"persistent"}],"assignees":[]}]'
API_ERROR=0
RESPONSE_BODY='[]'
date() {
	local arg="${1:-}"
	if [[ "$arg" == +%s ]]; then printf '%s\n' "$NOW"; else command date "$@"; fi
	return 0
}
gh() {
	local arg="" endpoint="" conditional="" etag=""
	for arg in "$@"; do
		case "$arg" in repos/*) endpoint="$arg" ;; 'If-None-Match: '*) conditional="${arg#*: }" ;; esac
	done
	[[ "$API_ERROR" == 0 ]] || return 1
	case "$endpoint" in
	*/pulls\?*) printf '%s\n' "$PRS"; return 0 ;;
	*/issues\?*) etag="$ISSUES_ETAG" ;;
	*/commits\?*) etag="$COMMITS_ETAG" ;;
	*) return 1 ;;
	esac
	if [[ "$conditional" == "$etag" ]]; then
		printf 'gh: HTTP 304\n' >&2
		return 1
	fi
	printf 'HTTP/2.0 200 OK\r\nETag: %s\r\n\r\n%s\n' "$etag" "$RESPONSE_BODY"
	return 0
}
gh_issue_list() {
	printf 'scan\n' >>"$TEST_DIR/scans"
	printf '%s\n' "$ISSUES"
	return 0
}
assert() {
	local description="$1"
	shift
	if "$@"; then printf 'PASS: %s\n' "$description"; else printf 'FAIL: %s\n' "$description" >&2; exit 1; fi
	return 0
}
is_dormant() {
	local slug="$1"
	if pulse_repo_scan_allowed "$slug"; then return 1; fi
	return 0
}
empty_candidate_scan() {
	local slug="$1" result=""
	result=$(list_dispatchable_issue_candidates_json "$slug")
	[[ "$result" == '[]' ]] || return 1
	return 0
}

assert 'persistent-only full scan enters dormancy' empty_candidate_scan owner/idle
assert 'stderr-only 304 keeps repo dormant' is_dormant owner/idle
assert 'candidate discovery skips live list while dormant' empty_candidate_scan owner/idle
assert 'only one full issue scan occurred' test "$(wc -l <"$TEST_DIR/scans")" -eq 1
assert 'per-repo prefetch is skipped without calling its other helpers' _prefetch_single_repo owner/idle nowhere "$TEST_DIR/prefetch"
assert 'skip output explicitly reports dormancy' grep -q Dormant "$TEST_DIR/prefetch"

ISSUES_ETAG='"issues-2"'
RESPONSE_BODY='[{"body":"gh: HTTP 304 and HTTP/2 304 are issue prose, not a status"}]'
assert 'new/relabelled issue or PR wakes on next scan' pulse_repo_scan_allowed owner/idle
RESPONSE_BODY='[]'
assert 'remote wake bypasses cold tier' check_repo_tier_skip owner/idle
assert 'unchanged persistent repo can sleep again' empty_candidate_scan owner/idle
COMMITS_ETAG='"commits-2"'
assert 'planning push wakes repo' pulse_repo_scan_allowed owner/idle
assert 'repo sleeps again after complete scan' empty_candidate_scan owner/idle
pulse_repo_wake owner/idle interactive_claim
assert 'interactive claim/start marker wakes immediately' pulse_repo_scan_allowed owner/idle
assert 'local wake is pending until complete scan' pulse_repo_wake_pending owner/idle
assert 'full scan acknowledges wake' empty_candidate_scan owner/idle
assert 'acknowledged wake does not permanently bypass tiers' is_dormant owner/idle
if pulse_repo_wake_pending owner/idle; then exit 1; fi

PULSE_DORMANCY_BACKSTOP_SECONDS=10
NOW=$((NOW + 10))
assert 'backstop scans at the configured interval' pulse_repo_scan_allowed owner/idle
assert 'backstop bypasses tier cadence' check_repo_tier_skip owner/idle
assert 'entry is renewed only after a successful scan' empty_candidate_scan owner/idle
API_ERROR=1
assert 'API errors fail open, not starvation' pulse_repo_scan_allowed owner/idle
API_ERROR=0

PRS='[{"number":9}]'
assert 'open PR prevents dormancy' empty_candidate_scan owner/pr
assert 'open PR repo has no dormant state' test ! -e "$PULSE_DORMANCY_DIR/owner--pr.json"
PRS='[]'
ISSUES='[{"number":1,"labels":[{"name":"persistent"},{"name":"status:in-progress"}],"assignees":[]}]'
assert 'active worker status prevents dormancy' empty_candidate_scan owner/worker
assert 'worker repo has no dormant state' test ! -e "$PULSE_DORMANCY_DIR/owner--worker.json"
ISSUES='[{"number":1,"labels":[{"name":"persistent"}],"assignees":[{"login":"owner"}]}]'
assert 'assigned claim prevents dormancy' empty_candidate_scan owner/claim
assert 'claim repo has no dormant state' test ! -e "$PULSE_DORMANCY_DIR/owner--claim.json"
ISSUES='[{"number":1,"labels":[{"name":"persistent"},{"name":"worker-checkpoint"}],"assignees":[]}]'
assert 'held checkpoint recovery prevents dormancy' empty_candidate_scan owner/recovery
assert 'recovery repo has no dormant state' test ! -e "$PULSE_DORMANCY_DIR/owner--recovery.json"
ISSUES='[{"number":1,"labels":[{"name":"persistent"}],"assignees":[]}]'
list_dispatchable_issue_candidates_json owner/truncated 1 >/dev/null
assert 'bounded/truncated scan cannot prove absence' test ! -e "$PULSE_DORMANCY_DIR/owner--truncated.json"

printf '%s\n' '{"session_key":"worker","repo_slug":"owner/local","status":"checkpointed"}' >"$TEST_DIR/dispatch-ledger.jsonl"
assert 'local ledger checkpoint without an open issue/PR prevents dormancy' empty_candidate_scan owner/local
assert 'local checkpoint repo remains awake' test ! -e "$PULSE_DORMANCY_DIR/owner--local.json"
printf '%s\n' '{"session_key":"worker","repo_slug":"owner/local","status":"completed"}' >>"$TEST_DIR/dispatch-ledger.jsonl"
assert 'latest terminal ledger entry allows sleep' empty_candidate_scan owner/local
printf '%s\n' '{"session_key":"new","repo_slug":"owner/local","status":"in-flight"}' >>"$TEST_DIR/dispatch-ledger.jsonl"
assert 'new local worker wakes a sleeping repo even before GitHub labels change' pulse_repo_scan_allowed owner/local

# A wake racing the scan is not acknowledged or overwritten by state publication.
pulse_repo_dormancy_prepare owner/race
pulse_repo_wake owner/race planning_publication
pulse_repo_dormancy_observe owner/race "$ISSUES" '[]' 1
assert 'wake arriving during scan survives entry' pulse_repo_scan_allowed owner/race
assert 'repo can sleep after race is handled' empty_candidate_scan owner/race

# Exercise the real batch loop with two enabled repos and one disabled repo.
(
	export PULSE_STATS_FILE="$TEST_DIR/stats.json"
	export PULSE_BATCH_PREFETCH_CACHE_DIR="$TEST_DIR/batch"
	# shellcheck source=../pulse-batch-prefetch-helper.sh
	source "$SCRIPT_DIR/pulse-batch-prefetch-helper.sh" help >/dev/null
	pulse_stats_increment() { return 0; }
	gh_record_call() { return 0; }
	_gh_with_timeout() { shift; "$@"; return $?; }
	_prefetch_gh_read() { printf '100\n'; return 0; }
	_conditional_rest_capture_initial_markers() { return 0; }
	events_tickle() { return 0; }
	_events_tickle_skip_is_safe() { return 0; }
	_record_events_tickle_stats() { return 0; }
	_refresh_owner_issues() { local owner="$1" slugs="$2"; printf '%s|%s\n' "$owner" "$slugs" >>"$TEST_DIR/batch-slugs"; return 0; }
	_refresh_owner_prs() { local owner="$1" slugs="$2"; printf '%s|%s\n' "$owner" "$slugs" >>"$TEST_DIR/batch-slugs"; return 0; }
	REPOS_JSON="$TEST_DIR/repos.json"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/race","pulse":true},{"slug":"owner/awake","pulse":true},{"slug":"owner/disabled","pulse":false}]}' >"$REPOS_JSON"
	pulse_repo_wake owner/awake planning_publication
	_cmd_refresh >/dev/null
	assert 'batch filters dormant and disabled repos from comma-separated groups' test "$(sort -u "$TEST_DIR/batch-slugs")" == 'owner|owner/awake'
)

PULSE_REPO_DORMANCY_ENABLED=0
API_ERROR=1
assert 'rollback completely bypasses dormant state and probes' pulse_repo_scan_allowed owner/race
assert 'transitions and skip counters are observable in logs' grep -q reason=backstop "$LOGFILE"
printf 'All dormancy path checks passed\n'
