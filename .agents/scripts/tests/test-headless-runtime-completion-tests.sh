#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker output, finalization, and orphan-recovery tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	# Keep the documented entry point executable without duplicating the harness.
	exec bash "$(dirname "$0")/test-headless-runtime-helper.sh" "$@"
fi
[[ -n "${_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_LOADED=1

_setup_test_git_repo() {
	local work_dir="$1"
	local add_commit="${2:-0}"
	mkdir -p "$work_dir"
	git -C "$work_dir" init -q
	git -C "$work_dir" config user.email "test@test.local"
	git -C "$work_dir" config user.name "Test"
	# Create initial commit on main so origin/main reference exists
	touch "$work_dir/README.md"
	git -C "$work_dir" add README.md
	git -C "$work_dir" commit -q -m "init"
	git -C "$work_dir" branch -M main
	# Create remote stub unique to this repo (bare repo alongside work_dir)
	local remote_dir="${work_dir}.remote.git"
	git init -q --bare "$remote_dir"
	git -C "$work_dir" remote add origin "$remote_dir"
	git -C "$work_dir" push -q origin main
	# Switch to feature branch
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	if [[ "$add_commit" -eq 1 ]]; then
		echo "change" >"$work_dir/change.txt"
		git -C "$work_dir" add change.txt
		git -C "$work_dir" commit -q -m "feat: add change"
	fi
	return 0
}

test_worker_produced_output_no_commits_returns_noop() {
	local work_dir="${TEST_ROOT}/repo-no-commits"
	_setup_test_git_repo "$work_dir" 0
	# No gh available in test env, no DISPATCH_REPO_SLUG set — signal 3 skipped
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' with zero commits" 0
	else
		print_result "_worker_produced_output returns 'noop' with zero commits" 1 \
			"Expected 'noop' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_manual_issue_no_commits_returns_noop() {
	local work_dir="${TEST_ROOT}/repo-manual-no-commits"
	local WORKER_ISSUE_NUMBER="99999"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "manual-cli-99999-1789490308" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output evaluates manual issue dispatches" 0
	else
		print_result "_worker_produced_output evaluates manual issue dispatches" 1 \
			"Expected noop, got $classification"
	fi
	return 0
}

run_worker_no_output_classification_tests() {
	test_negated_blocked_signals
	test_worker_produced_output_no_commits_returns_noop
	test_worker_produced_output_manual_issue_no_commits_returns_noop
	test_pr_less_rejection_evidence
	test_review_triage_completion_evidence
	test_already_satisfied_completion_evidence
	test_signal_less_exit_after_own_pr_handoff
	test_merged_missing_summary_output_class
	return 0
}

# t19196: after merge the MERGE_SUMMARY gates nothing. The probe has verified
# exact head, merge and closing linkage, so a closed issue is completion; an
# open issue is a merged checkpoint; an unreadable issue keeps the failure.
test_merged_missing_summary_output_class() {
	local fixture_issue expected got
	for fixture_issue in closed open unreadable; do
		case "$fixture_issue" in
		closed) expected=pr_exists ;;
		open) expected=merged_checkpoint ;;
		*) expected=merged_missing_summary ;;
		esac
		got=$(
			gh() {
				[[ "$fixture_issue" != unreadable ]] || return 1
				printf '%s\n' "$fixture_issue"
				return 0
			}
			_hrw_pr_output_class merged_missing_summary owner/repo 42 1
		)
		if [[ "$got" == "$expected" ]]; then
			print_result "merged_missing_summary with ${fixture_issue} issue classifies as ${expected}" 0
		else
			print_result "merged_missing_summary with ${fixture_issue} issue classifies as ${expected}" 1 "got: '${got}'"
		fi
	done
	got=$(_hrw_pr_output_class ready_missing_summary owner/repo 42 1)
	if [[ "$got" == "ready_missing_summary" ]]; then
		print_result "ready_missing_summary classification is unchanged" 0
	else
		print_result "ready_missing_summary classification is unchanged" 1 "got: '${got}'"
	fi
	return 0
}

test_negated_blocked_signals() {
	local file="${TEST_ROOT}/negated-blocked-output" text result
	for text in $'BLOCKED: none\n\nFULL_LOOP_COMPLETE' \
		'BLOCKED: none. FULL_LOOP_COMPLETE (Outcome A)' \
		'**Status:** **BLOCKED** - N/A! FULL_LOOP_COMPLETE' \
		$'BLOCKED: no\nFULL_LOOP_COMPLETE' \
		$'BLOCKED: nothing\nFULL_LOOP_COMPLETE'; do
		printf '%s\n' "$text" >"$file"
		result=0
		output_has_blocked_signal "$file" && result=1
		output_has_completion_signal "$file" || result=1
		print_result "Negated blocker preserves completion: $text" "$result"
	done
	for text in 'BLOCKED: source_exhausted' '**BLOCKED**: needs maintainer publish' \
		'BLOCKED: none available' $'BLOCKED: none\nBLOCKED: real failure' \
		'BLOCKED: no.json is missing' \
		'{"type":"result","result":"FULL_LOOP_COMPLETE\nBLOCKED: source_exhausted"}'; do
		printf '%s\n' "$text" >"$file"
		result=0
		output_has_blocked_signal "$file" || result=1
		print_result "Real blocker remains blocked: $text" "$result"
	done
	printf '%s\n' '{"type":"result","result":"FULL_LOOP_COMPLETE\nBLOCKED: none"}' >"$file"
	result=0
	output_has_blocked_signal "$file" && result=1
	print_result "Negated blocker ending a JSON result is not blocked" "$result"
	printf '%s\n' '{"type":"result","result":"FULL_LOOP_COMPLETE\nBLOCKED: none."}' >"$file"
	result=0
	output_has_blocked_signal "$file" && result=1
	print_result "Negated blocker with period ending a JSON result is not blocked" "$result"
	printf '%s\n' $'BLOCKED: none\nunfinished work' >"$file"
	result=0
	output_has_completion_signal "$file" && result=1
	print_result "Negated blocker alone is not completion" "$result"
	return 0
}

# GH#38303: synthetic exact-head PR state per scenario.
_signal_less_fixture_pr_state() {
	case "$1" in
	missing_summary) printf 'ready_missing_summary|7' ;;
	merged_closed | merged_marker | merged_marker_dirty) printf 'merged|7' ;;
	draft) printf 'draft_checkpoint|7' ;;
	merged_missing_summary) printf 'merged_missing_summary|7' ;;
	*) printf 'ready|7' ;;
	esac
	return 0
}

# GH#38303: classify one scenario. Callers run this in $(...), so the stubs
# below stay scoped to that subshell.
_signal_less_fixture_result() {
	local scenario="$1" work_dir="$2"
	_headless_private_workload_enabled() { return 1; }
	_run_result_capture_live_blocker() { return 1; }
	output_has_post_pr_handoff_signal() { return 1; }
	output_has_blocked_signal() { return 1; }
	output_has_missing_context_blocked_signal() { return 1; }
	output_has_capability_blocked_signal() { return 1; }
	_run_result_terminal_completion_confirmed() { return 1; }
	_log_empty_result_gaps() { return 0; }
	print_warning() { return 0; }
	print_info() { return 0; }
	_pr_handoff_state_for_branch_or_issue() { _signal_less_fixture_pr_state "$scenario"; return 0; }
	gh() {
		[[ "$*" == "api repos/owner/repo/issues/42" && "$scenario" != unreadable ]] || return 1
		jq -cn --arg scenario "$scenario" '{number:42,state:"open",assignees:[{login:"runner"}],
			labels:[{name:"auto-dispatch"},{name:"status:in-review"}]}
			| if ($scenario | startswith("merged_")) then .state = "closed"
			elif $scenario == "foreign_assignee" then .assignees += [{login:"other"}]
			elif $scenario == "still_owned" then .labels = [{name:"status:in-progress"}]
			else . end'
		return 0
	}
	# shellcheck disable=SC2034 # Classifier inputs read by sourced result phases.
	local WORKER_ISSUE_NUMBER=42 DISPATCH_REPO_SLUG=owner/repo WORKER_GITHUB_LOGIN=runner
	# shellcheck disable=SC2034
	local AIDEVOPS_PR_REPAIR_NUMBER="" role=worker session_key=issue-42 discovered_session="" selected_model=fixture
	[[ "$scenario" != repair_contract ]] || AIDEVOPS_PR_REPAIR_NUMBER=7
	local output_file="${work_dir}.ndjson" rc=0
	printf '%s\n' '{"type":"text","text":"Opened the PR."}' >"$output_file"
	_run_result_label="" _run_failure_reason="unset" _run_classification_source="" _run_classification_pattern=""
	_handle_run_result_success_output || rc=$?
	printf 'rc=%s label=%s reason=%s source=%s pattern=%s' "$rc" "$_run_result_label" \
		"$_run_failure_reason" "$_run_classification_source" "$_run_classification_pattern"
	return 0
}

# GH#38303: a no-signal exit after the worker's own non-draft PR becomes a
# post-PR handoff only when the continuation would be ownership-fenced.
# Forge reads are synthetic; the worktree cleanliness check uses real Git.
# GH#38329: the post-merge cleanup-deferred marker alone is not unpublished work.
test_signal_less_exit_after_own_pr_handoff() {
	local scenario expected evidence work_dir
	for scenario in ready missing_summary merged_closed merged_marker merged_marker_dirty draft foreign_assignee still_owned unreadable dirty repair_contract merged_missing_summary; do
		work_dir="${TEST_ROOT}/signal-less-${scenario}"
		_setup_test_git_repo "$work_dir" 1
		[[ "$scenario" != dirty && "$scenario" != merged_marker_dirty ]] || touch "$work_dir/unpublished"
		if [[ "$scenario" == merged_marker || "$scenario" == merged_marker_dirty ]]; then
			mkdir -p "$work_dir/.agents"
			touch "$work_dir/.agents/.full-loop-cleanup-deferred"
		fi
		evidence=$(_signal_less_fixture_result "$scenario" "$work_dir")
		case "$scenario" in
		ready) expected='rc=0 label=post_pr_handoff reason= source=worker_pr_handoff_without_signal pattern=ready' ;;
		missing_summary) expected='rc=0 label=post_pr_handoff reason= source=worker_pr_handoff_without_signal pattern=ready_missing_summary' ;;
		merged_closed | merged_marker) expected='rc=0 label=post_pr_handoff reason= source=worker_pr_handoff_without_signal pattern=merged' ;;
		*) expected='rc=77 label=premature_exit ' ;;
		esac
		local result=1
		[[ "$evidence" == "$expected"* ]] && result=0
		print_result "Signal-less exit ${scenario}: own PR handoff routes to gate only when continuation is fenced" "$result" "$evidence"
	done
	return 0
}

# GH#37515: synthetic forge evidence for already-satisfied no-PR closes.
_already_satisfied_fixture_gh() {
	local request="$*"
	case "$request" in
	"api user --jq .login") printf 'worker\n' ;;
	"api repos/owner/repo/issues/456")
		jq -cn --arg shape "$shape" '{number:456,state:"closed",state_reason:"completed",
			author_association:"OWNER",closed_by:{login:"worker"},closed_at:"2026-10-25T12:01:00Z",
			html_url:"https://github.com/owner/repo/issues/456",labels:[{name:"auto-dispatch"},{name:"status:queued"}],
			body:"Roll out the helper in `README.md` as in the earlier issue."}
			| if $shape == "premise_falsified" then .state_reason = "not_planned"
			elif $shape == "wrong_closer" then .closed_by.login = "other"
			elif $shape == "unbound_path" then .body = "Roll out the helper as in the earlier issue."
			elif $shape == "nested_path" then .body = "Roll out the helper in `docs/README.md`."
			elif $shape == "prefixed_path" then .body = "Roll out the helper in `old-README.md`."
			elif $shape == "extended_path" then .body = "Roll out the helper in `README.md.bak`."
			elif $shape == "dotted_path" then .body = "Roll out the helper in `README.md./other`."
			elif $shape == "double_dot_path" then .body = "Roll out the helper in `README.md..backup`."
			elif $shape == "period_path" then .body = "Roll out the helper in README.md."
			elif $shape == "comma_path" then .body = "Update README.md, then verify."
			elif $shape == "parenthesized_path" then .body = "Roll out the helper (README.md)."
			elif $shape == "closed_before_attempt" then .closed_at = "2026-10-24T12:00:00Z"
			elif $shape == "review_feedback" then .body = "## Unactioned Review Feedback\n**File**: `README.md`\nquality-feedback-helper.sh scan-merged"
			else . end'
		;;
	"api --paginate repos/owner/repo/issues/456/comments?per_page=100")
		jq -cn --arg shape "$shape" --arg blob "$fixture_blob" '
			{schema:1,repository:"owner/repo",issue:456,attempt_id:"fixture",attempt_started_at:"1792929600000000000",
			 disposition:"already_satisfied",evidence_pr:42,path:"README.md",blob:$blob,
			 rationale:"Merged PR #42 already delivered README.md on the live default branch."}
			| if $shape == "premise_falsified" then .disposition = "premise_falsified" | del(.evidence_pr)
			elif $shape == "no_evidence" then del(.evidence_pr)
			elif $shape == "wrong_attempt" then .attempt_id = "old"
			elif $shape == "unsafe_path" then .path = "../README.md" else . end
			| {id:9,html_url:"https://github.com/owner/repo/issues/456#issuecomment-9",user:{login:"worker"},
			 author_association:"OWNER",created_at:"2026-10-25T12:00:30Z",updated_at:"2026-10-25T12:00:30Z",
			 body:("<!-- aidevops:already-satisfied-completion:v1 -->\n" + tojson)} as $receipt
			| [$receipt]
			| if $shape == "missing" or $shape == "completion_marker" then [$receipt | .body = "Already satisfied by #42; closing."]
			elif $shape == "duplicated" then . + [$receipt | .id = 10 | .html_url |= sub("9$"; "10")]
			elif $shape == "stale" then .[0].created_at = "2026-10-24T12:00:00Z"
			elif $shape == "retried" then [$receipt | .id = 8 | .created_at = "2026-10-24T12:00:00Z"] + .
			elif $shape == "edited_after_close" then .[0].updated_at = "2026-10-25T12:02:00Z"
			elif $shape == "wrong_author" then .[0].user.login = "other"
			elif $shape == "untrusted_receipt" then .[0].author_association = "NONE"
			elif $shape == "spoofed_url" then .[0].html_url = "https://example.invalid/comment"
			else . end'
		;;
	"api repos/owner/repo/pulls/42")
		jq -cn --arg shape "$shape" '{number:42,state:"closed",merged_at:"2026-10-24T00:00:00Z",base:{repo:{full_name:"owner/repo"}}}
			| if $shape == "unmerged" then .merged_at = null else . end'
		;;
	"api --paginate repos/owner/repo/pulls/42/files?per_page=100")
		jq -cn --arg shape "$shape" '[{filename:"README.md",status:"modified"}]
			| if $shape == "untouched" then .[0].filename = "other.md"
			elif $shape == "removed" then .[0].status = "removed" else . end'
		;;
	"issue edit 456 --repo owner/repo "*) printf '%s\n' "$request" >>"$label_log" ;;
	"pr list"*) [[ "$request" != *--head* ]] || printf '0\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_already_satisfied_fixture_result() {
	local shape="$1"
	local WORKER_ISSUE_NUMBER=456 DISPATCH_REPO_SLUG=owner/repo
	local AIDEVOPS_ATTEMPT_ID=fixture AIDEVOPS_ATTEMPT_STARTED_AT=1792929600000000000
	local work_dir="${TEST_ROOT}/satisfied-${shape}" output_file="${TEST_ROOT}/satisfied-output"
	local role=worker provider=openai session_key=issue-456 selected_model=openai/fixture
	local permission_request_file="${TEST_ROOT}/permission" metric_work_dir="$work_dir"
	local _metric_kill_reason=natural _metric_session_id="" _metric_output_file=""
	local _metric_excerpt_candidate="${TEST_ROOT}/satisfied-excerpt" resource_sampler_pid=""
	local _run_failure_reason="" _run_permission_request_file=""
	local exit_code=0 start_ms=0 end_ms=0 duration_ms=0 rc=0 fixture_blob label_log="${TEST_ROOT}/satisfied-labels-${shape}"
	_setup_test_git_repo "$work_dir" 0
	fixture_blob=$(git -C "$work_dir" rev-parse HEAD:README.md)
	_HRW_PR_LESS_VERIFIED_CONTEXT=""
	_hrw_own_merged_terminal_complete() { return 1; }
	_hrw_continued_merged_terminal_complete() { return 1; }
	_hrw_post_merge_permission_completion_evidence() { return 1; }
	_hrw_resolve_default_branch() { printf main; return 0; }
	_hrw_reconcile_session_permission_blockers() { return 0; }
	gh() { _already_satisfied_fixture_gh "$@"; return $?; }
	append_runtime_metric() { printf 'metric=%s|%s|%s|%s\n' "$5" "$6" "${18}" "${19}"; return 0; }
	case "$shape" in
	missing_attempt) AIDEVOPS_ATTEMPT_ID="" ;;
	dirty) touch "$work_dir/unpublished" ;;
	stale_blob)
		printf 'changed\n' >"$work_dir/README.md"
		git -C "$work_dir" add README.md
		git -C "$work_dir" commit -qm changed
		git -C "$work_dir" push -q origin HEAD:main
		git -C "$work_dir" reset -q --hard HEAD~1
		;;
	esac
	printf '%s\n' '{"type":"text","text":"Verified the work is already on the live default branch and closed the issue."}' >"$output_file"
	[[ "$shape" != completion_marker ]] || printf '%s\n' '{"type":"text","text":"FULL_LOOP_COMPLETE"}' >>"$output_file"
	printf 'process exit\n' >"$_metric_excerpt_candidate"
	_finish_run_attempt_result || rc=$?
	printf 'rc=%s normalized=%s\n' "$rc" "$([[ -f "$label_log" ]] && printf yes || printf no)"
	# The success finisher gates worker_noop on this predicate, not the marker.
	local objective=0
	_hrw_terminal_objective_complete "$session_key" "$work_dir" || objective=$?
	printf 'objective=%s reason=%s\n' "$objective" "${_HRW_PR_LESS_REJECTION:-}"
	return 0
}

test_already_satisfied_completion_evidence() {
	local shape evidence result expected
	for shape in already_satisfied premise_falsified retried missing completion_marker duplicated stale edited_after_close wrong_closer wrong_author untrusted_receipt spoofed_url wrong_attempt unsafe_path no_evidence unbound_path nested_path prefixed_path extended_path dotted_path double_dot_path period_path comma_path parenthesized_path unmerged untouched removed stale_blob dirty closed_before_attempt missing_attempt review_feedback; do
		evidence=$(_already_satisfied_fixture_result "$shape")
		result=1
		case "$shape" in
		missing | completion_marker) expected=already_satisfied_receipt_missing ;;
		duplicated) expected=already_satisfied_receipt_duplicated ;;
		stale) expected=already_satisfied_receipt_stale ;;
		edited_after_close) expected=already_satisfied_receipt_edited ;;
		wrong_closer | wrong_author | untrusted_receipt) expected=already_satisfied_closer_mismatch ;;
		spoofed_url | wrong_attempt | unsafe_path | no_evidence) expected=already_satisfied_receipt_invalid ;;
		unbound_path | nested_path | prefixed_path | extended_path | dotted_path | double_dot_path) expected=already_satisfied_path_unbound ;;
		unmerged | untouched | removed) expected=already_satisfied_evidence_invalid ;;
		stale_blob) expected=already_satisfied_default_blob_mismatch ;;
		dirty) expected=unpublished_worktree_changes ;;
		# Shapes outside this predicate keep the earlier predicate's reason.
		closed_before_attempt | missing_attempt) expected=no_merged_pr_candidate ;;
		review_feedback) expected=triage_context_invalid ;;
		*) expected=success ;;
		esac
		if [[ "$expected" == success ]]; then
			[[ "$evidence" == *'metric=success|0|'* && "$evidence" == *'rc=0 normalized=yes'* &&
				"$evidence" == *'objective=0 reason='* && "$evidence" != *pr_less_completion_rejected* ]] && result=0
		elif [[ "$shape" == completion_marker ]]; then
			# A bare marker ends the run, but is never credited as the objective.
			[[ "$evidence" == *'normalized=no'* && "$evidence" == *"objective=1 reason=${expected}"* ]] && result=0
		elif [[ "$evidence" == *"metric=premature_exit|77|pr_less_completion_rejected|${expected}"* &&
			"$evidence" == *'normalized=no'* && "$evidence" == *"objective=1 reason="* ]]; then
			# The runtime mints a fresh attempt ID when none was bound, so the
			# later re-check rejects the fixture receipt instead of retaining.
			[[ "$shape" == missing_attempt || "$evidence" == *"objective=1 reason=${expected}"* ]] && result=0
		fi
		print_result "Already satisfied ${shape}: evidence-bound no-PR close preserves guards" "$result" "$evidence"
	done
	return 0
}

# All forge calls are synthetic; local unpublished-work checks use real Git.
_review_triage_fixture_gh() {
	local request="$*"
	case "$request" in
	"api user --jq .login") printf 'triager\n' ;;
	"api repos/owner/repo/issues/456")
		[[ "$shape" != api_marker ]] || return 1
		jq -cn --arg shape "$shape" '{number:456,state:"closed",state_reason:"not_planned",
			author_association:"COLLABORATOR",closed_by:{login:"triager"},closed_at:"2026-10-25T12:01:00Z",
			html_url:"https://github.com/owner/repo/issues/456",labels:[{name:"auto-dispatch"},{name:"status:in-progress"}],
			body:"## Unactioned Review Feedback\n**Source PR**: #40\n**File**: `README.md`\n**Findings**: 1\nIndentation should be fixed.\n[View comment](https://github.com/owner/repo/pull/40#discussion_r7)\nquality-feedback-helper.sh scan-merged"}
			| if $shape == "ordinary" then .body = "Implement the new feature"
			elif $shape == "untrusted_issue" then .author_association = "NONE"
			elif $shape == "open" or $shape == "open_marker" then .state = "open"
			elif $shape == "completed" then .state_reason = "completed"
			elif $shape == "wrong_closer" then .closed_by.login = "other"
			elif $shape == "multiple_findings" then .body |= sub("Findings\\*\\*: 1"; "Findings**: 2")
			else . end'
		;;
	"api --paginate repos/owner/repo/issues/456/comments?per_page=100")
		jq -cn --arg shape "$shape" --arg blob "$fixture_blob" '
			{schema:1,repository:"owner/repo",issue:456,attempt_id:"fixture",attempt_started_at:"1792929600000000000",
			 disposition:"obsolete",source_pr:40,review_comment_id:7,evidence_pr:42,path:"README.md",blob:$blob,
			 rationale:"The cited merged change fixes the captured indentation finding."}
			| if $shape == "wrong_attempt" or $shape == "forged_marker" then .attempt_id = "old"
			elif $shape == "wrong_repo" then .repository = "other/repo"
			elif $shape == "wrong_issue" then .issue = 789
			elif $shape == "false_premise" then .disposition = "premise_falsified"
			elif $shape == "implementation" then .disposition = "implemented" else . end
			| [{id:9,html_url:"https://github.com/owner/repo/issues/456#issuecomment-9",user:{login:"triager"},
			 author_association:"COLLABORATOR",created_at:"2026-10-25T12:00:01Z",updated_at:"2026-10-25T12:00:01Z",
			 body:("<!-- aidevops:review-triage-completion:v1 -->\n" + tojson)}]
			| if $shape == "untrusted_receipt" then .[0].author_association = "NONE"
			elif $shape == "wrong_author" then .[0].user.login = "other"
			elif $shape == "old_receipt" then .[0].created_at = "2026-10-24T12:00:00Z"
			elif $shape == "edited_after_close" then .[0].updated_at = "2026-10-25T12:02:00Z"
			elif $shape == "spoofed_url" then .[0].html_url = "https://example.invalid/comment"
			elif $shape == "prose_only" then .[0].body = "The premise was falsified; issue closed."
			elif $shape == "appended_findings" then . + [{body:"## Additional Review Feedback (PR #41)\nAn unresolved finding"}]
			else . end'
		;;
	"api repos/owner/repo/pulls/comments/7")
		jq -cn --arg shape "$shape" '{pull_request_url:"https://api.github.com/repos/owner/repo/pulls/40",
			html_url:"https://github.com/owner/repo/pull/40#discussion_r7",path:"README.md",body:"Indentation should be fixed."}
			| if $shape == "wrong_review" then .pull_request_url += "1"
			elif $shape == "uncaptured_review" then .body = "Unrelated suggestion" else . end'
		;;
	"api repos/owner/repo/pulls/42")
		jq -cn --arg shape "$shape" '{number:42,state:"closed",merged_at:"2026-10-24T00:00:00Z",base:{repo:{full_name:"owner/repo"}}}
			| if $shape == "unmerged" then .merged_at = null else . end'
		;;
	"api --paginate repos/owner/repo/pulls/42/files?per_page=100")
		jq -cn --arg blob "$fixture_blob" '[{filename:"README.md",sha:$blob,status:"modified"}]'
		;;
	"issue edit 456 --repo owner/repo "*)
		[[ "$shape" != label_failure ]] || return 1
		printf '%s\n' "$request" >>"$label_log"
		;;
	"pr list"*) [[ "$request" != *--head* ]] || printf '0\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_review_triage_fixture_result() {
	local shape="$1"
	local WORKER_ISSUE_NUMBER=456 DISPATCH_REPO_SLUG=owner/repo
	local AIDEVOPS_ATTEMPT_ID=fixture AIDEVOPS_ATTEMPT_STARTED_AT=1792929600000000000
	local work_dir="${TEST_ROOT}/triage-${shape}" output_file="${TEST_ROOT}/triage-output"
	local role=worker provider=openai session_key=issue-456 selected_model=openai/fixture
	local permission_request_file="${TEST_ROOT}/permission" metric_work_dir="$work_dir"
	local _metric_kill_reason=natural _metric_session_id="" _metric_output_file=""
	local _metric_excerpt_candidate="${TEST_ROOT}/triage-excerpt" resource_sampler_pid=""
	local _run_failure_reason="" _run_permission_request_file=""
	local exit_code=0 start_ms=0 end_ms=0 duration_ms=0 rc=0 fixture_blob label_log="${TEST_ROOT}/triage-labels-${shape}"
	_setup_test_git_repo "$work_dir" 0
	fixture_blob=$(git -C "$work_dir" rev-parse HEAD:README.md)
	_HRW_PR_LESS_VERIFIED_CONTEXT=""
	_hrw_own_merged_terminal_complete() { return 1; }
	_hrw_continued_merged_terminal_complete() { return 1; }
	_hrw_post_merge_permission_completion_evidence() { return 1; }
	_hrw_resolve_default_branch() { printf main; return 0; }
	_hrw_reconcile_session_permission_blockers() { return 0; }
	gh() { _review_triage_fixture_gh "$@"; return $?; }
	append_runtime_metric() { printf 'metric=%s|%s|%s|%s\n' "$5" "$6" "${18}" "${19}"; return 0; }
	case "$shape" in
	missing_attempt) AIDEVOPS_ATTEMPT_ID="" ;;
	dirty) touch "$work_dir/unpublished" ;;
	ahead)
		touch "$work_dir/unpublished"
		git -C "$work_dir" add unpublished
		git -C "$work_dir" commit -qm unpublished
		;;
	stale_blob)
		printf 'changed\n' >"$work_dir/README.md"
		git -C "$work_dir" add README.md
		git -C "$work_dir" commit -qm changed
		git -C "$work_dir" push -q origin HEAD:main
		;;
	permission) _run_permission_request_file="${TEST_ROOT}/triage-permission-event.json"; touch "$_run_permission_request_file" ;;
	provider) exit_code=1 ;;
	esac
	printf '%s\n' '{"type":"text","text":"Investigated and closed the obsolete review finding without code changes."}' >"$output_file"
	if [[ "$shape" == *_marker ]]; then
		printf '%s\n' '{"type":"text","text":"FULL_LOOP_COMPLETE"}' >>"$output_file"
	fi
	[[ "$shape" != provider ]] || printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"Too Many Requests","statusCode":429,"isRetryable":true}}}' >>"$output_file"
	printf 'process exit\n' >"$_metric_excerpt_candidate"
	_finish_run_attempt_result || rc=$?
	printf 'rc=%s normalized=%s\n' "$rc" "$([[ -f "$label_log" ]] && printf yes || printf no)"
	return 0
}

test_review_triage_completion_evidence() {
	local shape evidence result expected
	for shape in obsolete false_premise completed completion_marker forged_marker api_marker open_marker ordinary untrusted_issue open wrong_closer multiple_findings appended_findings wrong_attempt wrong_repo wrong_issue implementation untrusted_receipt wrong_author old_receipt edited_after_close spoofed_url prose_only wrong_review uncaptured_review unmerged missing_attempt dirty ahead stale_blob label_failure permission provider; do
		evidence=$(_review_triage_fixture_result "$shape")
		result=1
		expected=triage_receipt_invalid
		case "$shape" in
		# An ordinary issue the runner closed in this attempt needs the GH#37515 receipt.
		ordinary) expected=already_satisfied_receipt_missing ;;
		untrusted_issue) expected=issue_not_trusted_completed ;;
		open | open_marker) expected=issue_not_closed ;;
		api_marker) expected=issue_evidence_unavailable ;;
		multiple_findings | missing_attempt) expected=triage_context_invalid ;;
		wrong_review | uncaptured_review) expected=triage_review_invalid ;;
		unmerged) expected=triage_support_invalid ;;
		dirty) expected=unpublished_worktree_changes ;;
		ahead) expected=unpublished_local_commits ;;
		stale_blob) expected=triage_default_blob_mismatch ;;
		label_failure) expected=completion_labels_unavailable ;;
		esac
		case "$shape" in
		obsolete | false_premise | completed | completion_marker)
			[[ "$evidence" == *'metric=success|0|review_triage_receipt|verified_no_code_review_triage'* &&
				"$evidence" == *'rc=0 normalized=yes'* ]] && result=0
			;;
		permission) [[ "$evidence" == *'metric=permission_required|84|opencode_permission_event|'* && "$evidence" == *'normalized=no'* ]] && result=0 ;;
		provider) [[ "$evidence" == *'metric=rate_limit|'* && "$evidence" == *'normalized=no'* ]] && result=0 ;;
		*) [[ "$evidence" == *"metric=premature_exit|77|pr_less_completion_rejected|${expected}"* && "$evidence" == *'normalized=no'* ]] && result=0 ;;
		esac
		print_result "Review triage ${shape}: authenticated no-code outcome preserves guards" "$result" "$evidence"
	done
	return 0
}

# Synthetic forge evidence shared by the GH#36100 shapes via dynamic scope.
_pr_less_rejection_fixture_gh() {
	local request="$*"
	case "$request" in
	"issue edit 456 --repo owner/repo "*) return 0 ;;
	"api repos/owner/repo/issues/456")
		[[ "$shape" != issue_api ]] || {
			printf 'protected API detail\n' >&2
			return 1
		}
		printf '%s\n' '{"state":"closed","state_reason":"completed","author_association":"OWNER","updated_at":"fixture","body":"Already delivered by #42"}'
		;;
	"pr list"*)
		if [[ "$request" == *--head* ]]; then
			printf '0\n'
		elif [[ "$shape" == search_api ]]; then
			return 1
		elif [[ "$shape" == multiple_candidates ]]; then
			printf '42\n43\n'
		elif [[ "$shape" != no_candidate ]]; then printf '42\n'; fi
		;;
	"pr view"*)
		[[ "$shape" != candidate_api ]] || return 1
		[[ "$request" != 'pr view 43 '* ]] || return 1
		if [[ "$shape" == valid_closing ]]; then
			printf '%s\n' '{"state":"MERGED","mergedAt":"fixture","closingIssuesReferences":[{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]}'
		else
			printf '%s\n' '{"state":"MERGED","mergedAt":"fixture","closingIssuesReferences":[]}'
		fi
		;;
	*) return 1 ;;
	esac
	return 0
}

# Keep the case-based fixture outside command substitution for Bash 3.2 parsing.
_pr_less_rejection_fixture_evidence() {
	local shape="$1"
	local WORKER_ISSUE_NUMBER=456 DISPATCH_REPO_SLUG=owner/repo
	local AIDEVOPS_ATTEMPT_ID=fixture AIDEVOPS_ATTEMPT_STARTED_AT=1792929600000000000
	local work_dir="${TEST_ROOT}/rejection-${shape}" output_file="${TEST_ROOT}/rejection-output"
	local role=worker provider=openai session_key=issue-456 selected_model=openai/fixture
	local permission_request_file="${TEST_ROOT}/permission" metric_work_dir="$work_dir"
	local _metric_kill_reason=natural _metric_session_id="" _metric_output_file=""
	local _metric_excerpt_candidate="${TEST_ROOT}/rejection-excerpt" resource_sampler_pid=""
	local _run_failure_reason=""
	local exit_code=0 start_ms=0 end_ms=0 duration_ms=0 rc=0 fixture_head fixture_branch fixture_blob
	_setup_test_git_repo "$work_dir" 0
	fixture_head=$(git -C "$work_dir" rev-parse HEAD)
	fixture_branch=$(git -C "$work_dir" branch --show-current)
	fixture_blob=$(git -C "$work_dir" rev-parse HEAD:README.md)
	# Stale diagnostic state must not survive a new successful evaluation.
	_HRW_PR_LESS_REJECTION=stale_previous_rejection
	_HRW_PR_LESS_VERIFIED_CONTEXT=""
	_hrw_own_merged_terminal_complete() { return 1; }
	_hrw_resolve_default_branch() {
		printf main
		return 0
	}
	_hrw_reconcile_session_permission_blockers() { return 0; }
	gh() {
		_pr_less_rejection_fixture_gh "$@"
		return $?
	}
	# Model verifier output, not acceptance: production runtime still checks
	# attempt, scope blobs, local context and issue revision independently.
	bash() {
		[[ "$shape" != missing_receipt ]] || return 1
		if [[ "$shape" == invalid_receipt || "$shape" == multiple_candidates ]]; then
			printf 'unreadable receipt\n'
			return 0
		fi
		jq -cn --arg head "$fixture_head" --arg branch "$fixture_branch" --arg worktree "$work_dir" --arg blob "$fixture_blob" \
			--arg shape "$shape" '{schema_version:1,kind:"scoped_delivery",verified:true,
				repository:"owner/repo",issue:456,pr:42,attempt_id:"fixture",attempt_started_at:"1792929600000000000",
				worktree:$worktree,head:$head,branch:$branch,issue_updated_at:"fixture",files:[{path:"README.md",blob:$blob}]}
				| if $shape == "stale_receipt" then .attempt_id = "older"
				elif $shape == "blob_mismatch" then .files[0].blob = ("f" * 40) else . end'
		return 0
	}
	append_runtime_metric() {
		printf 'metric=%s|%s|%s|%s\n' "$5" "$6" "${18}" "${19}"
		if [[ -f "${13}" ]]; then
			grep -F 'classification_source=pr_less_completion_rejected' "${13}"
		fi
		return 0
	}
	case "$shape" in
	missing_attempt) AIDEVOPS_ATTEMPT_ID="" ;;
	dirty) touch "$work_dir/unpublished" ;;
	ahead)
		touch "$work_dir/unpublished"
		git -C "$work_dir" add unpublished
		git -C "$work_dir" commit -qm unpublished
		;;
	esac
	printf '%s\n' '{"type":"text","text":"Already satisfied by older merged PR #42; tests passed; issue closed."}' >"$output_file"
	if [[ "$shape" == valid_closing ]]; then
		shape=no_candidate
		_run_result_terminal_completion_confirmed && exit 1
		[[ "$_run_classification_source" == pr_less_completion_rejected ]] || exit 1
		shape=valid_closing
		_run_result_terminal_completion_confirmed || exit 1
		[[ -z "$_run_classification_source" && -z "$_run_classification_pattern" ]] || exit 1
	fi
	printf 'process exit 0\n' >"$_metric_excerpt_candidate"
	_finish_run_attempt_result || rc=$?
	printf 'rc=%s reason=%s\n' "$rc" "${_HRW_PR_LESS_REJECTION:-}"
	return 0
}

# GH#36100: exit 0 and a closed issue citing an older PR are not proof. Exercise
# candidate discovery separately from receipt validation, through final metrics.
test_pr_less_rejection_evidence() {
	local shape expected evidence result
	for shape in no_candidate issue_api search_api candidate_api missing_attempt missing_receipt invalid_receipt stale_receipt multiple_candidates dirty ahead blob_mismatch valid_scope valid_closing; do
		case "$shape" in
		no_candidate) expected=no_merged_pr_candidate ;;
		issue_api) expected=issue_evidence_unavailable ;;
		search_api) expected=candidate_discovery_unavailable ;;
		candidate_api) expected=candidate_evidence_unavailable ;;
		missing_attempt) expected=scoped_attempt_binding_missing ;;
		missing_receipt) expected=scoped_receipt_unavailable ;;
		invalid_receipt | stale_receipt | multiple_candidates) expected=scoped_receipt_invalid ;;
		dirty) expected=unpublished_worktree_changes ;;
		ahead) expected=unpublished_local_commits ;;
		blob_mismatch) expected=scoped_default_blob_mismatch ;;
		valid_scope | valid_closing) expected=success ;;
		esac
		evidence=$(_pr_less_rejection_fixture_evidence "$shape")
		result=1
		if [[ "$expected" == success ]]; then
			[[ "$evidence" == *'metric=success|0|'* && "$evidence" == *'rc=0 reason=' && "$evidence" != *pr_less_completion_rejected* ]] && result=0
		elif [[ "$evidence" == *"metric=premature_exit|77|pr_less_completion_rejected|${expected}"* &&
			"$evidence" == *"cause=premature_exit "* && "$evidence" == *"classification_pattern=${expected}"* &&
			"$evidence" == *"rc=77 reason=${expected}" && "$evidence" != *'protected API detail'* ]]; then
			result=0
		fi
		print_result "PR-less ${shape}: bounded rejection survives exit diagnostics and metrics" "$result" "$evidence"
	done
	return 0
}

test_worker_produced_output_with_commits_returns_pr_exists_failopen() {
	# Commits present but no DISPATCH_REPO_SLUG → cannot confirm PR absence → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-with-commits"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 1 \
			"Expected 'pr_exists' (fail-open) but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_non_worker_session_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pulse"
	_setup_test_git_repo "$work_dir" 0

	# Non-worker session keys (pulse, triage) must always return pr_exists (fail-open)
	local classification
	classification=$(_worker_produced_output "pulse-main" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 1 \
			"Non-worker session should always return 'pr_exists' (fail-open), got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_invalid_workdir_returns_pr_exists() {
	# Missing / non-git work_dir must fail-open
	local classification
	classification=$(_worker_produced_output "issue-99999" "/nonexistent/path/$$")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 1 \
			"Invalid work_dir should fail-open as 'pr_exists', got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_zero_diff_pushed_branch_returns_noop() {
	# A successful zero-count comparison proves no PR can exist for this head,
	# even when the feature ref was pushed and repo slug context is unavailable.
	local work_dir="${TEST_ROOT}/repo-pushed-noslug"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 0
	else
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 1 \
			"Expected 'noop' after a successful zero-count base comparison, got '${classification}'"
	fi
	return 0
}

# AC#2: pushed branch + confirmed no PR → branch_orphan
test_worker_produced_output_branch_no_pr_returns_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-orphan"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	# Set DISPATCH_REPO_SLUG and stub the PR-list wrapper to return no PRs.
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh_pr_list() { printf '[]'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh_pr_list 2>/dev/null || true

	if [[ "$classification" == "branch_orphan" ]]; then
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 0
	else
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 1 \
			"Expected 'branch_orphan' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_local_branch_no_remote_returns_local_branch_unpushed() {
	local work_dir="${TEST_ROOT}/repo-local-unpushed"
	_setup_test_git_repo "$work_dir" 1
	# Do not push the feature branch: local commits exist, remote branch absent.
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh_pr_list() { printf '[]'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh_pr_list 2>/dev/null || true

	if [[ "$classification" == "local_branch_unpushed" ]]; then
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 0
	else
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 1 \
			"Expected 'local_branch_unpushed' but got '${classification}'"
	fi
	return 0
}

# AC#2 variant: PR confirmed → pr_exists even when branch is pushed
test_worker_produced_output_branch_with_pr_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pr-exists"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	gh_pr_list() {
		printf '[{"number":123,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]\n' "$expected_head"
		return 0
	}
	gh() {
		if [[ "${*}" == *"api --paginate"* && "${*}" == *"/issues/123/comments"* ]]; then
			printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
		elif [[ "${*}" == *"api repos/"* && "${*}" == *"/pulls/123"* ]]; then
			printf '%s\n' 'Resolves #99999'
		else
			return 1
		fi
		return 0
	}

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh_pr_list 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	# The focused stubs above replace shell functions rather than commands.
	# Restore direct adapters for the remaining completion tests so later stubs
	# do not fall through to missing wrapper functions.
	gh_pr_list() { gh pr list "$@"; return $?; }
	gh_issue_view() { gh issue view "$@"; return $?; }

	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 1 \
			"Expected 'pr_exists' but got '${classification}'"
	fi
	return 0
}

# shellcheck source=./test-headless-runtime-completion-tests-finish.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-headless-runtime-completion-tests-finish.sh"
# shellcheck source=./test-headless-runtime-completion-tests-recovery.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-headless-runtime-completion-tests-recovery.sh"
