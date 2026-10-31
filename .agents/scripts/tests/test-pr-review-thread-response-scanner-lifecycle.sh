#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Re-review, locking, candidate rotation, and mutation tests.
# Sourced by test-pr-review-thread-response-scanner.sh; not a standalone suite.
# The entry point owns strict mode, TEST_SCRIPT_DIR, and shared test state.

[[ -n "${_PRRTS_TEST_LIFECYCLE_LOADED:-}" ]] && return 0
_PRRTS_TEST_LIFECYCLE_LOADED=1

test_mark_complete_requests_trusted_rereview_once_per_changed_head() {
	setup_test_env
	write_rereview_dispatch_state
	set_trusted_change_request_review
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_2"
	export STUB_THREADS_MODE="none"
	$SCANNER mark-complete owner/repo 1 repaired_head
	$SCANNER mark-complete owner/repo 1 repaired_head
	local rereview_state="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.rereview"
	if [[ "$(wc -l <"$PR_EDIT_LOG")" -eq 1 ]] &&
		grep -Fq -- '--add-reviewer trusted-reviewer' "$PR_EDIT_LOG" &&
		grep -Fxq "head_sha=${TEST_HEAD_OID_2}" "$rereview_state" &&
		grep -Fxq 'reviewers=trusted-reviewer' "$rereview_state"; then
		print_result "mark-complete requests one trusted re-review per changed head" 0
	else
		print_result "mark-complete requests one trusted re-review per changed head" 1 \
			"edits=$(tr '\n' ';' <"$PR_EDIT_LOG" 2>/dev/null || printf ''), state=$(tr '\n' ';' <"$rereview_state" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_mark_complete_skips_rereview_without_changed_head() {
	setup_test_env
	write_rereview_dispatch_state
	set_trusted_change_request_review
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_1"
	$SCANNER mark-complete owner/repo 1 no_push
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ ! -s "$PR_EDIT_LOG" ]] && grep -Fxq 'analysis_complete=true' "$state_file"; then
		print_result "mark-complete does not request re-review without a changed head" 0
	else
		print_result "mark-complete does not request re-review without a changed head" 1
	fi
	teardown_test_env
	return 0
}

test_mark_complete_fails_closed_on_unknown_reviewer_identity() {
	setup_test_env
	write_rereview_dispatch_state
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_2"
	export STUB_THREADS_MODE="none"
	export STUB_REVIEWS_RESPONSE='[[{"id":12,"submitted_at":"2026-08-28T01:00:00Z","state":"CHANGES_REQUESTED","commit_id":"'"$TEST_HEAD_OID_1"'","author_association":"OWNER","user":{"login":"unknown reviewer","type":"User"}}]]'
	$SCANNER mark-complete owner/repo 1 unknown_reviewer
	if [[ ! -s "$PR_EDIT_LOG" ]]; then
		print_result "mark-complete never requests an unvalidated reviewer identity" 0
	else
		print_result "mark-complete never requests an unvalidated reviewer identity" 1
	fi
	teardown_test_env
	return 0
}

test_mark_complete_defers_rereview_until_all_threads_converge() {
	setup_test_env
	write_rereview_dispatch_state
	set_trusted_change_request_review
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_2"
	export STUB_THREADS_MODE="human"
	$SCANNER mark-complete owner/repo 1 partial_batch
	if [[ ! -s "$PR_EDIT_LOG" ]] && grep -Fq 'unresolved review threads remain' "$LOGFILE"; then
		print_result "mark-complete defers re-review while unresolved threads remain" 0
	else
		print_result "mark-complete defers re-review while unresolved threads remain" 1
	fi
	teardown_test_env
	return 0
}

test_mark_complete_preserves_incomplete_state_when_rereview_write_fails() {
	setup_test_env
	write_rereview_dispatch_state
	set_trusted_change_request_review
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_2"
	export STUB_THREADS_MODE="none"
	export STUB_REREVIEW_REQUEST_FAIL="true"
	local mark_rc=0
	$SCANNER mark-complete owner/repo 1 request_failed || mark_rc=$?
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	local rereview_state="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.rereview"
	if [[ "$mark_rc" -eq 1 && ! -f "$rereview_state" ]] &&
		! grep -Fxq 'analysis_complete=true' "$state_file"; then
		print_result "mark-complete fails closed when the re-review request fails" 0
	else
		print_result "mark-complete fails closed when the re-review request fails" 1 "rc=${mark_rc}"
	fi
	teardown_test_env
	return 0
}

test_mark_blocked_never_requests_rereview() {
	setup_test_env
	write_rereview_dispatch_state
	set_trusted_change_request_review
	export STUB_PULL_HEAD_OID="$TEST_HEAD_OID_2"
	$SCANNER mark-blocked owner/repo 1 code remediation_failed
	if [[ ! -s "$PR_EDIT_LOG" ]]; then
		print_result "mark-blocked never requests re-review" 0
	else
		print_result "mark-blocked never requests re-review" 1
	fi
	teardown_test_env
	return 0
}

test_mark_blocked_publishes_continuation_finding() {
	setup_test_env
	local gh_log="${TEST_ROOT}/continuation-gh.log"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CONT_GH_LOG}"
if [[ "$*" == *'--method POST'* && "${CONT_POST_FAIL:-false}" == true ]]; then
	exit 1
fi
exit 0
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	export CONT_GH_LOG="$gh_log"
	local details_file="${TEST_ROOT}/continuation-details.txt"
	printf 'needs a maintainer choice' >"$details_file"
	# Ordinary review workers carry no linked issue: nothing is published.
	$SCANNER mark-blocked owner/repo 1 decision needs_choice "$details_file"
	local ordinary_posts=0
	[[ -f "$gh_log" ]] && ordinary_posts=$(grep -c 'issues/77/comments' "$gh_log" || true)
	AIDEVOPS_PR_REPAIR_LINKED_ISSUE=77 AIDEVOPS_PR_REPAIR_HEAD_SHA="$TEST_HEAD_OID_1" \
		$SCANNER mark-blocked owner/repo 1 decision needs_choice "$details_file"
	if [[ "$ordinary_posts" -eq 0 ]] &&
		grep -Fq 'repos/owner/repo/issues/77/comments --method POST' "$gh_log" &&
		grep -Fq 'CONTINUATION_BLOCKER_FINDING' "$gh_log"; then
		print_result "mark-blocked publishes continuation finding only for continuation workers" 0
	else
		print_result "mark-blocked publishes continuation finding only for continuation workers" 1 \
			"log=$(tr '\n' ';' <"$gh_log" 2>/dev/null || printf '')"
	fi
	local pending_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.blocker-pending.json"
	export CONT_POST_FAIL=true
	AIDEVOPS_PR_REPAIR_LINKED_ISSUE=77 AIDEVOPS_PR_REPAIR_HEAD_SHA="$TEST_HEAD_OID_1" \
		$SCANNER mark-blocked owner/repo 1 decision publication_retry "$details_file"
	if [[ -s "$pending_file" ]] &&
		grep -Fxq 'analysis_complete=true' "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"; then
		print_result "failed blocker publication persists payload without failing local completion" 0
	else
		print_result "failed blocker publication persists payload without failing local completion" 1
	fi
	unset CONT_POST_FAIL
	# A fresh recovery process needs neither the worker environment nor details file.
	rm -f "$details_file"
	bash -c 'source "$1"; _prrts_retry_continuation_blocker owner/repo 1 77' _ "$SCANNER"
	if [[ ! -f "$pending_file" ]] && grep -Fq 'publication_retry' "$gh_log"; then
		print_result "continuation recovery republishes saved finding and clears pending payload" 0
	else
		print_result "continuation recovery republishes saved finding and clears pending payload" 1
	fi
	unset CONT_GH_LOG
	teardown_test_env
	return 0
}

test_dispatch_pr_skips_when_pr_lock_held() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	local dispatch_rc=0
	local owner_process_start=""
	owner_process_start=$(process_start_for_pid "$$")
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'owner_process_start=%s\n' "$owner_process_start"
	} >"${lock_dir}/metadata"
	$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || dispatch_rc=$?
	if [[ "$dispatch_rc" -eq 10 && ! -s "$HEADLESS_LOG" ]]; then
		print_result "dispatch-pr reports held repo PR lock as deferred" 0
	else
		print_result "dispatch-pr reports held repo PR lock as deferred" 1 "rc=${dispatch_rc}, lock-held dispatch unexpectedly launched"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reports_deduplicated_dispatch() {
	setup_test_env
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	: >"$HEADLESS_LOG"
	local dispatch_rc=0
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || dispatch_rc=$?
	if [[ "$dispatch_rc" -eq 10 && ! -s "$HEADLESS_LOG" ]] &&
		grep -Eq 'dispatch state active|same thread fingerprint dispatched' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch-pr reports a deduplicated targeted dispatch with deferred outcome" 0
	else
		print_result "dispatch-pr reports a deduplicated targeted dispatch with deferred outcome" 1 \
			"rc=${dispatch_rc}, headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reports_active_worker_as_deferred() {
	setup_test_env
	export STUB_ACTIVE_RESPONSE_WORKER="pr-review-thread-response-owner-repo-1"
	local dispatch_rc=0
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || dispatch_rc=$?
	if [[ "$dispatch_rc" -eq 10 && ! -s "$HEADLESS_LOG" ]] &&
		grep -q 'response worker already active' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch-pr reports an active response worker as deferred" 0
	else
		print_result "dispatch-pr reports an active response worker as deferred" 1 \
			"rc=${dispatch_rc}, headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reclaims_stale_lock() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	local old_epoch=""
	old_epoch="$(($(date +%s) - 120))"
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "legacy-owner"
		printf 'created_at=%s\n' "$old_epoch"
	} >"${lock_dir}/metadata"
	PR_REVIEW_THREAD_RESPONSE_LOCK_STALE=60 $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ -s "$HEADLESS_LOG" && -f "$state_file" && ! -d "$lock_dir" ]]; then
		print_result "dispatch-pr reclaims stale repo PR lock" 0
	else
		print_result "dispatch-pr reclaims stale repo PR lock" 1 "headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), state=${state_file}, lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reclaims_dead_young_lock() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "999999"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'owner_process_start=%s\n' "dead-owner"
	} >"${lock_dir}/metadata"
	$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	if [[ -s "$HEADLESS_LOG" && ! -d "$lock_dir" ]]; then
		print_result "dispatch-pr immediately reclaims a dead young lock owner" 0
	else
		print_result "dispatch-pr immediately reclaims a dead young lock owner" 1 "lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_reclaims_pid_reused_young_lock() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'owner_process_start=%s\n' "definitely-not-the-current-process-start"
	} >"${lock_dir}/metadata"
	$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1
	wait_for_headless_log || true
	if [[ -s "$HEADLESS_LOG" && ! -d "$lock_dir" ]]; then
		print_result "dispatch-pr reclaims a young lock after PID identity reuse" 0
	else
		print_result "dispatch-pr reclaims a young lock after PID identity reuse" 1 "lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_preserves_malformed_young_lock_until_age_fallback() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	local dispatch_rc=0
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "not-a-pid"
		printf 'created_at=%s\n' "$(date +%s)"
	} >"${lock_dir}/metadata"
	$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || dispatch_rc=$?
	if [[ "$dispatch_rc" -eq 10 && ! -s "$HEADLESS_LOG" && -d "$lock_dir" ]]; then
		print_result "dispatch-pr preserves malformed young legacy lock for age fallback" 0
	else
		print_result "dispatch-pr preserves malformed young legacy lock for age fallback" 1 "rc=${dispatch_rc}, lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_pr_preserves_indeterminate_young_lock_until_age_fallback() {
	setup_test_env
	local lock_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.lock"
	local dispatch_rc=0
	mkdir -p "$lock_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'owner_process_start=%s\n' "known-owner-start"
	} >"${lock_dir}/metadata"
	STUB_PS_LSTART_UNAVAILABLE=1 $SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || dispatch_rc=$?
	if [[ "$dispatch_rc" -eq 10 && ! -s "$HEADLESS_LOG" && -d "$lock_dir" ]]; then
		print_result "dispatch-pr preserves indeterminate young lock for age fallback" 0
	else
		print_result "dispatch-pr preserves indeterminate young lock for age fallback" 1 "rc=${dispatch_rc}, lock_dir=${lock_dir}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_reports_graphql_budget_exhaustion_when_scan_blind() {
	setup_test_env
	export STUB_THREADS_MODE="rate_limit"
	export STUB_GRAPHQL_REMAINING="0"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if grep -q 'dispatch: owner/repo skipped — GraphQL budget exhausted (1 PRs uncheckable)' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch reports GraphQL exhaustion instead of no active PRs" 0
	else
		print_result "dispatch reports GraphQL exhaustion instead of no active PRs" 1 "log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_reports_fetch_errors_when_scan_blind() {
	setup_test_env
	export STUB_THREADS_MODE="error"
	export STUB_GRAPHQL_REMAINING="100"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if grep -q 'dispatch: owner/repo skipped — 1 PRs had fetch errors' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch reports fetch errors instead of no active PRs" 0
	else
		print_result "dispatch reports fetch errors instead of no active PRs" 1 "log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rotates_candidates_with_repo_cursor() {
	setup_test_env
	export PR_REVIEW_THREAD_RESPONSE_MAX_PER_REPO=2
	export STUB_PR_LIST=$'1\tOne\tfalse\torigin:worker\tfeature/one\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n2\tTwo\tfalse\torigin:worker\tfeature/two\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n3\tThree\tfalse\torigin:worker\tfeature/three\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n4\tFour\tfalse\torigin:worker\tfeature/four\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n5\tFive\tfalse\torigin:worker\tfeature/five\t'"${TEST_HEAD_OID_1}"$'\tworker-bot'
	local state_dir="$AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR"
	local cursor_file="${state_dir}/owner-repo-cursor.state"

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local first_window=""
	first_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	rm -f "${state_dir}"/owner-repo-[0-9]*.state

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local second_window=""
	second_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	rm -f "${state_dir}"/owner-repo-[0-9]*.state

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local third_window=""
	third_window="$(for pr_number in 1 2 3 4 5; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	local cursor_value=""
	cursor_value="$(grep '^pr_number=' "$cursor_file" 2>/dev/null || true)"

	if [[ "$first_window" == "12" && "$second_window" == "34" && "$third_window" == "15" && "$cursor_value" == "pr_number=1" ]]; then
		print_result "dispatch rotates candidate windows with repo cursor" 0
	else
		print_result "dispatch rotates candidate windows with repo cursor" 1 "first=${first_window}, second=${second_window}, third=${third_window}, cursor=${cursor_value}, log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_stale_cursor_falls_back_to_original_order() {
	setup_test_env
	export PR_REVIEW_THREAD_RESPONSE_MAX_PER_REPO=2
	export STUB_PR_LIST=$'1\tOne\tfalse\torigin:worker\tfeature/one\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n2\tTwo\tfalse\torigin:worker\tfeature/two\t'"${TEST_HEAD_OID_1}"$'\tworker-bot\n3\tThree\tfalse\torigin:worker\tfeature/three\t'"${TEST_HEAD_OID_1}"$'\tworker-bot'
	local state_dir="$AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR"
	local cursor_file="${state_dir}/owner-repo-cursor.state"
	printf 'pr_number=999\n' >"$cursor_file"

	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local dispatched_window=""
	dispatched_window="$(for pr_number in 1 2 3; do if [[ -f "${state_dir}/owner-repo-${pr_number}.state" ]]; then printf '%s' "$pr_number"; fi; done)"
	local cursor_value=""
	cursor_value="$(grep '^pr_number=' "$cursor_file" 2>/dev/null || true)"

	if [[ "$dispatched_window" == "12" && "$cursor_value" == "pr_number=2" ]]; then
		print_result "dispatch stale cursor falls back to original order" 0
	else
		print_result "dispatch stale cursor falls back to original order" 1 "window=${dispatched_window}, cursor=${cursor_value}"
	fi
	teardown_test_env
	return 0
}

test_reply_and_resolve_use_graphql_mutations() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer fixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	$SCANNER resolve owner/repo THREAD1
	if grep -q '^reply$' "$GRAPHQL_MUTATIONS_LOG" 2>/dev/null && grep -q '^resolve$' "$GRAPHQL_MUTATIONS_LOG" 2>/dev/null; then
		print_result "reply and resolve use GraphQL mutations" 0
	else
		print_result "reply and resolve use GraphQL mutations" 1 "mutations=$(tr '\n' ',' <"$GRAPHQL_MUTATIONS_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_reply_rejects_impossible_mutation_responses() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local missing_id_rc=0 partial_error_rc=0
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer fixed at file.sh:1; verified with test.sh\n' >"$body_file"
	STUB_REPLY_RESPONSE_MODE="missing-id" $SCANNER reply owner/repo THREAD1 "$body_file" || missing_id_rc=$?
	STUB_REPLY_RESPONSE_MODE="partial-error" $SCANNER reply owner/repo THREAD1 "$body_file" || partial_error_rc=$?
	if [[ "$missing_id_rc" -ne 0 && "$partial_error_rc" -ne 0 ]]; then
		print_result "reply rejects impossible mutation response shapes" 0
	else
		print_result "reply rejects impossible mutation response shapes" 1 "missing_id_rc=${missing_id_rc}, partial_error_rc=${partial_error_rc}"
	fi
	teardown_test_env
	return 0
}

test_resolve_rejects_impossible_mutation_responses() {
	setup_test_env
	local wrong_thread_rc=0 partial_error_rc=0
	STUB_RESOLVE_RESPONSE_MODE="wrong-thread" $SCANNER resolve owner/repo THREAD1 || wrong_thread_rc=$?
	STUB_RESOLVE_RESPONSE_MODE="partial-error" $SCANNER resolve owner/repo THREAD1 || partial_error_rc=$?
	if [[ "$wrong_thread_rc" -ne 0 && "$partial_error_rc" -ne 0 ]]; then
		print_result "resolve rejects impossible mutation response shapes" 0
	else
		print_result "resolve rejects impossible mutation response shapes" 1 "wrong_thread_rc=${wrong_thread_rc}, partial_error_rc=${partial_error_rc}"
	fi
	teardown_test_env
	return 0
}

test_reply_auto_prepends_thread_author() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local captured=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\nfixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	captured=$(<"$GRAPHQL_BODY_CAPTURE")
	if [[ "$captured" == @reviewer\ * ]]; then
		print_result "reply prepends review thread author mention" 0
	else
		print_result "reply prepends review thread author mention" 1 "body=${captured}"
	fi
	teardown_test_env
	return 0
}

test_reply_sends_author_mention_body_as_raw_field() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local captured="" flag=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\nfixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	captured=$(<"$GRAPHQL_BODY_CAPTURE")
	flag=$(<"$GRAPHQL_BODY_FLAG_CAPTURE")
	if [[ "$flag" == "-f" && "$captured" == @reviewer\ * ]]; then
		print_result "reply sends author-mention body as raw GraphQL field" 0
	else
		print_result "reply sends author-mention body as raw GraphQL field" 1 "flag=${flag}, body=${captured}"
	fi
	teardown_test_env
	return 0
}

test_reply_does_not_double_prepend_thread_author() {
	setup_test_env
	local body_file="${TEST_ROOT}/reply.md"
	local mention_count=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer fixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	mention_count=$(grep -o '@reviewer' "$GRAPHQL_BODY_CAPTURE" 2>/dev/null | wc -l | tr -d '[:space:]')
	if [[ "$mention_count" == "1" ]]; then
		print_result "reply does not double-prepend thread author mention" 0
	else
		print_result "reply does not double-prepend thread author mention" 1 "count=${mention_count}"
	fi
	teardown_test_env
	return 0
}

test_reply_falls_back_when_thread_author_missing() {
	setup_test_env
	export STUB_THREAD_AUTHOR_MODE="missing"
	local body_file="${TEST_ROOT}/reply.md"
	local captured=""
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\nfixed at file.sh:1; verified with test.sh\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	captured=$(<"$GRAPHQL_BODY_CAPTURE")
	if [[ "$captured" == '<!-- aidevops:review-thread-response:THREAD1 -->'* ]]; then
		print_result "reply falls back when thread author is missing" 0
	else
		print_result "reply falls back when thread author is missing" 1 "body=${captured}"
	fi
	teardown_test_env
	return 0
}

test_reply_skips_duplicate_marker() {
	setup_test_env
	export STUB_THREADS_MODE="marker"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB_MARKER'
#!/usr/bin/env bash
if [[ "$1" == "api" && "${2:-}" == "rate_limit" ]]; then
	printf '100\n'
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
	[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || exit 1
	if [[ "$*" == *"comments(first: 100)"* ]]; then
		printf '{"data":{"node":{"comments":{"nodes":[{"body":"<!-- aidevops:review-thread-response:THREAD1 --> already"}],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}\n'
		exit 0
	fi
	if [[ "$*" == *"addPullRequestReviewThreadReply"* ]]; then
		printf 'reply\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		printf '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"COMMENT1"}},"rateLimit":{"cost":1}}}\n'
		exit 0
	fi
fi
printf '{}\n'
exit 0
GH_STUB_MARKER
	chmod +x "${TEST_ROOT}/bin/gh"
	local body_file="${TEST_ROOT}/reply.md"
	printf '<!-- aidevops:review-thread-response:THREAD1 -->\n@reviewer duplicate\n' >"$body_file"
	$SCANNER reply owner/repo THREAD1 "$body_file" 'aidevops:review-thread-response:THREAD1'
	if [[ ! -s "$GRAPHQL_MUTATIONS_LOG" ]]; then
		print_result "reply skips duplicate idempotency marker" 0
	else
		print_result "reply skips duplicate idempotency marker" 1 "unexpected mutation"
	fi
	teardown_test_env
	return 0
}
