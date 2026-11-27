#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-partial-continuation.sh — GH#34312 regression guard.
#
# A merged worker PR with a non-closing `For #N` reference must return #N from
# the worker's in-review handoff to status:available (+ auto-dispatch for
# leaves) and release the runner, but only when the finished worker run is the
# newest owner, no hold label applies, and no other open PR references #N.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MODULE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge-partial-continuation.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SLUG="owner/repo"

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -z "$detail" ]] || printf '     %s\n' "$detail"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	STATUS_LOG="${TEST_ROOT}/status.log"
	COMMENT_LOG="${TEST_ROOT}/comments.log"
	COMMENT_ATTEMPTS="${TEST_ROOT}/comment-attempts.log"
	API_LOG="${TEST_ROOT}/api.log"
	UNFILTERED_LOG="${TEST_ROOT}/unfiltered.log"
	return 0
}

teardown_test_env() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

reset_case() {
	: >"$LOGFILE"
	: >"$STATUS_LOG"
	: >"$COMMENT_LOG"
	: >"$COMMENT_ATTEMPTS"
	: >"$API_LOG"
	: >"$UNFILTERED_LOG"
	TEST_AVAILABLE_ISSUES='[]'
	TEST_TARGET="501"
	TEST_CLOSING=""
	TEST_CLOSING_RC=0
	TEST_BODY_EDIT_RC=0
	TEST_GRAPHQL_RC=0
	TEST_GRAPHQL_JSON='{"data":{"repository":{"p900":{"number":900,"merged":true},"p901":{"number":901,"merged":false},"p902":{"number":902,"merged":false}}}}'
	TEST_CLOSING_950=""
	TEST_TARGET_960="777"
	TEST_PR_BODY_960_RC=0
	TEST_PR_TITLE_960="t777: other work"
	unset PULSE_PARTIAL_REVISIT_MAX_PRS
	TEST_PR_LABELS="origin:worker,tier:standard"
	TEST_PR_JSON=$(pr_json true runner1)
	TEST_PR_RC=0
	TEST_PERMISSION="write"
	TEST_COMMENT_RC=0
	TEST_COMMENT_FAILS=0
	TEST_COMMENTS_AFTER_ATTEMPT=""
	TEST_PR_BODY=$'Partial delivery: published the first edition.\n\nFor #501'
	TEST_PR_BODY_RC=0
	TEST_PR_TITLE="Partial delivery"
	TEST_PR_TITLE_RC=0
	TEST_OPEN_PRS="[]"
	TEST_OPEN_PR_PAGES=""
	TEST_OPEN_PRS_RC=0
	TEST_NOW=2000000000
	TEST_DEADLINE_AFTER_FIRST=0
	PULSE_PARTIAL_LEASE_GRACE_SECONDS=900
	PULSE_PARTIAL_RECONCILE_PAGE_SIZE=10
	unset PULSE_PARTIAL_RECONCILE_MAX_PAGES
	PULSE_PARTIAL_RECONCILE_STATE_DIR="${TEST_ROOT}/partial-cursor"
	if [[ -d "$PULSE_PARTIAL_RECONCILE_STATE_DIR" ]]; then
		printf '1\n' >"${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo"
	fi
	TEST_REVIEW_ISSUES='[{"number":501},{"number":502}]'
	TEST_REVIEW_PAGE2='[]'
	TEST_TIMELINE='[[{"event":"cross-referenced","source":{"issue":{"number":900,"repository_url":"https://api.github.com/repos/owner/repo","pull_request":{"merged_at":"2026-10-10T12:00:00Z"}}}}]]'
	TEST_ISSUE_JSON=$(issue_json "status:in-review,origin:worker,tier:standard" "runner1")
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1 ts=2026-10-10T10:20:00Z")")
	# GH#38355 closed checkpoint fixtures: release at 10:02, draft opened at
	# 10:00:30 and closed the next day; the checkpoint removed auto-dispatch at 10:01:30.
	TEST_CLOSED_PRS='[]'
	TEST_CLOSED_PRS_P2='[]'
	TEST_CLOSED_P2_RC=0
	PULSE_PARTIAL_MERGED_LOOKBACK_SECONDS=999999999
	# GH#39491: fixture merges predate the synthetic clock by years.
	PULSE_PARTIAL_MERGED_OVERLAP_SECONDS=999999999
	rm -f "${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.merged-page" \
		"${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.merged-walk" \
		"${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.recheck"
	unset PULSE_CLOSED_CHECKPOINT_PAGE_SIZE PULSE_CLOSED_CHECKPOINT_MAX_PAGES
	rm -f "${PULSE_PARTIAL_RECONCILE_STATE_DIR}/"*.closed-scan 2>/dev/null
	TEST_CLOSED_PR_JSON=$(closed_pr_json false 2026-10-11T00:00:00Z feature/auto-20261010-095500-gh501)
	TEST_EVENTS='[[{"event":"labeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T09:00:00Z"},{"event":"unlabeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T10:01:30Z"}]]'
	PULSE_CLOSED_CHECKPOINT_LOOKBACK_SECONDS=999999999
	return 0
}

# REST pulls/905 JSON for a closed worker checkpoint draft.
# Args: $1=merged (true|false), $2=closed_at, $3=head ref
closed_pr_json() {
	local merged="$1" closed_at="$2" ref="$3"
	jq -cn --argjson merged "$merged" --arg closed "$closed_at" --arg ref "$ref" '{
		number: 905, state: "closed", merged: $merged, draft: true,
		merged_at: (if $merged then $closed else null end),
		created_at: "2026-10-10T10:00:30Z", closed_at: $closed,
		head: {ref: $ref, sha: "abc", repo: {full_name: "owner/repo"}}
	}'
	return 0
}

# REST pulls/N JSON for the merged PR.
# Args: $1=merged (true|false), $2=author login
pr_json() {
	local merged="$1"
	local author="$2"
	jq -cn --argjson merged "$merged" --arg author "$author" '{
		number: 900, merged: $merged, state: (if $merged then "closed" else "open" end),
		user: {login: $author}
	}'
	return 0
}

# Args: $1=labels CSV, $2=assignees CSV, $3=body (optional; omitted when empty)
issue_json() {
	local labels="$1"
	local assignees="$2"
	local body="${3:-}"
	jq -cn --arg labels "$labels" --arg assignees "$assignees" --arg body "$body" '{
		number: 501, state: "open",
		labels: ($labels | split(",") | map(select(length > 0) | {name: .})),
		assignees: ($assignees | split(",") | map(select(length > 0) | {login: .}))
	} + (if $body == "" then {} else {body: $body} end)'
	return 0
}

# Args: $1=id (also orders created_at), $2=author_association, $3=login, $4=body
comment() {
	local comment_id="$1"
	local association="$2"
	local login="$3"
	local body="$4"
	jq -cn --argjson id "$comment_id" --arg assoc "$association" --arg login "$login" --arg body "$body" '{
		id: $id, author_association: $assoc, user: {login: $login},
		created_at: ("2026-10-10T10:" + (if $id < 10 then "0" else "" end) + ($id | tostring) + ":00Z"),
		body: ("<!-- ops:start -->\n" + $body + "\n<!-- ops:end -->")
	}'
	return 0
}

# Wrap comment objects as `gh api --paginate --slurp` pages (one page).
pages() {
	local joined=""
	joined=$(printf '%s\n' "$@" | jq -cs '.')
	printf '[%s]' "$joined"
	return 0
}

# --- stubs for pulse-merge.sh and shared wrapper dependencies ---
_pm_issue_api() {
	local slug="$1"
	local issue_num="$2"
	printf 'repos/%s/issues/%s' "$slug" "$issue_num"
	return 0
}

_extract_linked_issue() {
	printf '%s\n' "closing-read" >>"$API_LOG"
	[[ "$TEST_CLOSING_RC" -eq 0 ]] || return "$TEST_CLOSING_RC"
	if [[ "${1:-}" == "950" ]]; then
		printf '%s' "${TEST_CLOSING_950:-}"
		return 0
	fi
	printf '%s' "$TEST_CLOSING"
	return 0
}

_extract_pr_work_issue() {
	local pr_number="$1"
	if [[ "$pr_number" == "902" ]]; then
		printf '502'
		return 0
	fi
	# GH#39254: PR 960 is a merged non-closing `For #777` PR mentioning #501.
	if [[ "$pr_number" == "960" ]]; then
		printf '%s' "$TEST_TARGET_960"
		return 0
	fi
	[[ -n "$TEST_TARGET" ]] || return 1
	printf '%s' "$TEST_TARGET"
	return 0
}

gh_pr_view() {
	local args="$*"
	if [[ "$args" == *"--json labels"* ]]; then
		printf '%s' "$TEST_PR_LABELS"
		return 0
	fi
	if [[ "$args" == *"--json title"* ]]; then
		printf '%s\n' "pr-title $*" >>"$API_LOG"
		[[ "$TEST_PR_TITLE_RC" -eq 0 ]] || return "$TEST_PR_TITLE_RC"
		if [[ "$args" == "960 "* ]]; then
			printf '%s' "$TEST_PR_TITLE_960"
			return 0
		fi
		printf '%s' "$TEST_PR_TITLE"
		return 0
	fi
	# The module reads the merged PR body with --jq '.body // ""'.
	if [[ "$args" == *"--json body"* ]]; then
		printf '%s\n' "pr-body $*" >>"$API_LOG"
		[[ "$TEST_PR_BODY_RC" -eq 0 ]] || return "$TEST_PR_BODY_RC"
		if [[ "$args" == "902 "* ]]; then
			printf 'For #502'
			return 0
		fi
		if [[ "$args" == "960 "* ]]; then
			[[ "$TEST_PR_BODY_960_RC" -eq 0 ]] || return "$TEST_PR_BODY_960_RC"
			printf 'For #777\n\nResults continuation #501 remains open.'
			return 0
		fi
		printf '%s\n' "$TEST_PR_BODY"
		return 0
	fi
	return 1
}

feedback_test_gh() {
	local operation="${2:-}" filter_flag="${3:-}"
	if [[ "$operation" == graphql ]]; then
		[[ "$TEST_GRAPHQL_RC" -eq 0 ]] || return 1
		printf '%s' "$TEST_GRAPHQL_JSON"
	elif [[ "$filter_flag" == --jq ]]; then
		printf '%s' "$TEST_ISSUE_JSON" | jq -c '.body // ""'
	else
		printf '%s' "$TEST_ISSUE_JSON"
	fi
	return 0
}

gh() {
	printf '%s\n' "$*" >>"$API_LOG"
	case "${1:-} ${2:-}" in
	"api graphql"|"api repos/${SLUG}/issues/501") feedback_test_gh "$@"; return $? ;;
	esac
	if [[ "${2:-}" == "repos/${SLUG}/issues?state=open"* ]]; then
		# GH#38039: only label-filtered candidates are listed.
		if [[ "${2:-}" != *"labels="* ]]; then
			printf 'unfiltered issue listing\n' >>"$UNFILTERED_LOG"
			printf '[]'
		elif [[ "${2:-}" == *"labels=status:available"* ]]; then
			printf '%s' "$TEST_AVAILABLE_ISSUES"
		elif [[ "${2:-}" == *"&page=2" ]]; then
			printf '%s' "$TEST_REVIEW_PAGE2"
		elif [[ "${2:-}" == *"&page="[3-9] ]]; then
			printf '[]'
		else
			printf '%s' "$TEST_REVIEW_ISSUES"
		fi
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/issues/501/timeline"* ]]; then
		printf '%s' "$TEST_TIMELINE"
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/issues/502/timeline"* ]]; then
		printf '%s' "${TEST_TIMELINE//900/902}"
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/pulls/902" ]]; then
		pr_json true runner1
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/pulls?state=closed"* ]]; then
		# GH#38396: page=2 serves TEST_CLOSED_PRS_P2 (or fails); other pages TEST_CLOSED_PRS.
		if [[ "${2:-}" == *"&page=2" ]]; then
			[[ "$TEST_CLOSED_P2_RC" -eq 0 ]] || return "$TEST_CLOSED_P2_RC"
			printf '%s' "$TEST_CLOSED_PRS_P2"
		elif [[ "${2:-}" == *"&page=3" ]]; then
			printf '[]'
		else
			printf '%s' "$TEST_CLOSED_PRS"
		fi
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/pulls/905" ]]; then
		printf '%s' "$TEST_CLOSED_PR_JSON"
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/issues/501/events"* ]]; then
		printf '%s' "$TEST_EVENTS"
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/issues/502/comments"* ]]; then
		pages "$(comment 2 MEMBER runner1 "DISPATCH_LEASE phase=ready expires_at=2000001000")"
		return 0
	fi
	if [[ "${2:-}" == "repos/${SLUG}/issues/502" ]]; then
		issue_json "status:in-review" "runner1"
		return 0
	fi
	# Open-PR listing: `gh api --paginate --slurp` pages. TEST_OPEN_PRS is one
	# page; TEST_OPEN_PR_PAGES supplies several pages verbatim.
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/pulls?state=open"* ]]; then
		[[ "$TEST_OPEN_PRS_RC" -eq 0 ]] || return "$TEST_OPEN_PRS_RC"
		if [[ -n "$TEST_OPEN_PR_PAGES" ]]; then
			printf '%s' "$TEST_OPEN_PR_PAGES"
		else
			printf '[%s]' "$TEST_OPEN_PRS"
		fi
		return 0
	fi
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/pulls/900" ]]; then
		[[ "$TEST_PR_RC" -eq 0 ]] || return "$TEST_PR_RC"
		printf '%s' "$TEST_PR_JSON"
		return 0
	fi
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/collaborators/runner1/permission" ]]; then
		printf '%s' "$TEST_PERMISSION"
		return 0
	fi
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/issues/501/comments"* ]]; then
		# Models a comment write that errored client-side but landed server-side.
		if [[ -n "$TEST_COMMENTS_AFTER_ATTEMPT" && -s "$COMMENT_ATTEMPTS" ]]; then
			printf '%s' "$TEST_COMMENTS_AFTER_ATTEMPT"
			return 0
		fi
		printf '%s' "$TEST_COMMENTS_JSON"
		return 0
	fi
	return 1
}

date() {
	local arg="${1:-}"
	if [[ "$arg" == "+%s" ]]; then
		if [[ "$TEST_DEADLINE_AFTER_FIRST" -eq 1 ]] && grep -Fq 'issues/501/timeline' "$API_LOG"; then
			printf '2000000061\n'
			return 0
		fi
		printf '%s\n' "$TEST_NOW"
		return 0
	fi
	command date "$@"
	return $?
}

set_issue_status() {
	printf '%s\n' "$*" >>"$STATUS_LOG"
	return 0
}

gh_issue_edit_safe() {
	local issue_num="$1" repo_flag="$2" slug="$3" body_flag="$4" body="$5"
	[[ "$issue_num" == 501 && "$repo_flag" == --repo && "$slug" == "$SLUG" && "$body_flag" == --body ]] || return 1
	[[ "$TEST_BODY_EDIT_RC" -eq 0 ]] || return 1
	printf '%s' "$body" >"${TEST_ROOT}/edited-body"
	return 0
}

# TEST_COMMENT_RC fails every attempt; TEST_COMMENT_FAILS fails the first N.
gh_issue_comment() {
	local attempts=""
	printf '%s\n' "attempt" >>"$COMMENT_ATTEMPTS"
	attempts=$(wc -l <"$COMMENT_ATTEMPTS" | tr -d ' ')
	[[ "$TEST_COMMENT_RC" -eq 0 ]] || return "$TEST_COMMENT_RC"
	[[ "$attempts" -gt "$TEST_COMMENT_FAILS" ]] || return 1
	printf '%s\n' "$*" >>"$COMMENT_LOG"
	return 0
}

comment_attempts() {
	wc -l <"$COMMENT_ATTEMPTS" | tr -d ' '
	return 0
}

# Posted comment bodies span several lines; count markers, not lines.
posted_markers() {
	grep -c -- "kind=merged-partial-continuation pr=900 " "$COMMENT_LOG" || true
	return 0
}

# --- assertions ---
assert_status_call() {
	local expected="$1"
	local name="$2"
	local actual=""
	actual=$(cat "$STATUS_LOG")
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected status call [${expected}], saw [${actual}]"
	fi
	return 0
}

assert_no_write() {
	local name="$1"
	if [[ ! -s "$STATUS_LOG" && ! -s "$COMMENT_LOG" ]]; then
		pass "$name"
	else
		fail "$name" "unexpected write: $(tr '\n' ' ' <"$STATUS_LOG") $(tr '\n' ' ' <"$COMMENT_LOG")"
	fi
	return 0
}

assert_comment_contains() {
	local needle="$1"
	local name="$2"
	if grep -Fq -- "$needle" "$COMMENT_LOG"; then
		pass "$name"
	else
		fail "$name" "comment lacks [${needle}]: $(tr '\n' ' ' <"$COMMENT_LOG")"
	fi
	return 0
}

assert_log_contains() {
	local needle="$1"
	local name="$2"
	if grep -Fq -- "$needle" "$LOGFILE"; then
		pass "$name"
	else
		fail "$name" "log lacks [${needle}]: $(tr '\n' ' ' <"$LOGFILE")"
	fi
	return 0
}

# --- cases ---
test_unlabeled_worker_provenance() {
	reset_case
	TEST_PR_LABELS="tier:standard"
	TEST_PR_JSON=$(printf '%s' "$TEST_PR_JSON" | jq '. + {body: "<!-- aidevops:origin:worker -->", head: {ref: "feature/auto-20261108-155943-gh501"}}')
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" "unlabeled trusted worker returns to queue"
	reset_case
	TEST_PR_LABELS="tier:standard"
	TEST_PR_JSON=$(printf '%s' "$TEST_PR_JSON" | jq '. + {body: "<!-- aidevops:origin:worker -->", head: {ref: "feature/auto-20261108-155943-gh501"}}')
	TEST_PERMISSION="read"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "untrusted worker marker cannot release issue"
	TEST_PERMISSION="write"
	TEST_PR_JSON=$(printf '%s' "$TEST_PR_JSON" | jq '.head.ref = "feature/other"')
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "worker marker without worker branch cannot release issue"
	return 0
}

# GH#38042: marker-less worker PR proven by the author's own matching claim.
# Args: $1=claim author login, $2=claim line, $3=head ref (optional)
claim_case() {
	local claim_author="$1"
	local claim_line="$2"
	local branch="${3:-feature/auto-20261108-155943-gh501}"
	reset_case
	TEST_PR_LABELS="tier:standard"
	TEST_PR_JSON=$(printf '%s' "$TEST_PR_JSON" | jq --arg ref "$branch" '. + {body: "Partial work.\n\nFor #501", head: {ref: $ref}}')
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER "$claim_author" "$claim_line")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1 ts=2026-10-10T10:20:00Z")")
	return 0
}

test_claim_matched_worker_provenance() {
	local good="DISPATCH_CLAIM nonce=n1 runner=runner1 ts=2026-11-08T15:59:30Z max_age_s=600 session=issue-501 phase=prelaunch"
	claim_case runner1 "$good"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" "claim-matched marker-less worker returns to queue"
	claim_case runner2 "${good//runner1/runner2}"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "claim from a different login is refused"
	claim_case runner1 "${good//session=issue-501/session=issue-777}"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "claim for a different session is refused"
	claim_case runner1 "$good" "feature/auto-20261108-155943-gh777"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "claim on a different issue than the branch is refused"
	claim_case runner1 "${good//15:59:30Z/15:48:30Z}"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "claim more than 10 minutes from the branch is refused"
	claim_case runner1 "$good"
	TEST_PERMISSION="read"
	_pm_restore_partial_continuation 900 "$SLUG" "" "" 501
	assert_no_write "claim-matched author without write access is refused"
	return 0
}

set_origin_label() {
	printf 'origin %s\n' "$*" >>"$STATUS_LOG"
	return 0
}

test_unlabeled_worker_branch_merge_gate() {
	local good="DISPATCH_CLAIM nonce=n1 runner=runner1 ts=2026-11-08T15:59:30Z session=issue-501 phase=prelaunch"
	local info="" rc=0
	claim_case runner1 "${good//runner1/runner2}"
	info='{"headRefName":"feature/auto-20261108-155943-gh501","body":"For #501"}'
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "tier:standard" "$info" || rc=$?
	if [[ "$rc" -eq 1 && ! -s "$STATUS_LOG" ]]; then
		assert_log_contains "no provable worker provenance" "unprovable worker branch is not merged"
	else
		fail "unprovable worker branch is not merged" "rc=${rc} writes=$(tr '\n' ' ' <"$STATUS_LOG")"
	fi
	claim_case runner1 "$good"
	rc=0
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "tier:standard" "$info" || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		assert_status_call "origin 900 ${SLUG} worker --pr" "proven worker branch is relabelled and deferred"
	else
		fail "proven worker branch is relabelled and deferred" "rc=${rc}"
	fi
	# GH#40524: -sN continuation heads prove against the stem's claim.
	local info_s2='{"headRefName":"feature/auto-20261108-155943-gh501-s2","body":"For #501"}'
	claim_case runner1 "$good"
	rc=0
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "tier:standard" "$info_s2" || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		assert_status_call "origin 900 ${SLUG} worker --pr" "proven -s2 continuation branch is relabelled"
	else
		fail "proven -s2 continuation branch is relabelled" "rc=${rc}"
	fi
	claim_case runner1 "${good//runner1/runner2}"
	rc=0
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "tier:standard" "$info_s2" || rc=$?
	if [[ "$rc" -eq 1 && ! -s "$STATUS_LOG" ]]; then
		pass "unprovable -s2 continuation branch is still skipped"
	else
		fail "unprovable -s2 continuation branch is still skipped" "rc=${rc}"
	fi
	reset_case
	rc=0
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "origin:worker" "$info" || rc=$?
	_pm_gate_unlabeled_worker_branch 900 "$SLUG" runner1 "tier:standard" '{"headRefName":"bugfix/x","body":""}' || rc=$?
	if [[ "$rc" -eq 0 && ! -s "$STATUS_LOG" ]]; then
		pass "labelled or non-worker branches pass through unchanged"
	else
		fail "labelled or non-worker branches pass through unchanged" "rc=${rc}"
	fi
	return 0
}

test_eligible_leaf_returns_to_queue() {
	reset_case
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker,tier:standard"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"eligible leaf: available + auto-dispatch + runner released"
	assert_comment_contains "kind=merged-partial-continuation pr=900 " \
		"eligible leaf: idempotency marker recorded"
	assert_comment_contains "<!-- ops:start" "eligible leaf: comment is an ops audit block"
	return 0
}

test_parent_tracker_skips_auto_dispatch() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review,parent-task" "runner1")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1" \
		"parent-task tracker: available + runner released, no auto-dispatch"
	return 0
}

test_terminal_lease_proves_finished_run() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 MEMBER runner1 "DISPATCH_LEASE phase=terminal lease_token=[redacted] session=issue-501 expires_at=0")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"terminal lease without CLAIM_RELEASED: finished run releases"
	return 0
}

test_labels_fetched_when_not_supplied() {
	reset_case
	_pm_restore_partial_continuation 900 "$SLUG" ""
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"omitted PR labels: fetched and honoured"
	return 0
}

test_live_dispatch_keeps_review() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")" \
		"$(comment 2 MEMBER runner2 "Dispatching worker (deterministic).")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "newer live dispatch: no write"
	return 0
}

test_interactive_claim_keeps_review() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")" \
		"$(comment 2 OWNER runner1 "> Interactive session claimed by @runner1 on host.")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "newer interactive claim: no write"
	return 0
}

test_ownership_lost_keeps_review() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_ownership_lost runner=runner1 ts=2026-10-10T10:02:00Z")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "ownership-lost release preserves the live owner: no write"
	return 0
}

test_untrusted_release_is_ignored() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 NONE outsider "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=outsider")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "untrusted release comment: no write"
	return 0
}

test_hold_label_keeps_review() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review,hold-for-review" "runner1")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "hold-for-review: no write"
	return 0
}

test_non_review_status_is_untouched() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:blocked" "runner1")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "status:blocked target: no write"
	return 0
}

test_foreign_assignee_keeps_review() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review" "runner1,maintainer")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "foreign assignee: no write"
	return 0
}

test_other_open_pr_keeps_review() {
	reset_case
	TEST_OPEN_PRS='[{"number":901,"body":"Continuation.\n\nFor #501"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "another open For PR: no write"
	return 0
}

test_unrelated_open_pr_mention_is_ignored() {
	reset_case
	TEST_OPEN_PRS='[{"number":902,"body":"Mentions #5012 and issue 501 in prose only"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"open PR without a keyword reference: still restores"
	return 0
}

test_pr_lookup_failure_fails_closed() {
	reset_case
	TEST_OPEN_PRS_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "open PR lookup failure: no write"
	return 0
}

test_existing_marker_is_idempotent() {
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")" \
		"$(comment 2 MEMBER runner1 "<!-- aidevops:ops kind=merged-partial-continuation pr=900 -->")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "existing marker for this PR: no write"
	return 0
}

test_closing_target_is_noop() {
	reset_case
	_pm_restore_partial_continuation 900 "$SLUG" "501" "origin:worker"
	if [[ ! -s "$API_LOG" ]]; then
		pass "closing target: no lookups"
	else
		fail "closing target: no lookups" "$(tr '\n' ' ' <"$API_LOG")"
	fi
	assert_no_write "closing target: no write"
	return 0
}

test_non_worker_pr_is_noop() {
	reset_case
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:interactive"
	assert_no_write "origin:interactive PR: no write"
	return 0
}

test_ambiguous_reference_is_noop() {
	reset_case
	TEST_TARGET=""
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "ambiguous/no explicit reference: no write"
	return 0
}

# t2449: ambiguous explicit references must produce a specific deny reason,
# not the generic "trust metadata unavailable" text.
test_ambiguous_reference_verdict_reason() {
	local verdict=""
	verdict=$(
		_PULSE_MERGE_PROCESS_WORKER_BRIEFED_LOADED=""
		# Use the same explicit-reference parser as the production merge path.
		# shellcheck source=../gh-closing-reference-lib.sh
		source "${MODULE_FILE%/*}/gh-closing-reference-lib.sh"
		# shellcheck source=../pulse-merge-process-worker-briefed.sh
		source "${MODULE_FILE%/*}/pulse-merge-process-worker-briefed.sh"
		gh_pr_view() {
			printf '%s' '{"labels":[{"name":"origin:worker"}],"isDraft":false,"headRefOid":"abc","body":"Ref #21729\nRef #19530"}'
			return 0
		}
		_pulse_is_trusted_issue_sync_pr() { return 1; }
		_extract_pr_work_issue() { return 2; }
		worker_briefed_trust_verdict 900 "$SLUG" || true
	)
	if [[ "$verdict" == deny:*"ambiguous explicit issue references"*"#19530, #21729"* && "$verdict" != *"trust metadata unavailable"* ]]; then
		pass "ambiguous explicit refs: specific deny reason"
	else
		fail "ambiguous explicit refs: specific deny reason" "got: $verdict"
	fi
	return 0
}

test_corroborated_partial_target() {
	local body="" title=""
	for title in 't501: partial delivery' 'GH#501: partial delivery'; do
		for body in $'## Remaining\nFor #501' 'People phase (data only). For #501' 'For #501. For #777.' \
			$'<!-- hidden\n> -->\nFor #501'; do
			reset_case
			TEST_TARGET=""
			TEST_PR_TITLE="$title"
			TEST_PR_BODY="$body"
			_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker" 501
			assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
				"corroborated ${title}: [${body//$'\n'/ }] restores only title target"
		done
	done
	reset_case
	TEST_TARGET=777
	TEST_PR_TITLE='t501: partial delivery'
	TEST_PR_BODY=$'For #777\n## Remaining\nRef #501'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker" 501
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"periodic explicit mismatch: corroborated expected target restores"
	reset_case
	TEST_TARGET=""
	TEST_PR_TITLE='t501: partial delivery'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker" 777
	assert_no_write "corroborated title does not match periodic target: no write"
	reset_case
	TEST_TARGET=""
	TEST_PR_TITLE='t501: partial delivery'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"merge-time fallback without expected target restores"
	return 0
}

test_uncorroborated_partial_target_is_noop() {
	local body="" title=""
	for body in 'For #777' 'For #5012' 'Ref #501suffix' \
		$'## Remaining\n> For #501' $'```text\nFor #501\n```' \
		$'```text\n    ```\nFor #501\n```' \
		$'~~~~\nFor #501\n~~~\nRef #501\n~~~~' \
		'<!-- For #501 -->' $'<!-- hidden\nFor #501\n-->' \
		$'    For #501' $'For #501\nCloses: #777'; do
		reset_case
		TEST_TARGET=""
		TEST_PR_TITLE='t501: partial delivery'
		TEST_PR_BODY="$body"
		_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
		assert_no_write "uncorroborated or closing [${body//$'\n'/ }]: no write"
	done
	for title in 'Other t501: partial' 't501suffix' 'GH#501suffix' ''; do
		reset_case
		TEST_TARGET=""
		TEST_PR_TITLE="$title"
		_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
		assert_no_write "non-target title [${title}]: no write"
	done
	reset_case
	TEST_TARGET=""
	TEST_PR_TITLE_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "unreadable fallback title: no write"
	return 0
}

test_unconfirmed_merge_keeps_review() {
	reset_case
	TEST_PR_JSON=$(pr_json false runner1)
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "merge still in progress (PR not merged): no write"
	assert_log_contains "merge not confirmed" "merge still in progress: skip is logged"
	return 0
}

test_pr_read_failure_fails_closed() {
	reset_case
	TEST_PR_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "merged-state read failure: no write"
	return 0
}

# The open-PR scan reads every REST page; a full first page is not the end.
test_open_pr_scan_reads_every_page() {
	local full_page=""
	full_page=$(jq -cn '[range(0; 100) | {number: (1000 + .), body: "Mentions #501 in prose only"}]')
	reset_case
	TEST_OPEN_PR_PAGES="[${full_page},[{\"number\":1100,\"body\":\"Continuation.\\n\\nRef #501\"}]]"
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "reference on the second open-PR page: no write"
	if grep -Fq "pulls?state=open&per_page=100 --paginate --slurp" "$API_LOG"; then
		pass "open-PR scan requests complete pagination"
	else
		fail "open-PR scan requests complete pagination" "$(tr '\n' ' ' <"$API_LOG")"
	fi
	reset_case
	TEST_OPEN_PR_PAGES="[${full_page},[{\"number\":1100,\"body\":null}]]"
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"two open-PR pages without a reference: restores"
	reset_case
	TEST_OPEN_PR_PAGES="[${full_page},[{\"number\":1100}]]"
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "unreadable entry on a later open-PR page: no write"
	return 0
}

# _extract_linked_issue parses only `keyword #N`; GitHub also closes `Closes: #N`,
# GH-N, owner/repo#N and issue URLs. Such a PR completes work: no continuation.
test_unparsed_closing_reference_is_noop() {
	local body=""
	for body in $'For #501\n\nFixes owner/repo#777' \
		$'For #501\n\nCloses https://github.com/other/repo/issues/12' \
		$'For #501\n\nResolves: #777' \
		$'For #501\n\nfixes GH-777'; do
		reset_case
		TEST_PR_BODY="$body"
		_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
		assert_no_write "PR body closes [${body//$'\n'/ }]: no write"
		assert_log_contains "body closes an issue" "closing body logged distinctly"
		if grep -Fq "issues/501" "$API_LOG"; then
			fail "PR body closes [${body//$'\n'/ }]: no issue lookups" "$(tr '\n' ' ' <"$API_LOG")"
		else
			pass "PR body closes [${body//$'\n'/ }]: no issue lookups"
		fi
	done
	reset_case
	TEST_PR_BODY=$'For #501\n\nFollow-up to owner/repo#777; the prefix: #9 note is prose'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"non-closing qualified mention: still restores"
	reset_case
	TEST_PR_BODY_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "PR body read failure: no write"
	assert_log_contains "body unreadable" "unreadable body is logged distinctly"
	return 0
}

test_recent_merged_scan_outside_traversal() {
	reset_case
	mkdir -p "$PULSE_PARTIAL_RECONCILE_STATE_DIR"
	printf 'a9\n' >"${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo"
	TEST_REVIEW_ISSUES='[]'
	TEST_CLOSED_PRS='[{"number":900,"merged_at":"2026-10-10T12:00:00Z","updated_at":"2026-10-10T12:00:00Z"}]'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"recent merged PR restores outside the in-review traversal window"
	return 0
}

# GH#39491: rows the guard would reject from their own body and labels are
# dropped from the listing without a per-PR read; candidates still reach it.
test_recent_merged_prefilter_skips_reads() {
	local merged='"merged_at":"2026-10-10T12:00:00Z","updated_at":"2026-10-10T12:00:00Z"'
	local reads=""
	reset_case
	mkdir -p "$PULSE_PARTIAL_RECONCILE_STATE_DIR"
	TEST_CLOSED_PRS="[{\"number\":910,${merged},\"body\":\"Fixes: owner/repo#600\",\"labels\":[{\"name\":\"origin:worker\"}]},"
	TEST_CLOSED_PRS+="{\"number\":911,${merged},\"body\":\"For #600\",\"labels\":[{\"name\":\"origin:interactive\"}]},"
	TEST_CLOSED_PRS+="{\"number\":900,${merged},\"body\":\"For #501\",\"labels\":[{\"name\":\"origin:worker\"},{\"name\":\"origin:interactive\"}]}]"
	_pmpc_reconcile_recent_merges "$SLUG" 2000000060 || fail "prefilter: walk completes" "rc=$?"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"prefilter: worker partial still restores"
	reads=$(grep -c '^closing-read$' "$API_LOG")
	if [[ "$reads" == "1" ]]; then
		pass "prefilter: closing and foreign-origin rows make no guard reads"
	else
		fail "prefilter: closing and foreign-origin rows make no guard reads" "closing reads=${reads}"
	fi
	return 0
}

# GH#39491: a completed walk bounds the next one, and a cursor left without walk
# state (pre-GH#39491) restarts at page 1 instead of resuming deep history.
test_recent_merged_walk_is_incremental() {
	local walk="${TEST_ROOT}/partial-cursor/owner__repo.merged-walk"
	reset_case
	mkdir -p "$PULSE_PARTIAL_RECONCILE_STATE_DIR"
	printf '7\n' >"${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.merged-page"
	TEST_CLOSED_PRS='[{"number":900,"merged_at":"2026-10-10T12:00:00Z","updated_at":"2026-10-10T12:00:00Z"}]'
	_pmpc_reconcile_recent_merges "$SLUG" 2000000060 || fail "incremental: first walk completes" "rc=$?"
	if grep -q 'pulls?state=closed.*&page=1$' "$API_LOG" && ! grep -q '&page=7$' "$API_LOG"; then
		pass "incremental: legacy cursor restarts at page 1"
	else
		fail "incremental: legacy cursor restarts at page 1" "$(tr '\n' ' ' <"$API_LOG")"
	fi
	if grep -qx "completed=${TEST_NOW}" "$walk" && ! grep -q '^start=' "$walk"; then
		pass "incremental: completed walk is recorded"
	else
		fail "incremental: completed walk is recorded" "$(tr '\n' ' ' <"$walk")"
	fi
	: >"$STATUS_LOG"
	: >"$API_LOG"
	PULSE_PARTIAL_MERGED_OVERLAP_SECONDS=3600
	_pmpc_reconcile_recent_merges "$SLUG" 2000000060 || fail "incremental: second walk completes" "rc=$?"
	if [[ ! -s "$STATUS_LOG" ]] && ! grep -q '^closing-read$' "$API_LOG"; then
		pass "incremental: merges before the previous walk are left to the in-review traversal"
	else
		fail "incremental: merges before the previous walk are left to the in-review traversal" "$(tr '\n' ' ' <"$API_LOG")"
	fi
	return 0
}

test_parent_tracker_drops_existing_auto_dispatch() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review,parent-task,auto-dispatch" "runner1")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --remove-label auto-dispatch" \
		"parent-task tracker carrying auto-dispatch: ends without it"
	return 0
}

test_takeover_runner_differs_from_author() {
	reset_case
	TEST_PR_JSON=$(pr_json true taker)
	TEST_ISSUE_JSON=$(issue_json "status:in-review,origin:worker-takeover" "runner1,taker")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker-takeover"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --remove-assignee taker --add-label auto-dispatch" \
		"takeover: released runner and PR author are both released"
	return 0
}

test_comment_failure_is_logged() {
	reset_case
	TEST_COMMENT_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"audit comment failure: status transition still applied"
	assert_log_contains "audit comment failed and no retry confirmed it" \
		"audit comment failure: retried once, missing marker logged"
	if [[ "$(comment_attempts)" == "2" ]]; then
		pass "audit comment failure: exactly one retry"
	else
		fail "audit comment failure: exactly one retry" "attempts=$(comment_attempts)"
	fi
	return 0
}

# Upstream closing-target read failed (caller passes ""), but the PR closes an
# issue: the explicit resolver would return that closing target first.
test_empty_caller_target_rechecks_closing() {
	reset_case
	TEST_CLOSING="777"
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "empty caller target but PR closes an issue: no write"
	if grep -Fq "issues/" "$API_LOG"; then
		fail "empty caller target but PR closes an issue: no issue lookups" "$(tr '\n' ' ' <"$API_LOG")"
	else
		pass "empty caller target but PR closes an issue: no issue lookups"
	fi
	return 0
}

test_closing_read_failure_fails_closed() {
	reset_case
	TEST_CLOSING_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "closing-target read failure: no write"
	return 0
}

test_unreadable_assignees_fail_closed() {
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review" "" | jq -c '.assignees = [{}]')
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "assignee entry without a login: no write"
	reset_case
	TEST_ISSUE_JSON=$(issue_json "status:in-review" "" | jq -c 'del(.assignees)')
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "issue without an assignees list: no write"
	return 0
}

test_open_pr_entry_without_body_fails_closed() {
	reset_case
	TEST_OPEN_PRS='[{"number":903}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "open PR entry without a body field: no write"
	return 0
}

test_open_pr_null_body_is_empty() {
	reset_case
	TEST_OPEN_PRS='[{"number":904,"body":null}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"open PR with an empty (null) description: still restores"
	return 0
}

test_comment_retry_posts_one_marker() {
	reset_case
	TEST_COMMENT_FAILS=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_comment_contains "kind=merged-partial-continuation pr=900 " \
		"transient comment failure: retry records the marker"
	if [[ "$(comment_attempts)" == "2" && "$(posted_markers)" == "1" ]]; then
		pass "transient comment failure: one marker after one retry"
	else
		fail "transient comment failure: one marker after one retry" \
			"attempts=$(comment_attempts) posted=$(posted_markers)"
	fi
	return 0
}

test_landed_comment_is_not_duplicated() {
	reset_case
	TEST_COMMENT_FAILS=1
	TEST_COMMENTS_AFTER_ATTEMPT=$(pages "$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")" \
		"$(comment 2 MEMBER pulse "<!-- aidevops:ops kind=merged-partial-continuation pr=900 -->")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"comment error after the write landed: transition applied"
	if [[ "$(comment_attempts)" == "1" ]] && ! grep -Fq "audit comment failed" "$LOGFILE"; then
		pass "comment error after the write landed: no second marker"
	else
		fail "comment error after the write landed: no second marker" "attempts=$(comment_attempts)"
	fi
	return 0
}

# A newer trusted comment whose body or timestamp is missing could be a live
# dispatch; the older release must not authorize the write.
test_unreadable_comment_fails_closed() {
	local release=""
	release=$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")
	reset_case
	TEST_COMMENTS_JSON=$(pages "$release" "$(comment 2 MEMBER runner2 "Dispatching worker." | jq -c 'del(.body)')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "newer trusted comment without a body: no write"
	reset_case
	TEST_COMMENTS_JSON=$(pages "$release" "$(comment 2 MEMBER runner2 "Dispatching worker." | jq -c 'del(.created_at)')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "trusted comment without a timestamp: no write"
	reset_case
	TEST_COMMENTS_JSON=$(pages "$release" "$(comment 2 NONE outsider "note" | jq -c 'del(.author_association)')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "comment without an author association: no write"
	return 0
}

test_unreadable_reread_skips_retry() {
	reset_case
	TEST_COMMENT_FAILS=1
	TEST_COMMENTS_AFTER_ATTEMPT=$(pages "$(comment 1 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1")" \
		"$(comment 2 MEMBER pulse "audit" | jq -c 'del(.body)')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"unreadable comment re-read: transition kept"
	if [[ "$(comment_attempts)" == "1" ]]; then
		pass "unreadable comment re-read: retry skipped, no duplicate risk"
	else
		fail "unreadable comment re-read: retry skipped, no duplicate risk" "attempts=$(comment_attempts)"
	fi
	assert_log_contains "audit comment failed and no retry confirmed it" \
		"unreadable comment re-read: missing marker logged"
	return 0
}

test_qualified_open_pr_reference_keeps_review() {
	reset_case
	TEST_OPEN_PRS='[{"number":905,"body":"Fixes owner/repo#501"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "open PR closing owner/repo#501: no write"
	reset_case
	TEST_OPEN_PRS='[{"number":906,"body":"For https://github.com/Owner/Repo/issues/501"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "open PR with For <same-repo issue URL>: no write"
	reset_case
	TEST_OPEN_PRS='[{"number":907,"body":"Fixes other/repo#501 and see https://github.com/owner/repo/issues/5012"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"open PR referencing another repo's #501: still restores"
	reset_case
	TEST_OPEN_PRS='[{"number":908,"body":"For GH-501"}]'
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "open PR with For GH-501: no write"
	return 0
}

test_expired_lease_recovery() {
	local expiry="" event=""
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "DISPATCH_LEASE phase=ready expires_at=1999999099")")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"lease older than grace: releases"
	for expiry in 2000001000 1999999100 1999999500 missing garbage 1999990000bad; do
		reset_case
		TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "DISPATCH_LEASE phase=ready expires_at=${expiry}")")
		_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
		assert_no_write "live/grace/malformed expiry ${expiry}: no write"
	done
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready lease_token=redacted')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "missing expires_at: no write"
	for event in 'DISPATCH_CLAIM runner=runner2' 'Dispatching worker.' '> Interactive session claimed by @runner2' 'CLAIM_RELEASED reason=worker_ownership_lost runner=runner1'; do
		reset_case
		TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=1999990000')" \
			"$(comment 2 MEMBER runner1 "$event")")
		_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
		assert_no_write "newer ${event}: preserves owner"
	done
	reset_case
	PULSE_PARTIAL_LEASE_GRACE_SECONDS=2000
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=1999998500')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	assert_no_write "configured grace: protects recent expiry"
	return 0
}

test_periodic_pass() {
	local label="" rc=0
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=1999990000')")
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"periodic pass: expired zombie restored, live #502 untouched"
	TEST_COMMENTS_AFTER_ATTEMPT=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=1999990000')" \
		"$(comment 2 MEMBER pulse '<!-- aidevops:ops kind=merged-partial-continuation pr=900 -->')")
	: >"$STATUS_LOG"
	: >"$COMMENT_LOG"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "periodic second run: marker prevents repeat"
	for label in hold-for-review no-auto-dispatch needs-maintainer-review needs-maintainer-permissions persistent; do
		reset_case
		TEST_ISSUE_JSON=$(issue_json "status:in-review,${label}" runner1)
		_pm_reconcile_partial_continuations "$SLUG" 2000000060
		assert_no_write "periodic held ${label}: no write"
	done
	reset_case
	TEST_OPEN_PRS='[{"number":901,"body":"For #501"}]'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "periodic open PR: no write"
	reset_case
	TEST_PR_BODY=$'For #501\nCloses #777'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "periodic latest merged PR closes: no write"
	reset_case
	TEST_TARGET=777
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "periodic reference resolves to different target: no write"
	reset_case
	TEST_TIMELINE='not-json'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || rc=$?
	[[ "$rc" -eq 1 ]] && pass "unreadable timeline fails closed" || fail "unreadable timeline fails closed"
	assert_no_write "unreadable timeline: no write"
	# GH#39948: the in-review phase is one snapshot; available pages stay paged.
	reset_case
	PULSE_PARTIAL_RECONCILE_PAGE_SIZE=1
	PULSE_PARTIAL_RECONCILE_MAX_PAGES=1
	TEST_REVIEW_ISSUES='[]'
	TEST_AVAILABLE_ISSUES='[{"number":503,"labels":[{"name":"auto-dispatch"}]}]'
	rc=0
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || rc=$?
	[[ "$rc" -eq 3 ]] && pass "page budget: full page remains due" || fail "page budget: full page remains due"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	if grep -Fq 'labels=status:available,origin:worker&sort=created&direction=asc&per_page=1&page=2' "$API_LOG"; then
		pass "page budget: bounded pass resumes next page"
	else
		fail "page budget: bounded pass resumes next page"
	fi
	unset PULSE_PARTIAL_RECONCILE_MAX_PAGES
	return 0
}

# GH#38677: one call traverses while the deadline allows. GH#39948: the
# in-review set is one paginated snapshot, so restores cannot shift a page.
test_multi_page_traversal() {
	local rc=0 cursor="${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo"
	reset_case
	PULSE_PARTIAL_RECONCILE_PAGE_SIZE=1
	TEST_REVIEW_ISSUES='[[{"number":501}],[{"number":502}]]'
	rc=0
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -Fq 'issues/501/timeline' "$API_LOG" && grep -Fq 'issues/502/timeline' "$API_LOG"; then
		pass "deadline allows: one call processes both snapshot pages and completes"
	else
		fail "deadline allows: one call processes both snapshot pages and completes (rc=${rc})"
	fi
	if [[ "$(grep -c 'labels=status:in-review' "$API_LOG")" -eq 1 ]] && grep -q 'labels=status:in-review.*--paginate' "$API_LOG"; then
		pass "in-review snapshot: one paginated read, never a shifting page"
	else
		fail "in-review snapshot: one paginated read, never a shifting page"
	fi
	# A deadline after the first issue persists every unstarted snapshot issue.
	reset_case
	TEST_REVIEW_ISSUES='[[{"number":501}],[{"number":502}]]'
	TEST_DEADLINE_AFTER_FIRST=1
	rc=0
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || rc=$?
	if [[ "$rc" -eq 3 && "$(head -n 1 "$cursor")" == "a1" ]] && grep -qx '502' "$cursor" \
		&& ! grep -Fq 'issues/502/timeline' "$API_LOG"; then
		pass "deadline after the first issue: returns 3 and the cursor keeps the snapshot suffix"
	else
		fail "deadline after the first issue: returns 3 and the cursor keeps the snapshot suffix (rc=${rc})"
	fi
	TEST_DEADLINE_AFTER_FIRST=0
	reset_case
	rc=0
	_pm_reconcile_partial_continuations "$SLUG" 2000000000 || rc=$?
	[[ "$rc" -eq 3 ]] && pass "deadline defers pass" || fail "deadline defers pass"
	assert_no_write "deadline: no write"
	reset_case
	TEST_DEADLINE_AFTER_FIRST=1
	rc=0
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || rc=$?
	[[ "$rc" -eq 3 ]] && pass "mid-page deadline keeps pass due" || fail "mid-page deadline keeps pass due"
	TEST_DEADLINE_AFTER_FIRST=0
	: >"$API_LOG"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	if grep -Fq 'issues/502/timeline' "$API_LOG" && ! grep -Fq 'issues/501/timeline' "$API_LOG"; then
		pass "mid-page resume processes pending suffix without restarting first issue"
	else
		fail "mid-page resume processes pending suffix without restarting first issue"
	fi
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c '.[0] += [{event:"cross-referenced",source:{issue:{number:888,repository_url:"https://api.github.com/repos/owner/repo",pull_request:{merged_at:"2026-10-09T12:00:00Z"}}}}]')
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"periodic pass selects newest merged PR, not last timeline entry"
	# GH#38869: newest merged PR closes a sibling issue; older partial restores.
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c '.[0] += [{event:"cross-referenced",source:{issue:{number:950,repository_url:"https://api.github.com/repos/owner/repo",pull_request:{merged_at:"2026-10-11T12:00:00Z"}}}}]')
	TEST_CLOSING_950="777"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"periodic pass skips newest PR closing a sibling issue and restores"
	# Contrast: the newest PR closes this issue itself, so no restore.
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c '.[0] += [{event:"cross-referenced",source:{issue:{number:950,repository_url:"https://api.github.com/repos/owner/repo",pull_request:{merged_at:"2026-10-11T12:00:00Z"}}}}]')
	TEST_CLOSING_950="501"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "periodic pass does not restore when newest PR closes the issue"
	test_revisit_skips_other_target_prs
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:in-review,parent-task' runner1)
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1" \
		"periodic parent tracker: releases runner without auto-dispatch"
	return 0
}

# GH#39948: the snapshot drops rows the guard rejects from the listing alone
# (a hold, another status, an open-PR reference) with no timeline read. An
# unlabeled row, or every row when the open-PR listing fails, goes to the guard.
test_review_snapshot_prefilter() {
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501},{"number":502,"labels":[{"name":"status:in-review"},{"name":"hold-for-review"}]},{"number":503,"labels":["status:in-review","status:blocked"]},{"number":504}]'
	TEST_OPEN_PRS='[{"number":910,"body":"For #504"}]'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	if grep -Fq 'issues/501/timeline' "$API_LOG" && ! grep -Eq 'issues/50[234]/timeline' "$API_LOG"; then
		pass "snapshot prefilter: hold, other-status and open-PR rows make no timeline read"
	else
		fail "snapshot prefilter: hold, other-status and open-PR rows make no timeline read"
	fi
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"snapshot prefilter: an unlabeled row still restores"
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_OPEN_PRS_RC=1
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	if grep -Fq 'issues/501/timeline' "$API_LOG"; then
		pass "snapshot prefilter: unreadable open-PR listing keeps the candidate"
	else
		fail "snapshot prefilter: unreadable open-PR listing keeps the candidate"
	fi
	assert_no_write "snapshot prefilter: the guard still fails closed on the unreadable listing"
	return 0
}

# GH#39948: a lease still live at merge time, or an unconfirmed merge, arms a
# local recheck (an earlier one wins); a snapshot consumes it once due.
test_recheck_hint() {
	local hint="${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.recheck"
	reset_case
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=2000001000')")
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	[[ "$(cat "$hint" 2>/dev/null)" == 2000001901 ]] && pass "live lease arms a recheck after its grace" ||
		fail "live lease arms a recheck after its grace" "hint=$(cat "$hint" 2>/dev/null)"
	TEST_PR_JSON=$(pr_json false runner1)
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	TEST_PR_JSON=$(pr_json true runner1)
	_pm_restore_partial_continuation 900 "$SLUG" "" "origin:worker"
	[[ "$(cat "$hint" 2>/dev/null)" == 2000000600 ]] && pass "unconfirmed merge arms an earlier recheck, which wins" ||
		fail "unconfirmed merge arms an earlier recheck, which wins" "hint=$(cat "$hint" 2>/dev/null)"
	assert_no_write "armed rechecks: no write"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	[[ "$(cat "$hint" 2>/dev/null)" == 2000000600 ]] && pass "snapshot keeps a recheck that is not yet due" ||
		fail "snapshot keeps a recheck that is not yet due" "hint=$(cat "$hint" 2>/dev/null)"
	reset_case
	printf '1999999999\n' >"$hint"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060 || true
	# The due hint is consumed; live #502 (lease to 2000001000) re-arms it.
	[[ "$(cat "$hint" 2>/dev/null)" == 2000001901 ]] && pass "snapshot consumes a due recheck; a live lease re-arms it" ||
		fail "snapshot consumes a due recheck; a live lease re-arms it" "hint=$(cat "$hint" 2>/dev/null)"
	return 0
}

# GH#39254: a newer merged PR that only mentions the issue (For #777, or no
# target) is skipped so the older partial is revisited; a PR that may own the
# issue, or whose metadata is unreadable, still ends the walk without a write.
# Args: $1=PR 960 explicit target, $2=PR 960 title
revisit_with_newer_960() {
	local target="$1" title="$2"
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c '.[0] += [{event:"cross-referenced",source:{issue:{number:960,repository_url:"https://api.github.com/repos/owner/repo",pull_request:{merged_at:"2026-10-11T12:00:00Z"}}}}]')
	TEST_TARGET_960="$target"
	TEST_PR_TITLE_960="$title"
	return 0
}

test_revisit_skips_other_target_prs() {
	local target=""
	for target in 777 ""; do
		revisit_with_newer_960 "$target" "t777: other work"
		_pm_reconcile_partial_continuations "$SLUG" 2000000060
		assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
			"revisit skips newer PR targeting [${target:-none}] and restores from the older partial"
		assert_log_contains "skipped merged PR #960 in #501 revisit — it targets another issue or none (GH#39254)" \
			"revisit logs the skipped other-target PR [${target:-none}]"
	done
	revisit_with_newer_960 501 "t777: other work"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "newer PR explicitly targeting the issue ends the walk (guard decides)"
	revisit_with_newer_960 777 "t501: continuation"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "newer PR whose title names the issue ends the walk (guard decides)"
	revisit_with_newer_960 777 "t777: other work"
	TEST_PR_BODY_960_RC=1
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "newer PR with an unreadable body ends the walk without a write"
	revisit_with_newer_960 777 "t777: other work"
	PULSE_PARTIAL_REVISIT_MAX_PRS=1
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "walk cap stops before the older partial"
	assert_log_contains "stopped #501 revisit after 1 merged PRs" "walk cap is logged"
	test_revisit_uses_timeline_pr_fields
	return 0
}

# GH#39493: a timeline row carrying body/title spares the per-PR live reads.
# Args: $1=PR 960 timeline title
revisit_with_timeline_960_fields() {
	local title="$1"
	revisit_with_newer_960 777 "live title must not be read"
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c --arg t "$title" \
		'.[0] |= map(if .source.issue.number == 960 then .source.issue += {body:"For #777", title:$t} else . end)')
	return 0
}

test_revisit_uses_timeline_pr_fields() {
	revisit_with_timeline_960_fields "t777: other work"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"timeline body/title: skips newer other-target PR and restores from the older partial"
	if ! grep -Eq '^pr-(body|title) 960 ' "$API_LOG"; then
		pass "timeline body/title: no live body or title read for the skipped PR"
	else
		fail "timeline body/title: no live body or title read for the skipped PR"
	fi
	revisit_with_timeline_960_fields "t501: continuation"
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_no_write "timeline title naming the issue ends the walk (guard decides)"
	# A null timeline body is GitHub's empty body, not a missing field.
	revisit_with_newer_960 "" "live title must not be read"
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c \
		'.[0] |= map(if .source.issue.number == 960 then .source.issue += {body:null, title:"chore: no target"} else . end)')
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"null timeline body: untargeted newer PR is skipped without a live read"
	if ! grep -Eq '^pr-(body|title) 960 ' "$API_LOG"; then
		pass "null timeline body: no live body or title read"
	else
		fail "null timeline body: no live body or title read"
	fi
	return 0
}

test_available_dispatch_recovery() {
	local label="" marker=""
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' '')
	TEST_REVIEW_ISSUES='[]'
	TEST_AVAILABLE_ISSUES='[{"number":501,"labels":[{"name":"status:available"},{"name":"origin:worker"}]},{"number":503,"labels":[{"name":"auto-dispatch"}]}]'
	TEST_TIMELINE='[[]]'
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "sweep-restored available issue regains dispatch without merged timeline"
	# GH#38039: candidates only. No unfiltered listing, no timeline read, and an
	# available issue already carrying auto-dispatch is never read at all.
	if [[ ! -s "$UNFILTERED_LOG" ]] && ! grep -Fq '/timeline' "$API_LOG" && ! grep -Fq 'issues/503' "$API_LOG"; then
		pass "revisit reads only label-filtered candidates (no timeline or comment read for non-candidates)"
	else
		fail "revisit reads only label-filtered candidates (no timeline or comment read for non-candidates)"
	fi
	if grep -Fq 'labels=status:in-review' "$API_LOG" && grep -Fq 'labels=status:available,origin:worker' "$API_LOG"; then
		pass "revisit lists in-review then available worker candidates"
	else
		fail "revisit lists in-review then available worker candidates"
	fi
	if grep -q 'kind=available-dispatch-recovery' "$COMMENT_LOG"; then
		pass "available dispatch recovery records audit"
	else
		fail "available dispatch recovery records audit"
	fi
	for label in auto-dispatch no-auto-dispatch parent-task hold-for-review lockdown needs-maintainer-review needs-maintainer-permissions persistent status:in-progress; do
		reset_case
		TEST_ISSUE_JSON=$(issue_json "status:available,origin:worker,${label}" '')
		_pmpc_restore_available_dispatch "$SLUG" 501 || true
		assert_no_write "available recovery preserves ${label}"
	done
	for marker in 'cost-circuit-breaker:fired' 'worker-recovery-loop:blocked' 'dispatch-circuit-breaker:worker_recovery_loop' 'stale-recovery-tick:escalated' 'DISPATCH_CLAIM runner=runner2' 'DISPATCH_LEASE phase=ready expires_at=2000001000' 'CLAIM_RELEASED reason=worker_ownership_lost' 'CLAIM_RELEASED reason=blocked'; do
		reset_case
		TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' '')
		TEST_COMMENTS_JSON=$(pages "$(comment 3 MEMBER runner1 "$marker")")
		_pmpc_restore_available_dispatch "$SLUG" 501 || true
		assert_no_write "available recovery preserves ${marker}"
	done
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' '')
	TEST_COMMENTS_JSON=$(pages "$(comment 2 MEMBER runner1 '<!-- stale-recovery-tick:escalated -->')" \
		"$(comment 3 MEMBER runner1 '<!-- stale-recovery-release:verified -->')")
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "automatic recovery cannot infer maintainer permission from a copied release marker"
	TEST_COMMENTS_JSON='[[{"body":"unreadable coordination metadata"}]]'
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "available recovery fails closed on unreadable comments"
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' '')
	TEST_OPEN_PRS='[{"number":901,"body":"For #501","draft":true}]'
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "available recovery preserves open draft"
	TEST_OPEN_PRS='[{"number":901,"body":"Resolves #501","draft":false}]'
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "available recovery preserves ready PR"
	TEST_OPEN_PRS_RC=1
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "available recovery fails closed on PR read failure"
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' runner2)
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "available recovery preserves assigned issue"
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:interactive' '')
	_pmpc_restore_available_dispatch "$SLUG" 501 || true
	assert_no_write "periodic available recovery requires worker origin"
	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:available,origin:worker' '')
	TEST_COMMENTS_JSON=$(pages "$(comment 2 MEMBER runner1 'DISPATCH_LEASE phase=ready expires_at=1999990000')")
	_pmpc_restore_available_dispatch "$SLUG" 501
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "available recovery accepts expired lease"
	return 0
}

# GH#38355: a closed, unmerged checkpoint draft no longer holds its issue.
closed_checkpoint_case() {
	local labels="${1:-status:available,origin:interactive}" assignees="${2:-}"
	reset_case
	TEST_REVIEW_ISSUES='[]'
	TEST_ISSUE_JSON=$(issue_json "$labels" "$assignees")
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_draft_checkpoint runner=runner1 ts=2026-10-10T10:02:00Z")")
	TEST_CLOSED_PRS='[{"number":904,"merged_at":"2026-10-11T00:00:00Z","closed_at":"2026-10-11T00:00:00Z","head":{"ref":"feature/auto-20261010-095000-gh501","repo":{"full_name":"owner/repo"}}},{"number":905,"merged_at":null,"closed_at":"2026-10-11T00:00:00Z","head":{"ref":"feature/auto-20261010-095500-gh501","repo":{"full_name":"owner/repo"}}},{"number":906,"merged_at":null,"closed_at":"2026-10-11T00:00:00Z","head":{"ref":"bugfix/manual-gh501","repo":{"full_name":"owner/repo"}}}]'
	return 0
}

test_closed_checkpoint_dispatch_recovery() {
	local label=""
	closed_checkpoint_case
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" \
		"closed checkpoint draft restores auto-dispatch for any origin"
	assert_comment_contains "kind=closed-checkpoint-dispatch-recovery pr=905 " "closed checkpoint restore records audit"
	if grep -Fq 'pulls/906' "$API_LOG"; then
		fail "closed scans skip unmerged non-worker branches"
	else
		pass "closed scans skip unmerged non-worker branches"
	fi

	closed_checkpoint_case 'status:in-review,origin:interactive' runner1
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch --remove-assignee runner1" \
		"stranded in-review checkpoint releases its runner"
	closed_checkpoint_case 'status:in-review,origin:interactive' runner2
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "closed checkpoint keeps a different assignee"
	closed_checkpoint_case 'status:available,origin:interactive' runner1
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "closed checkpoint keeps an assigned available issue"

	for label in auto-dispatch no-auto-dispatch parent-task hold-for-review lockdown persistent needs-maintainer-review status:blocked; do
		closed_checkpoint_case "status:available,${label}"
		_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
		assert_no_write "closed checkpoint preserves ${label}"
	done

	closed_checkpoint_case
	TEST_OPEN_PRS='[{"number":907,"body":"Resolves #501"}]'
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "worker or seed replacement PR still owns the issue"
	closed_checkpoint_case
	TEST_CLOSED_PR_JSON=$(closed_pr_json true 2026-10-11T00:00:00Z feature/auto-20261010-095500-gh501)
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "merged checkpoint is left to the partial-continuation path"
	closed_checkpoint_case
	TEST_CLOSED_PR_JSON=$(closed_pr_json false 2026-10-10T10:01:00Z feature/auto-20261010-095500-gh501)
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "PR closed before the checkpoint release is not its checkpoint"
	closed_checkpoint_case
	TEST_CLOSED_PR_JSON=$(closed_pr_json false 2026-10-11T00:00:00Z feature/auto-20261010-095500-gh777)
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "PR for another issue is not this checkpoint"
	closed_checkpoint_case
	TEST_COMMENTS_JSON=$(pages "$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_draft_checkpoint runner=runner1 ts=x")" \
		"$(comment 3 MEMBER runner1 "DISPATCH_CLAIM runner=runner1")")
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "newer owner after the checkpoint release is preserved"
	closed_checkpoint_case
	TEST_COMMENTS_JSON=$(pages "$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_failed runner=runner1 ts=x")")
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "other release reasons are not checkpoints"
	closed_checkpoint_case
	TEST_COMMENTS_JSON=$(pages "$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_draft_checkpoint runner=runner1 ts=x")" \
		"$(comment 3 MEMBER pulse "<!-- aidevops:ops kind=closed-checkpoint-dispatch-recovery pr=905 -->")")
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "recorded restore is not repeated"
	closed_checkpoint_case
	TEST_EVENTS='[[{"event":"unlabeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T10:01:30Z"},{"event":"labeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T11:00:00Z"},{"event":"unlabeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T12:00:00Z"}]]'
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "a person's later removal of auto-dispatch is respected"
	closed_checkpoint_case
	TEST_EVENTS='[[{"event":"labeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T07:00:00Z"},{"event":"unlabeled","label":{"name":"auto-dispatch"},"created_at":"2026-10-10T08:30:00Z"}]]'
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "a person's removal during the run is respected"
	closed_checkpoint_case
	TEST_EVENTS='[[]]'
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "an issue that never had auto-dispatch does not gain it"
	closed_checkpoint_case
	TEST_EVENTS='not-json'
	_pmpc_restore_closed_checkpoint_dispatch "$SLUG" 501 905 || true
	assert_no_write "unreadable label timeline fails closed"
	return 0
}

# GH#38396: the closed-checkpoint scan pages until the floor and keeps a stamp.
test_closed_checkpoint_scan_pagination() {
	local stamp_file="${PULSE_PARTIAL_RECONCILE_STATE_DIR}/owner__repo.closed-scan"
	local manual='{"number":%s,"merged_at":null,"closed_at":"2026-10-11T00:00:00Z","updated_at":"2026-10-12T00:00:00Z","head":{"ref":"bugfix/manual","repo":{"full_name":"owner/repo"}}}'
	local p1="" p2=""
	p1="[$(printf "$manual" 910),$(printf "$manual" 911)]"
	p2='[{"number":905,"merged_at":null,"closed_at":"2026-10-11T00:00:00Z","updated_at":"2026-10-11T00:00:00Z","head":{"ref":"feature/auto-20261010-095500-gh501","repo":{"full_name":"owner/repo"}}}]'

	closed_checkpoint_case
	TEST_CLOSED_PRS="$p1"
	TEST_CLOSED_PRS_P2="$p2"
	PULSE_CLOSED_CHECKPOINT_PAGE_SIZE=2
	_pmpc_reconcile_closed_checkpoints "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" \
		"checkpoint PR only on page 2 restores auto-dispatch"
	if [[ -r "$stamp_file" && "$(<"$stamp_file")" == "2000000000" ]]; then
		pass "complete scan writes the stamp"
	else
		fail "complete scan writes the stamp"
	fi

	closed_checkpoint_case
	TEST_CLOSED_PRS="$p1"
	TEST_CLOSED_PRS_P2="$p2"
	PULSE_CLOSED_CHECKPOINT_PAGE_SIZE=2
	PULSE_CLOSED_CHECKPOINT_LOOKBACK_SECONDS=100
	_pmpc_reconcile_closed_checkpoints "$SLUG" 2000000060
	if grep -Fq '&page=2' "$API_LOG"; then
		fail "scan stops at the first page older than the floor"
	else
		pass "scan stops at the first page older than the floor"
	fi
	[[ -r "$stamp_file" ]] && pass "floor stop advances the stamp" || fail "floor stop advances the stamp"

	closed_checkpoint_case
	TEST_CLOSED_PRS="$p1"
	TEST_CLOSED_PRS_P2="$p2"
	PULSE_CLOSED_CHECKPOINT_PAGE_SIZE=2
	TEST_CLOSED_P2_RC=1
	_pmpc_reconcile_closed_checkpoints "$SLUG" 2000000060 || true
	[[ ! -e "$stamp_file" ]] && pass "unreadable page leaves the stamp unchanged" || fail "unreadable page leaves the stamp unchanged"

	closed_checkpoint_case
	TEST_CLOSED_PRS="$p1"
	TEST_CLOSED_PRS_P2="$p2"
	PULSE_CLOSED_CHECKPOINT_PAGE_SIZE=2
	_pmpc_reconcile_closed_checkpoints "$SLUG" 2000000000
	[[ ! -e "$stamp_file" ]] && pass "deadline stop leaves the stamp unchanged" || fail "deadline stop leaves the stamp unchanged"

	closed_checkpoint_case
	TEST_CLOSED_PRS="$p1"
	TEST_CLOSED_PRS_P2="$p2"
	PULSE_CLOSED_CHECKPOINT_PAGE_SIZE=2
	PULSE_CLOSED_CHECKPOINT_MAX_PAGES=1
	_pmpc_reconcile_closed_checkpoints "$SLUG" 2000000060
	[[ ! -e "$stamp_file" ]] && pass "page-cap stop leaves the stamp unchanged" || fail "page-cap stop leaves the stamp unchanged"
	return 0
}

# GH#38021: a draft checkpoint on a canonical consolidated spec gets back the
# auto-dispatch label that the same worker run removed, and nothing else does.
test_checkpoint_spec_dispatch_restore() {
	local label="" spec=$'_Supersedes #400 — this issue is the consolidated spec._\n\n## What\nFix it.'
	local before="" after=""
	before=$(issue_json 'status:in-progress,consolidated,auto-dispatch' runner1 "$spec")
	after=$(issue_json 'status:available,consolidated' '' "$spec")

	reset_case
	TEST_ISSUE_JSON="$before"
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON="$after"
	TEST_OPEN_PRS='[{"number":901,"body":"For #501","draft":true}]'
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "checkpoint spec regains dispatch beside its open draft"
	if [[ ! -s "$COMMENT_LOG" ]]; then
		pass "checkpoint spec restore posts no comment"
	else
		fail "checkpoint spec restore posts no comment"
	fi
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "checkpoint spec receipt is consumed on use"

	reset_case
	TEST_ISSUE_JSON="$after"
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "label removed before the checkpoint stays removed"

	reset_case
	TEST_ISSUE_JSON="$after"
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "restore without a receipt writes nothing"

	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:in-progress,consolidated,auto-dispatch' runner1 'Hand-written body.')
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON=$(issue_json 'status:available,consolidated' '' 'Hand-written body.')
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "consolidated issue without the canonical marker is not relabelled"

	reset_case
	TEST_ISSUE_JSON=$(issue_json 'status:in-progress,auto-dispatch' runner1 "$spec")
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON=$(issue_json 'status:available' '' "$spec")
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "ordinary issue is not relabelled"

	reset_case
	TEST_ISSUE_JSON='unreadable'
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON="$after"
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "unreadable pre-checkpoint state records no receipt"

	reset_case
	TEST_ISSUE_JSON="$before"
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON="$after"
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 502 || true
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "receipt for another issue is discarded without a write"

	for label in auto-dispatch no-auto-dispatch parent-task hold-for-review lockdown persistent needs-maintainer-review needs-simplification status:blocked; do
		reset_case
		TEST_ISSUE_JSON="$before"
		_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
		TEST_ISSUE_JSON=$(issue_json "status:available,consolidated,${label}" '' "$spec")
		_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
		assert_no_write "checkpoint spec restore preserves ${label}"
	done

	reset_case
	TEST_ISSUE_JSON="$before"
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON=$(issue_json 'status:available,consolidated' runner2 "$spec")
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_no_write "checkpoint spec restore preserves an assigned issue"

	reset_case
	TEST_ISSUE_JSON="$before"
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON=$(issue_json 'status:in-review,consolidated' '' "$spec")
	_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
	TEST_ISSUE_JSON="$after"
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "repeated escalation keeps the first receipt"
	return 0
}

# GH#38021: the restore reports its outcome, and a deferred release replay in
# another process adopts the recording run's receipt.
test_checkpoint_spec_receipt_outcomes() {
	local label="" spec=$'_Supersedes #400 — this issue is the consolidated spec._\n\n## What\nFix it.'
	local before="" after="" rc=0 outcomes=""
	before=$(issue_json 'status:in-progress,consolidated,auto-dispatch' runner1 "$spec")
	after=$(issue_json 'status:available,consolidated' '' "$spec")

	# 0 restored, 1 nothing to restore (label already back, then no receipt),
	# 2 receipt held but the issue is on hold.
	for label in '' auto-dispatch hold-for-review; do
		reset_case
		TEST_ISSUE_JSON="$before"
		_pmpc_record_checkpoint_spec_dispatch "$SLUG" 501 || true
		TEST_ISSUE_JSON=$(issue_json "status:available,consolidated${label:+,${label}}" '' "$spec")
		rc=0
		_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || rc=$?
		outcomes+="${rc} "
	done
	rc=0
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || rc=$?
	outcomes+="$rc"
	if [[ "$outcomes" == "0 1 2 1" ]]; then
		pass "checkpoint spec restore reports restored, nothing to restore and refused"
	else
		fail "checkpoint spec restore reports restored, nothing to restore and refused (got ${outcomes})"
	fi

	# A deferred release replay adopts the recording run's receipt.
	reset_case
	TEST_ISSUE_JSON="$after"
	_pmpc_adopt_checkpoint_spec_receipt 'not a slug' 501 || true
	_pmpc_adopt_checkpoint_spec_receipt "$SLUG" 0 || true
	if _pmpc_holds_checkpoint_spec_receipt "$SLUG" 501; then
		fail "malformed issue reference adopts no receipt"
	else
		pass "malformed issue reference adopts no receipt"
	fi
	_pmpc_adopt_checkpoint_spec_receipt "$SLUG" 501 || true
	_pmpc_restore_checkpoint_spec_dispatch "$SLUG" 501 || true
	assert_status_call "501 ${SLUG} available --add-label auto-dispatch" "adopted receipt restores dispatch"
	return 0
}

# GH#39857: a leaf released with worker_ready_missing_linkage (auto-dispatch
# removed, status:in-review) whose For #N PR was merged by a different runner,
# with a partial closeout comment and a newer sibling-issue cross-reference on
# the timeline, must still return to the queue.
test_cross_runner_leaf_with_sibling_reference() {
	reset_case
	TEST_REVIEW_ISSUES='[{"number":501}]'
	TEST_PR_JSON=$(pr_json true runner2)
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "DISPATCH_CLAIM nonce=n1 runner=runner1 ts=2026-10-10T09:30:00Z max_age_s=600 session=issue-501 phase=prelaunch")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1 ts=2026-10-10T10:20:00Z")" \
		"$(comment 3 MEMBER runner2 "<!-- PARTIAL_PARENT_CLOSEOUT:PR#900 -->
## Partial Parent Closeout

Delivered: spec only.")")
	TEST_TIMELINE=$(printf '%s' "$TEST_TIMELINE" | jq -c '.[0] += [{event:"cross-referenced",source:{issue:{number:777,repository_url:"https://api.github.com/repos/owner/repo"}}}]')
	_pm_reconcile_partial_continuations "$SLUG" 2000000060
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" \
		"cross-runner leaf with closeout comment and sibling issue reference returns to queue"
	return 0
}

test_merged_feedback_cleanup() {
	reset_case
	local stale='' kept='' original='' expected='' actual=''
	stale=$'<!-- feedback-route:start:conflict:PR900:SHAabc -->\nold conflict\n<!-- feedback-route:complete:conflict:PR900:SHAabc -->'
	kept=$'<!-- feedback-route:start:conflict:PR901:SHAdef:PR900:detail -->\nclosed unmerged\n<!-- feedback-route:complete:conflict:PR901:SHAdef:PR900:detail -->'
	original=$'Remaining scope\r\n\n'"${stale}"$'\n'"${kept}"$'\n'"${stale}"$'\n\n'
	expected=$'Remaining scope\r\n\n\n'"${kept}"$'\n\n\n'
	TEST_ISSUE_JSON=$(issue_json "status:in-review,origin:worker" runner1 "$original")
	_pm_restore_partial_continuation 900 "$SLUG" "" "$TEST_PR_LABELS"
	IFS= read -r -d '' actual <"${TEST_ROOT}/edited-body" || true
	if [[ "$actual" == "$expected" ]]; then
		pass 'partial merge removes only its paired blocks and preserves all other bytes'
	else
		fail 'partial merge removes only its paired blocks and preserves all other bytes' "$actual"
	fi
	assert_status_call "501 ${SLUG} available --remove-assignee runner1 --add-label auto-dispatch" 'feedback cleanup keeps continuation transition'
	[[ "$(posted_markers)" == 1 ]] && pass 'feedback cleanup retains audit comment' || fail 'feedback cleanup retains audit comment'
	TEST_BODY_EDIT_RC=1
	_pm_restore_partial_continuation 900 "$SLUG" "" "$TEST_PR_LABELS"
	grep -q 'feedback cleanup failed' "$LOGFILE" && pass 'body edit failure is logged without failing continuation' || fail 'body edit failure is logged without failing continuation'
	return 0
}

test_dispatch_feedback_guard() {
	reset_case
	# Load the real launch function, not a second copy of the implementation.
	# shellcheck source=../pulse-dispatch-worker-launch.sh
	source "${SCRIPT_DIR_TEST}/../pulse-dispatch-worker-launch.sh"
	local stale='' kept='' open='' body='' result=''
	stale=$'<!-- feedback-route:start:conflict:PR900:SHAabc -->\nSTALE_CONFLICT\n<!-- feedback-route:complete:conflict:PR900:SHAabc -->'
	kept=$'<!-- feedback-route:start:conflict:PR901:SHAdef -->\nKEEP_CLOSED_UNMERGED\n<!-- feedback-route:complete:conflict:PR901:SHAdef -->'
	open=$'<!-- feedback-route:start:ci:PR902:SHAghi -->\nKEEP_OPEN\n<!-- feedback-route:complete:ci:PR902:SHAghi -->'
	body=$'Remaining scope\n'"${stale}"$'\n'"${kept}"$'\n'"${open}"
	TEST_ISSUE_JSON=$(issue_json status:available '' "$body")
	result=$(_dlw_filter_merged_feedback 501 "$SLUG" "$body")
	if [[ "$result" != *STALE_CONFLICT* && "$result" == *"$kept"* && "$result" == *"$open"* && "$result" == *'Remaining scope'* ]]; then
		pass 'dispatch strips merged routes from seed and snapshot but keeps closed-unmerged and open routes'
	else
		fail 'dispatch strips merged routes from seed and snapshot but keeps closed-unmerged and open routes' "$result"
	fi
	[[ "$(grep -c '^api graphql' "$API_LOG")" == 1 ]] && pass 'dispatch batches all PR states once' || fail 'dispatch batches all PR states once'
	local malformed='' nested=''
	malformed=$'<!-- feedback-route:start:unknown -->\nKEEP_UNKNOWN\n<!-- feedback-route:complete:unknown -->'
	nested=$'<!-- feedback-route:start:conflict:PR900:SHAnested -->\n'"${kept}"$'\n<!-- feedback-route:complete:conflict:PR900:SHAnested -->'
	body+=$'\n'"${malformed}"$'\n'"${nested}"
	TEST_ISSUE_JSON=$(issue_json status:available '' "$body")
	result=$(_dlw_filter_merged_feedback 501 "$SLUG" "$body")
	[[ "$result" == *"$malformed"* && "$result" == *"$nested"* ]] && pass 'unknown and nested routes cannot swallow unrelated feedback' || fail 'unknown and nested routes cannot swallow unrelated feedback'
	TEST_GRAPHQL_RC=1
	result=$(_dlw_filter_merged_feedback 501 "$SLUG" "$body")
	[[ "$result" == "$body" ]] && pass 'state lookup failure preserves feedback' || fail 'state lookup failure preserves feedback'
	: >"$API_LOG"
	TEST_ISSUE_JSON=$(issue_json status:available '' 'Remaining scope only')
	result=$(_dlw_filter_merged_feedback 501 "$SLUG" 'original prompt')
	[[ "$result" == 'original prompt' && "$(grep -c '^api graphql' "$API_LOG" || true)" == 0 ]] && pass 'no feedback skips PR state lookup' || fail 'no feedback skips PR state lookup'
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=../pulse-merge-partial-continuation.sh
	source "$MODULE_FILE"

	test_unlabeled_worker_provenance
	test_claim_matched_worker_provenance
	test_unlabeled_worker_branch_merge_gate
	test_eligible_leaf_returns_to_queue
	test_parent_tracker_skips_auto_dispatch
	test_terminal_lease_proves_finished_run
	test_labels_fetched_when_not_supplied
	test_live_dispatch_keeps_review
	test_interactive_claim_keeps_review
	test_ownership_lost_keeps_review
	test_untrusted_release_is_ignored
	test_hold_label_keeps_review
	test_non_review_status_is_untouched
	test_foreign_assignee_keeps_review
	test_other_open_pr_keeps_review
	test_unrelated_open_pr_mention_is_ignored
	test_pr_lookup_failure_fails_closed
	test_existing_marker_is_idempotent
	test_closing_target_is_noop
	test_non_worker_pr_is_noop
	test_ambiguous_reference_is_noop
	test_ambiguous_reference_verdict_reason
	test_corroborated_partial_target
	test_uncorroborated_partial_target_is_noop
	test_unconfirmed_merge_keeps_review
	test_pr_read_failure_fails_closed
	test_open_pr_scan_reads_every_page
	test_parent_tracker_drops_existing_auto_dispatch
	test_takeover_runner_differs_from_author
	test_comment_failure_is_logged
	test_empty_caller_target_rechecks_closing
	test_closing_read_failure_fails_closed
	test_unreadable_assignees_fail_closed
	test_open_pr_entry_without_body_fails_closed
	test_open_pr_null_body_is_empty
	test_comment_retry_posts_one_marker
	test_landed_comment_is_not_duplicated
	test_unreadable_comment_fails_closed
	test_unreadable_reread_skips_retry
	test_qualified_open_pr_reference_keeps_review
	test_unparsed_closing_reference_is_noop
	test_recent_merged_scan_outside_traversal
	test_recent_merged_prefilter_skips_reads
	test_recent_merged_walk_is_incremental
	test_expired_lease_recovery
	test_periodic_pass
	test_multi_page_traversal
	test_review_snapshot_prefilter
	test_recheck_hint
	test_available_dispatch_recovery
	test_closed_checkpoint_dispatch_recovery
	test_closed_checkpoint_scan_pagination
	test_checkpoint_spec_dispatch_restore
	test_checkpoint_spec_receipt_outcomes
	test_cross_runner_leaf_with_sibling_reference
	test_merged_feedback_cleanup
	test_dispatch_feedback_guard

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
