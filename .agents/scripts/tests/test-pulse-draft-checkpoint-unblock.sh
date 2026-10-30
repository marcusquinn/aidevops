#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36028: exercise the sourced production pass without GitHub writes.
# The production function is sourced first, then overridden for cycle-only tests.
# shellcheck disable=SC2218
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
LOGFILE="$ROOT/pulse.log"
API_LOG="$ROOT/api.log"
WRITE_LOG="$ROOT/write.log"
# shellcheck source=../pulse-merge-partial-continuation.sh
source "$TEST_DIR/../pulse-merge-partial-continuation.sh"
# shellcheck source=../pulse-draft-checkpoint-unblock.sh
source "$TEST_DIR/../pulse-draft-checkpoint-unblock.sh"

ISSUES="" PRS="" COMMENTS="" TIMELINE="" FAIL_READ="" EXPIRE_READ="" NOW=1000
reset_case() {
	ISSUES='[{"number":10,"state":"open","labels":[{"name":"status:blocked"}],"assignees":[{"login":"runner"}]}]'
	PRS='[{"number":20,"draft":true,"body":"Resolves #10","labels":[{"name":"origin:worker"}]}]'
	COMMENTS='[{"id":30,"author_association":"MEMBER","user":{"login":"runner"},"created_at":"2026-10-30T10:00:00Z","body":"CLAIM_RELEASED reason=worker_complete runner=runner"}]'
	TIMELINE='[{"id":40,"event":"labeled","label":{"name":"status:blocked"},"actor":{"login":"runner"},"created_at":"2026-10-30T10:00:07Z"}]'
	FAIL_READ="" EXPIRE_READ="" NOW=1000
	: >"$API_LOG"
	: >"$WRITE_LOG"
	return 0
}
date() {
	printf '%s\n' "$NOW"
	return 0
}
_pmpc_gh_read() {
	local verb="$1" endpoint="$2" kind=""
	[[ "$verb" == api ]] || return 1
	case "$endpoint" in
	*/issues\?*) kind=issues ;;
	*/pulls\?*) kind="prs" ;;
	*/comments\?*) kind=comments ;;
	*/timeline\?*) kind=timeline ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$kind" >>"$API_LOG"
	[[ "$kind" != "$FAIL_READ" ]] || return 1
	# File survives the command substitution, unlike an in-memory clock update.
	[[ "$kind" != "$EXPIRE_READ" ]] || touch "$ROOT/expired"
	case "$kind" in
	issues) printf '%s' "$ISSUES" ;;
	prs) printf '%s' "$PRS" ;;
	comments) printf '%s' "$COMMENTS" ;;
	timeline) printf '%s' "$TIMELINE" ;;
	esac
	return 0
}
set_issue_status() {
	printf 'status %s\n' "$*" >>"$WRITE_LOG"
	# Simulate the real status projection, so the next pass sees no candidate.
	ISSUES=$(printf '%s' "$ISSUES" | jq '.[0].labels = [{name:"status:available"}] | .[0].assignees = []')
	return 0
}
gh_issue_comment() {
	printf 'comment %s\n' "$*" >>"$WRITE_LOG"
	return 0
}
assert() {
	local description="$1"
	shift
	if ! "$@"; then
		printf 'FAIL: %s\n' "$description"
		exit 1
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}
reject() {
	local description="$1" rc=0
	_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000 || rc=$?
	assert "$description (no writes, rc=$rc)" test ! -s "$WRITE_LOG"
	return 0
}

# Prevent drift from the executable helper without sourcing its CLI/bootstrap.
pattern=$(awk -F "'" '/^_PCC_STALL_RELEASE_PATTERN=/{print $2}' "$TEST_DIR/../pr-checkpoint-continuation-helper.sh")
assert 'continuation reason set stays synchronized' test "$pattern" = "$_PDCU_RELEASE_PATTERN"
reset_case
_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
assert 'status and assignment projected together' grep -q 'status 10 owner/repo available --remove-assignee runner' "$WRITE_LOG"
assert 'one exact release audit marker' grep -q 'kind=draft-checkpoint-unblock pr=20 release=30 -->' "$WRITE_LOG"
assert 'one status and one comment write' test "$(wc -l <"$WRITE_LOG")" -eq 3
before=$(cksum "$WRITE_LOG")
_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
assert 'second pass is write-idempotent' test "$before" = "$(cksum "$WRITE_LOG")"

for reason in clean worker_draft_checkpoint no_activity wall_clock_stale stale_assignment_reset watchdog_kill:idle api_timeout io_stall; do
	reset_case
	COMMENTS=${COMMENTS/worker_complete/$reason}
	_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
	assert "eligible release $reason" test -s "$WRITE_LOG"
done
for reason in blocked push_policy_timeout network_policy_timeout worker_ownership_lost capability_limit; do
	reset_case
	COMMENTS=${COMMENTS/worker_complete/$reason}
	reject "excluded release $reason"
done
for label in hold-for-review no-auto-dispatch needs-maintainer-review needs-maintainer-permissions persistent parent-task status:in-progress; do
	reset_case
	ISSUES=$(printf '%s' "$ISSUES" | jq --arg label "$label" '.[0].labels += [{name:$label}]')
	reject "protective/conflicting label $label"
	assert 'protected issues stop after one read' test "$(wc -l <"$API_LOG")" -eq 1
done
for event in 'DISPATCH_CLAIM runner=runner' 'DISPATCH_LEASE phase=ready' 'Dispatching worker' 'Interactive session claimed'; do
	reset_case
	COMMENTS=$(printf '%s' "$COMMENTS" | jq --arg event "$event" '. + [.[0] | .id=31 | .created_at="2026-10-30T10:01:00Z" | .body=$event]')
	reject "newer ownership fence $event"
done
for association in NONE CONTRIBUTOR; do
	reset_case
	COMMENTS=$(printf '%s' "$COMMENTS" | jq --arg a "$association" '.[0].author_association=$a')
	reject "untrusted release $association"
done
for mutation in '.[0].user.login="other"' '.[0].updated_at="2026-10-30T10:01:00Z"' 'del(.[0].body)' 'del(.[0].created_at)' 'del(.[0].author_association)' '.[0].created_at="invalid"'; do
	reset_case
	COMMENTS=$(printf '%s' "$COMMENTS" | jq "$mutation")
	reject "unreadable/edited release $mutation"
done
for mutation in '.[0].actor.login="other"' '.[0].created_at="2026-10-30T09:58:59Z"' '.[0].created_at="2026-10-30T10:10:01Z"' 'del(.[0].actor)' 'del(.[0].label)' '.[0].created_at="invalid"' '. + [.[0] | .id=41 | .actor.login="other" | .created_at="2026-10-30T10:00:08Z"]'; do
	reset_case
	TIMELINE=$(printf '%s' "$TIMELINE" | jq "$mutation")
	reject "label evidence rejects $mutation"
done
for timestamp in 09:59:00 10:10:00; do
	reset_case
	TIMELINE=$(printf '%s' "$TIMELINE" | jq --arg t "2026-10-30T${timestamp}Z" '.[0].created_at=$t')
	_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
	assert "inclusive label window $timestamp" test -s "$WRITE_LOG"
done
for mutation in '.[0].assignees += [{login:"other"}]' 'del(.[0].assignees)' 'del(.[0].labels)' '.[0].labels=[{}]'; do
	reset_case
	ISSUES=$(printf '%s' "$ISSUES" | jq "$mutation")
	reject "issue guard $mutation"
done
reset_case
ISSUES=$(printf '%s' "$ISSUES" | jq '.[0].assignees=[]')
_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
assert 'unassigned released issue eligible' grep -q '^status 10 owner/repo available$' "$WRITE_LOG"
for mutation in '. + [.[0] | .number=21]' '.[0].draft=false' '.[0].labels=[]' '.[0].body="For #10"' 'del(.[0].body)' '[range(100) | {number:.,draft:true,body:"Fixes #10",labels:[]}]' '[]'; do
	reset_case
	PRS=$(printf '%s' "$PRS" | jq "$mutation")
	reject "draft matching $mutation"
	assert 'unmatched pair uses at most two reads' test "$(wc -l <"$API_LOG")" -le 2
done
for marker in '<!-- aidevops:ops kind=draft-checkpoint-unblock pr=20 release=30 -->' '<!-- aidevops:ops kind=draft-checkpoint-unblock pr=20 release=1 -->\n<!-- aidevops:ops kind=draft-checkpoint-unblock pr=20 release=2 -->\n<!-- aidevops:ops kind=draft-checkpoint-unblock pr=20 release=3 -->'; do
	reset_case
	# Three separate trusted comments, not three strings in one comment.
	COMMENTS=$(printf '%s' "$COMMENTS" | jq --arg marker "$marker" '. + [($marker | split("\\n")[]) as $body | .[0] | .id=29 | .body=$body]')
	reject 'release marker idempotency / per-PR fuse'
done
for kind in issues prs comments timeline; do
	reset_case
	FAIL_READ="$kind"
	reject "failed $kind read"
done
# Shape failures must remain retryable, not merely prevent the current write.
for kind in issues prs comments timeline; do
	reset_case
	case "$kind" in
	issues) ISSUES='{}' ;;
	prs) PRS=$(printf '%s' "$PRS" | jq 'del(.[0].draft)') ;;
	comments) COMMENTS='[{}]' ;;
	timeline) TIMELINE='[{}]' ;;
	esac
	rc=0
	_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000 || rc=$?
	assert "malformed $kind remains retryable" test "$rc" -eq 1
	assert 'malformed evidence prevents writes' test ! -s "$WRITE_LOG"
done
reset_case
ISSUES='[]'
_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000
assert 'empty repo uses one read' test "$(wc -l <"$API_LOG")" -eq 1
reset_case
NOW=2000
rc=0
_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000 || rc=$?
assert 'expired pass returns partial before any read' test "$rc" -eq 3
assert 'expired pass has no API calls' test ! -s "$API_LOG"

# Simulate deadline expiry after each API, including immediately before writes.
date() {
	if [[ -f "$ROOT/expired" ]]; then printf '2000\n'; else printf '1000\n'; fi
	return 0
}
for kind in issues prs comments timeline; do
	reset_case
	rm -f "$ROOT/expired"
	EXPIRE_READ="$kind"
	rc=0
	_pm_reconcile_draft_checkpoint_unblocks owner/repo 2000 || rc=$?
	assert "deadline after $kind returns partial" test "$rc" -eq 3
	assert 'deadline prevents writes' test ! -s "$WRITE_LOG"
done
unset -f date

# Exercise the actual cycle wiring: own stamp, deadline and partial retry.
# shellcheck source=../pulse-wrapper-cycle.sh
source "$TEST_DIR/../pulse-wrapper-cycle.sh"
HOME="$ROOT/home"
mkdir -p "$HOME/.aidevops/cache"
_file_mtime_epoch() {
	local file="$1"
	if [[ -f "$file" ]]; then date +%s; else printf '0\n'; fi
	return 0
}
reconcile_stale_blocked_issues() { return 0; }
_pm_reconcile_draft_checkpoint_unblocks() {
	local repo="$1" deadline="$2"
	printf '%s:%s\n' "$repo" "$deadline" >>"$ROOT/cycle"
	return "${CYCLE_RC:-0}"
}
now=$(date +%s)
_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now"
assert 'unblock completion has separate stamp' test -f "$HOME/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now"
assert 'fresh unblock pass skipped' test "$(wc -l <"$ROOT/cycle")" -eq 1
rm -f "$HOME/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
assert 'stale unblock stamp makes repo due' test ! -f "$HOME/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
if _pulse_stale_blocked_repo_all_fresh owner/repo 1800 "$now"; then
	printf 'FAIL: missing unblock stamp was hidden by dependency completion\n'
	exit 1
fi
CYCLE_RC=3 rc=0
_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now" || rc=$?
assert 'partial pass remains due' test "$rc" -eq 3
assert 'partial unblock not stamped' test ! -f "$HOME/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
CYCLE_RC=1 rc=0
_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now" || rc=$?
assert 'failed pass remains retryable' test "$rc" -eq 1
assert 'failed unblock not stamped' test ! -f "$HOME/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
printf 'All draft-checkpoint-unblock regression cases passed\n'
