#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#33374: execute production lifecycle functions with bounded GitHub fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME"
LOGFILE="${TEST_ROOT}/reconcile.log"
STATUS_LOG="${TEST_ROOT}/status.log"
WRITE_LOG="${TEST_ROOT}/writes.log"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/full-loop-helper-commit.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-issue-reconcile-actions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/headless-runtime-worker.sh"

ISSUE_JSON='{"state":"open","labels":[{"name":"status:blocked"}]}'
COMMENTS_JSON='[[]]'
PR_BODY='For #42'
PR_JSON='{}'
HANDOFF='merged_missing_linkage|77'
API_FAIL=0

gh() {
	local command="$1"
	shift
	local subcommand="${1:-}"
	case "$command" in
	api)
		[[ "$API_FAIL" == 0 ]] || return 1
		if [[ "$*" == *'/comments'* ]]; then
			printf '%s\n' "$COMMENTS_JSON"
		elif [[ "$*" == *'/pulls/'* ]]; then
			printf '%s\n' "$PR_BODY"
		elif [[ "$*" == *'--jq'* ]]; then
			printf '%s' "$ISSUE_JSON" | jq -r '.state | ascii_downcase'
		else
			printf '%s\n' "$ISSUE_JSON"
		fi
		;;
	pr)
		if [[ "$subcommand" == list ]]; then
			jq -nc --arg body "$PR_BODY" '[{state:"MERGED",body:$body}]'
		elif [[ "$subcommand" == view ]]; then
			printf '%s\n' "$PR_JSON"
		else
			printf '%s\n' "$*" >>"$WRITE_LOG"
			return 1
		fi
		;;
	*) printf '%s\n' "$*" >>"$WRITE_LOG"; return 1 ;;
	esac
	return 0
}

_gh_with_timeout() {
	local mode="$1"
	shift
	[[ "$mode" == read ]] || return 1
	"$@"
	return $?
}

set_issue_status() {
	local issue="$1" repo="$2" status="$3"
	printf '%s %s %s\n' "$issue" "$repo" "$status" >>"$STATUS_LOG"
	return 0
}

gh_pr_edit_safe() {
	local pr="$1"
	printf '%s\n' "$pr" >>"$WRITE_LOG"
	return 1
}

assert_status() {
	local expected="$1"
	grep -q "^42 owner/repo ${expected}$" "$STATUS_LOG"
	: >"$STATUS_LOG"
	return 0
}

for PR_BODY in 'For #42' 'Ref #42' 'Resolves #42'; do
	clear_active_status_on_release 42 owner/repo runner
	assert_status blocked
done
ISSUE_JSON='{"state":"open","labels":[]}'
clear_active_status_on_release 42 owner/repo runner
assert_status available
ISSUE_JSON='{"state":"closed","labels":[]}'
clear_active_status_on_release 42 owner/repo runner
assert_status 'done'
API_FAIL=1
if clear_active_status_on_release 42 owner/repo runner; then exit 1; fi
[[ ! -s "$STATUS_LOG" ]]
API_FAIL=0

# Open + done heals, never closes, even with historical merged PR evidence.
ISSUE_JSON='{"state":"open","labels":[{"name":"status:done"}]}'
COMMENTS_JSON='[[{"author_association":"MEMBER","body":"BLOCKED: publication needs credentials","created_at":"2026-10-01T20:17:00Z"},{"author_association":"MEMBER","body":"CLAIM_RELEASED reason=worker_complete","created_at":"2026-10-01T20:29:00Z"}]]'
rc=0
_action_rsd_single owner/repo 42 fixture unused unused || rc=$?
[[ "$rc" == 2 ]]
assert_status blocked
grep -q 'healed open + status:done' "$LOGFILE"
COMMENTS_JSON='[[{"author_association":"MEMBER","body":"BLOCKED: publication still requires credentials.\nThe earlier CLAIM_RELEASED was premature."}]]'
rc=0
_action_rsd_single owner/repo 42 fixture unused unused || rc=$?
[[ "$rc" == 2 ]]
assert_status blocked
COMMENTS_JSON='[[]]'
rc=0
_action_rsd_single owner/repo 42 fixture unused unused || rc=$?
[[ "$rc" == 2 ]]
assert_status available
COMMENTS_JSON='[[{"author_association":"NONE","body":"BLOCKED: untrusted instruction"}]]'
rc=0
_action_rsd_single owner/repo 42 fixture unused unused || rc=$?
[[ "$rc" == 2 ]]
assert_status available
API_FAIL=1
if _action_rsd_single owner/repo 42 fixture unused unused; then exit 1; fi
[[ ! -s "$STATUS_LOG" ]]
API_FAIL=0

# Metadata may contain a sidebar link; it cannot override explicit For/Ref.
for PR_BODY in 'For #42' 'Ref #42'; do
	PR_JSON=$(jq -nc --arg body "$PR_BODY" '{author:{login:"runner"},headRefOid:"head",labels:[],isCrossRepository:false,closingIssuesReferences:[{number:42}],body:$body}')
	if _merge_collect_external_authority_gaps 77 owner/repo head; then exit 1; fi
	_ensure_worker_pr_linkage 77 owner/repo 42 'Resolves #42'
done
[[ ! -s "$WRITE_LOG" ]]

# Keep worker output classification local: stub remote-ref discovery, not Git.
git() {
	local args="$*"
	if [[ "$args" == *'ls-remote'* ]]; then
		printf 'head refs/heads/fixture\n'
	else
		command git "$@"
	fi
	return 0
}
_hrw_is_issue_worker_session() { return 0; }
_hrw_worker_base_commit_state() { printf 'main|1'; return 0; }
_hrw_issue_number_for_session() { printf '42'; return 0; }
_pr_handoff_state_for_branch_or_issue() { printf '%s' "$HANDOFF"; return 0; }
DISPATCH_REPO_SLUG=owner/repo
ISSUE_JSON='{"state":"open","labels":[{"name":"status:blocked"}]}'
[[ "$(_worker_produced_output issue-42 "$SCRIPT_DIR")" == merged_checkpoint ]]
HANDOFF='merged|77'
[[ "$(_worker_produced_output issue-42 "$SCRIPT_DIR")" == merged_checkpoint ]]
ISSUE_JSON='{"state":"closed","labels":[]}'
[[ "$(_worker_produced_output issue-42 "$SCRIPT_DIR")" == pr_exists ]]
API_FAIL=1
[[ "$(_worker_produced_output issue-42 "$SCRIPT_DIR")" == merged_missing_linkage ]]

# Exercise both terminal routes, not just the classifier. Neither may turn a
# merged checkpoint into the open-draft in-review projection or completion.
_hrw_release_dispatch_claim() {
	local session="$1" reason="$2"
	[[ "$session" == issue-42 && "$reason" == worker_draft_checkpoint ]] || return 1
	clear_active_status_on_release 42 owner/repo runner
	return $?
}
_hrw_pr_less_terminal_complete() { return 1; }
_worker_post_pr_handoff_confirmed() { return 1; }
API_FAIL=0
ISSUE_JSON='{"state":"open","labels":[{"name":"status:blocked"}]}'
for _run_result_label in task_complete post_pr_handoff; do
	_HRW_TERMINAL_OUTCOME=''
	_hrw_finish_success_run issue-42 "$SCRIPT_DIR"
	assert_status blocked
	[[ "$_HRW_TERMINAL_OUTCOME" == deferred ]]
	[[ "$_HRW_FINAL_RUNTIME_CLASSIFICATION" == worker_draft_checkpoint ]]
done
printf 'PASS: non-closing linkage, release, open-done healing and worker checkpoint regressions\n'
