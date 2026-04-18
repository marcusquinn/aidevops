#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: install complexity-regression pre-push hook in every initialized
# repo (t2198). Sourced by setup.sh — do not execute directly.
#
# Idempotent: re-installs managed hooks, skips unmanaged ones with a warning,
# counts each outcome, and returns success regardless of per-repo conflicts
# so setup.sh does not abort on a single non-cooperative repo.
#
# Opt out by exporting AIDEVOPS_COMPLEXITY_GUARD=false before running setup.

#######################################
# Resolve the path of install-pre-push-guards.sh relative to this module.
# Returns: path on stdout, 0 on success; nothing on stdout, 1 on miss.
# NOTE: _load_guards_installer may already be defined by _privacy_guard.sh
# (both modules are sourced into the same shell). Guard for double-definition.
#######################################
if ! declare -f _load_guards_installer >/dev/null 2>&1; then
	_load_guards_installer() {
		local installer_path
		installer_path="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../install-pre-push-guards.sh"
		if [[ ! -f "$installer_path" ]]; then
			print_warning "install-pre-push-guards.sh not found at: $installer_path"
			return 1
		fi
		printf '%s' "$installer_path"
		return 0
	}
fi

#######################################
# Install or refresh the complexity-regression pre-push hook in every
# initialized repo listed in repos.json. Called from setup.sh.
#
# Behaviour:
#   - Iterates initialized_repos[].path, expanding leading ~
#   - Skips entries without a local .git present
#   - Calls install-pre-push-guards.sh install --guard complexity (idempotent)
#   - Counts outcomes: ok, conflict (unmanaged hook present), skip (no .git), err
#   - Reports a one-line summary via print_info
#   - Tracks success via setup_track_configured
#
# Opt out: AIDEVOPS_COMPLEXITY_GUARD=false
#######################################
setup_complexity_guard() {
	if [[ "${AIDEVOPS_COMPLEXITY_GUARD:-true}" == "false" ]]; then
		print_info "Complexity guard install disabled via AIDEVOPS_COMPLEXITY_GUARD=false"
		setup_track_skipped "Complexity guard" "opted out via AIDEVOPS_COMPLEXITY_GUARD=false"
		return 0
	fi

	print_info "Installing complexity regression pre-push hook across initialized repos..."

	local installer_path
	if ! installer_path=$(_load_guards_installer); then
		setup_track_skipped "Complexity guard" "installer not available"
		return 0
	fi

	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_config" ]]; then
		print_warning "repos.json not found — skipping complexity guard rollout"
		setup_track_skipped "Complexity guard" "repos.json not found"
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not installed — skipping complexity guard rollout"
		setup_track_skipped "Complexity guard" "jq not installed"
		return 0
	fi

	local ok=0 conflict=0 skip=0 err=0
	local rawpath path result

	while IFS= read -r rawpath; do
		[[ -z "$rawpath" ]] && continue
		path="${rawpath/#\~/$HOME}"
		if [[ ! -e "$path/.git" ]]; then
			skip=$((skip + 1))
			continue
		fi
		result=$(cd -- "$path" && bash "$installer_path" install --guard complexity 2>&1 </dev/null || true)
		case "$result" in
		*"pre-push guards"*)
			ok=$((ok + 1))
			;;
		*"Refusing to overwrite"* | *"NOT managed"*)
			conflict=$((conflict + 1))
			;;
		*)
			err=$((err + 1))
			;;
		esac
	done < <(jq -r '.initialized_repos[]? | select(.path != null) | .path' "$repos_config")

	print_info "Complexity guard: ok=$ok conflict=$conflict skip=$skip err=$err"
	setup_track_configured "Complexity guard (${ok} repos)"
	return 0
}
