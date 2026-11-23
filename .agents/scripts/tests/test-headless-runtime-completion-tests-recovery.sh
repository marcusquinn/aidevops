#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Run-id refresh, reconciled-outcome and orphan-recovery tests.
#
# Sourced by test-headless-runtime-completion-tests.sh (itself sourced by
# test-headless-runtime-harness.sh) after the shared test harness is initialized.

[[ -n "${_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_RECOVERY_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_RECOVERY_LOADED=1

# True when a stubbed gh call is the shared PR-base resolver's remote default
# lookup (`gh api repos/<slug> --jq .default_branch`, shared-pr-base.sh,
# GH#39167). Stubs answer it so fixtures without a configured base still
# resolve one; the resolver no longer reads `gh repo view` (GH#39209).
_fixture_gh_is_default_branch_lookup() {
	[[ "${1:-}" == "api" && "${2:-}" == "repos/test-owner/test-repo" ]]
	return $?
}

# `gh pr create` runs inside a command substitution (_create_orphan_recovery_pr),
# so a stub cannot report it through parent-shell variables. Stubs record the
# NUL-delimited argv to a log file instead; tests read it back with
# _fixture_pr_create_flag.
_fixture_record_gh_pr_create() {
	local log="$1"
	shift
	if [[ "${*}" == *"pr create"* ]]; then
		printf '%s\0' "$@" >>"$log"
	fi
	return 0
}

# Print every value following the given flag in the recorded argv, comma-joined.
_fixture_pr_create_flag() {
	local log="$1"
	local flag="$2"
	local arg="" prev="" joined=""
	[[ -f "$log" ]] || return 0
	while IFS= read -r -d '' arg; do
		if [[ "$prev" == "$flag" ]]; then
			joined="${joined:+${joined},}${arg}"
		fi
		prev="$arg"
	done <"$log"
	printf '%s' "$joined"
	return 0
}

test_begin_worker_runtime_run_refreshes_run_id() {
	local first_run_id="" second_run_id=""
	AIDEVOPS_RUN_ID="run:stale"
	_begin_worker_runtime_run
	first_run_id="$AIDEVOPS_RUN_ID"
	_begin_worker_runtime_run
	second_run_id="$AIDEVOPS_RUN_ID"

	if [[ "$first_run_id" == run:* && "$second_run_id" == run:* ]] &&
		[[ "$first_run_id" != "run:stale" && "$second_run_id" != "$first_run_id" ]]; then
		print_result "each runtime process invocation receives a fresh run ID" 0
	else
		print_result "each runtime process invocation receives a fresh run ID" 1 \
			"first=${first_run_id:-<empty>} second=${second_run_id:-<empty>}"
	fi
	return 0
}

test_internal_opencode_retries_refresh_run_id() {
	local refresh_count=""
	local attempt_helper="${SCRIPT_DIR}/headless-runtime-attempt.sh"
	refresh_count=$(python3 - "$attempt_helper" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
print(len(re.findall(r"_begin_worker_runtime_run\s*\n\s*_invoke_opencode", source)))
PY
	)

	if [[ "$refresh_count" == "2" ]]; then
		print_result "internal OpenCode retries refresh run identity before invocation" 0
	else
		print_result "internal OpenCode retries refresh run identity before invocation" 1 \
			"Expected two guarded internal retries, got ${refresh_count:-<empty>}"
	fi
	return 0
}

test_reconciled_outcome_persistence_retries() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper.sh"
	local count_file="${TEST_ROOT}/fake-objective-helper.count"
	local args_file="${TEST_ROOT}/fake-objective-helper.args"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
set -u
count=0
[[ -f "$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE" ]] && read -r count <"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" >"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
printf '%s\n' "$*" >"$AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE"
[[ "$count" -ge 3 ]]
SH
	chmod +x "$fake_helper"

	(
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE="$count_file"
		export AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE="$args_file"
		export AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS=3
		export AIDEVOPS_ATTEMPT_ID="attempt:retry-test"
		export AIDEVOPS_ATTEMPT_STARTED_AT=700
		export AIDEVOPS_RUN_ID="run:retry-test"
		export WORKER_ISSUE_NUMBER=99999
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "issue-99999" "premature_exit" \
			"success" "recovered" "worker_complete"
	)

	local call_count="" captured_args=""
	[[ -f "$count_file" ]] && read -r call_count <"$count_file"
	[[ -f "$args_file" ]] && read -r captured_args <"$args_file"
	if [[ "$call_count" == "3" && "$captured_args" == *"--attempt-id attempt:retry-test"* ]] &&
		[[ "$captured_args" == *"--run-id run:retry-test"* ]]; then
		print_result "reconciled outcome persistence retries bounded transient failures" 0
	else
		print_result "reconciled outcome persistence retries bounded transient failures" 1 \
			"calls=${call_count:-<empty>} args=${captured_args:-<empty>}"
	fi
	return 0
}

test_reconciled_outcome_persistence_has_deadline() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper-hangs.sh"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
sleep 20
SH
	chmod +x "$fake_helper"

	local started=$SECONDS
	(
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS=1
		export AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_TIMEOUT_SECONDS=1
		export AIDEVOPS_ATTEMPT_ID="attempt:deadline-test"
		export WORKER_ISSUE_NUMBER=99999
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "issue-99999" "premature_exit" \
			"failed" "failed" "persistence_deadline_test"
	)
	local elapsed=$((SECONDS - started))

	if [[ "$elapsed" -lt 5 ]]; then
		print_result "reconciled outcome persistence cannot retain a worker slot indefinitely" 0
	else
		print_result "reconciled outcome persistence cannot retain a worker slot indefinitely" 1 \
			"elapsed=${elapsed}s"
	fi
	return 0
}

test_reconciled_outcome_requires_explicit_issue() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper-no-issue.sh"
	local called_file="${TEST_ROOT}/fake-objective-helper-no-issue.called"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
set -u
printf 'called\n' >"$AIDEVOPS_FAKE_OBJECTIVE_CALLED_FILE"
exit 0
SH
	chmod +x "$fake_helper"

	(
		unset WORKER_ISSUE_NUMBER 2>/dev/null || true
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_FAKE_OBJECTIVE_CALLED_FILE="$called_file"
		export AIDEVOPS_ATTEMPT_ID="attempt:null-issue"
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "routine-r004" "permission_required" \
			"failed" "failed" "permission_request_persistence_failed"
	)

	if [[ ! -e "$called_file" ]]; then
		print_result "reconciled outcome requires an explicit issue number" 0
	else
		print_result "reconciled outcome requires an explicit issue number" 1 \
			"non-issue session routine-r004 was attributed to issue 4"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_when_no_workdir() {
	# When work_dir is absent (fail paths), behaviour is unchanged: worker_complete
	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 0
	else
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 1 \
			"Expected worker_complete (fail-open), got '${released_reason}'"
	fi
	return 0
}

# AC#3: orphan-recovery attempts gh pr create with correct args
test_attempt_orphan_recovery_pr_calls_gh_create() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	printf '{"pr_base_branch":"develop"}\n' >"${work_dir}/.aidevops.json"

	local gh_log="${work_dir}.gh-pr-create.log"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then
			printf '[]'
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
		else
			_fixture_record_gh_pr_create "$gh_log" "$@"
		fi
		return 0
	}

	# Capture the status: under `set -e` a bare non-zero return aborts the whole
	# suite before its Tests run/Failures summary (GH#39209).
	local recovery_rc=0
	_attempt_orphan_recovery_pr \
		"issue-99999" "$work_dir" "feature/auto-test-issue-99999" "test-owner/test-repo" || recovery_rc=$?

	unset -f gh 2>/dev/null || true

	local gh_head="" gh_base="" gh_labels="" gh_called=0
	gh_head=$(_fixture_pr_create_flag "$gh_log" "--head")
	gh_base=$(_fixture_pr_create_flag "$gh_log" "--base")
	gh_labels=$(_fixture_pr_create_flag "$gh_log" "--label")
	[[ -s "$gh_log" ]] && gh_called=1

	if [[ "$gh_called" -eq 1 ]]; then
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 0
	else
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 1 \
			"gh was not called (rc=${recovery_rc})"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" ]]; then
		print_result "_attempt_orphan_recovery_pr passes correct --head" 0
	else
		print_result "_attempt_orphan_recovery_pr passes correct --head" 1 \
			"Expected --head=feature/auto-test-issue-99999, got '${gh_head}'"
	fi

	if [[ ",${gh_labels}," == *",origin:worker-takeover,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 1 \
			"Expected --label=origin:worker-takeover, got '${gh_labels}'"
	fi

	if [[ ",${gh_labels}," == *",status:in-review,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 1 \
			"Expected --label=status:in-review, got '${gh_labels}'"
	fi

	if [[ "$gh_base" == "develop" ]]; then
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 0
	else
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 1 \
			"Expected --base=develop, got '${gh_base}'"
	fi

	return 0
}

test_attempt_orphan_recovery_pr_uses_authoritative_worker_issue() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery-authoritative-issue"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	local WORKER_ISSUE_NUMBER="28313"
	local gh_log="${work_dir}.gh-pr-create.log"

	gh() {
		if [[ "${*}" == *"pr list"* ]]; then
			printf '[]'
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
		elif _fixture_gh_is_default_branch_lookup "$@"; then
			printf 'main'
		else
			_fixture_record_gh_pr_create "$gh_log" "$@"
		fi
		return 0
	}

	local recovery_rc=0
	_attempt_orphan_recovery_pr \
		"manual-cli-28313-1784593858" "$work_dir" \
		"feature/auto-test-issue-99999" "test-owner/test-repo" "draft" || recovery_rc=$?
	unset -f gh 2>/dev/null || true

	local gh_title="" gh_body="" gh_called=0
	gh_title=$(_fixture_pr_create_flag "$gh_log" "--title")
	gh_body=$(_fixture_pr_create_flag "$gh_log" "--body")
	[[ -s "$gh_log" ]] && gh_called=1

	# GH#32933: recovery PRs use the non-closing `For #N` reference.
	if [[ "$gh_called" -eq 1 && "$gh_title" == *"#28313"* && \
		"$gh_body" == *"For #28313"* && "$gh_body" != *"Resolves #28313"* && \
		"$gh_title" != *"1784593858"* && "$gh_body" != *"#1784593858"* ]]; then
		print_result "orphan recovery prefers authoritative worker issue over session timestamp" 0
	else
		print_result "orphan recovery prefers authoritative worker issue over session timestamp" 1 \
			"rc=${recovery_rc} called=${gh_called} title=${gh_title:-<empty>} body=${gh_body:-<empty>}"
	fi
	return 0
}

test_ensure_orphan_recovery_rejects_empty_branch() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery-empty-branch"
	_setup_test_git_repo "$work_dir" 1

	local recovery_state=""
	if recovery_state=$(_ensure_orphan_recovery_branch_remote "$work_dir" "" "99999" "test-owner/test-repo"); then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected failure for empty branch, got '${recovery_state}'"
		return 0
	fi

	if [[ -z "$recovery_state" ]]; then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 0
	else
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected no state for empty branch, got '${recovery_state}'"
	fi
	return 0
}

test_build_orphan_recovery_pr_body_tolerates_missing_publish_flag() {
	local pr_body=""
	if ! pr_body=$(_build_orphan_recovery_pr_body "issue-99999" "feature/auto-test-issue-99999" "For #99999"); then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Function failed when published_local_branch arg was omitted"
		return 0
	fi

	if [[ "$pr_body" == *"worker_branch_orphan"* ]] && [[ "$pr_body" != *"worker_local_branch_unpushed"* ]]; then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 0
	else
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Expected default orphan marker, got '${pr_body}'"
	fi
	return 0
}

# AC#4: on auto-PR success, _cmd_run_finish emits worker_complete with orphan note
test_cmd_run_finish_orphan_recovery_success_emits_worker_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-ok"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0 (no PR); pr create succeeds; issue view = OPEN
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif _fixture_gh_is_default_branch_lookup "$@"; then printf 'main'
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 0
	else
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 1 \
			"Expected worker_complete (PR auto-created), got '${released_reason}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_pushes_and_recovers_pr() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-ok"
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	local gh_log="${work_dir}.gh-pr-create.log"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '[]'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif _fixture_gh_is_default_branch_lookup "$@"; then printf 'main'
		else _fixture_record_gh_pr_create "$gh_log" "$@"
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	local remote_ref=""
	remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/feature/auto-test-issue-99999" 2>/dev/null || true)
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	local gh_head="" gh_base="" gh_called=0
	gh_head=$(_fixture_pr_create_flag "$gh_log" "--head")
	gh_base=$(_fixture_pr_create_flag "$gh_log" "--base")
	[[ -s "$gh_log" ]] && gh_called=1

	if [[ "$released_reason" == "worker_complete" && "$gh_called" -eq 1 && -n "$remote_ref" ]]; then
		print_result "_cmd_run_finish pushes local branch and recovers PR" 0
	else
		print_result "_cmd_run_finish pushes local branch and recovers PR" 1 \
			"Expected worker_complete, gh pr create, and remote ref; got reason='${released_reason}' gh_called=${gh_called} remote_ref='${remote_ref}'"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" && "$gh_base" == "main" ]]; then
		print_result "local unpushed recovery creates PR from pushed branch against base" 0
	else
		print_result "local unpushed recovery creates PR from pushed branch against base" 1 \
			"Expected head feature/auto-test-issue-99999 base main, got head='${gh_head}' base='${gh_base}'"
	fi
	return 0
}

test_handle_worker_branch_orphan_empty_branch_issue_search_is_not_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-cleaned"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Empty branch forces issue-search fallback, which is dedup evidence but cannot
	# prove an exact-head completed handoff.
	gh() {
		if [[ "${*}" == *"pr list"* && "${*}" == *"--search #99999 in:body"* ]]; then
			printf '%s\n' '[{"number":123}]'
			return 0
		fi
		printf '%s\n' '[]'
		return 0
	}

	local released_reason=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_increment_orphan_count_stat() { return 0; }

	_handle_worker_branch_orphan "issue-99999" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 0
	else
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 1 \
			"Expected worker_branch_orphan for inconclusive issue search, got '${released_reason}'"
	fi
	return 0
}

# AC#4: on auto-PR failure, _cmd_run_finish emits worker_branch_orphan
test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	# Stub gh: pr list returns 0, issue view = OPEN, pr create FAILS
	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		elif [[ "${*}" == *"pr create"* ]]; then
			return 1  # Simulate pr create failure
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 0
	else
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 1 \
			"Expected worker_branch_orphan (PR create failed), got '${released_reason}'"
	fi

	if [[ "$posted_body" == *"gh pr create --head feature/auto-test-issue-99999 --base develop --repo test-owner/test-repo"* ]]; then
		print_result "worker_branch_orphan comment uses configured PR base" 0
	else
		print_result "worker_branch_orphan comment uses configured PR base" 1 \
			"Expected orphan recovery comment with --base develop, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_push_failure_emits_distinct_reason() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" remote set-url origin "${TEST_ROOT}/missing-remote.git"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_local_branch_unpushed" ]]; then
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 0
	else
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 1 \
			"Expected worker_local_branch_unpushed, got '${released_reason}'"
	fi

	local expected_push_ref="HE""AD:feature/auto-test-issue-99999"
	if [[ "$posted_body" == *"WORKER_LOCAL_BRANCH_UNPUSHED"* && "$posted_body" == *"git -C ${work_dir} push origin ${expected_push_ref}"* ]]; then
		print_result "local unpushed failure comment is distinct and includes push recovery" 0
	else
		print_result "local unpushed failure comment is distinct and includes push recovery" 1 \
			"Expected local-unpushed recovery comment, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_fail_recovers_branch_orphan_output() {
	local work_dir="${TEST_ROOT}/repo-fail-orphan-ok"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif _fixture_gh_is_default_branch_lookup "$@"; then printf 'main'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }
	_cmd_run_finish "issue-99999" "fail" "$work_dir"
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail recovers branch-orphan output" 0
	else
		print_result "_cmd_run_finish fail recovers branch-orphan output" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success for recovered failed run" 0
	else
		print_result "_cmd_run_finish records success for recovered failed run" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_closed_issue_without_merged_pr_fails() {
	local work_dir="${TEST_ROOT}/repo-fail-issue-closed"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 0
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* ]]; then printf ''
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_failed" && "$fast_fail_called" -eq 1 ]]; then
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 0
	else
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 1 \
			"Expected worker_failed and fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 0
	else
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_existing_pr_recovery_remains_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-pr-merged"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--state merged"* ]]; then printf '1'
		else printf '0'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 0
	else
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}

test_cmd_run_finish_fail_confirmed_terminal_state_releases_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-terminal-complete"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	WORKER_TARGET_BRANCH=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD)
	export WORKER_TARGET_BRANCH
	rm -rf "$work_dir"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--head"* && "${*}" == *"--state merged"* ]]; then printf '123'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--search"* && "${*}" == *"--state merged"* ]]; then printf '123'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset WORKER_TARGET_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail uses cached branch when live worktree lookup is invalid" 0
	else
		print_result "_cmd_run_finish fail treats confirmed terminal GitHub state as complete" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}
