#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Ownership -- Worktree claims and prelaunch leases
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker-ownership.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_WORKER_OWNERSHIP_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_OWNERSHIP_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_hrw_current_worktree_branch() {
	local work_dir="$1"
	local branch=""

	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || true)
	if [[ -z "$branch" ]]; then
		branch="detached"
	fi
	printf '%s\n' "$branch"
	return 0
}

_hrw_epoch_seconds_from_iso() {
	local iso_ts="$1"
	[[ -n "$iso_ts" ]] || return 1
	python3 - "$iso_ts" <<'PY' 2>/dev/null || return 1
import datetime
import sys

value = sys.argv[1].strip()
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
print(int(datetime.datetime.fromisoformat(value).timestamp()))
PY
	return 0
}

_hrw_worktree_task_status() {
	local work_dir="$1"
	local status_output=""
	status_output=$(git -C "$work_dir" status --porcelain 2>/dev/null) || return 1

	# Heal markers created by the pre-t18098 exclusion helper. This exemption is
	# intentionally exact and macOS-only: every other untracked or modified path
	# remains task state and continues to block ownership transfer or trigger
	# recovery. An empty regular file proves the known Spotlight marker shape.
	if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" && \
		-f "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" && ! -L "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" && \
		! -s "${work_dir}/${_HRW_SPOTLIGHT_MARKER}" ]] && \
		printf '%s\n' "$status_output" | grep -Fqx "?? ${_HRW_SPOTLIGHT_MARKER}"; then
		local exclude_file=""
		exclude_file=$(git -C "$work_dir" rev-parse --git-path info/exclude 2>/dev/null) || return 1
		[[ -n "$exclude_file" ]] || return 1
		if [[ "$exclude_file" != /* ]]; then
			exclude_file="${work_dir}/${exclude_file}"
		fi
		[[ -f "$exclude_file" ]] || return 1
		if ! grep -Fqx "/${_HRW_SPOTLIGHT_MARKER}" "$exclude_file" 2>/dev/null; then
			printf '/%s\n' "$_HRW_SPOTLIGHT_MARKER" >>"$exclude_file" 2>/dev/null || return 1
		fi
		git -C "$work_dir" check-ignore --quiet --no-index -- "$_HRW_SPOTLIGHT_MARKER" 2>/dev/null || return 1
		status_output=$(git -C "$work_dir" status --porcelain 2>/dev/null) || return 1
	fi

	printf '%s' "$status_output"
	return 0
}

_hrw_worktree_clean_for_owner_reclaim() {
	local work_dir="$1"
	local status_output=""
	status_output=$(_hrw_worktree_task_status "$work_dir") || return 1
	[[ -z "$status_output" ]] || return 1

	local upstream_ref=""
	upstream_ref=$(git -C "$work_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
	if [[ -z "$upstream_ref" ]]; then
		if git -C "$work_dir" rev-parse --verify "origin/HEAD" >/dev/null 2>&1; then
			upstream_ref="origin/HEAD"
		elif git -C "$work_dir" rev-parse --verify "origin/main" >/dev/null 2>&1; then
			upstream_ref="origin/main"
		elif git -C "$work_dir" rev-parse --verify "origin/master" >/dev/null 2>&1; then
			upstream_ref="origin/master"
		else
			upstream_ref="$_HRW_GIT_HEAD"
		fi
	fi

	local upstream_ahead=""
	upstream_ahead=$(git -C "$work_dir" rev-list --count "${upstream_ref}..HEAD" 2>/dev/null) || return 1
	[[ "$upstream_ahead" =~ ^[0-9]+$ ]] || return 1
	[[ "$upstream_ahead" -eq 0 ]] || return 1

	return 0
}

_hrw_is_dispatch_precreate_owner() {
	local owner_session="$1"
	case "$owner_session" in
		dispatch-precreate | dispatch-precreate-*) return 0 ;;
	esac
	return 1
}

_hrw_transfer_worktree_owner_snapshot() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local owner_pid="$4"
	local owner_session="$5"
	local owner_batch="$6"
	local owner_task="$7"
	local created_at="$8"
	local owner_process_start="$9"

	transfer_worktree_ownership_if_expected "$work_dir" "$branch" \
		--session "$session_key" \
		--task "${WORKER_ISSUE_NUMBER:-}" \
		--owner-pid "$$" \
		--expected-owner-pid "$owner_pid" \
		--expected-session "$owner_session" \
		--expected-batch "$owner_batch" \
		--expected-task "$owner_task" \
		--expected-created-at "$created_at" \
		--expected-process-start "$owner_process_start" || return 1
	return 0
}

_hrw_transfer_authorized_continuation_owner() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local expected_owner_pid="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID:-}"
	local expected_owner_session="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION:-}"
	local expected_owner_batch="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH:-}"
	local expected_owner_task="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK:-}"
	local expected_owner_created_at="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT:-}"
	local expected_owner_process_start="${AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START:-}"

	_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
	[[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_owner_session" && -n "$expected_owner_task" && -n "$expected_owner_created_at" &&
		-n "$expected_owner_process_start" ]] || return 1
	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || "$expected_owner_task" != "${WORKER_ISSUE_NUMBER:-}" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_task_mismatch"
		return 1
	fi

	local owner_info="" snapshot_status=0
	owner_info=$(check_worktree_owner_snapshot "$work_dir" 2>/dev/null) || snapshot_status=$?
	if [[ "$snapshot_status" -eq 1 ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_OWNER_ABSENT"
		return 1
	fi
	if [[ "$snapshot_status" -ne 0 || -z "$owner_info" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_owner_unavailable"
		return 1
	fi

	local owner_pid="" owner_session="" owner_batch="" owner_task="" created_at="" owner_process_start=""
	IFS='|' read -r owner_pid owner_session owner_batch owner_task created_at owner_process_start <<<"$owner_info"
	if [[ "$owner_task" != "${WORKER_ISSUE_NUMBER:-}" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_task_mismatch"
		return 1
	fi
	if [[ "$owner_pid" != "$expected_owner_pid" || "$owner_session" != "$expected_owner_session" ||
		"$owner_batch" != "$expected_owner_batch" || "$created_at" != "$expected_owner_created_at" ||
		"$owner_process_start" != "$expected_owner_process_start" ]]; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_owner_mismatch"
		return 1
	fi

	if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at" "$owner_process_start"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_continuation_concurrent_mutation"
		return 1
	fi

	print_info "[lifecycle] worker_worktree_continuation_owner_transferred session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

_hrw_export_worker_worktree_owner_proof() {
	local session_key="$1"
	local work_dir="$2"
	local resolved_work_dir=""
	resolved_work_dir=$(cd "$work_dir" 2>/dev/null && pwd -P) || return 1

	export AIDEVOPS_WORKTREE_OWNER_PID="$$"
	export AIDEVOPS_WORKTREE_OWNER_SESSION="$session_key"
	export AIDEVOPS_WORKTREE_OWNER_TASK="${WORKER_ISSUE_NUMBER:-}"
	export AIDEVOPS_WORKTREE_OWNER_PATH="$resolved_work_dir"
	return 0
}

_hrw_reclaim_stale_worker_worktree_owner() {
	local session_key="$1"
	local work_dir="$2"
	local branch="$3"
	local owner_info=""
	_HRW_WORKTREE_RECLAIM_OUTCOME=""

	owner_info=$(check_worktree_owner_snapshot "$work_dir" 2>/dev/null || true)
	[[ -n "$owner_info" ]] || return 1

	local owner_pid="" owner_session="" owner_batch="" owner_task="" created_at="" owner_process_start=""
	IFS='|' read -r owner_pid owner_session owner_batch owner_task created_at owner_process_start <<<"$owner_info"

	if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
		if ! declare -F _wt_pid_is_definitely_absent >/dev/null 2>&1 ||
			! _wt_pid_is_definitely_absent "$owner_pid"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_live_owner"
			return 1
		fi
		if ! _wt_unregister_owner_if_generation_matches "$work_dir" "$owner_pid" \
			"$owner_process_start" "$created_at" 2>/dev/null; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_dead_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid}"
		_HRW_WORKTREE_RECLAIM_OUTCOME="$_HRW_WORKTREE_RECLAIM_VACATED"
		return 0
	fi

	_WORKER_PRELAUNCH_FAILURE_REASON="worker_worktree_live_owner"
	[[ -n "${WORKER_ISSUE_NUMBER:-}" && "$owner_task" == "${WORKER_ISSUE_NUMBER:-}" ]] || return 1

	# Dispatcher worktree pre-creation registers ownership to a live pulse
	# process before the detached worker starts. That owner is intentionally
	# short-lived and transferable; otherwise every worker sees a live owner,
	# exits immediately, and pulse retries the same issue forever.
	if _hrw_is_dispatch_precreate_owner "$owner_session"; then
		# Heal only the exact legacy infrastructure marker when possible, but
		# never make task-state cleanliness a prerequisite for transferring the
		# dispatcher's same-task placeholder owner.
		_hrw_worktree_task_status "$work_dir" >/dev/null 2>&1 || true
		if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
			"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at" "$owner_process_start"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_dispatch_precreate_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
		_HRW_WORKTREE_RECLAIM_OUTCOME="$_HRW_WORKTREE_RECLAIM_TRANSFERRED"
		unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
		return 0
	fi

	if [[ "${AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER:-0}" == "1" ]]; then
		if ! _hrw_worktree_clean_for_owner_reclaim "$work_dir"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
			return 1
		fi
		if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
			"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at" "$owner_process_start"; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
			return 1
		fi
		print_info "[lifecycle] worker_worktree_reclaimed_authorized_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} previous_session=${owner_session}"
		_HRW_WORKTREE_RECLAIM_OUTCOME="$_HRW_WORKTREE_RECLAIM_TRANSFERRED"
		unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
		return 0
	fi

	[[ -n "$created_at" ]] || return 1

	local now_epoch="" created_epoch=""
	now_epoch=$(date +%s 2>/dev/null || true)
	created_epoch=$(_hrw_epoch_seconds_from_iso "$created_at" 2>/dev/null || true)
	[[ "$now_epoch" =~ ^[0-9]+$ && "$created_epoch" =~ ^[0-9]+$ ]] || return 1

	local owner_age_s=$((now_epoch - created_epoch))
	local reclaim_age_s="${AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS:-900}"
	[[ "$reclaim_age_s" =~ ^[0-9]+$ ]] || reclaim_age_s=900
	[[ "$owner_age_s" -ge "$reclaim_age_s" ]] || return 1

	if ! _hrw_worktree_clean_for_owner_reclaim "$work_dir"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
		return 1
	fi

	if ! _hrw_transfer_worktree_owner_snapshot "$session_key" "$work_dir" "$branch" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$created_at" "$owner_process_start"; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
		return 1
	fi
	print_warning "[lifecycle] worker_worktree_reclaimed_stale_live_owner session=${session_key} branch=${branch} path=${work_dir} previous_pid=${owner_pid} age_s=${owner_age_s}"
	_HRW_WORKTREE_RECLAIM_OUTCOME="$_HRW_WORKTREE_RECLAIM_TRANSFERRED"
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

_hrw_claim_worker_worktree() {
	local session_key="$1"
	local work_dir="$2"

	# Only dispatcher-created issue workers need this transfer. Interactive
	# sessions already hold either a registry entry or an interactive claim stamp.
	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	local branch=""
	branch=$(_hrw_current_worktree_branch "$work_dir")
	local transfer_mode="${AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE:-}"
	if [[ -n "$transfer_mode" ]]; then
		if [[ "$transfer_mode" != "continuation" ]]; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED"
			print_error "[fatal] unsupported worker worktree transfer mode: ${transfer_mode}"
			return 1
		fi
		if _hrw_transfer_authorized_continuation_owner "$session_key" "$work_dir" "$branch"; then
			_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
			print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$ mode=continuation"
			return 0
		fi
		if [[ "${_WORKER_PRELAUNCH_FAILURE_REASON:-}" == "$_HRW_REASON_WORKTREE_CONTINUATION_OWNER_ABSENT" ]]; then
			# The dispatcher snapshot can become stale after the previous owner
			# exits. Claiming through the registry is the atomic absence check:
			# a concurrent replacement owner makes this fail closed.
			if claim_worktree_ownership "$work_dir" "$branch" \
				--session "$session_key" \
				--task "${WORKER_ISSUE_NUMBER:-}" \
				--owner-pid "$$"; then
				unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
				_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
				print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$ mode=continuation-owner-absent"
				return 0
			fi
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION"
		fi
		print_error "[fatal] worker worktree continuation transfer rejected: ${work_dir} reason=${_WORKER_PRELAUNCH_FAILURE_REASON:-worker_worktree_live_owner}"
		return 1
	fi

	# t3550: dispatcher pre-creation registers the worktree to a short-lived
	# pulse subshell. After that subshell exits, cleanup sees a dead owner and
	# can remove the worker's cwd while validators/merge-gate fixes still run.
	# Transfer ownership to the long-lived headless-runtime-helper PID so
	# worktree cleanup treats the active worker as the canonical owner.
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	if ! claim_worktree_ownership "$work_dir" "$branch" \
		--session "$session_key" \
		--task "${WORKER_ISSUE_NUMBER:-}" \
		--owner-pid "$$"; then
		if _hrw_reclaim_stale_worker_worktree_owner "$session_key" "$work_dir" "$branch"; then
			if [[ "$_HRW_WORKTREE_RECLAIM_OUTCOME" == "$_HRW_WORKTREE_RECLAIM_TRANSFERRED" ]]; then
				_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
				print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$ mode=owner-transfer"
				return 0
			fi
			if [[ "$_HRW_WORKTREE_RECLAIM_OUTCOME" == "$_HRW_WORKTREE_RECLAIM_VACATED" ]] && \
				claim_worktree_ownership "$work_dir" "$branch" \
					--session "$session_key" \
					--task "${WORKER_ISSUE_NUMBER:-}" \
					--owner-pid "$$"; then
				_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
				print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$ mode=vacated-owner"
				return 0
			fi
		fi
		print_error "[fatal] worker worktree already has a live owner: $work_dir"
		return 1
	fi

	_hrw_export_worker_worktree_owner_proof "$session_key" "$work_dir" || return 1
	print_info "[lifecycle] worker_worktree_claimed session=${session_key} branch=${branch} path=${work_dir} pid=$$"
	return 0
}

_hrw_renew_dispatch_prelaunch_lease() {
	local session_key="$1"

	if [[ -z "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" || -z "${WORKER_ISSUE_NUMBER:-}" || -z "${WORKER_REPO_SLUG:-}" ]]; then
		return 0
	fi
	# GH#34901: manual dispatch runs as manual-cli-* but its claim lease
	# session is issue-N; the dispatcher names that lease session explicitly.
	"${SCRIPT_DIR}/dispatch-claim-helper.sh" transition prelaunch "$WORKER_ISSUE_NUMBER" \
		"$WORKER_REPO_SLUG" "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "${AIDEVOPS_DISPATCH_LEASE_SESSION:-$session_key}" \
		"${AIDEVOPS_DISPATCH_CLAIM_ORPHAN_GRACE:-120}" 2>/dev/null || return 1
	return 0
}

_hrw_release_worker_worktree() {
	local work_dir="$1"
	local session_key="$2"

	if [[ -z "${WORKER_ISSUE_NUMBER:-}" || -z "$work_dir" || -z "$session_key" ]]; then
		return 0
	fi
	unregister_worktree_if_owner_contract "$work_dir" "$$" "$session_key" \
		"${WORKER_ISSUE_NUMBER:-}" 2>/dev/null || true
	return 0
}
