#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared runtime resolution for worker launchers and scheduled Pulse services.
# This is data, never shell code; service generation need not capture shell env.

# A failed stat does not prove absence: find the nearest visible ancestor and
# require directory traversal before treating missing descendants as absent.
_worker_lifecycle_config_parent_accessible() {
	local parent="$1"
	[[ "$parent" == /* ]] || return 1
	while [[ ! -e "$parent" && ! -L "$parent" && "$parent" != / ]]; do
		parent="${parent%/*}"
		[[ -n "$parent" ]] || parent=/
	done
	if [[ ! -d "$parent" || ! -x "$parent" ]]; then
		return 1
	fi
	return 0
}

worker_lifecycle_state_dir() {
	local state_dir="${AIDEVOPS_LIFECYCLE_STATE_DIR:-}"
	local config_file="${HOME}/.config/aidevops/lifecycle-state-dir"
	if [[ -z "$state_dir" ]] && ! _worker_lifecycle_config_parent_accessible "${config_file%/*}"; then
		printf '[worker-lifecycle] observation-gap reason=host-state-config-inaccessible\n' >&2
		return 0
	fi
	if [[ -z "$state_dir" && ( -e "$config_file" || -L "$config_file" ) ]]; then
		if [[ ! -f "$config_file" || -L "$config_file" || ! -O "$config_file" || ! -r "$config_file" ]]; then
			printf '[worker-lifecycle] observation-gap reason=host-state-config-unreadable\n' >&2
			return 0
		fi
		# Accept a final line without a newline. Preserve spaces and backslashes.
		IFS= read -r state_dir <"$config_file" || true
		if [[ -z "$state_dir" ]]; then
			printf '[worker-lifecycle] observation-gap reason=host-state-config-empty\n' >&2
			return 0
		fi
		# Host settings must mean the same path in every worker/service cwd.
		# Validate before expanding ~/; environment overrides retain legacy behavior.
		case "$state_dir" in
		/* | \~/*) ;;
		*)
			printf '[worker-lifecycle] observation-gap reason=host-state-config-relative\n' >&2
			return 0
			;;
		esac
	fi
	state_dir="${state_dir:-${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}/worker-lifecycle}"
	case "$state_dir" in
	\~/*) state_dir="$HOME/${state_dir#\~/}" ;;
	esac
	printf '%s\n' "$state_dir"
	return 0
}

# Produce argv, not shell text. IDs are supplied by the new admission controller,
# never inferred from old registries. Missing mandatory prerequisites deny launch.
worker_lifecycle_prepare_launch() {
	local worktree="$1"
	local entry="$2"
	local private_workload="${3:-0}"
	local generation="${AIDEVOPS_LIFECYCLE_GENERATION_ID:-}"
	local run="${AIDEVOPS_LIFECYCLE_RUN_ID:-}"
	local required=0
	local state_dir="" python=""
	WORKER_LIFECYCLE_PREFIX=()
	if [[ -n "$generation" || -n "$run" ]]; then
		required=1
		if [[ -z "$generation" || -z "$run" || -z "$worktree" || "$private_workload" == 1 || "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
			printf '[worker-lifecycle] admission-denied reason=incomplete-or-excluded-context\n' >&2
			return 75
		fi
	elif [[ -z "$worktree" || "$private_workload" == 1 || "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
		return 0
	fi
	state_dir=$(worker_lifecycle_state_dir)
	if [[ -z "$state_dir" || ! -f "$entry" ]] || ! python="$(type -P python3)" ||
		! "$python" -E -s -B "$entry" --help >/dev/null 2>&1; then
		if [[ "$required" -eq 1 ]]; then
			printf '[worker-lifecycle] admission-denied reason=entry-or-state-unavailable\n' >&2
			return 75
		fi
		printf '[worker-lifecycle] observation-gap reason=entry-or-runtime-unavailable\n' >&2
		return 0
	fi
	if [[ "$required" -eq 1 ]]; then
		worktree=$(cd -- "$worktree" && pwd -P) || return 75
		WORKER_LIFECYCLE_PREFIX=("$python" -E -s -B "$entry" --state-dir "$state_dir"
			--worktree "$worktree" --generation-id "$generation" --run-id "$run" --)
	else
		WORKER_LIFECYCLE_PREFIX=("$python" -E -s -B "$entry" --initialize --state-dir "$state_dir"
			--worktree "$worktree" --)
	fi
	return 0
}
