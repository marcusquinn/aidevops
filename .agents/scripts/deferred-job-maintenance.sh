#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Cancellation and retention commands for deferred jobs.

if [[ -n "${_AIDEVOPS_DEFERRED_JOB_MAINTENANCE_LOADED:-}" ]]; then
	return 0
fi
_AIDEVOPS_DEFERRED_JOB_MAINTENANCE_LOADED=1

cmd_cancel() {
	local job_id="${1:-}"
	local job_file=""
	local job_json=""
	local status=""
	local now_epoch=0
	local now_iso=""
	local updated=""
	local prompt_file=""
	_dj_valid_job_id "$job_id" || {
		printf 'ERROR: cancel requires a valid JOB_ID\n' >&2
		return 2
	}
	_dj_init_storage || return 1
	job_file=$(_dj_job_file "$job_id")
	_dj_acquire_lock || return 1
	job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
	if [[ -z "$job_json" ]]; then
		_dj_release_lock
		printf 'ERROR: deferred job not found: %s\n' "$job_id" >&2
		return 1
	fi
	if ! _dj_schema_supported "$job_json"; then
		_dj_release_lock
		printf 'ERROR: unsupported deferred-job schema; state was not changed\n' >&2
		return 1
	fi
	status=$(printf '%s\n' "$job_json" | jq -r '.status')
	case "$status" in
	queued | claimed)
		now_epoch=$(_dj_now_epoch)
		now_iso=$(_dj_epoch_to_iso "$now_epoch") || {
			_dj_release_lock
			return 1
		}
		updated=$(printf '%s\n' "$job_json" | jq \
			--arg finished_at "$now_iso" --argjson finished_epoch "$now_epoch" \
			'.status="cancelled" | .finished_at=$finished_at | .finished_epoch=$finished_epoch
			 | .lease={id:null,expires_epoch:null} | .runner_pid=null | .pid=null
			 | .outcome="cancelled_before_launch" | .error=null') || {
			_dj_release_lock
			return 1
		}
		_dj_atomic_write_json "$job_file" "$updated" || {
			_dj_release_lock
			return 1
		}
		_dj_append_event "$job_id" "cancelled" "cancelled_before_launch" || true
		prompt_file=$(_dj_prompt_file "$job_id")
		_dj_release_lock
		rm -f "$prompt_file"
		printf 'Cancelled %s\n' "$job_id"
		return 0
		;;
	running)
		_dj_release_lock
		printf 'ERROR: deferred job is already running and cannot be cancelled safely\n' >&2
		return 1
		;;
	*)
		_dj_release_lock
		printf 'Deferred job %s is already terminal (%s)\n' "$job_id" "$status"
		return 0
		;;
	esac
}

_dj_parse_prune_days() {
	local days=30
	local arg=""
	local value=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		if [[ "$arg" != "--days" || $# -eq 0 ]]; then
			return 2
		fi
		value="$1"
		shift
		[[ "$value" =~ ^[0-9]+$ ]] || return 2
		days="$value"
	done
	printf '%s\n' "$days"
	return 0
}

cmd_prune() {
	local days=30
	local now_epoch=0
	local cutoff=0
	local job_file=""
	local job_json=""
	local job_id=""
	local status=""
	local finished_epoch=0
	local removed=0
	days=$(_dj_parse_prune_days "$@") || {
		printf 'ERROR: prune usage: prune [--days N]\n' >&2
		return 2
	}
	_dj_init_storage || return 1
	now_epoch=$(_dj_now_epoch)
	cutoff=$((now_epoch - (days * 86400)))
	_dj_acquire_lock || return 1
	for job_file in "$_DJ_JOBS_DIR"/*.json; do
		[[ -e "$job_file" ]] || continue
		job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
		[[ -n "$job_json" ]] || continue
		_dj_schema_supported "$job_json" || continue
		status=$(printf '%s\n' "$job_json" | jq -r '.status // ""')
		case "$status" in success | failure | cancelled) ;; *) continue ;; esac
		finished_epoch=$(printf '%s\n' "$job_json" | jq -r '.finished_epoch // 0')
		[[ "$finished_epoch" =~ ^[0-9]+$ ]] || finished_epoch=0
		[[ "$finished_epoch" -le "$cutoff" ]] || continue
		job_id=$(printf '%s\n' "$job_json" | jq -r '.id')
		rm -f "$(_dj_prompt_file "$job_id")" "$job_file"
		removed=$((removed + 1))
	done
	_dj_release_lock
	printf 'Pruned %s terminal deferred job(s)\n' "$removed"
	return 0
}
