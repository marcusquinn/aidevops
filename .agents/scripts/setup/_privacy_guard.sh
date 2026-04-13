#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: install privacy-guard pre-push hook in every initialized repo.
# Sourced by setup.sh — do not execute directly.
#
# Idempotent: re-installs managed hooks, skips unmanaged ones with a warning,
# counts each outcome, and returns success regardless of per-repo conflicts
# so setup.sh does not abort on a single non-cooperative repo.
#
# Opt out by exporting AIDEVOPS_PRIVACY_GUARD=false before running setup.

#######################################
# Resolve the path of install-privacy-guard.sh relative to this module.
# Returns: path on stdout, 0 on success; nothing on stdout, 1 on miss.
#######################################
_load_privacy_guard_installer() {
	local installer_path
	installer_path="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../install-privacy-guard.sh"
	if [[ ! -f "$installer_path" ]]; then
		print_warning "install-privacy-guard.sh not found at: $installer_path"
		return 1
	fi
	printf '%s' "$installer_path"
	return 0
}

#######################################
# Install or refresh the privacy-guard pre-push hook in every initialized
# repo listed in repos.json. Called from setup.sh.
#
# Behaviour:
#   - Iterates initialized_repos[].path, expanding leading ~
#   - Skips entries without a local .git present
#   - Calls install-privacy-guard.sh install inside each repo (idempotent)
#   - Counts outcomes: ok, already-managed, conflict (unmanaged hook present),
#     skip (no .git), err (other)
#   - Reports a one-line summary via print_info
#   - Tracks success via setup_track_configured
#
# Opt out: AIDEVOPS_PRIVACY_GUARD=false
#######################################
setup_privacy_guard() {
	if [[ "${AIDEVOPS_PRIVACY_GUARD:-true}" == "false" ]]; then
		print_info "Privacy guard install disabled via AIDEVOPS_PRIVACY_GUARD=false"
		setup_track_skipped "Privacy guard" "opted out via AIDEVOPS_PRIVACY_GUARD=false"
		return 0
	fi

	print_info "Installing privacy guard pre-push hook across initialized repos..."

	local installer_path
	if ! installer_path=$(_load_privacy_guard_installer); then
		setup_track_skipped "Privacy guard" "installer not available"
		return 0
	fi

	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_config" ]]; then
		print_warning "repos.json not found — skipping privacy guard rollout"
		setup_track_skipped "Privacy guard" "repos.json not found"
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not installed — skipping privacy guard rollout"
		setup_track_skipped "Privacy guard" "jq not installed"
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
		*"installed privacy guard"*)
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

	print_info "Privacy guard: ok=$ok already=$already conflict=$conflict skip=$skip err=$err"
	local total_covered=$((ok + already))
	setup_track_configured "Privacy guard (${total_covered} repos)"
	return 0
}
