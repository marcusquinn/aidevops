#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
TEST_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=../dependency-event-reconciler.sh
source "${TEST_DIR}/../dependency-event-reconciler.sh"
# shellcheck source=../pulse-budget-priority.sh
source "${TEST_DIR}/../pulse-budget-priority.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"
DER_RETRY_DIR="$ROOT/retries"
DER_STALE_BLOCKED_CURSOR_DIR="$ROOT/cursors"
mkdir -p "$HOME/.aidevops/cache/stale-blocked-weight"
CALLS="$ROOT/calls"
NOW=1000
date() { printf '%s\n' "$NOW"; return 0; }
_der_live_issue_closed() { return 0; }
_der_fetch_closed_context() {
	printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","issue":{"title":"blocker","state":"CLOSED","blocking":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
	return 0
}
_der_collect_candidates() {
	jq -cn 'range(20;23) | {number:.,repository:{nameWithOwner:"owner/repo"}}'
	return 0
}
_der_reconcile_terminal_worker_blockers() { return 0; }
_der_try_unblock() {
	local repo="$1" number="$2"
	printf 'try %s %s\n' "$repo" "$number" >>"$CALLS"
	[[ "$number" != 21 ]] || return 1
	_DER_RESULT=unblocked
	return 0
}
rc=0
reconcile_dependants_after_verified_closure owner/repo 10 2>"$ROOT/closure.log" || rc=$?
[[ "$rc" == 3 ]]
[[ $(grep -c '' "$CALLS") == 3 ]]
grep -q 'dependants=3 unblocked=2 not_ready=0 held=0 failed=1' "$ROOT/closure.log"
grep -q 'issue=#21 status=1' "$ROOT/closure.log"
grep -qx 'issue 21' "$DER_RETRY_DIR/owner__repo.txt"

# Pre-collection failures retain the closure identity and a visible reason.
(
	DER_RETRY_DIR="$ROOT/early"
	_der_fetch_closed_context() { return 1; }
	rc=0
	reconcile_dependants_after_verified_closure owner/repo 10 2>"$ROOT/early.log" || rc=$?
	[[ "$rc" == 1 ]]
	grep -q 'reason=context_fetch' "$ROOT/early.log"
	grep -qx 'closure 10' "$DER_RETRY_DIR/owner__repo.txt"
)

# The retry and native-ready lanes precede the expensive REST body listing,
# even when the per-repo share has expired and only three seconds remain.
gh() {
	local command="$1" operation="$2" number="${3:-}"
	printf '%s\n' "$*" >>"$CALLS"
	if [[ "$command $operation" == 'issue view' ]]; then
		if [[ "$*" == *number,title,body,labels,updatedAt* ]]; then
			jq -cn --argjson n "$number" '{number:$n,title:"fixture",body:"",updatedAt:"v1",labels:[{name:"status:blocked"}]}'
		else
			printf 'status:blocked\n'
		fi
	elif [[ "$command $operation" == 'api repos/owner/repo/issues/'* ]]; then
		printf '{"body":""}\n'
	elif [[ "$command $operation" == 'api graphql' ]]; then
		# More than 300 blocked issues; only #22 has closed native blockers.
		jq -cn '[{data:{repository:{issues:{pageInfo:{hasNextPage:false},nodes:
			[range(1;351) | {number:.,updatedAt:"v1",labels:{nodes:[{name:"status:blocked"}],pageInfo:{hasNextPage:false}},blockedBy:{totalCount:1,
				nodes:[{number:99,state:(if . == 22 then "CLOSED" else "OPEN" end)}]}}]}}}}]'
	else
		return 1
	fi
	return 0
}
dsr_repoint_if_superseded() { return 0; }
_der_try_unblock() {
	local repo="$1" number="$2"
	printf 'try %s %s\n' "$repo" "$number" >>"$CALLS"
	NOW=$((NOW + 1))
	_DER_RESULT=held
	return 0
}
: >"$CALLS"
rc=0
DER_STALE_BLOCKED_DEADLINE_EPOCH=999 DER_STALE_BLOCKED_STOP_EPOCH=1003 \
	reconcile_stale_blocked_issues owner/repo 2>"$ROOT/sweep.log" || rc=$?
[[ "$rc" == 0 || "$rc" == "$DER_SWEEP_PARTIAL" ]]
grep -q 'try owner/repo 21' "$CALLS"
grep -q 'try owner/repo 22' "$CALLS"
if grep -q 'issues?state=open' "$CALLS"; then exit 1; fi
grep -q 'ready=1 ready_visited=1' "$ROOT/sweep.log"
[[ ! -e "$DER_RETRY_DIR/owner__repo.txt.pending" ]]

# An unchanged held ready candidate consumes neither another issue view nor
# another ready slot. The GraphQL timestamp invalidates this memo on change.
: >"$CALLS"
reconcile_stale_blocked_issues owner/repo 2>"$ROOT/memo.log"
if grep -q 'api repos/owner/repo/issues/22' "$CALLS"; then exit 1; fi
grep -q 'skipped_unchanged=1' "$ROOT/memo.log"

# Failed retry snapshots survive a hard stop and are consumed next cycle.
_der_retry_append owner/repo issue 23
rc=0
_der_retry_drain owner/repo 1 || rc=$?
[[ "$rc" == "$DER_SWEEP_PARTIAL" && -s "$DER_RETRY_DIR/owner__repo.txt.pending" ]]
_pulse_dependency_recovery_pending
_der_retry_drain owner/repo 0
[[ ! -e "$DER_RETRY_DIR/owner__repo.txt.pending" ]]
printf '0\n' >"$HOME/.aidevops/cache/stale-blocked-weight/owner__repo.ready"
[[ $(_pulse_stage_priority_class stale_blocked_reconcile) == deferrable ]]
printf '2\n' >"$HOME/.aidevops/cache/stale-blocked-weight/owner__repo.ready"
[[ $(_pulse_stage_priority_class stale_blocked_reconcile) == critical ]]
printf '0\n' >"$HOME/.aidevops/cache/stale-blocked-weight/owner__repo.ready"
_der_retry_append owner/repo closure 10
[[ $(_pulse_stage_priority_class stale_blocked_reconcile) == critical ]]
_der_retry_drain owner/repo 0 2>"$ROOT/replayed.log"
grep -q 'dependants=3 unblocked=0 not_ready=0 held=3 failed=0' "$ROOT/replayed.log"
[[ ! -e "$DER_RETRY_DIR/owner__repo.txt.pending" ]]
printf 'PASS: partial closure, retry recovery, ready-first deadlines, held memo and budget priority\n'
