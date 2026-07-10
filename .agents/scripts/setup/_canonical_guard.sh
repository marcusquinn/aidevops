#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Setup module: install canonical-on-main-guard post-checkout hook in every
# initialized repo. Mirrors _privacy_guard.sh from t1968.
#
# Sourced by setup.sh — do not execute directly.
#
# Idempotent: re-installs managed hooks, skips unmanaged ones with a warning,
# counts each outcome, and fails setup when protection is inactive.

#######################################
# Resolve the path of install-canonical-guard.sh relative to this module.
#######################################
_load_canonical_guard_installer() {
	local installer_path
	installer_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../install-canonical-guard.sh"
	if [[ ! -f "$installer_path" ]]; then
		print_warning "install-canonical-guard.sh not found at: $installer_path"
		return 1
	fi
	printf '%s' "$installer_path"
	return 0
}

#######################################
# Install the canonical-on-main guard in every initialized repo with a
# local .git present. Prints a per-run summary.
#######################################
setup_canonical_guard() {
	print_info "Installing canonical-on-main guard hook across initialized repos..."

	local installer_path
	if ! installer_path=$(_load_canonical_guard_installer); then
		return 1
	fi

	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_config" ]]; then
		print_warning "repos.json not found — skipping canonical guard rollout"
		return 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not installed — skipping canonical guard rollout"
		return 1
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
		if ! result=$(cd "$path" && bash "$installer_path" install 2>&1 </dev/null); then
			if [[ "$result" == *"Refusing to overwrite"* || "$result" == *"NOT managed"* ]]; then
				conflict=$((conflict + 1))
			else
				err=$((err + 1))
			fi
			continue
		fi
		if [[ "$result" == *"installed canonical-on-main-guard"* ]]; then
			ok=$((ok + 1))
		elif [[ "$result" == *"already installed"* ]]; then
			already=$((already + 1))
		elif [[ "$result" == *"Refusing to overwrite"* || "$result" == *"NOT managed"* ]]; then
			conflict=$((conflict + 1))
		else
			err=$((err + 1))
		fi
	done < <(jq -r '.initialized_repos[]? | select(.path != null) | .path' "$repos_config")

	print_info "Canonical guard: ok=$ok already=$already conflict=$conflict skip=$skip err=$err"
	local total_covered=$((ok + already))
	if [[ "$err" -gt 0 ]]; then
		print_error "Canonical guard installation incomplete; refusing successful setup"
		return 1
	fi
	if [[ "$conflict" -gt 0 ]]; then
		print_warning "Canonical detector hook conflicts remain, but preventive runtime/PATH guards are active"
	fi
	setup_track_configured "Canonical guard (${total_covered} repos)"
	return 0
}
