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
