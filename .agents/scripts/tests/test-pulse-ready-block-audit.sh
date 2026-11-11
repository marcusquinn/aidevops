#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#37684: exercise the real dependency verifier and candidate label writer.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
LOGFILE="${TMP_ROOT}/pulse.log"
: >"$LOGFILE"
# shellcheck source=../pulse-dep-graph.sh
source "${SCRIPTS_DIR}/pulse-dep-graph.sh"
# shellcheck source=../pulse-dispatch-lib-candidates.sh
source "${SCRIPTS_DIR}/pulse-dispatch-lib-candidates.sh"

native_state=CLOSED
lookup_unavailable=0
issue_lookup_unavailable=0
live_blocker_state=OPEN
fixture_labels=status:available
writes=0
stats=0
# shellcheck disable=SC2016 # Literal issue prose, not shell substitutions.
fixture_body='requires-secrets: EXAMPLE_ONE EXAMPLE_TWO EXAMPLE_THREE EXAMPLE_FOUR EXAMPLE_FIVE
Do not set `status:blocked`.
Leave the issue blocked on #10.'
prose_body="$fixture_body"

_dep_validate_issue_target() {
	return 0
}
_blocked_by_load_cache() {
	printf '%s\n' "$DEP_CACHE_EMPTY_JSON"
	return 0
}
_dispatch_stats_increment() {
	stats=$((stats + 1))
	return 0
}
gh() {
	local args="$*" response="" filter="" arg=""
	if [[ "$args" == api\ graphql* ]]; then
		[[ "$lookup_unavailable" == 0 ]] || return 1
		response=$(jq -cn --arg state "$native_state" '
			{data:{rateLimit:{cost:1},repository:{issue:{blockedBy:{
			 pageInfo:{hasNextPage:false},nodes:(if $state == "ABSENT" then [] else
			 [{number:10,state:$state,stateReason:"COMPLETED",repository:{nameWithOwner:"owner/repo"}}] end)}}}}}')
		while [[ $# -gt 0 ]]; do
			arg="$1"
			shift
			if [[ "$arg" == --jq ]]; then filter="$1"; break; fi
		done
		if [[ -n "$filter" ]]; then
			printf '%s' "$response" | jq -r "$filter"
		else
			printf '%s\n' "$response"
		fi
	elif [[ "$args" == 'issue view 20 '* ]]; then
		if [[ "$args" == *'--json body'* ]]; then
			printf '%s\n' "$fixture_body"
		else
			printf '%s\n' "$fixture_labels"
		fi
	elif [[ "$args" == 'issue view 10 '* ]]; then
		[[ "$issue_lookup_unavailable" == 0 ]] || return 1
		printf '%s:\n' "$live_blocker_state"
	elif [[ "$args" == 'issue edit 20 '* ]]; then
		writes=$((writes + 1))
		fixture_labels=status:blocked
	else
		printf 'Unexpected API call: %s\n' "$args" >&2
		return 1
	fi
	return 0
}

# The real dispatch dependency verifier admits closed native blockers even with
# secrets and misleading prose. Candidate normalization must not reverse that.
if is_blocked_by_unresolved "$fixture_body" owner/repo 20; then
	printf 'FAIL: closed native blocker rejected\n' >&2
	exit 1
fi
_dispatch_normalize_dependency_blocked_candidate 20 owner/repo ''
[[ "$fixture_labels" == status:available && "$writes" == 0 ]]
printf 'PASS: closed native blockers plus secrets/prose stay available\n'

# A stale supersession log bypasses the candidate pre-read, so the actual write
# boundary must still recheck native state rather than trusting old log/cache.
stale_line='#20 blocker owner/repo#10 is open — keeping blocked (GH#34341)'
_dispatch_normalize_dependency_blocked_candidate 20 owner/repo "$stale_line"
[[ "$writes" == 0 ]]
native_state=ABSENT
_dispatch_normalize_dependency_blocked_candidate 20 owner/repo "$stale_line"
[[ "$writes" == 0 ]]
lookup_unavailable=1
_dispatch_normalize_dependency_blocked_candidate 20 owner/repo "$stale_line"
[[ "$writes" == 0 ]]
printf 'PASS: stale verdict cannot persist clear, removed, or unavailable edges\n'

lookup_unavailable=0
native_state=OPEN
_dispatch_normalize_dependency_blocked_candidate 20 owner/repo ''
[[ "$writes" == 1 && "$stats" == 1 && "$fixture_labels" == status:blocked ]]
grep -q 'DISPATCH_BLOCK_APPLIED reason=dependency_native_unresolved source=dependency_normalization native_rc=0' "$LOGFILE"
printf 'PASS: open native dependency is blocked with structured audit reason\n'

native_state=ABSENT
fixture_labels=status:available
fixture_body="${prose_body}"$'\nBlocked by: #10'
_refresh_ensure_unresolved_is_blocked owner/repo 20
[[ "$writes" == 2 && "$fixture_labels" == status:blocked ]]
grep -q 'DISPATCH_BLOCK_APPLIED reason=dependency_structured_unresolved' "$LOGFILE"
printf 'PASS: current structured fallback still blocks with an audit reason\n'

# Unknown live evidence must still block dispatch, but cannot justify a write.
fixture_labels=status:available
issue_lookup_unavailable=1
is_blocked_by_unresolved "$fixture_body" owner/repo 20
if _refresh_ensure_unresolved_is_blocked owner/repo 20; then
	printf 'FAIL: unavailable structured blocker caused a label write\n' >&2
	exit 1
fi
[[ "$writes" == 2 && "$fixture_labels" == status:available ]]
issue_lookup_unavailable=0
live_blocker_state=UNKNOWN
is_blocked_by_unresolved "$fixture_body" owner/repo 20
if _refresh_ensure_unresolved_is_blocked owner/repo 20; then
	printf 'FAIL: inconclusive structured blocker caused a label write\n' >&2
	exit 1
fi
[[ "$writes" == 2 && "$fixture_labels" == status:available ]]
printf 'PASS: unknown issue evidence blocks dispatch without persisting a hold\n'

gh_issue_list() {
	printf '%s\n' "$task_matches"
	return 0
}
task_matches='[]'
fixture_body='Blocked by: t10'
is_blocked_by_unresolved "$fixture_body" owner/repo 20
if _refresh_ensure_unresolved_is_blocked owner/repo 20; then
	printf 'FAIL: unresolved task identity caused a label write\n' >&2
	exit 1
fi
[[ "$writes" == 2 && "$fixture_labels" == status:available ]]
task_matches='[{"number":10,"title":"t10: blocker","state":"OPEN"}]'
_refresh_ensure_unresolved_is_blocked owner/repo 20
[[ "$writes" == 3 && "$fixture_labels" == status:blocked ]]
printf 'PASS: task fallback requires live unresolved evidence for label writes\n'

# Model the reported race: absent first lookup, unavailable on a repeat.
native_calls=0
_blocked_by_check_native_relationships() {
	native_calls=$((native_calls + 1))
	[[ "$native_calls" == 1 ]] || return 3
	return 1
}
fixture_labels=status:available
fixture_body='Blocked by: #10'
issue_lookup_unavailable=1
if _refresh_ensure_unresolved_is_blocked owner/repo 20; then
	printf 'FAIL: changing native availability caused a label write\n' >&2
	exit 1
fi
[[ "$writes" == 3 && "$fixture_labels" == status:available && "$native_calls" == 1 ]]
printf 'PASS: write fallback does not repeat the native lookup or persist unknown evidence\n'
