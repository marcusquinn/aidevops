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
	TEST_TARGET="501"
	TEST_CLOSING=""
	TEST_CLOSING_RC=0
	TEST_PR_LABELS="origin:worker,tier:standard"
	TEST_PR_JSON=$(pr_json true runner1)
	TEST_PR_RC=0
	TEST_COMMENT_RC=0
	TEST_COMMENT_FAILS=0
	TEST_COMMENTS_AFTER_ATTEMPT=""
	TEST_PR_BODY=$'Partial delivery: published the first edition.\n\nFor #501'
	TEST_PR_BODY_RC=0
	TEST_OPEN_PRS="[]"
	TEST_OPEN_PR_PAGES=""
	TEST_OPEN_PRS_RC=0
	TEST_ISSUE_JSON=$(issue_json "status:in-review,origin:worker,tier:standard" "runner1")
	TEST_COMMENTS_JSON=$(pages "$(comment 1 MEMBER runner1 "Dispatching worker (deterministic).")" \
		"$(comment 2 MEMBER runner1 "CLAIM_RELEASED reason=worker_ready_missing_linkage runner=runner1 ts=2026-10-10T10:20:00Z")")
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

# Args: $1=labels CSV, $2=assignees CSV
issue_json() {
	local labels="$1"
	local assignees="$2"
	jq -cn --arg labels "$labels" --arg assignees "$assignees" '{
		number: 501, state: "open",
		labels: ($labels | split(",") | map(select(length > 0) | {name: .})),
		assignees: ($assignees | split(",") | map(select(length > 0) | {login: .}))
	}'
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
	printf '%s' "$TEST_CLOSING"
	return 0
}

_extract_pr_work_issue() {
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
	# The module reads the merged PR body with --jq '.body // ""'.
	if [[ "$args" == *"--json body"* ]]; then
		printf '%s\n' "pr-body $*" >>"$API_LOG"
		[[ "$TEST_PR_BODY_RC" -eq 0 ]] || return "$TEST_PR_BODY_RC"
		printf '%s\n' "$TEST_PR_BODY"
		return 0
	fi
	return 1
}

gh() {
	printf '%s\n' "$*" >>"$API_LOG"
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
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/issues/501/comments"* ]]; then
		# Models a comment write that errored client-side but landed server-side.
		if [[ -n "$TEST_COMMENTS_AFTER_ATTEMPT" && -s "$COMMENT_ATTEMPTS" ]]; then
			printf '%s' "$TEST_COMMENTS_AFTER_ATTEMPT"
			return 0
		fi
		printf '%s' "$TEST_COMMENTS_JSON"
		return 0
	fi
	if [[ "${1:-}" == "api" && "${2:-}" == "repos/${SLUG}/issues/501" ]]; then
		printf '%s' "$TEST_ISSUE_JSON"
		return 0
	fi
	return 1
}

set_issue_status() {
	printf '%s\n' "$*" >>"$STATUS_LOG"
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
	assert_log_contains "body closes an issue or is unreadable" "closing-reference skip is logged"
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

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=../pulse-merge-partial-continuation.sh
	source "$MODULE_FILE"

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

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
