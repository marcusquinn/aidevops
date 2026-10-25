#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Resume, runner identity, deduplication, consensus and prelaunch validator tests.
# Sourced by the main runner; depends on its helper imports, mocks and assertions.
# shellcheck disable=SC2016

[[ -n "${_TEST_DSI_PRELAUNCH_LOADED:-}" ]] && return 0
_TEST_DSI_PRELAUNCH_LOADED=1

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
