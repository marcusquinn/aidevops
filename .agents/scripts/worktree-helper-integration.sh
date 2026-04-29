#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# =============================================================================
# Worktree Helper -- Localdev + Preview Proxy Integration Sub-Library
# =============================================================================
# Localdev integration (t1224.8): when a worktree is created for a
# localdev-registered project, auto-create a branch subdomain route
# (e.g., feature-xyz.myapp.local) and output the URL. On removal,
# auto-clean the corresponding route.
#
# Preview Proxy integration (GH#21560): per-worktree preview subdomains
# via local proxy. On worktree add, allocate a port + register a proxy
# route. On remove, free the port + deregister. Both best-effort, non-fatal.
#
# Usage: source "${SCRIPT_DIR}/worktree-helper-integration.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, colour vars)
#   - localdev-helper.sh (optional, detected at runtime)
#   - preview-proxy-helper.sh (optional, detected at runtime)
#   - LOCALDEV_PORTS_FILE, LOCALDEV_HELPER, PREVIEW_PROXY_HELPER must be set
#     by the orchestrator before sourcing this file.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_INTEGRATION_LIB_LOADED:-}" ]] && return 0
_WORKTREE_INTEGRATION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Localdev Integration (t1224.8) ---

# Detect if the current repo is registered as a localdev project.
# Matches repo directory name against registered app names in ports.json.
# Outputs the app name if found, empty string otherwise.
detect_localdev_project() {
	local repo_root="${1:-}"
	[[ -z "$repo_root" ]] && repo_root="$(get_repo_root)"
	[[ -z "$repo_root" ]] && return 1

	# ports.json must exist
	[[ ! -f "$LOCALDEV_PORTS_FILE" ]] && return 1

	# localdev-helper.sh must exist
	[[ ! -f "$LOCALDEV_HELPER" ]] && return 1

	local repo_name
	repo_name=$(basename "$repo_root")

	# Check if repo name matches any registered app
	local app_name
	app_name=$(jq -r --arg name "$repo_name" '.apps | to_entries[] | select(.value.path // .key | endswith($name)) | .key' \
		"$LOCALDEV_PORTS_FILE" 2>/dev/null | head -1)

	if [[ -n "$app_name" ]]; then
		echo "$app_name"
		return 0
	fi

	# Also check direct key match
	app_name=$(jq -r --arg name "$repo_name" 'if has($name) then $name else "" end' \
		"$LOCALDEV_PORTS_FILE" 2>/dev/null)

	if [[ -n "$app_name" ]]; then
		echo "$app_name"
		return 0
	fi

	return 1
}

# Auto-create a branch subdomain route for a new worktree.
# Called after git worktree add. Best-effort: never fails cmd_add.
# Args: $1=branch name
localdev_auto_branch() {
	local branch="$1"

	# Only run if localdev helper is available
	[[ ! -f "$LOCALDEV_HELPER" ]] && return 0

	local repo_root
	repo_root=$(get_repo_root) || return 0
	[[ -z "$repo_root" ]] && return 0

	local app_name
	app_name=$(detect_localdev_project "$repo_root") || return 0
	[[ -z "$app_name" ]] && return 0

	echo -e "${BLUE}Localdev: creating branch route for '$branch'...${NC}"
	"$LOCALDEV_HELPER" branch "$app_name" "$branch" >/dev/null 2>&1 || true
	return 0
}

# Auto-remove a branch subdomain route when a worktree is removed.
# Called during cmd_remove after git worktree remove. Best-effort.
# Args: $1=branch name
localdev_auto_branch_rm() {
	local branch="$1"

	# Only run if localdev helper is available
	[[ ! -f "$LOCALDEV_HELPER" ]] && return 0

	local repo_root
	repo_root=$(get_repo_root) || return 0
	[[ -z "$repo_root" ]] && return 0

	local app_name
	app_name=$(detect_localdev_project "$repo_root") || return 0
	[[ -z "$app_name" ]] && return 0

	"$LOCALDEV_HELPER" branch-rm "$app_name" "$branch" >/dev/null 2>&1 || true
	return 0
}

# --- Preview Proxy Integration (GH#21560) ---

# Allocate a preview port + register a proxy route for a new worktree.
# Called after git worktree add. Best-effort: never fails cmd_add.
# Args: $1=branch name
preview_proxy_auto_allocate() {
	local branch="$1"

	# Only run if preview proxy helper is available
	[[ ! -x "$PREVIEW_PROXY_HELPER" ]] && return 0

	"$PREVIEW_PROXY_HELPER" allocate "$branch" >/dev/null 2>&1 || true
	return 0
}

# Free preview port + deregister proxy route when a worktree is removed.
# Called during cmd_remove. Best-effort.
# Args: $1=branch name
preview_proxy_auto_free() {
	local branch="$1"

	# Only run if preview proxy helper is available
	[[ ! -x "$PREVIEW_PROXY_HELPER" ]] && return 0

	"$PREVIEW_PROXY_HELPER" free "$branch" >/dev/null 2>&1 || true
	return 0
}
