#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Claim, recovery, preflight, and dispatch logic for deferred jobs.

if [[ -n "${_AIDEVOPS_DEFERRED_JOB_RUNNER_LOADED:-}" ]]; then
	return 0
fi
_AIDEVOPS_DEFERRED_JOB_RUNNER_LOADED=1

_DJ_CLAIMED_JOB_ID=""
_DJ_CLAIMED_LEASE_ID=""
_DJ_PREFLIGHT_ERROR=""
_DJ_RUN_KIND=""
_DJ_RUN_HELPER=""
_DJ_RUN_PROMPT_FILE=""
_DJ_CHILD_PID=""
_DJ_SUCCESS_OUTCOME="completed"
_DJ_STATUS_QUEUED="queued"
_DJ_STATUS_CLAIMED="claimed"
_DJ_STATUS_RUNNING="running"
_DJ_STATUS_SUCCESS="success"
_DJ_STATUS_FAILURE="failure"

_dj_recover_stale_jobs_locked() {
	local now_epoch="$1"
	local job_file=""
	local job_json=""
	local job_id=""
	local status=""
	local lease_expires=0
	local now_iso=""
	local updated=""
	now_iso=$(_dj_epoch_to_iso "$now_epoch") || return 1

	for job_file in "$_DJ_JOBS_DIR"/*.json; do
		[[ -e "$job_file" ]] || continue
		job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
		[[ -n "$job_json" ]] || continue
		job_id=$(printf '%s\n' "$job_json" | jq -r '.id // "unknown"')
		if ! _dj_schema_supported "$job_json"; then
			_dj_append_event "$job_id" "unsupported" "unsupported_schema" || true
			continue
		fi
		status=$(printf '%s\n' "$job_json" | jq -r '.status // ""')
		lease_expires=$(printf '%s\n' "$job_json" | jq -r '.lease.expires_epoch // 0')
		[[ "$lease_expires" =~ ^[0-9]+$ ]] || lease_expires=0
		if [[ "$status" == "$_DJ_STATUS_CLAIMED" && "$lease_expires" -le "$now_epoch" ]]; then
			updated=$(printf '%s\n' "$job_json" | jq \
				--arg status "$_DJ_STATUS_QUEUED" \
				--arg recovered_at "$now_iso" \
				'.status = $status
				 | .claimed_at = null
				 | .lease = {id:null,expires_epoch:null}
				 | .runner_pid = null
				 | .pid = null
				 | .outcome = "recovered_expired_claim"
				 | .error = null
				 | .recovered_at = $recovered_at
				 | .recovery_count = ((.recovery_count // 0) + 1)') || return 1
			_dj_atomic_write_json "$job_file" "$updated" || return 1
			_dj_append_event "$job_id" "$_DJ_STATUS_QUEUED" "claim_recovered" || true
		elif [[ "$status" == "$_DJ_STATUS_RUNNING" && "$lease_expires" -le "$now_epoch" ]]; then
			updated=$(printf '%s\n' "$job_json" | jq \
				--arg status "$_DJ_STATUS_FAILURE" \
				--arg finished_at "$now_iso" \
				--argjson finished_epoch "$now_epoch" \
				'.status = $status
				 | .finished_at = $finished_at
				 | .finished_epoch = $finished_epoch
				 | .lease = {id:null,expires_epoch:null}
				 | .runner_pid = null
				 | .pid = null
				 | .outcome = "lease_expired_after_start"
				 | .error = "runner_lost_before_terminal_write"') || return 1
			_dj_atomic_write_json "$job_file" "$updated" || return 1
			_dj_append_event "$job_id" "$_DJ_STATUS_FAILURE" "running_lease_expired" "not_replayed" || true
		fi
	done
	return 0
}

_dj_claim_next_due() {
	local now_epoch=0
	local job_file=""
	local job_json=""
	local job_id=""
	local status=""
	local due_epoch=0
	local lease_id=""
	local lease_seconds="${AIDEVOPS_DEFERRED_LEASE_SECONDS:-300}"
	local lease_expires=0
	local now_iso=""
	local updated=""
	_DJ_CLAIMED_JOB_ID=""
	_DJ_CLAIMED_LEASE_ID=""
	[[ "$lease_seconds" =~ ^[1-9][0-9]*$ ]] || lease_seconds=300
	_dj_init_storage || return 1
	_dj_acquire_lock || return 1
	now_epoch=$(_dj_now_epoch)
	now_iso=$(_dj_epoch_to_iso "$now_epoch") || {
		_dj_release_lock
		return 1
	}
	_dj_recover_stale_jobs_locked "$now_epoch" || {
		_dj_release_lock
		return 1
	}

	for job_file in "$_DJ_JOBS_DIR"/*.json; do
		[[ -e "$job_file" ]] || continue
		job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
		[[ -n "$job_json" ]] || continue
		_dj_schema_supported "$job_json" || continue
		status=$(printf '%s\n' "$job_json" | jq -r '.status // ""')
		due_epoch=$(printf '%s\n' "$job_json" | jq -r '.due_epoch // 0')
		[[ "$due_epoch" =~ ^[0-9]+$ ]] || due_epoch=0
		[[ "$status" == "$_DJ_STATUS_QUEUED" && "$due_epoch" -le "$now_epoch" ]] || continue
		job_id=$(printf '%s\n' "$job_json" | jq -r '.id')
		lease_id="lease-${job_id}-${now_epoch}-$$-${RANDOM}"
		lease_expires=$((now_epoch + lease_seconds))
		updated=$(printf '%s\n' "$job_json" | jq \
			--arg status "$_DJ_STATUS_CLAIMED" \
			--arg claimed_at "$now_iso" \
			--arg lease_id "$lease_id" \
			--argjson lease_expires "$lease_expires" \
			'.status = $status
			 | .claimed_at = $claimed_at
			 | .attempt = ((.attempt // 0) + 1)
			 | .lease = {id:$lease_id,expires_epoch:$lease_expires}
			 | .runner_pid = null
			 | .pid = null
			 | .outcome = null
			 | .error = null') || {
			_dj_release_lock
			return 1
		}
		_dj_atomic_write_json "$job_file" "$updated" || {
			_dj_release_lock
			return 1
		}
		_dj_append_event "$job_id" "$_DJ_STATUS_CLAIMED" "due_claimed" || true
		_DJ_CLAIMED_JOB_ID="$job_id"
		_DJ_CLAIMED_LEASE_ID="$lease_id"
		break
	done
	_dj_release_lock
	return 0
}

_dj_transition_claimed_to_running() {
	local job_id="$1"
	local lease_id="$2"
	local started_epoch="$3"
	local job_file=""
	local job_json=""
	local current_status=""
	local current_lease=""
	local started_at=""
	local updated=""
	job_file=$(_dj_job_file "$job_id")
	started_at=$(_dj_epoch_to_iso "$started_epoch") || return 1
	_dj_acquire_lock || return 1
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	current_status=$(printf '%s\n' "$job_json" | jq -r '.status // ""' 2>/dev/null || true)
	current_lease=$(printf '%s\n' "$job_json" | jq -r '.lease.id // ""' 2>/dev/null || true)
	if [[ "$current_status" != "$_DJ_STATUS_CLAIMED" || "$current_lease" != "$lease_id" ]]; then
		_dj_release_lock
		return 1
	fi
	updated=$(printf '%s\n' "$job_json" | jq \
		--arg status "$_DJ_STATUS_RUNNING" \
		--arg started_at "$started_at" \
		--argjson started_epoch "$started_epoch" \
		--argjson runner_pid "$$" \
		'.status = $status
		 | .started_at = $started_at
		 | .started_epoch = $started_epoch
		 | .runner_pid = $runner_pid') || {
		_dj_release_lock
		return 1
	}
	_dj_atomic_write_json "$job_file" "$updated" || {
		_dj_release_lock
		return 1
	}
	_dj_append_event "$job_id" "$_DJ_STATUS_RUNNING" "dispatch_starting" || true
	_dj_release_lock
	return 0
}

_dj_set_child_pid() {
	local job_id="$1"
	local lease_id="$2"
	local child_pid="$3"
	local job_file=""
	local job_json=""
	local updated=""
	job_file=$(_dj_job_file "$job_id")
	_dj_acquire_lock || return 1
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	if [[ "$(printf '%s\n' "$job_json" | jq -r '.status // ""')" != "$_DJ_STATUS_RUNNING" ||
	"$(printf '%s\n' "$job_json" | jq -r '.lease.id // ""')" != "$lease_id" ]]; then
		_dj_release_lock
		return 1
	fi
	updated=$(printf '%s\n' "$job_json" | jq --argjson pid "$child_pid" '.pid = $pid') || {
		_dj_release_lock
		return 1
	}
	_dj_atomic_write_json "$job_file" "$updated" || {
		_dj_release_lock
		return 1
	}
	_dj_release_lock
	return 0
}

_dj_renew_lease() {
	local job_id="$1"
	local lease_id="$2"
	local lease_seconds="${AIDEVOPS_DEFERRED_LEASE_SECONDS:-300}"
	local now_epoch=0
	local expires_epoch=0
	local job_file=""
	local job_json=""
	local updated=""
	[[ "$lease_seconds" =~ ^[1-9][0-9]*$ ]] || lease_seconds=300
	now_epoch=$(_dj_now_epoch)
	expires_epoch=$((now_epoch + lease_seconds))
	job_file=$(_dj_job_file "$job_id")
	_dj_acquire_lock || return 1
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	if [[ "$(printf '%s\n' "$job_json" | jq -r '.status // ""')" != "$_DJ_STATUS_RUNNING" ||
	"$(printf '%s\n' "$job_json" | jq -r '.lease.id // ""')" != "$lease_id" ]]; then
		_dj_release_lock
		return 1
	fi
	updated=$(printf '%s\n' "$job_json" | jq --argjson expires "$expires_epoch" '.lease.expires_epoch = $expires') || {
		_dj_release_lock
		return 1
	}
	_dj_atomic_write_json "$job_file" "$updated" || {
		_dj_release_lock
		return 1
	}
	_dj_release_lock
	return 0
}

_dj_finish_job() {
	local job_id="$1"
	local lease_id="$2"
	local expected_status="$3"
	local final_status="$4"
	local outcome="$5"
	local error_code="$6"
	local duration="$7"
	local now_epoch=0
	local now_iso=""
	local job_file=""
	local job_json=""
	local updated=""
	local current_status=""
	local current_lease=""
	now_epoch=$(_dj_now_epoch)
	now_iso=$(_dj_epoch_to_iso "$now_epoch") || return 1
	job_file=$(_dj_job_file "$job_id")
	_dj_acquire_lock || return 1
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	current_status=$(printf '%s\n' "$job_json" | jq -r '.status // ""' 2>/dev/null || true)
	current_lease=$(printf '%s\n' "$job_json" | jq -r '.lease.id // ""' 2>/dev/null || true)
	if [[ "$current_status" != "$expected_status" || "$current_lease" != "$lease_id" ]]; then
		_dj_release_lock
		return 1
	fi
	updated=$(printf '%s\n' "$job_json" | jq \
		--arg status "$final_status" \
		--arg finished_at "$now_iso" \
		--argjson finished_epoch "$now_epoch" \
		--arg outcome "$outcome" \
		--arg error "$error_code" \
		--argjson duration "$duration" \
		'.status = $status
		 | .finished_at = $finished_at
		 | .finished_epoch = $finished_epoch
		 | .duration_seconds = $duration
		 | .lease = {id:null,expires_epoch:null}
		 | .runner_pid = null
		 | .pid = null
		 | .outcome = $outcome
		 | .error = (if $error == "" then null else $error end)') || {
		_dj_release_lock
		return 1
	}
	_dj_atomic_write_json "$job_file" "$updated" || {
		_dj_release_lock
		return 1
	}
	_dj_append_event "$job_id" "$final_status" "terminal" "$outcome" || true
	_dj_release_lock
	return 0
}

_dj_resolve_headless_helper() {
	local helper="${AIDEVOPS_HEADLESS_RUNTIME_HELPER:-${SCRIPT_DIR}/headless-runtime-helper.sh}"
	[[ -x "$helper" ]] || return 1
	printf '%s\n' "$helper"
	return 0
}

_dj_resolve_manual_helper() {
	local helper="${AIDEVOPS_MANUAL_DISPATCH_HELPER:-${SCRIPT_DIR}/dispatch-single-issue-helper.sh}"
	[[ -x "$helper" ]] || return 1
	printf '%s\n' "$helper"
	return 0
}

_dj_validate_prompt_material() {
	local job_json="$1"
	local job_id="$2"
	local prompt_ref=""
	local expected_ref="prompts/${job_id}.prompt"
	local expected_digest=""
	local actual_digest=""
	prompt_ref=$(printf '%s\n' "$job_json" | jq -r '.dispatch.prompt_ref // ""')
	expected_digest=$(printf '%s\n' "$job_json" | jq -r '.dispatch.prompt_sha256 // ""')
	if [[ "$prompt_ref" != "$expected_ref" ]]; then
		_DJ_PREFLIGHT_ERROR="invalid_prompt_reference"
		return 1
	fi
	_DJ_RUN_PROMPT_FILE=$(_dj_prompt_file "$job_id")
	if [[ ! -f "$_DJ_RUN_PROMPT_FILE" ]]; then
		_DJ_PREFLIGHT_ERROR="missing_prompt_material"
		return 1
	fi
	actual_digest=$(_dj_sha256 "$_DJ_RUN_PROMPT_FILE" 2>/dev/null || true)
	if [[ -z "$actual_digest" || "$actual_digest" != "$expected_digest" ]]; then
		_DJ_PREFLIGHT_ERROR="prompt_digest_mismatch"
		return 1
	fi
	return 0
}

_dj_preflight_job() {
	local job_json="$1"
	local job_id=""
	local dispatch_dir=""
	local worktree=""
	local branch=""
	local repo_slug=""
	local actual_dir=""
	local actual_worktree=""
	local actual_branch=""
	local actual_slug=""
	_DJ_PREFLIGHT_ERROR=""
	_DJ_RUN_KIND=$(printf '%s\n' "$job_json" | jq -r '.dispatch.kind // ""')
	job_id=$(printf '%s\n' "$job_json" | jq -r '.id // ""')
	dispatch_dir=$(printf '%s\n' "$job_json" | jq -r '.dispatch.dir // ""')
	if [[ -z "$dispatch_dir" || ! -d "$dispatch_dir" ]]; then
		_DJ_PREFLIGHT_ERROR="missing_dispatch_directory"
		return 1
	fi
	case "$_DJ_RUN_KIND" in
	prompt)
		_DJ_RUN_HELPER=$(_dj_resolve_headless_helper 2>/dev/null || true)
		[[ -n "$_DJ_RUN_HELPER" ]] || {
			_DJ_PREFLIGHT_ERROR="missing_headless_runtime_helper"
			return 1
		}
		_dj_validate_prompt_material "$job_json" "$job_id" || return 1
		;;
	issue-worktree)
		_DJ_RUN_HELPER=$(_dj_resolve_headless_helper 2>/dev/null || true)
		[[ -n "$_DJ_RUN_HELPER" ]] || {
			_DJ_PREFLIGHT_ERROR="missing_headless_runtime_helper"
			return 1
		}
		worktree=$(printf '%s\n' "$job_json" | jq -r '.dispatch.worktree // ""')
		branch=$(printf '%s\n' "$job_json" | jq -r '.dispatch.branch // ""')
		repo_slug=$(printf '%s\n' "$job_json" | jq -r '.dispatch.repo // ""')
		actual_dir=$(_dj_canonical_dir "$dispatch_dir" 2>/dev/null || true)
		actual_worktree=$(_dj_canonical_dir "$worktree" 2>/dev/null || true)
		if [[ -z "$actual_worktree" || "$actual_dir" != "$actual_worktree" ]]; then
			_DJ_PREFLIGHT_ERROR="worktree_scope_mismatch"
			return 1
		fi
		git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
			_DJ_PREFLIGHT_ERROR="invalid_worktree"
			return 1
		}
		actual_branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
		if [[ -n "$branch" && "$actual_branch" != "$branch" ]]; then
			_DJ_PREFLIGHT_ERROR="branch_scope_mismatch"
			return 1
		fi
		actual_slug=$(_dj_origin_slug "$worktree" 2>/dev/null || true)
		if [[ -z "$actual_slug" || "$actual_slug" != "$repo_slug" ]]; then
			_DJ_PREFLIGHT_ERROR="repository_scope_mismatch"
			return 1
		fi
		_dj_validate_prompt_material "$job_json" "$job_id" || return 1
		;;
	issue-manual)
		_DJ_RUN_HELPER=$(_dj_resolve_manual_helper 2>/dev/null || true)
		[[ -n "$_DJ_RUN_HELPER" ]] || {
			_DJ_PREFLIGHT_ERROR="missing_manual_dispatch_helper"
			return 1
		}
		;;
	*)
		_DJ_PREFLIGHT_ERROR="unsupported_dispatch_kind"
		return 1
		;;
	esac
	return 0
}

_dj_launch_job() {
	local job_json="$1"
	local job_id=""
	local dispatch_dir=""
	local session_key=""
	local title=""
	local agent_name=""
	local tier=""
	local model=""
	local issue_number=""
	local repo_slug=""
	local worktree=""
	local branch=""
	local job_log=""
	local -a command_args=()
	job_id=$(printf '%s\n' "$job_json" | jq -r '.id')
	dispatch_dir=$(printf '%s\n' "$job_json" | jq -r '.dispatch.dir')
	session_key=$(printf '%s\n' "$job_json" | jq -r '.session_key')
	title=$(printf '%s\n' "$job_json" | jq -r '.dispatch.title // "Deferred job"')
	agent_name=$(printf '%s\n' "$job_json" | jq -r '.dispatch.agent // ""')
	tier=$(printf '%s\n' "$job_json" | jq -r '.dispatch.tier // ""')
	model=$(printf '%s\n' "$job_json" | jq -r '.dispatch.model // ""')
	issue_number=$(printf '%s\n' "$job_json" | jq -r '.dispatch.issue // ""')
	repo_slug=$(printf '%s\n' "$job_json" | jq -r '.dispatch.repo // ""')
	worktree=$(printf '%s\n' "$job_json" | jq -r '.dispatch.worktree // ""')
	branch=$(printf '%s\n' "$job_json" | jq -r '.dispatch.branch // ""')
	job_log="${_DJ_LOGS_DIR}/${job_id}.log"
	: >>"$job_log"
	chmod 600 "$job_log"
	_DJ_SUCCESS_OUTCOME="completed"

	if [[ "$_DJ_RUN_KIND" == "issue-manual" ]]; then
		command_args=("$_DJ_RUN_HELPER" dispatch "$issue_number" "$repo_slug")
		[[ -z "$agent_name" ]] || command_args+=(--agent "$agent_name")
		[[ -z "$model" ]] || command_args+=(--model "$model")
		[[ -z "$branch" ]] || command_args+=(--base "$branch")
		"${command_args[@]}" >>"$job_log" 2>&1 &
		_DJ_CHILD_PID=$!
		_DJ_SUCCESS_OUTCOME="dispatched"
		return 0
	fi

	command_args=("$_DJ_RUN_HELPER" run --role worker --session-key "$session_key" --dir "$dispatch_dir" --title "$title" --prompt-file "$_DJ_RUN_PROMPT_FILE")
	[[ -z "$agent_name" ]] || command_args+=(--agent "$agent_name")
	[[ -z "$tier" ]] || command_args+=(--tier "$tier")
	[[ -z "$model" ]] || command_args+=(--model "$model")
	if [[ "$_DJ_RUN_KIND" == "issue-worktree" ]]; then
		WORKER_ISSUE_NUMBER="$issue_number" \
			WORKER_REPO_SLUG="$repo_slug" \
			DISPATCH_REPO_SLUG="$repo_slug" \
			WORKER_WORKTREE_PATH="$worktree" \
			GITHUB_REPOSITORY="$repo_slug" \
			"${command_args[@]}" >>"$job_log" 2>&1 &
	else
		"${command_args[@]}" >>"$job_log" 2>&1 &
	fi
	_DJ_CHILD_PID=$!
	return 0
}

cmd_run_due() {
	local job_id=""
	local lease_id=""
	local job_file=""
	local job_json=""
	local started_epoch=0
	local ended_epoch=0
	local duration=0
	local child_rc=0
	local heartbeat_pid=""
	local heartbeat_interval="${AIDEVOPS_DEFERRED_HEARTBEAT_SECONDS:-30}"
	[[ "$heartbeat_interval" =~ ^[1-9][0-9]*$ ]] || heartbeat_interval=30
	_dj_claim_next_due || return 1
	job_id="$_DJ_CLAIMED_JOB_ID"
	lease_id="$_DJ_CLAIMED_LEASE_ID"
	[[ -n "$job_id" ]] || return 0
	job_file=$(_dj_job_file "$job_id")
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	if [[ -z "$job_json" ]] || ! _dj_preflight_job "$job_json"; then
		_dj_finish_job "$job_id" "$lease_id" "$_DJ_STATUS_CLAIMED" "$_DJ_STATUS_FAILURE" "failed_preflight" "${_DJ_PREFLIGHT_ERROR:-invalid_job_state}" 0 || true
		printf 'Deferred job %s failed preflight: %s\n' "$job_id" "${_DJ_PREFLIGHT_ERROR:-invalid_job_state}" >&2
		return 1
	fi
	started_epoch=$(_dj_now_epoch)
	if ! _dj_transition_claimed_to_running "$job_id" "$lease_id" "$started_epoch"; then
		return 0
	fi
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	if ! _dj_launch_job "$job_json"; then
		_dj_finish_job "$job_id" "$lease_id" "$_DJ_STATUS_RUNNING" "$_DJ_STATUS_FAILURE" "launch_failed" "launch_failed" 0 || true
		return 1
	fi
	_dj_set_child_pid "$job_id" "$lease_id" "$_DJ_CHILD_PID" || true
	(
		while kill -0 "$_DJ_CHILD_PID" 2>/dev/null; do
			sleep "$heartbeat_interval"
			kill -0 "$_DJ_CHILD_PID" 2>/dev/null || break
			_dj_renew_lease "$job_id" "$lease_id" || break
		done
		return 0
	) &
	heartbeat_pid=$!
	wait "$_DJ_CHILD_PID" || child_rc=$?
	kill "$heartbeat_pid" 2>/dev/null || true
	wait "$heartbeat_pid" 2>/dev/null || true
	ended_epoch=$(_dj_now_epoch)
	duration=$((ended_epoch - started_epoch))
	[[ "$duration" -ge 0 ]] || duration=0
	if [[ "$child_rc" -eq 0 ]]; then
		_dj_finish_job "$job_id" "$lease_id" "$_DJ_STATUS_RUNNING" "$_DJ_STATUS_SUCCESS" "$_DJ_SUCCESS_OUTCOME" "" "$duration" || return 1
		printf 'Deferred job %s completed\n' "$job_id"
		return 0
	fi
	_dj_finish_job "$job_id" "$lease_id" "$_DJ_STATUS_RUNNING" "$_DJ_STATUS_FAILURE" "runtime_exit_${child_rc}" "runtime_failed" "$duration" || return 1
	printf 'Deferred job %s failed (exit %s)\n' "$job_id" "$child_rc" >&2
	return "$child_rc"
}
