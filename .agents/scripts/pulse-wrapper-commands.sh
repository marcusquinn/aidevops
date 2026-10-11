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

_pulse_wrapper_report_result() {
	local command_name="$1" rc="$2" outcome="failed"
	case "${command_name}:${rc}" in
	dispatch:0) outcome="launched" ;;
	dispatch:1 | dispatch:3) outcome="deferred" ;;
	repo-cap:0) outcome="at-cap" ;;
	repo-cap:1) outcome="below-cap" ;;
	esac
	printf 'PULSE_COMMAND_RESULT command=%s rc=%s outcome=%s\n' "$command_name" "$rc" "$outcome"
	return 0
}

_pulse_wrapper_observe_command() (
	local command_name="$1"
	shift
	# A subshell-local EXIT trap reports both normal returns and errexit exits,
	# without replacing the caller's traps or suppressing errexit in the delegate.
	# Do not invoke the delegate in if/||/&&, or enable/disable shell options here.
	trap '_pulse_wrapper_report_result "$command_name" "$?"' EXIT
	"$@"
	return $?
)

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
		_pulse_wrapper_observe_command dispatch dispatch_with_dedup "$@"
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
		_pulse_wrapper_observe_command repo-cap check_repo_worker_cap "$@"
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
	# GH#34323: return the delegated status. A case takes the status of its arm's
	# last command; callers that suppress errexit (if, ||, set +e) must still see
	# deferred dispatch (1/3) and predicate results such as repo-cap below-cap (1).
	# Do not wrap delegates in `|| rc=$?`: that would disable errexit inside them.
	return $?
}
