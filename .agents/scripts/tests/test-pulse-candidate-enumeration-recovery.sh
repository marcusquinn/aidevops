#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pulse-candidate-recovery-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export LOGFILE="${TEST_ROOT}/pulse.log"
export REPOS_JSON="${TEST_ROOT}/repos.json"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
: >"$LOGFILE"

# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=../pulse-repo-meta.sh
source "${SCRIPT_DIR}/pulse-repo-meta.sh"

fail() {
	printf 'FAIL %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	[[ "$actual" == "$expected" ]] || fail "${name}: expected=${expected} actual=${actual}"
	printf 'PASS %s\n' "$name"
}

ISSUE_FIXTURE='[{"number":100,"title":"Recovered candidate","url":"https://github.com/owner/repo/issues/100","state":"OPEN","labels":[{"name":"auto-dispatch"},{"name":"status:available"}],"assignees":[],"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z","body":"Worker-ready"}]'

# A complete canonical cache is accepted only inside the tighter dispatch TTL.
FAKE_PREFETCH="${TEST_ROOT}/fake-prefetch.sh"
{
	printf '%s\n' '#!/usr/bin/env bash'
	# shellcheck disable=SC2016  # generated helper expands this at execution time
	printf '%s\n' 'printf "%s\n" "${PULSE_TEST_BATCH_SNAPSHOT}"'
} >"$FAKE_PREFETCH"
chmod +x "$FAKE_PREFETCH"
export PULSE_BATCH_PREFETCH_HELPER="$FAKE_PREFETCH"
export PULSE_DISPATCH_CANDIDATE_CACHE_MAX_AGE_SECONDS=300
PULSE_DISPATCH_CANDIDATE_NOW_EPOCH=$(jq -nr '"2026-05-01T00:04:00Z" | fromdateiso8601')
export PULSE_DISPATCH_CANDIDATE_NOW_EPOCH
PULSE_TEST_BATCH_SNAPSHOT=$(jq -cn --argjson items "$ISSUE_FIXTURE" '{complete:true,fetched_at:"2026-05-01T00:00:00Z",items:$items}')
export PULSE_TEST_BATCH_SNAPSHOT
cached=$(_pulse_candidate_cached_issue_snapshot_json "owner/repo")
assert_eq "fresh complete batch cache is a recovery candidate source" "100" \
	"$(printf '%s' "$cached" | jq -r '.[0].number')"

PULSE_TEST_BATCH_SNAPSHOT=$(jq -cn --argjson items "$ISSUE_FIXTURE" '{complete:false,fetched_at:"2026-05-01T00:00:00Z",items:$items}')
export PULSE_TEST_BATCH_SNAPSHOT
if _pulse_candidate_cached_issue_snapshot_json "owner/repo" >/dev/null; then
	fail "incomplete batch cache authorized dispatch recovery"
fi
printf 'PASS incomplete batch cache stays fail-closed\n'

PULSE_TEST_BATCH_SNAPSHOT=$(jq -cn --argjson items "$ISSUE_FIXTURE" '{complete:true,fetched_at:"2026-04-30T23:58:59Z",items:$items}')
export PULSE_TEST_BATCH_SNAPSHOT
if _pulse_candidate_cached_issue_snapshot_json "owner/repo" >/dev/null; then
	fail "stale batch cache authorized dispatch recovery"
fi
printf 'PASS stale batch cache stays fail-closed\n'

# A failed REST-first wrapper read retries native GraphQL once when that pool has
# verified headroom, before consulting the cache.
gh_issue_list() {
	printf 'REST unavailable\n' >&2
	return 1
}
_pulse_candidate_graphql_retry_available() { return 0; }
_gh_with_timeout() {
	shift
	if [[ "${1:-}" == "gh" && "${2:-}" == "issue" && "${3:-}" == "list" ]]; then
		printf '%s\n' "$ISSUE_FIXTURE"
		return 0
	fi
	return 1
}
ERROR_FILE="${TEST_ROOT}/fetch.err"
SOURCE_FILE="${TEST_ROOT}/fetch.source"
retry_json=$(_pulse_fetch_candidate_issue_snapshot_json "owner/repo" 100 "$ERROR_FILE" "$SOURCE_FILE")
assert_eq "REST failure recovers through one native GraphQL read" "graphql-retry:100" \
	"$(printf '%s:%s' "$(<"$SOURCE_FILE")" "$(printf '%s' "$retry_json" | jq -r '.[0].number')")"

gh_issue_list() {
	printf '[gh-cooldown] secondary-rate-limit active=true skip=read\n' >&2
	return 75
}
GRAPHQL_RETRY_LOG="${TEST_ROOT}/graphql-retry.log"
_pulse_candidate_graphql_retry_available() {
	printf 'called\n' >>"$GRAPHQL_RETRY_LOG"
	return 0
}
_pulse_candidate_cached_issue_snapshot_json() { return 1; }
cooldown_rc=0
_pulse_fetch_candidate_issue_snapshot_json "owner/repo" 100 "$ERROR_FILE" "$SOURCE_FILE" >/dev/null || cooldown_rc=$?
assert_eq "secondary cooldown skips the alternate live transport" "1:unavailable" \
	"${cooldown_rc}:$(<"$SOURCE_FILE")"
[[ ! -s "$GRAPHQL_RETRY_LOG" ]] || fail "secondary cooldown retried GraphQL"
printf 'PASS secondary cooldown avoids repeated live transport resets\n'

# When both live pools are unavailable, a fresh cache returns candidates but
# cannot authorize lifecycle lock reconciliation or completeness lending.
_pulse_candidate_graphql_retry_available() { return 1; }
_pulse_candidate_cached_issue_snapshot_json() {
	printf '%s\n' "$ISSUE_FIXTURE"
	return 0
}
LOCK_RECONCILE_LOG="${TEST_ROOT}/lock-reconcile.log"
reconcile_auto_dispatch_issue_locks() {
	printf 'called\n' >>"$LOCK_RECONCILE_LOG"
	return 0
}
SNAPSHOT_STATUS="${TEST_ROOT}/snapshot.status"
COMPLETENESS="${TEST_ROOT}/snapshot.complete"
candidate_json=$(list_dispatchable_issue_candidates_json \
	"owner/repo" 100 "" "$SNAPSHOT_STATUS" skip "$COMPLETENESS")
assert_eq "cache recovery returns the worker-ready parent" "100" \
	"$(printf '%s' "$candidate_json" | jq -r '.[0].number')"
assert_eq "cache recovery does not claim a live snapshot" "0:0" \
	"$(printf '%s:%s' "$(<"$SNAPSHOT_STATUS")" "$(<"$COMPLETENESS")")"
[[ ! -s "$LOCK_RECONCILE_LOG" ]] || fail "cache recovery reconciled lifecycle locks"
printf 'PASS cache recovery leaves lifecycle authority fail-closed\n'

_pulse_candidate_cached_issue_snapshot_json() {
	printf '[]\n'
	return 0
}
empty_cache_rc=0
empty_cache_json=$(list_dispatchable_issue_candidates_json "owner/repo" 100 "" "" skip) || empty_cache_rc=$?
assert_eq "empty recovery cache cannot prove an empty dispatch queue" "1:[]" \
	"${empty_cache_rc}:${empty_cache_json}"

# If every source is unavailable, the campaign adapter and ranked builder must
# return failure instead of caching a successful empty queue.
list_dispatchable_issue_candidates_json() {
	printf '[]\n'
	return 1
}
_dispatch_filter_repo_pr_backlog_candidates() {
	printf '%s\n' "$2"
	return 0
}
export AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=0
if pulse_campaign_shadow_candidates_json "owner/repo" "$TEST_ROOT" 100 skip >/dev/null; then
	fail "campaign adapter swallowed source unavailability"
fi
printf 'PASS campaign adapter propagates source unavailability\n'

jq -cn --arg path "$TEST_ROOT" '{initialized_repos:[{slug:"owner/repo",path:$path,priority:"product",pulse:true,maintenance:true}]}' >"$REPOS_JSON"
check_repo_pulse_schedule() { return 0; }
check_repo_pulse_interval() { return 0; }
update_repo_pulse_timestamp() { return 0; }
ranked_rc=0
ranked_json=$(build_ranked_dispatch_candidates_json 100 skip) || ranked_rc=$?
assert_eq "all-repository source failure is not a successful empty queue" "1:[]" \
	"${ranked_rc}:${ranked_json}"

printf 'PASS Pulse candidate enumeration recovers across transports and fresh cache without false empty snapshots\n'
