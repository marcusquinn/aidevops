#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared runtime resolution for worker launchers and scheduled Pulse services.
# This is data, never shell code; service generation need not capture shell env.

worker_lifecycle_state_dir() {
	local state_dir="${AIDEVOPS_LIFECYCLE_STATE_DIR:-}"
	local config_file="${HOME}/.config/aidevops/lifecycle-state-dir"
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
	fi
	state_dir="${state_dir:-${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}/worker-lifecycle}"
	case "$state_dir" in
	\~/*) state_dir="$HOME/${state_dir#\~/}" ;;
	esac
	printf '%s\n' "$state_dir"
	return 0
}
