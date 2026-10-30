#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-draft-checkpoint-unblock.sh — GH#36028 regression guard.
#
# Runners before v3.39.89 projected status:blocked after a clean or
# worker_complete release while the worker's draft PR stayed open, so the
# draft was never continued. The pass must restore status:available only when
# trusted release and label-timeline evidence prove that projection, and must
# leave every terminal, protected, ambiguous or unreadable case unchanged.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MODULE_FILE="${SCRIPT_DIR_TEST}/../pulse-draft-checkpoint-unblock.sh"
CYCLE_FILE="${SCRIPT_DIR_TEST}/../pulse-wrapper-cycle.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SLUG="owner/repo"
RELEASE_TS="2026-10-29T19:32:03Z"

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

# --- fixtures ---
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

# Args: $1=number, $2=draft, $3=labels CSV, $4=body
pr_json() {
	local number="$1"
	local draft="$2"
	local labels="$3"
	local body="$4"
	jq -cn --argjson number "$number" --argjson draft "$draft" --arg labels "$labels" --arg body "$body" '{
		number: $number, draft: $draft, state: "open", body: $body,
		head: {sha: ("sha" + ($number | tostring))},
		base: {ref: "main", repo: {default_branch: "main"}},
		labels: ($labels | split(",") | map(select(length > 0) | {name: .}))
	}'
	return 0
}

# Args: $1=id, $2=created_at, $3=author_association, $4=login, $5=body line
comment() {
	local comment_id="$1"
	local created_at="$2"
	local association="$3"
	local login="$4"
	local body="$5"
	jq -cn --argjson id "$comment_id" --arg at "$created_at" --arg assoc "$association" \
		--arg login "$login" --arg body "$body" '{
		id: $id, created_at: $at, author_association: $assoc, user: {login: $login},
		body: ("<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\n"
			+ $body + "\n<!-- ops:end -->")
	}'
	return 0
}

# Args: $1=created_at, $2=actor, $3=label, [$4=event]
label_event() {
	local created_at="$1"
	local actor="$2"
	local label="$3"
	local event="${4:-labeled}"
	jq -cn --arg at "$created_at" --arg actor "$actor" --arg label "$label" --arg event "$event" '{
		event: $event, created_at: $at, actor: {login: $actor}, label: {name: $label}
	}'
	return 0
}

# Wrap objects as one `gh api --paginate --slurp` page.
pages() {
	local joined=""
	joined=$(printf '%s\n' "$@" | jq -cs '.')
	printf '[%s]' "$joined"
	return 0
}

release_comment() {
	local reason="${1:-worker_complete}"
	comment 6506414392 "$RELEASE_TS" COLLABORATOR runner1 \
		"CLAIM_RELEASED reason=${reason} runner=runner1 ts=${RELEASE_TS} aidevops_version=3.39.85"
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
	TEST_NOW=1793330000
	TEST_DEADLINE=1793339999
	# Default: `--paginate --slurp` pages; cases that override use one page.
	TEST_ISSUES=$(pages "$(issue_json "auto-dispatch,status:blocked,origin:worker,tier:standard" "runner1")")
	TEST_ISSUES_RC=0
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" $'Draft checkpoint.\n\nResolves #501')")
	TEST_PRS_RC=0
	TEST_COMMENTS=$(pages \
		"$(comment 6505537575 2026-10-29T18:50:45Z COLLABORATOR runner0 "Dispatching worker (deterministic).")" \
		"$(comment 6505704032 2026-10-29T18:58:19Z COLLABORATOR runner0 "CLAIM_RELEASED reason=blocked runner=runner0 ts=2026-10-29T18:58:12Z")" \
		"$(comment 6505811913 2026-10-29T19:03:05Z COLLABORATOR runner2 "<!-- aidevops:blocked-checkpoint-attention pr=900 head=sha900 release=6505704032 -->")" \
		"$(release_comment)")
	TEST_COMMENTS_RC=0
	TEST_COMMENTS_AFTER_ATTEMPT=""
	TEST_TIMELINE=$(pages \
		"$(label_event 2026-10-29T18:58:36Z runner0 status:available)" \
		"$(label_event 2026-10-29T19:27:24Z runner1 status:in-progress)" \
		"$(label_event 2026-10-29T19:32:10Z runner1 status:blocked)")
	TEST_TIMELINE_RC=0
	TEST_STATUS_RC=0
	TEST_COMMENT_RC=0
	unset PULSE_DRAFT_UNBLOCK_MAX_PER_PR PULSE_DRAFT_UNBLOCK_WINDOW_AFTER_SECONDS
	return 0
}

# --- stubs for shared wrapper dependencies ---
gh() {
	printf '%s\n' "$*" >>"$API_LOG"
	[[ "${1:-}" == "api" ]] || return 1
	case "${2:-}" in
	"repos/${SLUG}/issues?state=open&labels=status%3Ablocked"*)
		[[ "$TEST_ISSUES_RC" -eq 0 ]] || return "$TEST_ISSUES_RC"
		printf '%s' "$TEST_ISSUES"
		;;
	"repos/${SLUG}/pulls?state=open"*)
		[[ "$TEST_PRS_RC" -eq 0 ]] || return "$TEST_PRS_RC"
		printf '%s' "$TEST_PRS"
		;;
	"repos/${SLUG}/issues/501/comments"*)
		[[ "$TEST_COMMENTS_RC" -eq 0 ]] || return "$TEST_COMMENTS_RC"
		if [[ -n "$TEST_COMMENTS_AFTER_ATTEMPT" && -s "$COMMENT_ATTEMPTS" ]]; then
			printf '%s' "$TEST_COMMENTS_AFTER_ATTEMPT"
			return 0
		fi
		printf '%s' "$TEST_COMMENTS"
		;;
	"repos/${SLUG}/issues/501/timeline"*)
		[[ "$TEST_TIMELINE_RC" -eq 0 ]] || return "$TEST_TIMELINE_RC"
		printf '%s' "$TEST_TIMELINE"
		;;
	*) return 1 ;;
	esac
	return 0
}

date() {
	if [[ "${1:-}" == "+%s" ]]; then
		printf '%s\n' "$TEST_NOW"
		return 0
	fi
	command date "$@"
	return $?
}

set_issue_status() {
	[[ "$TEST_STATUS_RC" -eq 0 ]] || return "$TEST_STATUS_RC"
	printf '%s\n' "$*" >>"$STATUS_LOG"
	return 0
}

gh_issue_comment() {
	printf '%s\n' "attempt" >>"$COMMENT_ATTEMPTS"
	[[ "$TEST_COMMENT_RC" -eq 0 ]] || return "$TEST_COMMENT_RC"
	printf '%s\n' "$*" >>"$COMMENT_LOG"
	return 0
}

# --- assertions ---
run_pass() {
	PASS_RC=0
	_pm_reconcile_draft_checkpoint_blocks "$SLUG" "$TEST_DEADLINE" || PASS_RC=$?
	return 0
}

assert_restored() {
	local expected="$1"
	local name="$2"
	local actual=""
	actual=$(cat "$STATUS_LOG")
	if [[ "$PASS_RC" -eq 0 && "$actual" == "$expected" ]] &&
		grep -Fq "kind=draft-checkpoint-unblock pr=900 release=6506414392 " "$COMMENT_LOG"; then
		pass "$name"
	else
		fail "$name" "rc=${PASS_RC} status=[${actual}] comment=[$(tr '\n' ' ' <"$COMMENT_LOG")]"
	fi
	return 0
}

assert_no_write() {
	local name="$1"
	local expected_rc="${2:-0}"
	if [[ "$PASS_RC" -eq "$expected_rc" && ! -s "$STATUS_LOG" && ! -s "$COMMENT_LOG" ]]; then
		pass "$name"
	else
		fail "$name" "rc=${PASS_RC} (want ${expected_rc}) writes: $(tr '\n' ' ' <"$STATUS_LOG") $(tr '\n' ' ' <"$COMMENT_LOG")"
	fi
	return 0
}

# --- cases ---
test_restores_worker_complete_projection() {
	reset_case
	run_pass
	assert_restored "501 ${SLUG} available --remove-assignee runner1" \
		"worker_complete release + same-runner blocked label restores available and releases runner"
	return 0
}

test_restores_clean_release_unassigned() {
	reset_case
	TEST_ISSUES="[$(issue_json "auto-dispatch,status:blocked" "")]"
	TEST_COMMENTS=$(pages "$(release_comment clean)")
	run_pass
	assert_restored "501 ${SLUG} available" "clean release on an unassigned issue restores available"
	return 0
}

test_restores_url_closing_reference() {
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "Closes: https://github.com/Owner/Repo/issues/501")")
	run_pass
	assert_restored "501 ${SLUG} available --remove-assignee runner1" "issue-URL closing reference matches case-insensitively"
	return 0
}

test_terminal_lease_after_release_is_not_owner() {
	reset_case
	TEST_COMMENTS=$(pages "$(release_comment)" \
		"$(comment 6506414999 2026-10-29T19:32:30Z COLLABORATOR runner1 "DISPATCH_LEASE phase=terminal lease_token=x")")
	run_pass
	assert_restored "501 ${SLUG} available --remove-assignee runner1" "a terminal lease after the release does not keep ownership"
	return 0
}

test_terminal_blocker_release_stays_blocked() {
	local reason=""
	for reason in blocked push_policy_timeout worker_ownership_lost runner_capability_unmet; do
		reset_case
		TEST_COMMENTS=$(pages "$(release_comment "$reason")")
		run_pass
		assert_no_write "release reason ${reason} stays blocked"
	done
	return 0
}

test_later_owner_event_stays_blocked() {
	local event=""
	for event in "DISPATCH_CLAIM nonce=1 runner=runner3" "DISPATCH_LEASE phase=ready expires_at=1793339999" \
		"Dispatching worker (deterministic)." "Interactive session claimed this task."; do
		reset_case
		TEST_COMMENTS=$(pages "$(release_comment)" \
			"$(comment 6506415000 2026-10-29T19:40:00Z MEMBER runner3 "$event")")
		run_pass
		assert_no_write "owner event after release keeps blocked: ${event%% *}"
	done
	return 0
}

test_untrusted_release_stays_blocked() {
	reset_case
	TEST_COMMENTS=$(pages "$(comment 6506414392 "$RELEASE_TS" NONE runner1 \
		"CLAIM_RELEASED reason=worker_complete runner=runner1 ts=${RELEASE_TS}")")
	run_pass
	assert_no_write "release from a non-collaborator is not evidence"
	reset_case
	TEST_COMMENTS=$(pages "$(release_comment | jq -c '.updated_at = "2026-10-29T20:00:00Z"')")
	run_pass
	assert_no_write "an edited release is not evidence"
	reset_case
	TEST_COMMENTS=$(pages "$(release_comment | jq -c '.user.login = "runner9"')")
	run_pass
	assert_no_write "a release whose poster is not the named runner is not evidence"
	return 0
}

# Linux caps one argv string at 131072 bytes (MAX_ARG_STRLEN); evidence must be
# piped, never passed with --arg/--argjson. #35592's timeline was 149244 bytes.
test_large_timeline_is_read_from_stdin() {
	local -a events=()
	local index=0 padding=""
	padding=$(printf '%*s' 1400 '' | tr ' ' 'x')
	for ((index = 0; index < 120; index++)); do
		events+=("$(label_event 2026-10-29T19:00:00Z runner0 "noise-${index}-${padding}")")
	done
	reset_case
	TEST_TIMELINE=$(pages "${events[@]}" "$(label_event 2026-10-29T19:32:10Z runner1 status:blocked)")
	if [[ "${#TEST_TIMELINE}" -le 131072 ]]; then
		fail "large timeline fixture exceeds MAX_ARG_STRLEN" "size=${#TEST_TIMELINE}"
		return 0
	fi
	run_pass
	assert_restored "501 ${SLUG} available --remove-assignee runner1" \
		"a timeline larger than Linux MAX_ARG_STRLEN (${#TEST_TIMELINE} bytes) is still evaluated"
	return 0
}

test_label_actor_or_window_mismatch_stays_blocked() {
	reset_case
	TEST_TIMELINE=$(pages "$(label_event 2026-10-29T19:32:10Z maintainer status:blocked)")
	run_pass
	assert_no_write "status:blocked applied by another actor stays blocked"
	reset_case
	TEST_TIMELINE=$(pages "$(label_event 2026-10-29T21:00:00Z runner1 status:blocked)")
	run_pass
	assert_no_write "status:blocked applied outside the release window stays blocked"
	reset_case
	TEST_TIMELINE=$(pages "$(label_event 2026-10-29T19:32:10Z runner1 status:blocked)" \
		"$(label_event 2026-10-29T20:10:00Z maintainer status:blocked)")
	run_pass
	assert_no_write "a newer maintainer re-block wins over the release projection"
	return 0
}

test_protected_or_ineligible_issue_stays_blocked() {
	local labels=""
	for labels in "auto-dispatch,status:blocked,hold-for-review" "auto-dispatch,status:blocked,needs-maintainer-review" \
		"auto-dispatch,status:blocked,parent-task" "status:blocked,origin:worker" "auto-dispatch,status:blocked,status:in-review"; do
		reset_case
		TEST_ISSUES="[$(issue_json "$labels" "runner1")]"
		run_pass
		assert_no_write "issue labels [${labels}] stay unchanged"
	done
	reset_case
	TEST_ISSUES="[$(issue_json "auto-dispatch,status:blocked" "runner1,human")]"
	run_pass
	assert_no_write "a foreign assignee stays blocked"
	return 0
}

test_pr_shape_mismatch_stays_blocked() {
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 false "origin:worker" "Resolves #501")")
	run_pass
	assert_no_write "a ready (non-draft) PR is not a stranded checkpoint"
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:interactive" "Resolves #501")")
	run_pass
	assert_no_write "a non-worker draft is not a stranded checkpoint"
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "For #501")")
	run_pass
	assert_no_write "a non-closing reference is not a checkpoint for the issue"
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "Resolves #5011")")
	run_pass
	assert_no_write "a longer issue number does not match"
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "Resolves #501")" \
		"$(pr_json 901 true "origin:worker" "Fixes #501")")
	run_pass
	assert_no_write "two drafts closing one issue are ambiguous"
	return 0
}

test_pr_target_branch_guard() {
	local branch_filter=""
	for branch_filter in '.base.ref = "feature"' 'del(.base.ref)' \
		'del(.base.repo.default_branch)' '.base.repo.default_branch = ""'; do
		reset_case
		TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "Closes #501" | jq -c "$branch_filter")")
		run_pass
		assert_no_write "non-default or missing target metadata stays blocked: ${branch_filter}"
	done
	reset_case
	TEST_PRS=$(pages "$(pr_json 900 true "origin:worker" "Closes #501" |
		jq -c '.base.ref = "trunk" | .base.repo.default_branch = "trunk"')")
	run_pass
	assert_restored "501 ${SLUG} available --remove-assignee runner1" "a custom repository default branch permits closing references"
	return 0
}

test_idempotent_and_capped() {
	local marker="<!-- aidevops:ops kind=draft-checkpoint-unblock pr=900 release=6506414392 -->"
	reset_case
	TEST_COMMENTS=$(pages "$(release_comment)" \
		"$(comment 6506415100 2026-10-29T19:45:00Z MEMBER pulse "$marker")")
	run_pass
	assert_no_write "an existing marker for the same release prevents a second restore"
	reset_case
	PULSE_DRAFT_UNBLOCK_MAX_PER_PR=2
	TEST_COMMENTS=$(pages \
		"$(comment 6500000001 2026-10-28T10:00:00Z MEMBER pulse "<!-- aidevops:ops kind=draft-checkpoint-unblock pr=900 release=6400000001 -->")" \
		"$(comment 6500000002 2026-10-28T12:00:00Z MEMBER pulse "<!-- aidevops:ops kind=draft-checkpoint-unblock pr=900 release=6400000002 -->")" \
		"$(release_comment)")
	run_pass
	assert_no_write "the per-PR restore cap stops repeated restores"
	return 0
}

assert_logged() {
	local name="$1" stage="$2"
	if grep -qF -- "$stage" "$LOGFILE"; then
		pass "$name"
	else
		fail "$name" "log missing [${stage}]"
	fi
	return 0
}

test_unreadable_reads_fail_closed() {
	reset_case
	TEST_ISSUES_RC=1
	run_pass
	assert_no_write "unreadable blocked-issue listing fails the pass" 1
	assert_logged "an unreadable issue listing names its stage" "blocked-issue listing unreadable"
	reset_case
	TEST_PRS_RC=1
	run_pass
	assert_no_write "unreadable PR listing fails the pass" 1
	assert_logged "an unreadable PR listing names its stage" "open PR listing unreadable"
	reset_case
	TEST_COMMENTS_RC=1
	run_pass
	assert_no_write "unreadable comments make no write"
	assert_logged "unreadable comments name their stage" "#501 draft PR #900 in ${SLUG} — kept blocked: comments unreadable"
	reset_case
	TEST_TIMELINE_RC=1
	run_pass
	assert_no_write "unreadable timeline makes no write"
	assert_logged "an unreadable timeline names its stage" "kept blocked: timeline unreadable"
	reset_case
	TEST_COMMENTS='[[{"id":1,"author_association":"MEMBER","user":{"login":"runner1"}}]]'
	run_pass
	assert_no_write "a comment without readable fields makes no write"
	return 0
}

test_deadline_and_listing_cost() {
	local reads=""
	reset_case
	TEST_DEADLINE="$TEST_NOW"
	run_pass
	assert_no_write "an expired deadline stops before per-issue reads" 3
	reset_case
	TEST_ISSUES="[]"
	run_pass
	reads=$(wc -l <"$API_LOG" | tr -d ' ')
	if [[ "$PASS_RC" -eq 0 && "$reads" == "1" ]]; then
		pass "no blocked auto-dispatch issue costs one listing read"
	else
		fail "no blocked auto-dispatch issue costs one listing read" "rc=${PASS_RC} reads=${reads}"
	fi
	return 0
}

test_status_and_comment_failures() {
	reset_case
	TEST_STATUS_RC=1
	run_pass
	assert_no_write "a failed status transition posts no audit comment"
	reset_case
	TEST_COMMENT_RC=1
	TEST_COMMENTS_AFTER_ATTEMPT=$(pages "$(release_comment)" \
		"$(comment 6506415200 2026-10-29T19:50:00Z MEMBER pulse "<!-- aidevops:ops kind=draft-checkpoint-unblock pr=900 release=6506414392 -->")")
	run_pass
	if [[ "$(wc -l <"$COMMENT_ATTEMPTS" | tr -d ' ')" == "1" && -s "$STATUS_LOG" ]]; then
		pass "a comment that landed despite a client error is not retried"
	else
		fail "a comment that landed despite a client error is not retried" "attempts=$(wc -l <"$COMMENT_ATTEMPTS" | tr -d ' ')"
	fi
	return 0
}

# From PR #36031: keep the reason set aligned with the continuation helper
# without sourcing its CLI. Ownership loss is excluded here on purpose.
test_release_pattern_tracks_continuation_helper() {
	local pcc_pattern=""
	pcc_pattern=$(awk -F "'" '/^_PCC_STALL_RELEASE_PATTERN=/{print $2}' "${SCRIPT_DIR_TEST}/../pr-checkpoint-continuation-helper.sh")
	if [[ -n "$pcc_pattern" && "${pcc_pattern/worker_ownership_lost|/}" == "$_PDCU_RELEASE_REASON_PATTERN" ]]; then
		pass "release reasons match _PCC_STALL_RELEASE_PATTERN minus worker_ownership_lost"
	else
		fail "release reasons match _PCC_STALL_RELEASE_PATTERN minus worker_ownership_lost" "pcc=[${pcc_pattern}]"
	fi
	return 0
}

# From PR #36031: exercise the real cadence functions. Runs last because it
# sources pulse-wrapper-cycle.sh and replaces the pass with a recorder.
test_cycle_stamp_behavior() {
	local stamp="" rc=0 now=""
	# shellcheck source=../pulse-wrapper-cycle.sh
	source "$CYCLE_FILE"
	HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache"
	stamp="${HOME}/.aidevops/cache/draft-checkpoint-unblock-complete/owner__repo"
	_file_mtime_epoch() {
		local file="$1"
		if [[ -f "$file" ]]; then date +%s; else printf '0\n'; fi
		return 0
	}
	reconcile_stale_blocked_issues() { return 0; }
	_pm_reconcile_partial_continuations() { return 0; }
	_pm_reconcile_draft_checkpoint_blocks() {
		printf '%s\n' "$*" >>"${TEST_ROOT}/cycle"
		return "${CYCLE_RC:-0}"
	}
	now=$(date +%s)
	_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now" || rc=$?
	[[ "$rc" -eq 0 && -f "$stamp" ]] && pass "a complete pass writes its own stamp" ||
		fail "a complete pass writes its own stamp" "rc=${rc}"
	_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now" || true
	[[ "$(wc -l <"${TEST_ROOT}/cycle" | tr -d ' ')" == "1" ]] && pass "a fresh stamp skips the pass" ||
		fail "a fresh stamp skips the pass"
	rm -f "$stamp"
	if _pulse_stale_blocked_repo_all_fresh owner/repo 1800 "$now"; then
		fail "a missing unblock stamp keeps the repo due"
	else
		pass "a missing unblock stamp keeps the repo due"
	fi
	for CYCLE_RC in 3 1; do
		rc=0
		_pulse_stale_blocked_sweep_repo owner/repo "$((now + 60))" "$((now + 60))" 1800 "$now" || rc=$?
		[[ "$rc" -eq "$CYCLE_RC" && ! -f "$stamp" ]] && pass "pass rc ${CYCLE_RC} propagates and is not stamped" ||
			fail "pass rc ${CYCLE_RC} propagates and is not stamped" "rc=${rc}"
	done
	unset CYCLE_RC
	return 0
}

test_cycle_wiring() {
	local sweep="" all_fresh=""
	sweep=$(awk '/^_pulse_stale_blocked_sweep_repo\(\)/,/^}/' "$CYCLE_FILE")
	all_fresh=$(awk '/^_pulse_stale_blocked_repo_all_fresh\(\)/,/^}/' "$CYCLE_FILE")
	if [[ "$sweep" == *"_pm_reconcile_draft_checkpoint_blocks:draft-checkpoint-unblock-complete"* &&
		"$all_fresh" == *"draft-checkpoint-unblock-complete"* ]] &&
		grep -Eq '^source ".*/pulse-draft-checkpoint-unblock\.sh"$' "${SCRIPT_DIR_TEST}/../pulse-merge.sh"; then
		pass "the pass is sourced by pulse-merge.sh and scheduled with its own cadence stamp"
	else
		fail "the pass is sourced by pulse-merge.sh and scheduled with its own cadence stamp"
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	# shellcheck source=../pulse-draft-checkpoint-unblock.sh
	source "$MODULE_FILE"
	test_restores_worker_complete_projection
	test_restores_clean_release_unassigned
	test_restores_url_closing_reference
	test_terminal_lease_after_release_is_not_owner
	test_terminal_blocker_release_stays_blocked
	test_later_owner_event_stays_blocked
	test_untrusted_release_stays_blocked
	test_large_timeline_is_read_from_stdin
	test_label_actor_or_window_mismatch_stays_blocked
	test_protected_or_ineligible_issue_stays_blocked
	test_pr_shape_mismatch_stays_blocked
	test_pr_target_branch_guard
	test_idempotent_and_capped
	test_unreadable_reads_fail_closed
	test_deadline_and_listing_cost
	test_status_and_comment_failures
	test_cycle_wiring
	test_release_pattern_tracks_continuation_helper
	test_cycle_stamp_behavior
	printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
