#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper's policy-compatible command router for supervisor prompts.
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-commands.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_COMMANDS_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_COMMANDS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_pulse_wrapper_command_usage() {
	printf '%s\n' 'usage: pulse-wrapper.sh --command <capacity|list-candidates|dispatch|approve-pr|relabel-needs-info|dispatch-foss|repo-cap|count-debt|create-debt-worktree|sync-todo> [args...]' >&2
	return 2
}

_pulse_wrapper_run_command() {
	local command_name="${1:-}"
	[[ -n "$command_name" ]] || {
		_pulse_wrapper_command_usage
		return 2
	}
	shift

	case "$command_name" in
	capacity)
		[[ "$#" -eq 0 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		local max_workers="" active_workers="" available=""
		max_workers=$(get_max_workers_target)
		active_workers=$(count_active_workers)
		[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
		[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
		available=$((max_workers - active_workers))
		[[ "$available" -ge 0 ]] || available=0
		printf '%s|%s|%s\n' "$max_workers" "$active_workers" "$available"
		;;
	list-candidates)
		[[ "$#" -ge 1 && "$#" -le 2 && -n "${1:-}" && "${2:-100}" =~ ^[0-9]+$ ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		local repo_slug="$1" candidate_limit="${2:-100}"
		list_dispatchable_issue_candidates "$repo_slug" "$candidate_limit"
		;;
	dispatch)
		[[ "$#" -eq 7 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		dispatch_with_dedup "$@"
		;;
	approve-pr)
		[[ "$#" -eq 3 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		approve_collaborator_pr "$@"
		;;
	relabel-needs-info)
		[[ "$#" -le 1 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		relabel_needs_info_replies "$@"
		;;
	dispatch-foss)
		[[ "$#" -ge 1 && "$#" -le 2 && "${1:-}" =~ ^[0-9]+$ ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		dispatch_foss_workers "$@"
		;;
	repo-cap)
		[[ "$#" -eq 1 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		check_repo_worker_cap "$@"
		;;
	count-debt)
		[[ "$#" -eq 2 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		count_debt_workers "$@"
		;;
	create-debt-worktree)
		[[ "$#" -eq 3 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		create_quality_debt_worktree "$@"
		;;
	sync-todo)
		[[ "$#" -eq 2 ]] || {
			_pulse_wrapper_command_usage
			return 2
		}
		sync_todo_refs_for_repo "$@"
		;;
	*)
		_pulse_wrapper_command_usage
		return 2
		;;
	esac

	return 0
}
