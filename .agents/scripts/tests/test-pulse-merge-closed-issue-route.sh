#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Isolated runtime regression for GH#34531; no GitHub writes or worker launches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../pulse-merge-feedback-finalizer.sh"
source "${SCRIPT_DIR}/../pulse-merge-process.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_PULSE_FEEDBACK_FUSE_DIR="${TEST_ROOT}/fuse"
export AIDEVOPS_PULSE_RUNNER_ID="runner-a"
# login:permission pairs for the collaborator-permission API (GH#34605).
PERMISSIONS="other-runner:write outsider:read"
PERMISSION_LOOKUPS=0 PERMISSION_FAIL=0 DELETES=""
STATE="closed"
REASON="completed"
ISSUE_LABELS='[]'
PR_LABELS="origin:worker,conflict-feedback-routed"
HEAD="abc123repairsha"
WRITES=0 COMMENTS=0 DISPATCHES=0 FINISHED=0 FAIL_HOLD=0 COMMENT_NOOP=0
COMMENT_JSON='[]'
AFTER_COMMENT_HEAD="" AFTER_COMMENT_LABELS="" AFTER_HOLD_HEAD=""

gh() {
	local command="$1" endpoint="$2"
	[[ "$command" == "api" ]] || return 1
	case "$endpoint" in
	"repos/owner/repo/issues/42")
		jq -n --arg state "$STATE" --arg reason "$REASON" --argjson labels "$ISSUE_LABELS" \
			'{state:$state,state_reason:$reason,labels:$labels}'
		;;
	"repos/owner/repo/issues/100/comments?per_page=100")
		printf '%s\n' "$COMMENT_JSON"
		;;
	user)
		[[ "${IDENTITY_FAIL:-0}" == "0" ]] || return 1
		printf '7\tautomation\n'
		;;
	*) return 1 ;;
	esac
	return 0
}
# Stub the cached permission lookup; production uses pulse-merge-author-checks.sh.
_is_collaborator_author() {
	local author="$1" permission=""
	PERMISSION_LOOKUPS=$((PERMISSION_LOOKUPS + 1))
	[[ "$PERMISSION_FAIL" == "0" ]] || return 2
	permission=" ${PERMISSIONS} "
	[[ "$permission" == *" ${author}:"* ]] || return 1
	permission="${permission#*" ${author}:"}"
	permission="${permission%% *}"
	case "$permission" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}
reset_fuse() {
	rm -rf "$AIDEVOPS_PULSE_FEEDBACK_FUSE_DIR"
	return 0
}
_feedback_route_pr_snapshot() {
	printf 'OPEN\t%s\t%s\n' "$HEAD" "$PR_LABELS"
	return 0
}
_feedback_route_gh_write() {
	local target="$1" operation="$2" body="${7:-}"
	if [[ "$target" == "api" ]]; then
		DELETES="${DELETES} ${operation##*/}"
		return 0
	fi
	[[ "$target" == "pr" ]] || return 1
	WRITES=$((WRITES + 1))
	case "$operation" in
	comment)
		COMMENTS=$((COMMENTS + 1))
		[[ "$COMMENT_NOOP" == "0" ]] || return 0
		COMMENT_JSON=$(jq -n --arg body "$body" '{id:500,created_at:"2026-01-01T00:00:05Z",body:$body,user:{login:"automation",id:7},author_association:"CONTRIBUTOR"} | [.]')
		[[ -z "$AFTER_COMMENT_HEAD" ]] || HEAD="$AFTER_COMMENT_HEAD"
		[[ -z "$AFTER_COMMENT_LABELS" ]] || PR_LABELS="$AFTER_COMMENT_LABELS"
		;;
	edit)
		[[ "$FAIL_HOLD" == "0" ]] || return 1
		PR_LABELS="${PR_LABELS},hold-for-review"
		[[ -z "$AFTER_HOLD_HEAD" ]] || HEAD="$AFTER_HOLD_HEAD"
		;;
	*) return 1 ;;
	esac
	return 0
}
_dispatch_pr_repair_by_kind() {
	DISPATCHES=$((DISPATCHES + 1))
	return 0
}
_route_pr_feedback_terminal_guard() {
	return 0
}
_pulse_merge_queue_defer() {
	printf 'unexpected-defer\n' >>"${TEST_ROOT}/deferred"
	return 0
}
_pulse_merge_queue_finish() {
	FINISHED=$((FINISHED + 1))
	return 0
}
route() {
	local kind="$1" rc=0
	_route_pr_guard_and_dispatch_with_retry 1 100 owner/repo 42 "$kind" \
		"${kind}-feedback-routed" "Repair" '[]' || rc=$?
	[[ "$rc" == "76" ]] || return 1
	return 0
}

route conflict
route conflict
route ci
[[ "$COMMENTS" == "1" && "$WRITES" == "2" && "$DISPATCHES" == "0" && "$FINISHED" == "3" ]]
[[ ! -e "${TEST_ROOT}/deferred" ]]
printf 'PASS: completed closed issue held once across conflict/CI retries\n'

PR_LABELS="origin:worker"
COMMENT_JSON='[]'
reset_fuse
COMMENTS=0 WRITES=0
REASON="not_planned"
route ci
[[ "$COMMENTS" == "1" && "$WRITES" == "2" ]]
[[ "$COMMENT_JSON" == *"orphaned"* ]]
printf 'PASS: not-planned issue receives orphaned rationale\n'

PR_LABELS="origin:worker"
COMMENT_JSON='[]'
reset_fuse
COMMENTS=0
REASON="completed"
ISSUE_LABELS='[{"name":"consolidated"}]'
FAIL_HOLD=1
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$COMMENTS" == "1" ]]
FAIL_HOLD=0
route conflict
[[ "$COMMENTS" == "1" && "$COMMENT_JSON" == *"orphaned"* ]]
printf 'PASS: partial hold retries without duplicate comment\n'

PR_LABELS="origin:worker"
reset_fuse
COMMENTS=0 WRITES=0
COMMENT_JSON='[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha -->","user":{"login":"outsider","id":90},"author_association":"CONTRIBUTOR"},{"id":2,"created_at":"2026-01-01T00:00:01Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha -->","user":{"login":"automation","id":8},"author_association":"NONE"}]'
route conflict
[[ "$COMMENTS" == "1" ]]
printf 'PASS: receipt copied by a non-writer or a login impostor cannot suppress terminal comment\n'

# GH#34600: App read auth reports the runner's own comments as CONTRIBUTOR.
PR_LABELS="origin:worker"
reset_fuse
COMMENTS=0 WRITES=0 PERMISSION_LOOKUPS=0
COMMENT_JSON='[{"id":3,"created_at":"2026-01-01T00:00:00Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha -->","user":{"login":"automation","id":7},"author_association":"CONTRIBUTOR"}]'
route conflict
route conflict
[[ "$COMMENTS" == "0" && "$WRITES" == "1" && "$PR_LABELS" == *"hold-for-review"* && "$PERMISSION_LOOKUPS" == "0" ]]
printf 'PASS: own receipt read back as CONTRIBUTOR suppresses duplicate comment\n'

# GH#34605: another runner (write collaborator seen as CONTRIBUTOR) shares the
# receipt; the legacy marker without RUNNER is still accepted.
PR_LABELS="origin:worker"
COMMENTS=0 WRITES=0
COMMENT_JSON='[{"id":4,"created_at":"2026-01-01T00:00:00Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha -->","user":{"login":"other-runner","id":11},"author_association":"CONTRIBUTOR"}]'
route conflict
[[ "$COMMENTS" == "0" && "$WRITES" == "1" ]]
printf 'PASS: authorized receipt from another runner suppresses the comment\n'

# Permission API failure: the unverifiable receipt neither suppresses nor wins,
# and the local fuse still bounds this runner to one comment.
PR_LABELS="origin:worker"
reset_fuse
PERMISSION_FAIL=1 COMMENT_NOOP=1 COMMENTS=0 WRITES=0
COMMENT_JSON='[{"id":4,"created_at":"2026-01-01T00:00:00Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha -->","user":{"login":"other-runner","id":11},"author_association":"CONTRIBUTOR"}]'
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$COMMENTS" == "1" ]]
route conflict
route conflict
[[ "$COMMENTS" == "1" && "$PR_LABELS" == *"hold-for-review"* ]]
PERMISSION_FAIL=0 COMMENT_NOOP=0
printf 'PASS: invisible receipt and permission failure cannot repost (write fuse)\n'

# Concurrent receipts converge: the oldest authorized one wins and this runner
# deletes only its own later copy, never another runner's.
PR_LABELS="origin:worker,hold-for-review"
DELETES=""
COMMENT_JSON='[{"id":20,"created_at":"2026-01-01T00:00:00Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha:RUNNERb -->","user":{"login":"other-runner","id":11},"author_association":"CONTRIBUTOR"},{"id":21,"created_at":"2026-01-01T00:00:01Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha:RUNNERrunner-a -->","user":{"login":"automation","id":7},"author_association":"CONTRIBUTOR"},{"id":22,"created_at":"2026-01-01T00:00:02Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairsha:RUNNERc -->","user":{"login":"other-runner","id":11},"author_association":"CONTRIBUTOR"},{"id":23,"created_at":"2026-01-01T00:00:03Z","body":"<!-- feedback-route:closed-issue:PR100:ISSUE42:SHAabc123repairshaffff -->","user":{"login":"automation","id":7},"author_association":"CONTRIBUTOR"}]'
route conflict
[[ "$DELETES" == " 21" ]]
printf 'PASS: concurrent receipts converge by deleting only own duplicates\n'

# Unresolvable writer identity fails closed: no comment and no label.
PR_LABELS="origin:worker"
reset_fuse
COMMENT_JSON='[]'
IDENTITY_FAIL=1 WRITES=0
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$WRITES" == "0" ]]
IDENTITY_FAIL=0
printf 'PASS: unresolved writer identity does not write\n'


STATE="open"
WRITES=0 DISPATCHES=0
_route_pr_guard_and_dispatch_with_retry 0 100 owner/repo 42 conflict conflict-feedback-routed Repair '[]'
[[ "$WRITES" == "0" && "$DISPATCHES" == "1" ]]
printf 'PASS: open issue retains dispatch behaviour\n'

STATE="closed"
PR_LABELS="origin:interactive"
WRITES=0
route conflict
[[ "$WRITES" == "0" ]]
printf 'PASS: interactive ownership remains untouched\n'

PR_LABELS="origin:worker"
rc=0
_feedback_route_prepare_finalization_snapshot conflict 100 owner/repo 42 "$HEAD" || rc=$?
[[ "$rc" == "76" ]]
printf 'PASS: direct finalization also stops before closed-issue writes\n'

PR_LABELS="origin:worker"
COMMENT_JSON='[]'
reset_fuse
COMMENT_NOOP=1
WRITES=0
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$WRITES" == "1" && "$PR_LABELS" != *"hold-for-review"* ]]
COMMENT_NOOP=0
printf 'PASS: acknowledged comment without receipt is not terminal\n'
PR_LABELS="origin:worker"
reset_fuse

DRY_RUN=1
WRITES=0
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$WRITES" == "0" ]]
unset DRY_RUN
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict differenthead || rc=$?
[[ "$rc" == "75" && "$WRITES" == "0" ]]
printf 'PASS: dry-run and head drift do not mutate the PR\n'

AFTER_COMMENT_LABELS="origin:interactive"
COMMENT_JSON='[]'
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "76" && "$WRITES" == "1" && "$PR_LABELS" == "origin:interactive" ]]
AFTER_COMMENT_LABELS=""
printf 'PASS: ownership drift before label mutation preserves interactive PR\n'

PR_LABELS="origin:worker"
COMMENT_JSON='[]'
reset_fuse
WRITES=0
AFTER_COMMENT_HEAD="newhead123"
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" && "$WRITES" == "1" && "$PR_LABELS" == "origin:worker" ]]
AFTER_COMMENT_HEAD=""
AFTER_HOLD_HEAD="finalhead123"
rc=0
_feedback_route_guard_closed_issue 100 owner/repo 42 conflict || rc=$?
[[ "$rc" == "75" ]]
AFTER_HOLD_HEAD=""
route conflict
printf 'PASS: head drift at both write boundaries reclassifies before terminal success\n'

# GH#34600: automation-hold provenance shares the actor-pinned filter, so it
# must match the runner's own login under CONTRIBUTOR and nobody else's.
HOLD_COMMENTS='[[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"x<!-- m -->","user":{"login":"automation"},"author_association":"CONTRIBUTOR"},{"id":2,"created_at":"2026-01-01T00:00:01Z","body":"x<!-- m -->","user":{"login":"someone-else"},"author_association":"MEMBER"}]]'
gh() {
	[[ "$1" == "api" ]] || return 1
	printf '%s\n' "$HOLD_COMMENTS"
	return 0
}
hold_ids=$(_feedback_route_automation_hold_comments 42 owner/repo "<!-- m" " -->" automation | jq -c '[.[].id]')
[[ "$hold_ids" == "[1]" ]]
hold_ids=$(_feedback_route_automation_hold_comments 42 owner/repo "<!-- m" " -->" "" | jq -c '[.[].id]')
[[ "$hold_ids" == "[]" ]]
printf 'PASS: automation-hold comments match own login only, regardless of association\n'
