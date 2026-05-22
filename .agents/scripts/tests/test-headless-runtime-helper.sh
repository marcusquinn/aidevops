#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper.sh - Coverage for /full-loop headless contract injection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../headless-runtime-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	set +e
	# shellcheck source=/dev/null
	source "$HELPER_SCRIPT" >/dev/null 2>&1
	set -e
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

init_git_worktree() {
	local worktree_dir="$1"
	git -C "$worktree_dir" init -q
	git -C "$worktree_dir" remote add origin "https://github.com/owner/repo.git"
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "initial"
	git -C "$worktree_dir" update-ref refs/remotes/origin/main HEAD
	git -C "$worktree_dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	return 0
}

test_appends_escalation_contract() {
	local prompt='/full-loop Implement issue #14964'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'HEADLESS_CONTINUATION_CONTRACT_V9'* ]] &&
		[[ "$output" == *'Read the issue body FIRST'* ]] &&
		[[ "$output" == *'Look for a "Worker Guidance" or "How" section'* ]] &&
		[[ "$output" == *'do bounded discovery instead of stopping'* ]] &&
		[[ "$output" == *'Exit BLOCKED with reason "missing implementation context" only after bounded discovery'* ]] &&
		[[ "$output" == *'Worktree edit verification (GH#22816)'* ]] &&
		[[ "$output" == *'Incremental WIP commits (GH#23677)'* ]] &&
		[[ "$output" == *'A first WIP commit makes the worktree cleanup-visible as active real work even before a PR exists'* ]] &&
		[[ "$output" == *'Progressive context loading'* ]] &&
		[[ "$output" == *'Load only referenced workflow/reference docs'* ]] &&
		[[ "$output" == *'Stop reading once target files, reference pattern, constraints, and verification are clear.'* ]] &&
		[[ "$output" == *'Never ask for user confirmation, approval, or next steps. No user will respond.'* ]] &&
		[[ "$output" == *'The only valid exit states are FULL_LOOP_COMPLETE or BLOCKED with evidence.'* ]]; then
		print_result "appends escalation-before-blocked contract to full-loop prompts" 0
		return 0
	fi

	print_result "appends escalation-before-blocked contract to full-loop prompts" 1 "Output missing required contract clauses"
	return 0
}

test_non_full_loop_prompt_unchanged() {
	local prompt='Review this file only'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "leaves non-full-loop prompt unchanged" 0
		return 0
	fi

	print_result "leaves non-full-loop prompt unchanged" 1 "Prompt was unexpectedly modified"
	return 0
}

test_parse_initial_model_does_not_set_explicit_override() {
	local role="worker" session_key="issue-22862" work_dir="$TEST_ROOT" title="Issue #22862" prompt="/full-loop test" prompt_file=""
	local model_override="" initial_model="" tier_override="" variant_override="" agent_name="" headless_runtime="" detach=0
	local -a extra_args=()

	_parse_run_args --initial-model openai/gpt-5.5 --tier sonnet --opencode-arg --print-logs

	if [[ "$initial_model" == "openai/gpt-5.5" && -z "$model_override" && "$tier_override" == "sonnet" ]]; then
		print_result "--initial-model does not set explicit model override" 0
		return 0
	fi

	print_result "--initial-model does not set explicit model override" 1 \
		"initial_model=${initial_model:-<empty>} model_override=${model_override:-<empty>} tier=${tier_override:-<empty>}"
	return 0
}

test_startup_no_activity_timeout_returns_watchdog_continue() {
	local output_file="${TEST_ROOT}/startup-stall.log"
	printf '%s\n' 'sqlite-migration:done' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 124 "$output_file" "worker" "openai" "issue-22862" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "watchdog_startup_continue" && ! -f "$output_file" ]]; then
		print_result "startup no-activity timeout attempts bounded continuation" 0
		return 0
	fi

	print_result "startup no-activity timeout attempts bounded continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_sigkill_with_activity_attempts_continuation() {
	local output_file="${TEST_ROOT}/sigkill-with-activity.jsonl"
	cat >"$output_file" <<'EOF'
{"type":"text","text":"I made a change after reading docs that mention rate limit."}
[WORKER_EXIT_DIAGNOSTICS] exit_code=137 model=openai/gpt-5.5 role=worker session_key=issue-23036
[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)
EOF
	_run_result_label=""
	_run_failure_reason=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""

	local status=0
	_handle_run_result 137 "$output_file" "worker" "openai" "issue-23036" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "signal_killed_continue" && "$_run_runtime_error_type" == "sigkill" && ! -f "$output_file" ]]; then
		print_result "SIGKILL with activity attempts continuation" 0
		return 0
	fi

	print_result "SIGKILL with activity attempts continuation" 1 \
		"status=$status label=${_run_result_label:-<empty>} runtime=${_run_runtime_error_type:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	return 0
}

test_dispatcher_initial_model_can_rotate_after_rate_limit() {
	local result status action next_model
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		choose_model() { printf '%s' 'anthropic/claude-sonnet-4-6'; return 0; }
		_cmd_run_finish() { return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$cmd_run_action" "$cmd_run_next_model"
	)
	IFS='|' read -r status action next_model <<<"$result"

	if [[ "$status" -eq 0 && "$action" == "switch" && "$next_model" == "anthropic/claude-sonnet-4-6" ]]; then
		print_result "dispatcher-selected initial model can rotate after rate limit" 0
		return 0
	fi

	print_result "dispatcher-selected initial model can rotate after rate limit" 1 \
		"status=$status action=${action:-<empty>} next=${next_model:-<empty>}"
	return 0
}

test_explicit_model_override_remains_pinned_on_rate_limit() {
	local result status finished_status action
	result=$(
		cmd_run_action=""
		cmd_run_next_model=""
		_run_failure_reason="rate_limit"
		_run_should_retry=0
		_HRW_STATUS_FAIL="fail"
		print_warning() { return 0; }
		local finished_inner=""
		_cmd_run_finish() { local status_arg="$2"; finished_inner="$status_arg"; return 0; }
		local retry_status=0
		_cmd_run_prepare_retry "worker" "issue-22862" "openai/gpt-5.5" 1 3 "openai/gpt-5.5" 124 || retry_status=$?
		printf '%s|%s|%s' "$retry_status" "$finished_inner" "$cmd_run_action"
	)
	IFS='|' read -r status finished_status action <<<"$result"

	if [[ "$status" -eq 124 && "$finished_status" == "fail" && "$action" == "retry" ]]; then
		print_result "explicit model override remains pinned on rate limit" 0
		return 0
	fi

	print_result "explicit model override remains pinned on rate limit" 1 \
		"status=$status finish=${finished_status:-<empty>} action=${action:-<empty>}"
	return 0
}

test_issue_worker_env_contract_rejects_missing_env() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 0
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_issue_worker_env_contract_rejects_missing_worktree() {
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_WORKTREE_PATH unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 1 \
		"status=$status output=${output:-<empty>}"
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
	return 0
}

test_issue_worker_env_contract_accepts_valid_precreated_worktree() {
	local worktree_dir="${TEST_ROOT}/precreated-worktree"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	if _validate_issue_worker_env_contract \
		"worker" "issue-22438" "$worktree_dir" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438"; then
		print_result "issue worker env contract accepts valid precreated worktree" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract accepts valid precreated worktree" 1
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
	return 0
}

test_worker_worktree_claim_transfers_to_runtime_pid() {
	local worktree_dir="${TEST_ROOT}/claim-worktree"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"

	local claimed_path="" claimed_branch="" claimed_session="" claimed_task="" claimed_pid=""
	claim_worktree_ownership() {
		claimed_path="$1"
		claimed_branch="$2"
		shift 2
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--session)
				claimed_session="${2:-}"
				shift 2
				;;
			--task)
				claimed_task="${2:-}"
				shift 2
				;;
			--owner-pid)
				claimed_pid="${2:-}"
				shift 2
				;;
			*) shift ;;
			esac
		done
		return 0
	}

	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null

	unset -f claim_worktree_ownership 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER 2>/dev/null || true

	if [[ "$claimed_path" == "$worktree_dir" ]] &&
		[[ "$claimed_branch" == "detached" ]] &&
		[[ "$claimed_session" == "issue-22438" ]] &&
		[[ "$claimed_task" == "22438" ]] &&
		[[ "$claimed_pid" == "$$" ]]; then
		print_result "worker worktree claim transfers ownership to runtime PID" 0
		return 0
	fi

	print_result "worker worktree claim transfers ownership to runtime PID" 1 \
		"path=$claimed_path branch=$claimed_branch session=$claimed_session task=$claimed_task pid=$claimed_pid"
	return 0
}

test_worker_worktree_claim_reclaims_stale_live_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/claim-stale-live-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="1"
	local claim_calls=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "old-session" "" "22438" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$unregister_called" -eq 1 ]]; then
		print_result "worker worktree claim reclaims stale live same-task owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims stale live same-task owner" 1 \
		"status=$status calls=$claim_calls unregister=$unregister_called"
	return 0
}

test_worker_worktree_claim_reclaims_dispatch_precreate_owner() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="900"
	local claim_calls=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "" "22438" "2099-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$unregister_called" -eq 1 ]]; then
		print_result "worker worktree claim reclaims dispatch precreate owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims dispatch precreate owner" 1 \
		"status=$status calls=$claim_calls unregister=$unregister_called"
	return 0
}

test_worker_worktree_clean_without_upstream_blocks_local_commits() {
	local worktree_dir="${TEST_ROOT}/claim-local-commits"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	git -C "$worktree_dir" config --unset branch.main.remote 2>/dev/null || true
	git -C "$worktree_dir" config --unset branch.main.merge 2>/dev/null || true
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "local-only"

	local status=0
	_hrw_worktree_clean_for_owner_reclaim "$worktree_dir" >/dev/null || status=$?

	if [[ "$status" -ne 0 ]]; then
		print_result "worker worktree clean check blocks no-upstream local commits" 0
		return 0
	fi

	print_result "worker worktree clean check blocks no-upstream local commits" 1 "status=$status"
	return 0
}

test_worker_worktree_claim_classifies_unreclaimed_live_owner() {
	local worktree_dir="${TEST_ROOT}/claim-live-owner-blocked"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "active-session" "" "99999" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() { local unregister_path="$1"; [[ -n "$unregister_path" ]] || return 1; return 0; }

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	local reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$reason" == "worker_worktree_live_owner" ]]; then
		print_result "worker worktree claim classifies unreclaimed live owner" 0
		return 0
	fi

	print_result "worker worktree claim classifies unreclaimed live owner" 1 \
		"status=$status reason=${reason:-<empty>}"
	return 0
}

test_deleted_cwd_recovery_uses_worker_worktree() {
	local worktree_dir="${TEST_ROOT}/deleted-cwd-worktree"
	local stale_dir="${TEST_ROOT}/deleted-cwd-stale"
	local output=""
	local status=0
	mkdir -p "$worktree_dir" "$stale_dir"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	set +e
	output=$(
		cd "$stale_dir" || exit 20
		rmdir "$stale_dir" || exit 21
		_recover_deleted_cwd_before_launch "$TEST_ROOT" "test" 2>&1 || exit $?
		pwd -P
	)
	status=$?
	set -e

	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	if [[ "$status" -eq 0 && "$output" == *"recovered_deleted_cwd"* && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted cwd recovery cd's to worker worktree before launch" 0
		return 0
	fi

	print_result "deleted cwd recovery cd's to worker worktree before launch" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_cmd_run_aborts_issue_worker_before_canary_when_env_missing() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local canary_called=0
	_run_canary_test() { canary_called=1; return 0; }

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-22438 \
		--dir "$TEST_ROOT" \
		--title "Issue #22438: env contract" \
		--prompt "/full-loop Implement issue #22438" 2>&1) || status=$?

	unset -f _run_canary_test 2>/dev/null || true
	if [[ "$status" -ne 0 && "$canary_called" -eq 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "cmd_run aborts issue worker before canary when env missing" 0
		return 0
	fi

	print_result "cmd_run aborts issue worker before canary when env missing" 1 \
		"status=$status canary_called=$canary_called output=${output:-<empty>}"
	return 0
}

test_cmd_run_preserves_worker_origin_overrides_before_canary() {
	local worktree_dir="${TEST_ROOT}/origin-override-worktree"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER=23558
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"
	export AIDEVOPS_SESSION_ORIGIN=interactive
	export AIDEVOPS_HEADLESS=already-set

	choose_model() { printf '%s' 'openai/gpt-5.5'; return 0; }
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() {
		if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "interactive" && "${AIDEVOPS_HEADLESS:-}" == "already-set" ]]; then
			printf '%s\n' 'canary_saw_origin_overrides'
		fi
		return 1
	}

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-23558 \
		--dir "$worktree_dir" \
		--title "Issue #23558: origin overrides" \
		--prompt "/full-loop Implement issue #23558" 2>&1) || status=$?

	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH AIDEVOPS_SESSION_ORIGIN AIDEVOPS_HEADLESS 2>/dev/null || true
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test 2>/dev/null || true
	if [[ "$status" -eq 1 && "$output" == *"canary_saw_origin_overrides"* && "$output" == *"Canary failed"* ]]; then
		print_result "cmd_run preserves worker origin env overrides before canary" 0
		return 0
	fi

	print_result "cmd_run preserves worker origin env overrides before canary" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_deleted_launch_cwd_recovers_to_work_dir() {
	local stale_dir="${TEST_ROOT}/stale-cwd"
	local worktree_dir="${TEST_ROOT}/worker-worktree"
	mkdir -p "$stale_dir" "$worktree_dir"

	local output=""
	local status=0
	output=$(
		cd "$stale_dir" || exit 1
		rmdir "$stale_dir" || exit 1
		_ensure_valid_launch_cwd "$worktree_dir" || exit $?
		pwd -P
	) 2>&1 || status=$?

	if [[ "$status" -eq 0 && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted launch cwd recovers to worker worktree before runtime startup" 0
		return 0
	fi

	print_result "deleted launch cwd recovers to worker worktree before runtime startup" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_does_not_double_append() {
	local prompt='/full-loop Continue issue #14964

[HEADLESS_CONTINUATION_CONTRACT_V8]
This worker run is unattended.'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "does not double-append existing contract" 0
		return 0
	fi

	print_result "does not double-append existing contract" 1 "Existing contract was modified"
	return 0
}

test_extract_session_id_from_output_returns_latest_session_id() {
	local output_file="${TEST_ROOT}/opencode-output.jsonl"
	cat >"$output_file" <<'EOF'
not-json
{"type":"message","sessionID":"ses_early"}
{"type":"tool_use","part":{"sessionID":"ses_latest"}}
EOF

	local session_id
	session_id=$(extract_session_id_from_output "$output_file")
	if [[ "$session_id" == "ses_latest" ]]; then
		print_result "extract_session_id_from_output returns latest session id" 0
		return 0
	fi
	print_result "extract_session_id_from_output returns latest session id" 1 "Expected ses_latest, got ${session_id:-<empty>}"
	return 0
}
test_blocked_completion_records_blocked_label() {
	local output_file="${TEST_ROOT}/blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing dependency credentials"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 0 && "${_run_result_label:-}" == "blocked" && "${_run_failure_reason:-}" == "blocked" && "${_run_classification_source:-}" == "model_blocked_signal" ]] && { print_result "BLOCKED terminal signal records blocked label" 0; return 0; }
	print_result "BLOCKED terminal signal records blocked label" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} source=${_run_classification_source:-<unset>}"
	return 0
}
test_missing_context_blocked_requests_brief_recovery() {
	local output_file="${TEST_ROOT}/missing-context-blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing implementation context"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 82 && "${_run_result_label:-}" == "brief_recovery" && "${_run_failure_reason:-}" == "missing_implementation_context" && "${_run_classification_pattern:-}" == "missing_implementation_context" ]] && { print_result "missing-context BLOCKED requests brief recovery" 0; return 0; }
	print_result "missing-context BLOCKED requests brief recovery" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

test_headless_activity_timeout_default_matches_watchdog() {
	local expected="600"
	local actual="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-}"

	if [[ "$actual" == "$expected" ]]; then
		print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 0
		return 0
	fi

	print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 1 \
		"Expected ${expected}s to avoid GPT-5.x no-output false kills; got '${actual:-<unset>}'"
	return 0
}

test_activity_watchdog_classifiers_detect_rate_limit_and_ci_wait() {
	local output_file="${TEST_ROOT}/activity-classifier.out"

	printf 'OpenAI error: HTTP 429 rate limit exceeded\n' >"$output_file"
	if _activity_output_has_provider_rate_limit "$output_file"; then
		print_result "activity watchdog detects provider rate-limit marker" 0
	else
		print_result "activity watchdog detects provider rate-limit marker" 1
	fi

	printf 'waiting for CI checks to finish before merge\n' >"$output_file"
	if _activity_output_has_ci_wait "$output_file"; then
		print_result "activity watchdog detects CI-wait marker" 0
	else
		print_result "activity watchdog detects CI-wait marker" 1
	fi

	return 0
}

test_failure_classifier_records_provenance() {
	local output_file="${TEST_ROOT}/failure-classifier.out"
	local reason_file="${TEST_ROOT}/failure-classifier.reason"
	printf 'Provider returned HTTP 429: Too Many Requests\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "rate_limit" ]] &&
		[[ "${_failure_provider_error_type:-}" == "rate_limit" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]] &&
		[[ "${_failure_classification_pattern:-}" == *"too_many_requests"* ]]; then
		print_result "failure classifier records provider provenance" 0
		return 0
	fi

	print_result "failure classifier records provider provenance" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_service_interruption_candidate_uses_separate_path() {
	local output_file="${TEST_ROOT}/service-interruption.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_23037","text":"editing files"}' 'OpenAI 503 service unavailable after tool activity' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 1 "$output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && -f "$output_file" ]]; then
		print_result "service interruption uses dedicated continuation path" 0
	else
		print_result "service interruption uses dedicated continuation path" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	fi

	local local_output_file="${TEST_ROOT}/service-interruption-local.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_local","text":"editing files"}' 'worker received SIGTERM after tool activity' >"$local_output_file"
	_run_result_label=""
	_run_failure_reason=""
	status=0
	_handle_run_result 143 "$local_output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && "$_run_failure_reason" == "local_error" && -f "$local_output_file" ]]; then
		print_result "service interruption preserves specific failure reason and diagnostics" 0
	else
		print_result "service interruption preserves specific failure reason and diagnostics" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$local_output_file" ]] && printf yes || printf no)"
	fi

	if ! service_interruption_continue_candidate "rate_limit" "1" "1" "" "rate_limit"; then
		print_result "rate limits do not consume service interruption budget" 0
	else
		print_result "rate limits do not consume service interruption budget" 1
	fi

	if service_interruption_continue_candidate "local_error" "137" "1" "" ""; then
		print_result "SIGKILL with activity can resume as interruption" 0
	else
		print_result "SIGKILL with activity can resume as interruption" 1
	fi

	return 0
}

test_canary_pins_vanilla_agent_with_isolated_plugin_config() {
	local canary_root="${TEST_ROOT}/canary-agent"
	local fake_bin_dir="${canary_root}/bin"
	local plugin_dir="${canary_root}/plugin path"
	local plugin_path="${plugin_dir}/index.mjs"
	local args_file="${canary_root}/args.txt"
	local env_file="${canary_root}/env.txt"
	mkdir -p "$fake_bin_dir" "$plugin_dir"
	printf '%s\n' 'export default {};' >"$plugin_path"

	cat >"${fake_bin_dir}/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	printf '1.14.31\n'
	exit 0
fi
if [[ -n "${OPENCODE_SESSION_ID:-}${OPENCODE_PID:-}${OPENCODE_RUN_ID:-}${OPENCODE_PROCESS_ROLE:-}${OPENCODE:-}${OPENCODE_SERVER_PASSWORD:-}" ]]; then
	printf 'leaked session env\n' >"$AIDEVOPS_CANARY_ENV_FILE"
	exit 42
fi
printf '%s\n' "$*" >"$AIDEVOPS_CANARY_ARGS_FILE"
printf 'OPENCODE_BIN=%s\nOPENCODE_DB=%s\nAIDEVOPS_HEADLESS=%s\n' \
	"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}" "${AIDEVOPS_HEADLESS:-}" >"$AIDEVOPS_CANARY_ENV_FILE"
if [[ -f "${XDG_CONFIG_HOME:-}/opencode/opencode.json" ]]; then
	printf 'CONFIG=%s\n' "$(<"${XDG_CONFIG_HOME}/opencode/opencode.json")" >>"$AIDEVOPS_CANARY_ENV_FILE"
fi
printf 'The answer is Four.\n'
exit 0
EOF
	chmod +x "${fake_bin_dir}/opencode"

	local output
	if output=$(
		PATH="${fake_bin_dir}:$PATH" \
		HOME="${canary_root}/home" \
		OPENCODE_BIN="${fake_bin_dir}/opencode" \
		OPENCODE_DB="${canary_root}/opencode.db" \
		OPENCODE_SESSION_ID="ses_parent" \
		OPENCODE_PID="12345" \
		OPENCODE_RUN_ID="run_parent" \
		OPENCODE_PROCESS_ROLE="tui" \
		OPENCODE="1" \
		OPENCODE_SERVER_PASSWORD="session-password" \
		AIDEVOPS_PLUGIN_INDEX="$plugin_path" \
		AIDEVOPS_CANARY_ARGS_FILE="$args_file" \
		AIDEVOPS_CANARY_ENV_FILE="$env_file" \
		AIDEVOPS_HEADLESS_RUNTIME_DIR="${canary_root}/runtime" \
		CANARY_CACHE_TTL_SECONDS=0 \
		CANARY_TIMEOUT_SECONDS=5 \
		bash -c 'source "$1" help >/dev/null 2>&1; _run_canary_test "anthropic/claude-sonnet-4-6"' _ "$HELPER_SCRIPT"
	) && [[ -f "$args_file" && -f "$env_file" ]]; then
		local args
		args=$(<"$args_file")
		local env_output
		env_output=$(<"$env_file")
		local expected_plugin_url
		expected_plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$plugin_path")
		if [[ "$args" == *'What is two plus two?'* && "$args" != *'--pure'* && "$args" == *'--agent build'* ]] &&
			[[ "$env_output" == *"OPENCODE_BIN=${fake_bin_dir}/opencode"* ]] &&
			[[ "$env_output" == *"OPENCODE_DB=${canary_root}/opencode.db"* ]] &&
			[[ "$env_output" == *"AIDEVOPS_HEADLESS=1"* ]] &&
			[[ "$env_output" == *"$expected_plugin_url"* ]]; then
			print_result "canary pins vanilla agent with isolated plugin config" 0
			return 0
		fi
		print_result "canary pins vanilla agent with isolated plugin config" 1 \
			"Expected benign prompt, no --pure, --agent build, headless env, plugin config, and preserved OpenCode config env; got args: ${args}; env: ${env_output}"
		return 0
	fi

	print_result "canary pins vanilla agent with isolated plugin config" 1 \
		"Canary stub did not run successfully: ${output:-<empty>}"
	return 0
}

test_opencode_session_env_wrapper_strips_session_vars_only() {
	local output
	# shellcheck disable=SC2016 # Inner bash expands these after env stripping.
	output=$(
		OPENCODE_SESSION_ID="ses_parent" \
		OPENCODE_PID="12345" \
		OPENCODE_RUN_ID="run_parent" \
		OPENCODE_PROCESS_ROLE="tui" \
		OPENCODE="1" \
		OPENCODE_SERVER_PASSWORD="session-password" \
		OPENCODE_BIN="opencode" \
		OPENCODE_DB="/tmp/opencode.db" \
		run_without_opencode_session_env bash -c '
			printf "%s|%s|%s|%s|%s|%s|%s|%s" \
				"${OPENCODE_SESSION_ID:-}" "${OPENCODE_PID:-}" "${OPENCODE_RUN_ID:-}" \
				"${OPENCODE_PROCESS_ROLE:-}" "${OPENCODE:-}" "${OPENCODE_SERVER_PASSWORD:-}" \
				"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}"
		'
	)

	if [[ "$output" == "||||||opencode|/tmp/opencode.db" ]]; then
		print_result "OpenCode session env wrapper strips only session-bound vars" 0
		return 0
	fi

	print_result "OpenCode session env wrapper strips only session-bound vars" 1 \
		"Expected session vars stripped and config env preserved, got: ${output}"
	return 0
}

test_worker_opencode_exec_paths_strip_session_env() {
	if grep -Fq "run_without_opencode_session_env \"\$SANDBOX_EXEC_HELPER\" run" "$HELPER_SCRIPT" &&
		grep -Fq "run_without_opencode_session_env timeout \"\$HEADLESS_SANDBOX_TIMEOUT_DEFAULT\"" "$HELPER_SCRIPT"; then
		print_result "worker OpenCode exec paths strip session env" 0
		return 0
	fi

	print_result "worker OpenCode exec paths strip session env" 1 \
		"Expected sandbox and bare-timeout OpenCode exec paths to use run_without_opencode_session_env"
	return 0
}

test_sandbox_passthrough_scopes_provider_env() {
	local csv
	csv=$(
		OPENAI_API_KEY='openai-test' \
		ANTHROPIC_API_KEY='anthropic-test' \
		GOOGLE_API_KEY='google-test' \
		OPENCODE_BIN='opencode' \
		OPENCODE_DB='/tmp/opencode.db' \
		OPENCODE_SESSION_ID='ses_parent' \
		OPENCODE_PID='12345' \
		OPENCODE_RUN_ID='run_parent' \
		OPENCODE_PROCESS_ROLE='tui' \
		OPENCODE='1' \
		OPENCODE_SERVER_PASSWORD='session-password' \
		build_sandbox_passthrough_csv "openai"
	)

	if [[ "$csv" == *"OPENAI_API_KEY"* ]] &&
		[[ "$csv" != *"ANTHROPIC_API_KEY"* ]] &&
		[[ "$csv" != *"GOOGLE_API_KEY"* ]] &&
		[[ "$csv" == *"OPENCODE_BIN"* ]] &&
		[[ "$csv" == *"OPENCODE_DB"* ]] &&
		[[ "$csv" != *"OPENCODE_SESSION_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PID"* ]] &&
		[[ "$csv" != *"OPENCODE_RUN_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PROCESS_ROLE"* ]] &&
		[[ "$csv" != *"OPENCODE_SERVER_PASSWORD"* ]] &&
		[[ ",$csv," != *",OPENCODE,"* ]]; then
		print_result "sandbox passthrough scopes env to selected provider" 0
		return 0
	fi

	print_result "sandbox passthrough scopes env to selected provider" 1 \
		"Expected OpenAI env only, got: ${csv}"
	return 0
}

test_copy_scoped_opencode_auth_keeps_selected_provider_only() {
	local auth_root="${TEST_ROOT}/scoped-auth"
	local source_auth="${auth_root}/source.json"
	local dest_auth="${auth_root}/dest/opencode/auth.json"
	mkdir -p "$auth_root"
	cat >"$source_auth" <<'EOF'
{
  "openai": {"type": "oauth", "access": "openai-token"},
  "anthropic": {"type": "oauth", "access": "anthropic-token"}
}
EOF

	copy_scoped_opencode_auth "$source_auth" "$dest_auth" "openai"

	local has_openai has_anthropic
	has_openai=$(jq -r 'has("openai")' "$dest_auth")
	has_anthropic=$(jq -r 'has("anthropic")' "$dest_auth")
	if [[ "$has_openai" == "true" && "$has_anthropic" == "false" ]]; then
		print_result "copy_scoped_opencode_auth keeps selected provider only" 0
		return 0
	fi

	print_result "copy_scoped_opencode_auth keeps selected provider only" 1 \
		"Expected only openai auth entry in ${dest_auth}"
	return 0
}

test_large_opencode_prompt_uses_file_attachment() {
	local prompt="large-seed-prompt-with-worker-contract"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "opencode" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_run_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "" "" "" --file "$prompt_file")
	)

	if [[ "$prompt_arg" != *"$prompt"* ]] &&
		[[ -f "$prompt_file" ]] &&
		[[ "$(<"$prompt_file")" == "$prompt" ]] &&
		[[ "$cmd_text" == *"<--file><${prompt_file}>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "large opencode prompts use file attachment instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "large opencode prompts use file attachment instead of argv" 1 \
		"prompt_arg=${prompt_arg} prompt_file=${prompt_file} cmd=${cmd_text}"
	return 0
}

test_large_claude_prompt_uses_stdin_file() {
	local prompt="large-claude-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=8

	_prepare_runtime_prompt_transport "claude" "$prompt"

	local prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	local stdin_file="$_HEADLESS_CLAUDE_STDIN_FILE"
	local cmd_text=""
	cmd_text=$(
		while IFS= read -r -d '' arg; do
			printf '<%s>' "$arg"
		done < <(_build_claude_cmd "anthropic/claude-sonnet-4-6" "$TEST_ROOT" "$prompt_arg" \
			"Prompt Transport Test" "")
	)

	if [[ -z "$prompt_arg" ]] &&
		[[ -f "$stdin_file" ]] &&
		[[ "$(<"$stdin_file")" == "$prompt" ]] &&
		[[ "$cmd_text" == "<claude><-p>"* ]] &&
		[[ "$cmd_text" != *"$prompt"* ]]; then
		_cleanup_headless_runtime_temp_paths
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "large claude prompts use stdin file instead of argv" 0
		return 0
	fi

	_cleanup_headless_runtime_temp_paths
	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "large claude prompts use stdin file instead of argv" 1 \
		"prompt_arg=${prompt_arg} stdin_file=${stdin_file} cmd=${cmd_text}"
	return 0
}

test_registered_prompt_temp_cleanup_removes_dir() {
	local prompt="cleanup-seed-prompt"
	local old_threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-}"
	HEADLESS_PROMPT_FILE_THRESHOLD_BYTES=1

	_prepare_runtime_prompt_transport "opencode" "$prompt"
	local prompt_file="$_HEADLESS_RUN_PROMPT_FILE"
	local prompt_dir="${prompt_file%/*}"
	_cleanup_headless_runtime_temp_paths

	if [[ -n "$prompt_dir" && ! -e "$prompt_dir" ]]; then
		if [[ -n "$old_threshold" ]]; then
			HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
		else
			unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
		fi
		print_result "registered prompt temp cleanup removes prompt dir" 0
		return 0
	fi

	if [[ -n "$old_threshold" ]]; then
		HEADLESS_PROMPT_FILE_THRESHOLD_BYTES="$old_threshold"
	else
		unset HEADLESS_PROMPT_FILE_THRESHOLD_BYTES
	fi
	print_result "registered prompt temp cleanup removes prompt dir" 1 \
		"Prompt temp dir still exists: ${prompt_dir:-<empty>}"
	return 0
}

# Helper: create a bare git repo and a feature branch with optional commits.
# Each call uses work_dir-derived remote path to avoid inter-test collisions.
# Args: $1 = work_dir path, $2 = 1 to add a commit (0 for none)
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

test_worker_produced_output_pushed_branch_no_slug_returns_pr_exists() {
	# Pushed branch but DISPATCH_REPO_SLUG unset → cannot check PR → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-pushed-noslug"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for pushed branch (no slug, fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for pushed branch (no slug, fail-open)" 1 \
			"Expected 'pr_exists' (fail-open, no DISPATCH_REPO_SLUG), got '${classification}'"
	fi
	return 0
}

# AC#2: pushed branch + confirmed no PR → branch_orphan
test_worker_produced_output_branch_no_pr_returns_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-orphan"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	# Set DISPATCH_REPO_SLUG and stub gh to return 0 PRs
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "branch_orphan" ]]; then
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 0
	else
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 1 \
			"Expected 'branch_orphan' but got '${classification}'"
	fi
	return 0
}

# AC#2 variant: PR confirmed → pr_exists even when branch is pushed
test_worker_produced_output_branch_with_pr_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pr-exists"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '1'; return 0; }  # Stub gh: 1 PR found

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 1 \
			"Expected 'pr_exists' but got '${classification}'"
	fi
	return 0
}

test_cmd_run_finish_emits_noop_for_zero_output() {
	local work_dir="${TEST_ROOT}/repo-finish-noop"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	# Stub lifecycle functions to capture what was called
	local released_reason="" fast_fail_reason="" fast_fail_crash=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; fast_fail_crash="$3"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_noop" ]]; then
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 0
	else
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 1 \
			"Expected released_reason=worker_noop, got '${released_reason}'"
	fi

	if [[ "$fast_fail_reason" == "worker_noop_zero_output" && "$fast_fail_crash" == "no_work" ]]; then
		print_result "_cmd_run_finish increments fast-fail on noop" 0
	else
		print_result "_cmd_run_finish increments fast-fail on noop" 1 \
			"Expected fast_fail reason=worker_noop_zero_output/crash=no_work, got '${fast_fail_reason}'/'${fast_fail_crash}'"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_for_real_output() {
	local work_dir="${TEST_ROOT}/repo-finish-complete"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete for real output" 0
	else
		print_result "_cmd_run_finish emits worker_complete for real output" 1 \
			"Expected released_reason=worker_complete, got '${released_reason}'"
	fi

	if [[ "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 0
	else
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 1 \
			"fast-fail should not be called when worker produced real output"
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

	local gh_head="" gh_base="" gh_repo="" gh_label=""
	local gh_called=0
	gh() {
		# Capture pr create args
		local arg
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			"--repo") gh_repo="$arg" ;;
			"--label") gh_label="$arg" ;;
			esac
			_last_flag="$arg"
		done
		gh_called=1
		return 0
	}
	_last_flag=""

	_attempt_orphan_recovery_pr \
		"issue-99999" "$work_dir" "feature/auto-test-issue-99999" "test-owner/test-repo"

	unset -f gh 2>/dev/null || true

	if [[ "$gh_called" -eq 1 ]]; then
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 0
	else
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 1 \
			"gh was not called"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" ]]; then
		print_result "_attempt_orphan_recovery_pr passes correct --head" 0
	else
		print_result "_attempt_orphan_recovery_pr passes correct --head" 1 \
			"Expected --head=feature/auto-test-issue-99999, got '${gh_head}'"
	fi

	if [[ "$gh_label" == "origin:worker-takeover" ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 1 \
			"Expected --label=origin:worker-takeover, got '${gh_label}'"
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
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
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

test_handle_worker_branch_orphan_empty_branch_existing_pr_releases_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-cleaned"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: empty branch skips --head and falls back to issue search; existing PR found.
	gh() {
		if [[ "${*}" == *"pr list"* && "${*}" == *"--search 99999"* ]]; then
			printf '1'
			return 0
		fi
		printf '0'
		return 0
	}

	local released_reason=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_increment_orphan_count_stat() { return 0; }

	_handle_worker_branch_orphan "issue-99999" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_handle_worker_branch_orphan treats empty-branch existing PR as complete" 0
	else
		print_result "_handle_worker_branch_orphan treats empty-branch existing PR as complete" 1 \
			"Expected worker_complete (existing PR found by issue search), got '${released_reason}'"
	fi
	return 0
}

# AC#4: on auto-PR failure, _cmd_run_finish emits worker_branch_orphan
test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0, issue view = OPEN, pr create FAILS
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then
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
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 0
	else
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 1 \
			"Expected worker_branch_orphan (PR create failed), got '${released_reason}'"
	fi
	return 0
}

test_cmd_run_finish_fail_recovers_branch_orphan_output() {
	local work_dir="${TEST_ROOT}/repo-fail-orphan-ok"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
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
		print_result "_cmd_run_finish fail recovers branch-orphan output" 0
	else
		print_result "_cmd_run_finish fail recovers branch-orphan output" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}

main() {
	setup_test_env
	test_appends_escalation_contract
	test_non_full_loop_prompt_unchanged
	test_parse_initial_model_does_not_set_explicit_override
	test_startup_no_activity_timeout_returns_watchdog_continue
	test_sigkill_with_activity_attempts_continuation
	test_dispatcher_initial_model_can_rotate_after_rate_limit
	test_explicit_model_override_remains_pinned_on_rate_limit
	test_issue_worker_env_contract_rejects_missing_env
	test_issue_worker_env_contract_rejects_missing_worktree
	test_issue_worker_env_contract_accepts_valid_precreated_worktree
	test_worker_worktree_claim_transfers_to_runtime_pid
	test_worker_worktree_claim_reclaims_stale_live_same_task_owner
	test_worker_worktree_claim_reclaims_dispatch_precreate_owner
	test_worker_worktree_clean_without_upstream_blocks_local_commits
	test_worker_worktree_claim_classifies_unreclaimed_live_owner
	test_deleted_cwd_recovery_uses_worker_worktree
	test_cmd_run_aborts_issue_worker_before_canary_when_env_missing
	test_cmd_run_preserves_worker_origin_overrides_before_canary
	test_deleted_launch_cwd_recovers_to_work_dir
	test_does_not_double_append
	test_extract_session_id_from_output_returns_latest_session_id
	test_blocked_completion_records_blocked_label
	test_missing_context_blocked_requests_brief_recovery
	test_headless_activity_timeout_default_matches_watchdog
	test_activity_watchdog_classifiers_detect_rate_limit_and_ci_wait
	test_failure_classifier_records_provenance
	test_service_interruption_candidate_uses_separate_path
	test_canary_pins_vanilla_agent_with_isolated_plugin_config
	test_opencode_session_env_wrapper_strips_session_vars_only
	test_worker_opencode_exec_paths_strip_session_env
	test_sandbox_passthrough_scopes_provider_env
	test_copy_scoped_opencode_auth_keeps_selected_provider_only
	test_large_opencode_prompt_uses_file_attachment
	test_large_claude_prompt_uses_stdin_file
	test_registered_prompt_temp_cleanup_removes_dir
	test_worker_produced_output_no_commits_returns_noop
	test_worker_produced_output_with_commits_returns_pr_exists_failopen
	test_worker_produced_output_non_worker_session_returns_pr_exists
	test_worker_produced_output_invalid_workdir_returns_pr_exists
	test_worker_produced_output_pushed_branch_no_slug_returns_pr_exists
	test_worker_produced_output_branch_no_pr_returns_branch_orphan
	test_worker_produced_output_branch_with_pr_returns_pr_exists
	test_cmd_run_finish_emits_noop_for_zero_output
	test_cmd_run_finish_emits_complete_for_real_output
	test_cmd_run_finish_emits_complete_when_no_workdir
	test_attempt_orphan_recovery_pr_calls_gh_create
	test_cmd_run_finish_orphan_recovery_success_emits_worker_complete
	test_handle_worker_branch_orphan_empty_branch_existing_pr_releases_complete
	test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan
	test_cmd_run_finish_fail_recovers_branch_orphan_output
	teardown_test_env
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
