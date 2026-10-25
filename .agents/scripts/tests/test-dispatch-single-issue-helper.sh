#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for dispatch-single-issue-helper.sh — focused on the t3000
# fail-closed dispatch ceremony which mirrors the canonical pulse
# `_dlw_assign_and_label` ownership-claim sequence.
#
# Background: the manual single-issue dispatch CLI was previously launching
# workers without applying the pre-launch ceremony (status:queued +
# assignee normalize) that the pulse always applies. This
# created a race window where the next pulse cycle could see the issue in
# its prior state and dispatch a duplicate worker on top of the running one.
#
# The tests exercise the helper in isolation by sourcing the script (the
# `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard prevents main() from
# running) and overriding `set_issue_status` with a mock that captures
# every flag for assertion.

# Generated child scripts intentionally defer these expressions until runtime.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_PATH="${SCRIPT_DIR}/../dispatch-single-issue-helper.sh"
ASKPASS_PATH="${SCRIPT_DIR}/../github-auth-askpass.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SET_ISSUE_STATUS_LOG=""
SET_ORIGIN_LABEL_LOG=""
REGISTER_WORKTREE_LOG=""
MOCK_WORKTREE_HELPER_LOG=""
MOCK_GH_ISSUE_STATE="OPEN"
MOCK_GH_LABELS_JSON="[]"
MOCK_GH_FAIL="0"
MOCK_GH_TARGET_IS_PR="0"
MOCK_GH_AUTHOR_ASSOCIATION="OWNER"
MOCK_GH_AUTHOR_LOGIN="fixture-owner"
MOCK_GH_AUTHOR_TYPE="User"
MOCK_GH_PERMISSION_EVENTS_JSON='[[]]'
MOCK_GH_REST_LOGIN_MODE="success"
MOCK_GH_GRAPHQL_LOGIN_MODE="success"
MOCK_GH_CALL_LOG=""
MOCK_PS_LINES=""
MOCK_LIVE_PIDS=""
MOCK_LEDGER_RECORD=""
MOCK_GIT_WORKTREE_LIST="0"
MOCK_REPO_PATH=""
MOCK_WORKTREE_PATH=""
MOCK_WORKTREE_BRANCH=""
MOCK_DATE_UTC=""

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

# Source the helper so its functions become available in this shell.
# The main() guard means executing the test does NOT re-enter the dispatch
# CLI — only the function definitions land in scope.
# shellcheck source=../dispatch-single-issue-helper.sh
# shellcheck disable=SC1091
source "$HELPER_PATH"

# Override set_issue_status (defined by shared-gh-wrappers.sh which the
# helper sourced) with a mock that logs every flag to SET_ISSUE_STATUS_LOG.
# This is what the ceremony function calls; we never actually touch GitHub.
#
# Mode comes from the global $MOCK_SET_ISSUE_STATUS_MODE — NOT a local of
# the installer function. A nested function definition does not capture the
# enclosing function's locals (bash has no closures); after the installer
# returns, those locals are gone and `set -u` would tank the mock body.
MOCK_SET_ISSUE_STATUS_MODE="success"

# shellcheck disable=SC2317
set_issue_status() {
	printf 'set_issue_status %s\n' "$*" >>"$SET_ISSUE_STATUS_LOG"
	case "$MOCK_SET_ISSUE_STATUS_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_issue_status() {
	MOCK_SET_ISSUE_STATUS_MODE="${1:-success}"
	return 0
}

# Override set_origin_label (also from shared-gh-wrappers.sh) with a mock that
# logs every call to SET_ORIGIN_LABEL_LOG. Dispatch ceremony should not call it:
# origin:* labels are immutable creation provenance, not worker-claim state.
MOCK_SET_ORIGIN_LABEL_MODE="success"

# shellcheck disable=SC2317
set_origin_label() {
	printf 'set_origin_label %s\n' "$*" >>"$SET_ORIGIN_LABEL_LOG"
	case "$MOCK_SET_ORIGIN_LABEL_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_origin_label() {
	MOCK_SET_ORIGIN_LABEL_MODE="${1:-success}"
	return 0
}

# shellcheck disable=SC2317
register_worktree() {
	if [[ -z "${REGISTER_WORKTREE_LOG:-}" ]]; then
		return 0
	fi
	printf 'register_worktree %s\n' "$*" >>"$REGISTER_WORKTREE_LOG"
	return $?
}

# shellcheck disable=SC2317
date() {
	local date_first="${1:-}"
	local date_format="${2:-}"
	if [[ -n "$MOCK_DATE_UTC" && "$date_first" == "-u" && "$date_format" == "+%Y%m%d-%H%M%S" ]]; then
		printf '%s\n' "$MOCK_DATE_UTC"
		return 0
	fi
	command date "$@"
	return $?
}

# shellcheck disable=SC2317
git() {
	local git_first="${1:-}"
	local git_repo="${2:-}"
	local git_command="${3:-}"
	local git_subcommand="${4:-}"
	local git_format="${5:-}"
	if [[ "$MOCK_GIT_WORKTREE_LIST" == "1" && "$git_first" == "-C" && "$git_repo" == "$MOCK_REPO_PATH" &&
		"$git_command" == "worktree" && "$git_subcommand" == "list" && "$git_format" == "--porcelain" ]]; then
		printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/%s\n\n' \
			"$MOCK_WORKTREE_PATH" "$MOCK_WORKTREE_BRANCH"
		return 0
	fi
	command git "$@"
	return $?
}

# shellcheck disable=SC2317
gh() {
	local gh_subcommand="${1:-}"
	local gh_resource="${2:-}"
	if [[ -n "$MOCK_GH_CALL_LOG" ]]; then
		printf '%s\n' "$*" >>"$MOCK_GH_CALL_LOG"
	fi
	if [[ "$MOCK_GH_FAIL" == "1" ]]; then
		return 1
	fi

	if [[ "$gh_subcommand" == "issue" && "$gh_resource" == "view" ]]; then
		printf '{"number":%s,"title":"Mock issue","state":"%s","labels":%s,"assignees":[],"url":"https://example.invalid/issues/%s"}\n' \
			"$3" "$MOCK_GH_ISSUE_STATE" "$MOCK_GH_LABELS_JSON" "$3"
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == "user" ]]; then
		case "$MOCK_GH_REST_LOGIN_MODE" in
		success)
			printf '%s\n' 'runner-self'
			return 0
			;;
		invalid)
			printf '%s\n' 'invalid login!'
			return 0
			;;
		*) return 1 ;;
		esac
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == "graphql" ]]; then
		case "$MOCK_GH_GRAPHQL_LOGIN_MODE" in
		success)
			printf '%s\n' 'fallback-runner'
			return 0
			;;
		invalid)
			printf '%s\n' 'fallback;injection'
			return 0
			;;
		*) return 1 ;;
		esac
	fi
	if [[ "$gh_subcommand" == "api" && "$gh_resource" == */events\?* ]]; then
		printf '%s\n' "$MOCK_GH_PERMISSION_EVENTS_JSON"
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == repos/*/issues/* ]]; then
		case "$MOCK_GH_TARGET_IS_PR" in
		1) printf '{"number":123,"author_association":"%s","user":{"login":"%s","type":"%s"},"pull_request":{"url":"https://api.example.invalid/pulls/123"}}\n' "$MOCK_GH_AUTHOR_ASSOCIATION" "$MOCK_GH_AUTHOR_LOGIN" "$MOCK_GH_AUTHOR_TYPE" ;;
		api_fail) return 1 ;;
		*) printf '{"number":123,"author_association":"%s","user":{"login":"%s","type":"%s"}}\n' "$MOCK_GH_AUTHOR_ASSOCIATION" "$MOCK_GH_AUTHOR_LOGIN" "$MOCK_GH_AUTHOR_TYPE" ;;
		esac
		return 0
	fi

	printf 'unexpected gh call: %s\n' "$*" >&2
	return 1
}


# shellcheck disable=SC2317
_dsi_ps_worker_lines() {
	printf '%s\n' "$MOCK_PS_LINES"
	return 0
}

# shellcheck disable=SC2317
_dsi_pid_is_live() {
	local pid="$1"
	local live_pid=""
	for live_pid in $MOCK_LIVE_PIDS; do
		[[ "$pid" == "$live_pid" ]] && return 0
	done
	return 1
}

# shellcheck disable=SC2317
_dsi_repo_slug_for_worktree() {
	local worktree_path="$1"
	case "$worktree_path" in
	/tmp/aidevops-existing | /tmp/aidevops-recovery) printf '%s\n' "owner/repo" ;;
	*) printf '\n' ;;
	esac
	return 0
}

# shellcheck disable=SC2317
_dsi_repo_path_for_slug() {
	local repo_slug="$1"
	if [[ "$repo_slug" == "owner/repo" && -n "$MOCK_REPO_PATH" ]]; then
		printf '%s\n' "$MOCK_REPO_PATH"
		return 0
	fi
	return 1
}

# shellcheck disable=SC2317
_dsi_find_ledger_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	if [[ -n "$MOCK_LEDGER_RECORD" && "$issue_number" == "12345" && "$repo_slug" == "owner/repo" ]]; then
		printf '%s\n' "$MOCK_LEDGER_RECORD"
		return 0
	fi
	return 1
}

reset_test_state() {
	: >"$SET_ISSUE_STATUS_LOG"
	: >"$SET_ORIGIN_LABEL_LOG"
	return 0
}

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------

# shellcheck source=./test-dispatch-single-issue-ceremony.sh
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/test-dispatch-single-issue-ceremony.sh"

# shellcheck source=./test-dispatch-single-issue-policy.sh
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/test-dispatch-single-issue-policy.sh"

test_manual_resume_reuses_dispatch_lifecycle() {
	local result=0
	(
		resume_resolutions=0 resume_change_binding=0
		_dsi_resolve_permission_resume() {
			resume_resolutions=$((resume_resolutions + 1))
			_DSI_WORKTREE_PATH=/tmp/aidevops-recovery
			_DSI_WORKTREE_BRANCH=feature/preserved
			_DSI_RESUME_SESSION=manual-cli-123-100
			_DSI_RESUME_REQUEST=perm-0000000000000000
			if [[ "$resume_change_binding" == 1 && "$resume_resolutions" -gt 1 ]]; then
				_DSI_RESUME_REQUEST=perm-1111111111111111
			fi
			return 0
		}
		_dsi_run_dedup_check() {
			_DSI_DEDUP_STATE=clear
			_DSI_DEDUP_RC=1
			_DSI_DEDUP_RESULT=clear
			return 0
		}
		_dsi_acquire_consensus_claim() {
			resume_claimed=1
			return 0
		}
		_dsi_run_required_predispatch_validator() { return 0; }
		# Capability behavior is exercised separately with the real fresh validator.
		_dsi_check_runner_capability() { return 0; }
		_dsi_guard_no_existing_dispatch() { return 0; }
		_dsi_create_worktree() { return 1; }
		# Hermetic: never read the operator's registry for the fixture path.
		_dlw_classify_reuse_candidate() {
			printf 'legacy\n'
			return 0
		}
		_dsi_prepare_worker_git_auth() {
			resume_auth=1
			return 0
		}
		lock_issue_for_worker() { return 0; }
		_dsi_launch_and_report() {
			local session="${4:-}"
			[[ "$session" == manual-cli-123-100 && "$_DSI_WORKTREE_PATH" == /tmp/aidevops-recovery ]] || return 1
			[[ "$resume_claimed" == 1 && "$resume_auth" == 1 ]] || return 1
			return 0
		}
		MOCK_GH_LABELS_JSON='[]'
		MOCK_GH_FAIL=0 MOCK_GH_TARGET_IS_PR=0 MOCK_GH_ISSUE_STATE=OPEN
		unset AIDEVOPS_DISPATCH_BASE_REF
		cmd_resume 123 owner/repo || exit 1
		[[ "$_DSI_RESUME_MODE" == 0 ]] || exit 1
		resume_change_binding=1 resume_resolutions=0 resume_auth=0
		if cmd_resume 123 owner/repo; then exit 1; fi
		[[ "$resume_auth" == 0 ]] || exit 1
		if cmd_resume 123 owner/repo --no-ceremony; then exit 1; fi
		MOCK_GH_LABELS_JSON='[{"name":"needs-maintainer-permissions"}]'
		if cmd_resume 123 owner/repo; then exit 1; fi
	) || result=1
	print_result "manual resume reuses session/worktree through claim, ceremony and Git auth; holds remain enforced" "$result"
	return 0
}

test_cmd_dispatch_blocks_needs_maintainer_review_before_dedup() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"
	MOCK_GH_ISSUE_STATE="OPEN"
	MOCK_GH_LABELS_JSON='[{"name":"needs-maintainer-review"}]'

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="/path/that/must/not/be/called"
	local out="" rc=0
	out=$(cmd_dispatch 123 owner/repo --dry-run 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"requires maintainer review"* && "$out" != *"must/not/be/called"* ]] && check=0
	print_result "dispatch command blocks needs-maintainer-review before dedup" "$check" "rc=$rc output=$out"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	MOCK_GH_LABELS_JSON="[]"
	return 0
}

test_runner_login_transport_security() {
	local test_dir=""
	test_dir=$(mktemp -d)
	MOCK_GH_CALL_LOG="${test_dir}/gh-calls"
	MOCK_GH_REST_LOGIN_MODE="success"
	MOCK_GH_GRAPHQL_LOGIN_MODE="fail"

	local login="" rc=0 check=1
	login=$(_dsi_resolve_runner_login) || rc=$?
	if [[ "$rc" -eq 0 && "$login" == "runner-self" ]] &&
		! grep -Fq 'api graphql' "$MOCK_GH_CALL_LOG"; then
		check=0
	fi
	print_result "runner identity prefers authenticated REST" "$check" "rc=$rc login=$login"

	: >"$MOCK_GH_CALL_LOG"
	MOCK_GH_REST_LOGIN_MODE="fail"
	MOCK_GH_GRAPHQL_LOGIN_MODE="success"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 0 && "$login" == "fallback-runner" ]] && check=0
	print_result "runner identity falls back to authenticated GraphQL" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="invalid"
	MOCK_GH_GRAPHQL_LOGIN_MODE="invalid"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 1 && -z "$login" ]] && check=0
	print_result "runner identity rejects malformed transport output" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="fail"
	MOCK_GH_GRAPHQL_LOGIN_MODE="fail"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 1 && -z "$login" ]] && check=0
	print_result "runner identity fails closed when both transports fail" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="success"
	MOCK_GH_GRAPHQL_LOGIN_MODE="success"
	MOCK_GH_CALL_LOG=""
	rm -rf "$test_dir"
	return 0
}

test_dedup_receives_prefetched_issue_metadata() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local metadata_log="${test_dir}/metadata.json"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'printf "%s" "${ISSUE_META_JSON:-}" >"$MOCK_DEDUP_META_LOG"'
		printf '%s\n' 'exit 1'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	export MOCK_DEDUP_META_LOG="$metadata_log"
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local forwarded=""
	forwarded=$(<"$metadata_log")
	local check=1
	[[ "$_DSI_DEDUP_STATE" == "clear" && "$forwarded" == "$_DSI_ISSUE_META_JSON" ]] && check=0
	print_result "dedup child receives prefetched issue metadata" "$check" "state=$_DSI_DEDUP_STATE metadata=$forwarded"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_META_LOG
	rm -rf "$test_dir"
	return 0
}

test_transient_dedup_retries_are_bounded() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local count_log="${test_dir}/count"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'count=0'
		printf '%s\n' '[[ -f "$MOCK_DEDUP_COUNT_LOG" ]] && count=$(<"$MOCK_DEDUP_COUNT_LOG")'
		printf '%s\n' 'count=$((count + 1))'
		printf '%s\n' 'printf "%s\n" "$count" >"$MOCK_DEDUP_COUNT_LOG"'
		printf '%s\n' 'if ((count < 3)); then'
		printf '%s\n' '  printf "%s\n" "GUARD_UNCERTAIN (reason=gh-api-failure detail=timeout Retry-After:1)"'
		printf '%s\n' '  exit 0'
		printf '%s\n' 'fi'
		printf '%s\n' 'exit 1'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	export MOCK_DEDUP_COUNT_LOG="$count_log"
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local attempts=""
	attempts=$(<"$count_log")
	local check=1
	[[ "$_DSI_DEDUP_STATE" == "clear" && "$_DSI_DEDUP_ATTEMPTS" -eq 3 && "$attempts" == "3" ]] && check=0
	print_result "transient dedup retries stop after two retries" "$check" \
		"state=$_DSI_DEDUP_STATE attempts=$_DSI_DEDUP_ATTEMPTS calls=$attempts"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_COUNT_LOG
	rm -rf "$test_dir"
	return 0
}

test_persistent_uncertainty_does_not_retry_and_checkpoints_dryrun() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local count_log="${test_dir}/count"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'count=0'
		printf '%s\n' '[[ -f "$MOCK_DEDUP_COUNT_LOG" ]] && count=$(<"$MOCK_DEDUP_COUNT_LOG")'
		printf '%s\n' 'printf "%s\n" "$((count + 1))" >"$MOCK_DEDUP_COUNT_LOG"'
		printf '%s\n' 'printf "%s\n" "GUARD_UNCERTAIN (reason=jq-failure call=assignees-extract)"'
		printf '%s\n' 'exit 0'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	export MOCK_DEDUP_COUNT_LOG="$count_log"
	local -x AIDEVOPS_DSI_CHECKPOINT_DIR="${test_dir}/checkpoints"
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"
	MOCK_GH_ISSUE_STATE="OPEN"
	MOCK_GH_LABELS_JSON="[]"

	local out="" rc=0
	out=$(cmd_dispatch 123 owner/repo --dry-run 2>&1) || rc=$?
	local checkpoint_file="${AIDEVOPS_DSI_CHECKPOINT_DIR}/owner-repo-123.json"
	local checkpoint_ok=1
	if [[ -f "$checkpoint_file" ]] && jq -e \
		'.status == "recovering" and .issue == "123" and .repo == "owner/repo" and
		 .dedup_attempts == 1 and (.resume_command | contains("--dry-run")) and
		 (.resume_condition | contains("definitive clear or blocked"))' \
		"$checkpoint_file" >/dev/null; then
		checkpoint_ok=0
	fi
	local calls=""
	calls=$(<"$count_log")
	local check=1
	[[ "$rc" -eq 75 && "$calls" == "1" && "$checkpoint_ok" -eq 0 && "$out" == *"RECOVERY_CHECKPOINT_JSON="* ]] && check=0
	print_result "persistent uncertain dry-run returns 75 and persists checkpoint" "$check" \
		"rc=$rc calls=$calls checkpoint_ok=$checkpoint_ok output=$out"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_COUNT_LOG
	rm -rf "$test_dir"
	return 0
}

test_unexpected_dedup_exit_remains_error() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'printf "%s\n" "unexpected helper failure"'
		printf '%s\n' 'exit 2'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local check=1
	[[ "$_DSI_DEDUP_STATE" == "error" && "$_DSI_DEDUP_RC" -eq 2 && "$_DSI_DEDUP_ATTEMPTS" -eq 1 ]] && check=0
	print_result "unexpected dedup exit remains an error" "$check" \
		"state=$_DSI_DEDUP_STATE rc=$_DSI_DEDUP_RC attempts=$_DSI_DEDUP_ATTEMPTS"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	rm -rf "$test_dir"
	return 0
}

test_manual_consensus_claim_outcomes() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local helper="${test_dir}/dedup-helper.sh"
	cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "claim" ]]; then
	exit 1
fi
case "${MOCK_CLAIM_RESULT:-win}" in
win) printf '%s\n' 'CLAIM_WON: comment_id=123'; exit 0 ;;
loss) printf '%s\n' 'CLAIM_LOST: runner=runner-self lost to peer on issue #123 winner_claim_ts=2026-10-17T00:00:00Z winner_age=9s'; exit 1 ;;
blocked) printf '%s\n' 'CLAIM_BLOCKED: active_assignment issue=#123 repo=owner/repo runner=runner-self signal=PARENT_TASK_BLOCKED'; exit 1 ;;
hydrate)
	calls_file="${MOCK_CLAIM_CALLS_FILE:?}"
	calls=$(($(cat "$calls_file" 2>/dev/null || printf '0') + 1))
	printf '%s\n' "$calls" >"$calls_file"
	if [[ "$calls" -eq 1 ]]; then
		printf '%s\n' 'CLAIM_BLOCKED: active_assignment issue=#123 repo=owner/repo runner=runner-self signal=HYDRATION_WINDOW (issue=123 repo=owner/repo age=29s window=30s — labels may not be synced yet)'
		exit 1
	fi
	printf '%s\n' 'CLAIM_WON: comment_id=123'
	exit 0
	;;
error) printf '%s\n' 'CLAIM_ERROR'; exit 2 ;;
esac
exit 2
EOF
	chmod +x "$helper"
	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"

	local rc=0 out="" out_file="${test_dir}/claim.out"
	MOCK_CLAIM_RESULT=loss _dsi_acquire_consensus_claim 123 owner/repo runner-self >"$out_file" 2>&1 || rc=$?
	out=$(<"$out_file")
	local loss_ok=1
	[[ "$rc" -eq 1 && "$_DSI_CLAIM_WON" -eq 0 && "$out" == *"another runner won"* && "$out" == *"lost to peer"*"winner_claim_ts="* ]] && loss_ok=0
	print_result "manual dispatch blocks a lost consensus claim and names the winner" "$loss_ok" "rc=$rc won=$_DSI_CLAIM_WON out=$out"

	# GH#34922: a refused (not lost) claim reports the helper's reason.
	rc=0
	MOCK_CLAIM_RESULT=blocked _dsi_acquire_consensus_claim 123 owner/repo runner-self >"$out_file" 2>&1 || rc=$?
	out=$(<"$out_file")
	local blocked_ok=1
	[[ "$rc" -eq 1 && "$_DSI_CLAIM_WON" -eq 0 && "$out" != *"another runner won"* && "$out" == *"Reason: CLAIM_BLOCKED: active_assignment"* ]] && blocked_ok=0
	print_result "manual dispatch reports the concrete claim refusal reason" "$blocked_ok" "rc=$rc out=$out"

	# GH#34922: a fresh issue inside the hydration window waits once and wins.
	rc=0
	MOCK_CLAIM_RESULT=hydrate MOCK_CLAIM_CALLS_FILE="${test_dir}/calls" \
		_dsi_acquire_consensus_claim 123 owner/repo runner-self >"$out_file" 2>&1 || rc=$?
	out=$(<"$out_file")
	local hydrate_ok=1
	[[ "$rc" -eq 0 && "$_DSI_CLAIM_WON" -eq 1 && "$(cat "${test_dir}/calls")" == "2" && "$out" == *"label-hydration window; waiting 2s"* ]] && hydrate_ok=0
	print_result "manual dispatch waits out the hydration window instead of reporting a lost claim" "$hydrate_ok" "rc=$rc won=$_DSI_CLAIM_WON out=$out"

	rc=0
	MOCK_CLAIM_RESULT=error _dsi_acquire_consensus_claim 123 owner/repo runner-self >/dev/null 2>&1 || rc=$?
	local error_ok=1
	[[ "$rc" -eq 1 && "$_DSI_CLAIM_WON" -eq 0 ]] && error_ok=0
	print_result "manual dispatch fails closed on consensus claim error" "$error_ok" "rc=$rc won=$_DSI_CLAIM_WON"

	rc=0
	MOCK_CLAIM_RESULT=win _dsi_acquire_consensus_claim 123 owner/repo runner-self >/dev/null 2>&1 || rc=$?
	local win_ok=1
	[[ "$rc" -eq 0 && "$_DSI_CLAIM_WON" -eq 1 ]] && win_ok=0
	print_result "manual dispatch proceeds only after consensus claim win" "$win_ok" "rc=$rc won=$_DSI_CLAIM_WON"

	_DSI_CLAIM_WON=1
	_DSI_CLAIM_COMMENT_ID=123
	_dsi_release_consensus_claim 123 owner/repo runner-self test_failure >/dev/null 2>&1 || true
	local release_ok=1
	[[ "$_DSI_CLAIM_WON" -eq 0 && -z "$_DSI_CLAIM_COMMENT_ID" ]] && release_ok=0
	print_result "manual prelaunch failure clears its claim without retaining local state" "$release_ok"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	rm -rf "$test_dir"
	return 0
}

test_review_followup_validator_uncertainty_blocks_manual_dispatch() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local validator="${test_dir}/validator.sh"
	cat >"$validator" <<'EOF'
#!/usr/bin/env bash
exit 20
EOF
	chmod +x "$validator"
	local original_validator="$_DSI_VALIDATOR_HELPER"
	_DSI_VALIDATOR_HELPER="$validator"
	_DSI_ISSUE_LABELS="review-followup,source:review-scanner"
	local rc=0
	_dsi_run_required_predispatch_validator 123 owner/repo >/dev/null 2>&1 || rc=$?
	local blocked=1
	[[ "$rc" -eq 1 ]] && blocked=0
	print_result "manual review-followup dispatch fails closed on validator uncertainty" "$blocked" "rc=$rc"
	_DSI_VALIDATOR_HELPER="$original_validator"
	rm -rf "$test_dir"
	return 0
}

test_launch_worker_forwards_agent() {
	local failed=1
	if grep -Fq "cmd+=(--agent \"\$agent_name\")" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards --agent to headless runtime" "$failed"
	return 0
}

test_launch_worker_forwards_repo_contract() {
	local failed=1
	if grep -Fq "WORKER_REPO_SLUG=\"\$repo_slug\"" "$HELPER_PATH" &&
		grep -Fq "GITHUB_REPOSITORY=\"\$repo_slug\"" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards target repo contract" "$failed"
	return 0
}

test_launch_worker_forwards_github_login() {
	local failed=1
	if grep -Fq "WORKER_GITHUB_LOGIN=\"\$self_login\"" "$HELPER_PATH" &&
		grep -Fq "_dsi_launch_and_report \"\$issue_number\" \"\$repo_slug\" \"\$self_login\" \"\$session_key\"" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards dispatching GitHub login" "$failed"
	return 0
}

test_launch_worker_forwards_bounded_git_auth() {
	# shellcheck source=./test-headless-runtime-contract-tests.sh
	source "${BASH_SOURCE[0]%/*}/test-headless-runtime-contract-tests.sh"
	test_repository_bound_git_auth_contract
	test_detached_git_auth_envelope
	local failed=1
	if grep -Fq 'AIDEVOPS_GIT_AUTH_TOKEN_FILE="$_DSI_GIT_AUTH_TOKEN_FILE"' "$HELPER_PATH" &&
		grep -Fq 'AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN="$_DSI_GIT_AUTH_EXPECTED_ORIGIN"' "$HELPER_PATH" &&
		grep -Fq 'GIT_ASKPASS="$_DSI_ASKPASS_HELPER"' "$HELPER_PATH" &&
		grep -Fq 'GIT_AUTHOR_NAME="$_DSI_GIT_AUTHOR_NAME"' "$HELPER_PATH" &&
		! grep -Eq 'GH_TOKEN=.*(<|cat|read_token)' "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards bounded Git auth without token argv" "$failed"
	return 0
}

test_detached_git_auth_envelope() {
	local root="" result=0
	root=$(mktemp -d)
	root=$(cd "$root" && pwd -P)
	_test_git_auth_token_fixture "$root/home"
	cat >"$root/token-helper" <<'FIXTURE'
#!/usr/bin/env bash
case "$1" in
create) printf '%s' "$HOME/.aidevops/.agent-workspace/tokens/worker-fixture.token" ;;
validate) exec "$FIXTURE_SCRIPTS/worker-token-helper.sh" "$@" --local-only ;;
revoke) exec "$FIXTURE_SCRIPTS/worker-token-helper.sh" "$@" ;;
*) exit 1 ;;
esac
FIXTURE
	cat >"$root/runtime" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$FIXTURE_SCRIPTS"
source "$SCRIPT_DIR/headless-runtime-lib.sh"
source "$SCRIPT_DIR/headless-runtime-run.sh"
source "$SCRIPT_DIR/headless-runtime-worker-prepare.sh"
source "$SCRIPT_DIR/shared-temp-workspace.sh"
# Only unrelated worker setup is stubbed; authentication, temp-root setup,
# detach, and cleanup are production functions, executed in fresh processes
# with the real envelope.
_hrff_capture_external_outcome_contract() { return 0; }
_ensure_valid_launch_cwd() { return 0; }
_validate_issue_worker_env_contract() { return 0; }
_recover_deleted_cwd_before_launch() { return 0; }
role=worker private_workload=0 detach=0
session_key="$FIXTURE_SESSION" work_dir="$WORKER_WORKTREE_PATH" title=fixture prompt=fixture
_cmd_run_stop=0
for arg in "$@"; do [[ "$arg" != --detach ]] || detach=1; done
shift
[[ "$AIDEVOPS_SESSION_ORIGIN" == worker && "$AIDEVOPS_HEADLESS" == true ]] || exit 1
_prepare_cmd_run_environment "$@" || exit 1
[[ "$_cmd_run_stop" != 1 ]] || exit 0
[[ -f "$AIDEVOPS_GIT_AUTH_TOKEN_FILE" ]] || exit 1
_headless_git_auth_sandbox_env_is_normalized || exit 1
printf '%s\n' ready >"$FIXTURE_ROOT/ready"
cleanup_headless_git_auth
printf '%s\n' cleaned >"$FIXTURE_ROOT/cleaned"
FIXTURE
	chmod 700 "$root/runtime" "$root/token-helper"
	(
		export HOME="$root/home" FIXTURE_ROOT="$root"
		export FIXTURE_SCRIPTS="$_DSI_SCRIPT_DIR" FIXTURE_SESSION="git-auth-fixture-$$"
		# GH#33402: interactive caller metadata must not leak into the worker,
		# including the re-executed detached child and synchronous preflight.
		export AIDEVOPS_SESSION_ORIGIN=interactive AIDEVOPS_HEADLESS=false
		# GH#34556: the detached log lands in this approved root (with a space).
		export AIDEVOPS_WORKSPACE_DIR="$root/approved workspace"
		local log_root="$root/approved workspace/tmp" runtime_log=""
		_DSI_HEADLESS="$root/runtime"
		_DSI_TOKEN_HELPER="$root/token-helper"
		_DSI_ASKPASS_HELPER="$_DSI_SCRIPT_DIR/../scripts/github-auth-askpass.sh"
		_DSI_LOG_DIR="$root/logs"
		mkdir -p "$root/repo"
		command git -C "$root/repo" init -q
		command git -C "$root/repo" remote add origin https://github.com/owner/repo.git
		_dsi_prepare_worker_git_auth owner/repo "$root/repo" fixture || exit 1
		[[ -n "$_DSI_GIT_AUTH_TOKEN_FILE" ]] || exit 1
		# Exercise the real cmd_run/import path too, stopping before any model or
		# worktree ownership side effects. Preflight must not revoke the token.
		env AIDEVOPS_GIT_AUTH_PREFLIGHT_ONLY=1 WORKER_REPO_SLUG=owner/repo \
			AIDEVOPS_GIT_AUTH_TOKEN_FILE="$_DSI_GIT_AUTH_TOKEN_FILE" \
			AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN="$_DSI_GIT_AUTH_EXPECTED_ORIGIN" \
			GIT_ASKPASS="$_DSI_ASKPASS_HELPER" GIT_TERMINAL_PROMPT=0 \
			GIT_AUTHOR_NAME="$_DSI_GIT_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$_DSI_GIT_AUTHOR_EMAIL" \
			GIT_COMMITTER_NAME="$_DSI_GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$_DSI_GIT_AUTHOR_EMAIL" \
			"$FIXTURE_SCRIPTS/headless-runtime-helper.sh" run --role worker \
			--session-key "$FIXTURE_SESSION" --dir "$root/repo" --title fixture \
			--prompt fixture --detach >"$root/preflight.log" 2>&1 || exit 1
		[[ -f "$_DSI_GIT_AUTH_TOKEN_FILE" ]] || exit 1
		[[ -z "$(find "$root" -name "worker-${FIXTURE_SESSION}.log.*" -print -quit)" ]] || exit 1
		local pid="" attempt=0
		pid=$(_dsi_launch_worker "$FIXTURE_SESSION" "$root/repo" fixture fixture standard '' '' "$root/launch.log" 1 owner/repo fixture) || exit 1
		[[ "$pid" =~ ^[0-9]+$ ]] || exit 1
		for ((attempt = 0; attempt < 50; attempt++)); do
			[[ ! -f "$root/cleaned" ]] || break
			sleep 0.1
		done
		[[ -f "$root/ready" && -f "$root/cleaned" && ! -e "$_DSI_GIT_AUTH_TOKEN_FILE" ]] || exit 1
		runtime_log=$(_dsi_detached_runtime_log "$root/launch.log") || exit 1
		[[ "$runtime_log" == "$log_root"/"worker-${FIXTURE_SESSION}.log."* && -f "$runtime_log" ]] || exit 1
		[[ ! -e "/tmp/worker-${FIXTURE_SESSION}.log" ]] || exit 1
		rm -f "$root/ready" "$root/cleaned"
		_test_git_auth_token_fixture "$HOME"
		_dsi_prepare_worker_git_auth owner/repo "$root/repo" fixture || exit 1
		_DSI_GIT_AUTH_EXPECTED_ORIGIN=https://github.com/owner/other
		for attempt in 1 2; do
			if _dsi_launch_worker "$FIXTURE_SESSION" "$root/repo" fixture fixture standard '' '' "$root/rejected.log" 1 owner/repo fixture; then exit 1; fi
		done
		[[ ! -f "$root/ready" && "$(find "$root" -name "worker-${FIXTURE_SESSION}.log.*" | wc -l | tr -d ' ')" == 1 ]] || exit 1
		[[ -f "$_DSI_GIT_AUTH_TOKEN_FILE" ]] || exit 1
		[[ "$(grep -c 'reason=repository_mismatch' "$root/rejected.log")" == 2 ]] || exit 1
		! grep -q 'fixture-only-not-a-credential' "$root/launch.log" "$root/rejected.log" || exit 1
		_dsi_revoke_worker_git_auth
		[[ ! -f "$HOME/.aidevops/.agent-workspace/tokens/worker-fixture.token" && -f "$root/rejected.log" ]] || exit 1
	) || result=1
	rm -rf "$root"
	print_result "producer envelope survives detached readiness; cleanup follows readiness and repeated local failures never detach" "$result"
	return 0
}

test_askpass_rejects_changed_origin() {
	local test_dir="" home_dir="" repo_dir="" token_dir="" token_file=""
	test_dir=$(mktemp -d)
	test_dir=$(cd "$test_dir" && pwd -P)
	home_dir="${test_dir}/home"
	repo_dir="${test_dir}/repo"
	token_dir="${home_dir}/.aidevops/.agent-workspace/tokens"
	token_file="${token_dir}/worker-fixture.token"
	mkdir -p "$repo_dir" "$token_dir"
	chmod 700 "$token_dir"
	printf '%s' 'fixture-token-value' >"$token_file"
	printf '%s\n' '{"token_id":"worker-fixture","repo":"owner/repo","strategy":"github-app","expires_at":"2099-01-01T00:00:00Z","created_at":"2026-01-01T00:00:00Z","pid":1,"app_slug":"fixture-app"}' >"${token_file%.token}.meta"
	chmod 600 "$token_file" "${token_file%.token}.meta"
	command git -C "$repo_dir" init -q
	command git -C "$repo_dir" remote add origin https://github.com/owner/repo.git

	local username="" password="" changed_output="" changed_status=0
	username=$(HOME="$home_dir" WORKER_REPO_SLUG=owner/repo WORKER_WORKTREE_PATH="$repo_dir" \
		AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN=https://github.com/owner/repo \
		AIDEVOPS_GIT_AUTH_TOKEN_FILE="$token_file" \
		"$ASKPASS_PATH" "Username for 'https://github.com':")
	password=$(HOME="$home_dir" WORKER_REPO_SLUG=owner/repo WORKER_WORKTREE_PATH="$repo_dir" \
		AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN=https://github.com/owner/repo \
		AIDEVOPS_GIT_AUTH_TOKEN_FILE="$token_file" \
		"$ASKPASS_PATH" "Password for 'https://github.com':")
	command git -C "$repo_dir" remote set-url origin https://github.com/owner/other.git
	changed_output=$(HOME="$home_dir" WORKER_REPO_SLUG=owner/repo WORKER_WORKTREE_PATH="$repo_dir" \
		AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN=https://github.com/owner/repo \
		AIDEVOPS_GIT_AUTH_TOKEN_FILE="$token_file" \
		"$ASKPASS_PATH" "Password for 'https://github.com':" 2>/dev/null) || changed_status=$?

	local failed=1
	if [[ "$username" == "x-access-token" && "$password" == "fixture-token-value" &&
		"$changed_status" -ne 0 && -z "$changed_output" ]]; then
		failed=0
	fi
	rm -rf "$test_dir"
	print_result "AskPass serves only the prevalidated exact repository origin" "$failed" "changed_status=$changed_status"
	return 0
}

# GH#33629: verified same-ID transfer drift is a distinct pre-claim prerequisite
# with an explicit compare-and-swap repair; unknown origins still fail closed.
test_origin_identity_drift_prerequisite_and_repair() {
	local root="" result=0
	root=$(mktemp -d)
	root=$(cd "$root" && pwd -P)
	(
		# owner/repo is the transferred (current) name; old/repo redirects to it.
		gh() {
			case "$2" in
			repos/old/repo | repos/owner/repo) printf '42\towner/repo\n' ;;
			repos/other/repo) printf '99\tother/repo\n' ;;
			*) return 1 ;;
			esac
			return 0
		}
		_DSI_TOKEN_HELPER=/usr/bin/true
		_DSI_ASKPASS_HELPER=/usr/bin/true
		MOCK_REPO_PATH="$root/repo"
		local repo="$root/repo"
		command git -C "$root" init -q repo
		command git -C "$repo" remote add origin https://github.com/owner/repo.git
		command git -C "$repo" remote add upstream https://github.com/up/repo.git
		_dsi_runner_local_prerequisite "$repo" owner/repo >/dev/null || exit 1
		command git -C "$repo" remote set-url origin https://github.com/old/repo.git
		[[ "$(_dsi_runner_local_prerequisite "$repo" owner/repo)" == repository_identity_drift ]] || exit 1
		[[ "$(_dsi_origin_identity_hint repository_identity_drift owner/repo)" != *old/* ]] || exit 1
		command git -C "$repo" remote set-url origin https://github.com/other/repo.git
		[[ "$(_dsi_runner_local_prerequisite "$repo" owner/repo)" == repository_origin_mismatch ]] || exit 1
		command git -C "$repo" remote set-url origin https://github.com/gone/repo.git
		[[ "$(_dsi_runner_local_prerequisite "$repo" owner/repo)" == repository_origin_mismatch ]] || exit 1
		# Unknown identity is never rewritten, with or without --apply.
		if cmd_repair_origin owner/repo --apply 2>/dev/null; then exit 1; fi
		[[ "$(command git -C "$repo" remote get-url origin)" == https://github.com/gone/repo.git ]] || exit 1
		# Verified drift: plan-only by default, then transport-preserving CAS.
		command git -C "$repo" remote set-url origin git@github.com:old/repo.git
		cmd_repair_origin owner/repo >/dev/null 2>&1 || exit 1
		[[ "$(command git -C "$repo" remote get-url origin)" == git@github.com:old/repo.git ]] || exit 1
		command git -C "$repo" config remote.origin.pushurl git@github.com:old/repo.git
		if cmd_repair_origin owner/repo --apply 2>/dev/null; then exit 1; fi
		command git -C "$repo" config --unset remote.origin.pushurl
		cmd_repair_origin owner/repo --apply >/dev/null 2>&1 || exit 1
		[[ "$(command git -C "$repo" remote get-url origin)" == git@github.com:owner/repo.git ]] || exit 1
		[[ "$(command git -C "$repo" remote get-url upstream)" == https://github.com/up/repo.git ]] || exit 1
		command git -C "$repo" remote set-url origin https://github.com/old/repo.git
		cmd_repair_origin owner/repo --apply >/dev/null 2>&1 || exit 1
		[[ "$(command git -C "$repo" remote get-url origin)" == https://github.com/owner/repo.git ]] || exit 1
		_dsi_runner_local_prerequisite "$repo" owner/repo >/dev/null || exit 1
		# Scoped tokens disabled: the auth gate does not apply, so neither does this.
		command git -C "$repo" remote set-url origin https://github.com/other/repo.git
		WORKER_SCOPED_TOKENS=false _dsi_runner_local_prerequisite "$repo" owner/repo >/dev/null || exit 1
	) || result=1
	rm -rf "$root"
	print_result "verified transfer drift is a pre-claim prerequisite with a fail-closed CAS repair" "$result"
	return 0
}

# shellcheck source=./test-dispatch-single-issue-tracking.sh
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/test-dispatch-single-issue-tracking.sh"

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
test_fresh_runner_capability_before_manual_claim() {
	local result=0
	python3 - "$HELPER_PATH" <<'PY' || result=1
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Use the production dispatch/resume path and capability validator. All external
# effects are isolated spies, including the secret backend (never live secrets).
invocation = r'''
source "$HELPER"
_dsi_validate_dispatch_target() {
    _DSI_ISSUE_LABELS=""
    _DSI_ISSUE_META_JSON='{"body":"requires-secrets: FIXTURE_A"}'
    if [[ "$_DSI_RESUME_MODE" == 1 ]]; then
        _dsi_resolve_permission_resume || return 1
    fi
    return 0
}
_dsi_resolve_permission_resume() {
    _DSI_WORKTREE_PATH="$FIXTURE_ROOT"
    _DSI_WORKTREE_BRANCH=feature/preserved
    _DSI_RESUME_SESSION=manual-cli-123-100
    _DSI_RESUME_REQUEST=perm-0000000000000000
    return 0
}
_dsi_repo_path_for_slug() { printf '%s' "$REPO_PATH"; return 0; }
_dsi_resolve_runner_login() { printf runner; return 0; }
_dsi_run_dedup_check() {
    _DSI_DEDUP_STATE=clear _DSI_DEDUP_RC=1 _DSI_DEDUP_RESULT=clear
    return 0
}
_dsi_guard_no_existing_dispatch() { return 0; }
gh() {
    [[ "$*" == *'repos/owner/repo/issues/123'* ]] || return 1
    [[ "$FETCH_RC" == 0 ]] || return 1
    printf '%s' "$FRESH_META"
    return 0
}
_dsi_acquire_consensus_claim() { printf 'claim\n' >>"$EVENTS"; return 0; }
_dsi_run_required_predispatch_validator() { return 0; }
_dsi_apply_prelaunch_ceremony_if_enabled() { printf 'ceremony\n' >>"$EVENTS"; return 0; }
_dsi_create_worktree() {
    printf 'worktree\n' >>"$EVENTS"
    _DSI_WORKTREE_PATH="$FIXTURE_ROOT"
    return 0
}
_dsi_prepare_worker_git_auth() { printf 'auth\n' >>"$EVENTS"; return 0; }
lock_issue_for_worker() { printf 'lock\n' >>"$EVENTS"; return 0; }
_dsi_launch_and_report() { printf 'launch\n' >>"$EVENTS"; return 0; }
unset AIDEVOPS_DISPATCH_BASE_REF AIDEVOPS_WORKTREE_BASE
"$@"
'''
names = ['FIXTURE_A', 'FIXTURE_B', 'FIXTURE_C', 'FIXTURE_D', 'FIXTURE_E']
issue = dict(number=123, state='open', labels=[],
             body='requires-secrets: ' + ', '.join(names))
with tempfile.TemporaryDirectory(prefix='manual-capability-') as temp:
    root = Path(temp)
    (root / 'aidevops').write_text('''#!/usr/bin/env python3
import os, sys
assert sys.argv[1:3] == ['secret', 'check']
sys.exit(0 if sys.argv[3] in os.environ['AVAILABLE'].split(',') else 1)
''')
    (root / 'aidevops').chmod(0o700)
    events = root / 'events'
    env = dict(os.environ, HELPER=sys.argv[1], FIXTURE_ROOT=temp,
               REPO_PATH=temp, EVENTS=str(events),
               PATH=temp + os.pathsep + os.environ['PATH'])
    cases = [
        ('five names, two absent', issue, 0, names[:3], False),
        ('requirements edited after prefetch', issue, 0, names[:1], False),
        ('failed fresh read', issue, 1, names, False),
        ('invalid fresh metadata', {}, 0, names, False),
        ('closed fresh issue', dict(issue, state='closed'), 0, names, False),
        ('wrong fresh issue', dict(issue, number=124), 0, names, False),
        ('invalid requirement', dict(issue, body='requires-secrets: invalid'), 0, names, False),
        ('all names present', issue, 0, names, True),
    ]
    for command in (['cmd_dispatch', '123', 'owner/repo'],
                    ['cmd_dispatch', '123', 'owner/repo', '--no-ceremony'],
                    ['cmd_resume', '123', 'owner/repo']):
        for label, fresh, fetch_rc, available, admitted in cases:
            events.write_text('')
            fixture_env = dict(env, FRESH_META=json.dumps(fresh),
                               FETCH_RC=str(fetch_rc), AVAILABLE=','.join(available))
            result = subprocess.run(['bash', '-c', invocation, 'fixture', *command],
                                    env=fixture_env, capture_output=True, text=True)
            evidence = (command, label, result.returncode, result.stdout, result.stderr)
            assert (result.returncode == 0) == admitted, evidence
            effects = events.read_text().splitlines()
            if admitted:
                expected = ['claim', 'ceremony', 'auth', 'lock', 'launch']
                if command[0] != 'cmd_resume':
                    expected.insert(2, 'worktree')
                assert effects == expected, (evidence, effects)
                assert 'source=fresh requirements=5' in result.stderr, evidence
            else:
                assert not effects, (evidence, effects)
                assert 'runner_capability_unmet' in result.stderr, evidence
                if label == 'failed fresh read':
                    # GH#34003: metadata_unreadable belongs only to the fresh read.
                    assert 'metadata_unreadable' in result.stderr, evidence
                    assert 'reason=repo_' not in result.stderr, evidence
            # Requirement names are public diagnostics only as the missing-secret
            # reason (name=NAME), matching test-runner-capability.sh.
            output = result.stdout + result.stderr
            for name in names:
                output = output.replace('reason=secret_missing name=' + name, '')
            assert not any(name in output for name in names), evidence
    # A missing registered repository must not silently check the caller's cwd.
    # GH#34003: unregistered and moved checkouts get distinct, actionable reasons
    # (never metadata_unreadable), and dry-run discloses the same refusal.
    missing = str(root / 'moved-away')
    # The stubbed target validation leaves display-only metadata unset.
    dryrun_env = dict(fixture_env, _DSI_ISSUE_TITLE='fixture', _DSI_TIER='standard',
                      _DSI_ISSUE_URL='https://github.com/owner/repo/issues/123')
    for repo_path, reason in (('', 'repo_unregistered'), (missing, 'repo_path_missing')):
        for extra in ([], ['--dry-run']):
            events.write_text('')
            command = ['cmd_dispatch', '123', 'owner/repo', *extra]
            result = subprocess.run(['bash', '-c', invocation, 'fixture', *command],
                                    env=dict(dryrun_env, REPO_PATH=repo_path),
                                    capture_output=True, text=True)
            evidence = (command, reason, result.returncode, result.stdout, result.stderr)
            assert result.returncode == 1 and not events.read_text(), evidence
            assert 'reason=' + reason in result.stderr, evidence
            assert 'metadata_unreadable' not in result.stderr, evidence
            assert 'Dry-run complete' not in result.stdout, evidence
    # A registered path still yields a clean, non-mutating dry-run.
    events.write_text('')
    result = subprocess.run(['bash', '-c', invocation, 'fixture', 'cmd_dispatch', '123', 'owner/repo', '--dry-run'],
                            env=dryrun_env, capture_output=True, text=True)
    assert result.returncode == 0 and not events.read_text(), result
    assert 'Dry-run complete' in result.stdout and 'reason=repo_' not in result.stderr, result
print('PASS 29 isolated normal/no-ceremony/resume capability admission fixtures')
PY
	print_result "fresh runner capabilities block manual claims and checkpoint resume without secret disclosure" "$result"
	return 0
}

# IMPORTANT: the helper script we source defines `main()` for its CLI entry.
# We renamed our runner to `_run_tests` to avoid shadowing the helper's main
# (which is itself sourced but guarded behind BASH_SOURCE check). Sourcing
# re-defines main() in this shell, so a test runner named main would simply
# silently replace the helper's main and may collide with future helpers.

_run_tests() {
	SET_ISSUE_STATUS_LOG=$(mktemp)
	SET_ORIGIN_LABEL_LOG=$(mktemp)
	trap 'rm -f "$SET_ISSUE_STATUS_LOG" "$SET_ORIGIN_LABEL_LOG"' EXIT

	test_ceremony_applies_default
	test_ceremony_skip_when_self_assigned
	test_ceremony_handles_empty_assignees
	test_ceremony_handles_empty_self_login
	test_ceremony_handles_set_issue_status_failure
	test_ceremony_failure_blocks_launch_and_releases_claim
	test_conversation_lock_failure_blocks_manual_launch
	test_no_ceremony_flag_parses_correctly
	test_model_override_guidance_is_provider_neutral
	test_load_issue_meta_accepts_lowercase_open
	test_load_issue_meta_blocks_lowercase_closed
	test_pr_target_guard_detects_pull_request
	test_pr_target_guard_allows_plain_issue
	test_pr_target_guard_fails_closed_on_api_error
	test_interactive_hold_guard_blocks_review_label_without_handoff
	test_interactive_hold_guard_blocks_origin_interactive_without_handoff
	test_interactive_hold_guard_allows_auto_dispatch_handoff
	test_interactive_hold_guard_allows_auto_dispatch_review_handoff
	test_maintainer_review_guard_blocks_manual_dispatch
	test_issue_author_guard_blocks_missing_label_bypass
	test_maintainer_permission_guard_blocks_manual_dispatch
	test_permission_history_guard_requires_current_grant
	test_fresh_runner_capability_before_manual_claim
	test_manual_resume_reuses_dispatch_lifecycle
	test_cmd_dispatch_blocks_needs_maintainer_review_before_dedup
	test_runner_login_transport_security
	test_dedup_receives_prefetched_issue_metadata
	test_transient_dedup_retries_are_bounded
	test_persistent_uncertainty_does_not_retry_and_checkpoints_dryrun
	test_unexpected_dedup_exit_remains_error
	test_manual_consensus_claim_outcomes
	test_review_followup_validator_uncertainty_blocks_manual_dispatch
	test_agent_flag_parses_with_default
	test_launch_worker_forwards_agent
	test_launch_worker_forwards_repo_contract
	test_launch_worker_forwards_github_login
	test_launch_worker_forwards_bounded_git_auth
	test_askpass_rejects_changed_origin
	test_origin_identity_drift_prerequisite_and_repair
	test_create_worktree_uses_target_repo_path
	test_create_worktree_registers_dispatch_owner
	test_manual_lifetime_binding_and_managed_launch
	test_dispatch_base_ref_prefers_repo_configured_pr_base
	test_dispatch_base_ref_prefers_explicit_env_ref
	test_create_worktree_registration_fails_closed
	test_readiness_timeout_tracks_canary_budget
	test_readiness_accepts_worker_started_marker
	test_readiness_rejects_live_child_without_ready_signal
	test_readiness_rejects_ledger_without_worker_started
	test_launch_report_waits_before_success_message
	test_live_dispatch_detects_issue_repo
	test_guard_blocks_ledger_duplicate
	test_guard_blocks_live_worktree_duplicate
	test_status_reports_live_process_without_ledger
	test_status_rejects_dead_or_reused_ledger_pid
	test_status_accepts_live_identity_matched_ledger_pid
	test_status_handles_padded_ps_rows_and_unresolved_identity

	echo
	echo "======================================"
	echo "Tests run:    $TESTS_RUN"
	echo "Tests passed: $((TESTS_RUN - TESTS_FAILED))"
	echo "Tests failed: $TESTS_FAILED"
	echo "======================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

_run_tests "$@"
