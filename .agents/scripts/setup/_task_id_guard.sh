#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: install task-id collision guard commit-msg hook in every initialized repo.
# Sourced by setup.sh — do not execute directly.
#
# Idempotent: re-installs managed hooks, skips unmanaged ones with a warning,
# counts each outcome, and returns success regardless of per-repo conflicts
# so setup.sh does not abort on a single non-cooperative repo.
#
# Opt out by exporting AIDEVOPS_TASK_ID_GUARD=false before running setup.

#######################################
# Resolve the path of install-task-id-guard.sh relative to this module.
# Returns: path on stdout, 0 on success; nothing on stdout, 1 on miss.
#######################################
_load_task_id_guard_installer() {
	local installer_path
	installer_path="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../install-task-id-guard.sh"
	if [[ ! -f "$installer_path" ]]; then
		print_warning "install-task-id-guard.sh not found at: $installer_path"
		return 1
	fi
	printf '%s' "$installer_path"
	return 0
}

#######################################
# Install or refresh the task-id collision guard commit-msg hook in every
# initialized repo listed in repos.json. Called from setup.sh.
#
# Behaviour:
#   - Iterates initialized_repos[].path, expanding leading ~
#   - Skips entries without a local .git present
#   - Calls install-task-id-guard.sh install inside each repo (idempotent)
#   - Counts outcomes: ok, already-managed, conflict (unmanaged hook present),
#     skip (no .git), err (other)
#   - Reports a one-line summary via print_info
#   - Tracks success via setup_track_configured
#
# Opt out: AIDEVOPS_TASK_ID_GUARD=false
#######################################
setup_task_id_guard() {
	if [[ "${AIDEVOPS_TASK_ID_GUARD:-true}" == "false" ]]; then
		print_info "Task-ID guard install disabled via AIDEVOPS_TASK_ID_GUARD=false"
		setup_track_skipped "Task-ID guard" "opted out via AIDEVOPS_TASK_ID_GUARD=false"
		return 0
	fi

	print_info "Installing task-id collision guard commit-msg hook across initialized repos..."

	local installer_path
	if ! installer_path=$(_load_task_id_guard_installer); then
		setup_track_skipped "Task-ID guard" "installer not available"
		return 0
	fi

	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_config" ]]; then
		print_warning "repos.json not found — skipping task-id guard rollout"
		setup_track_skipped "Task-ID guard" "repos.json not found"
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not installed — skipping task-id guard rollout"
		setup_track_skipped "Task-ID guard" "jq not installed"
		return 0
	fi

	local ok=0 already=0 conflict=0 skip=0 err=0
	local rawpath path result

	while IFS= read -r rawpath; do
		[[ -z "$rawpath" ]] && continue
		path="${rawpath/#\~/$HOME}"
		if [[ ! -e "$path/.git" ]]; then
			skip=$((skip + 1))
			continue
		fi
		result=$(cd -- "$path" && bash "$installer_path" install 2>&1 </dev/null || true)
		case "$result" in
		*"installed task-id-guard"*)
			ok=$((ok + 1))
			;;
		*"already installed"*)
			already=$((already + 1))
			;;
		*"Refusing to overwrite"* | *"NOT managed"*)
			conflict=$((conflict + 1))
			;;
		*)
			err=$((err + 1))
			;;
		esac
	done < <(jq -r '.initialized_repos[]? | select(.path != null) | .path' "$repos_config")

	print_info "Task-ID guard: ok=$ok already=$already conflict=$conflict skip=$skip err=$err"
	local total_covered=$((ok + already))
	setup_track_configured "Task-ID guard (${total_covered} repos)"
	return 0
}
