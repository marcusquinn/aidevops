#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Review workers must leave a systemd oneshot's cgroup, not just its session.

# shellcheck source=./systemd-scope-launch.sh
source "${BASH_SOURCE[0]%/*}/systemd-scope-launch.sh"
# Reuse the owned-root, exclusive mode-600 log allocator, not the caller's log.
# shellcheck source=./headless-runtime-worker-prepare.sh
source "${BASH_SOURCE[0]%/*}/headless-runtime-worker-prepare.sh"

_prrts_launch_detached_worker() {
	local repo_slug="$1"
	local pr_number="$2"
	local pid_var="$3"
	local mode_var="$4"
	shift 4
	local launched_pid="" launched_mode="" launch_result=""
	local attempt_log=""
	attempt_log=$(_hrw_create_detached_log "pr-review-${repo_slug}-${pr_number}") || {
		PRRTS_WORKTREE_FAILURE_REASON="detached_log_creation_failed"
		return 1
	}
	_prrts_log "dispatch: ${repo_slug}#${pr_number} attempt_log=${attempt_log}"
	# env is part of the command for both systemd and nohup launch paths.
	set -- env "AIDEVOPS_WORKER_ATTEMPT_LOG=$attempt_log" "$@"
	if systemd_scope_available; then
		launch_result=$(systemd_scope_launch \
			"aidevops-pr-review-${pr_number}-$$-${RANDOM}" \
			"aidevops review response ${repo_slug}#${pr_number}" "$attempt_log" "$@") || {
			PRRTS_WORKTREE_FAILURE_REASON="worker_scope_launch_failed"
			return 1
		}
		read -r launched_pid launched_mode <<<"$launch_result"
	elif [[ -n "${INVOCATION_ID:-}" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="worker_scope_unavailable"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} blocked — systemd scope unavailable inside a managed unit"
		return 1
	elif command -v setsid >/dev/null 2>&1; then
		launched_mode="setsid+nohup"
		setsid nohup "$@" </dev/null >>"$attempt_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
		launched_pid="$!"
	else
		launched_mode="nohup"
		_prrts_log "dispatch: setsid unavailable for ${repo_slug}#${pr_number}; launching with nohup-only isolation"
		nohup "$@" </dev/null >>"$attempt_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
		launched_pid="$!"
	fi
	printf -v "$pid_var" '%s' "$launched_pid"
	printf -v "$mode_var" '%s' "$launched_mode"
	return 0
}

_prrts_launch_reserved_worker() {
	local repo_slug="$1" pr_number="$2" worker_worktree_path="$3" session_key="$4" outcome_id="$5" reservation_file="$6"
	local worker_pid="" detach_mode=""
	shift 6
	_prrts_launch_detached_worker "$repo_slug" "$pr_number" worker_pid detach_mode "$@" || return 1
	# A failed capacity activation does not prove that the detached worker never
	# ran. Leave its claim to worker/runtime reconciliation, not approval reuse.
	PRRTS_WORKER_LAUNCH_STARTED=1
	if ! _prrts_activate_global_capacity "$reservation_file" "$worker_pid" "$session_key"; then
		kill "$worker_pid" 2>/dev/null || true
		_prrts_release_global_capacity "$reservation_file" "$$" || true
		PRRTS_WORKTREE_FAILURE_REASON="global_worker_reservation_activation_failed"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — could not activate global worker reservation for pid=${worker_pid}"
		return 1
	fi
	disown "$worker_pid" 2>/dev/null || true
	_prrts_log "dispatch: launched response worker for ${repo_slug}#${pr_number} in ${worker_worktree_path} session_key=${session_key} pid=${worker_pid} detach=${detach_mode} attempt_id=${outcome_id}"
	return 0
}
