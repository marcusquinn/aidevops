#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Localdev Library — Localdev Integration Functions (GH#21324)
# =============================================================================
# Localdev integration functions extracted from worktree-helper.sh to reduce
# its line count below the 2000-line file-size gate.
#
# Covers: auto-create and auto-remove branch subdomain routes for projects
# registered with the localdev proxy (t1224.8).
#
# Usage: source "${SCRIPT_DIR}/worktree-localdev-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, colour vars: BLUE, YELLOW, NC)
#   - localdev-helper.sh (optional, detected at runtime)
#   - worktree-branch-lib.sh (get_repo_root — must be sourced before calling these fns)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_LOCALDEV_LIB_LOADED:-}" ]] && return 0
_WORKTREE_LOCALDEV_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Localdev Integration (t1224.8)
# =============================================================================
# When a worktree is created for a localdev-registered project, auto-create
# a branch subdomain route (e.g., feature-xyz.myapp.local) and output the URL.
# When a worktree is removed, auto-clean the corresponding branch route.

readonly LOCALDEV_PORTS_FILE="$HOME/.local-dev-proxy/ports.json"
readonly LOCALDEV_HELPER="${SCRIPT_DIR}/localdev-helper.sh"

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
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 1

	local repo_name
	repo_name="$(basename "$repo_root")"

	# Strip worktree suffix to get the base repo name
	# Worktree paths: ~/Git/{repo}-{branch-slug} → extract {repo}
	# Main repo paths: ~/Git/{repo} → use as-is
	local base_name="$repo_name"
	# If this is a worktree (has .git file, not directory), find the main repo name
	if [[ -f "$repo_root/.git" ]]; then
		local main_worktree
		main_worktree="$(git -C "$repo_root" worktree list --porcelain | head -1 | cut -d' ' -f2-)"
		if [[ -n "$main_worktree" ]]; then
			base_name="$(basename "$main_worktree")"
		fi
	fi

	# Check if this repo name is registered in ports.json
	if command -v jq >/dev/null 2>&1; then
		local match
		match="$(jq -r --arg n "$base_name" '.apps[$n] // empty | .domain // empty' "$LOCALDEV_PORTS_FILE" 2>/dev/null)"
		if [[ -n "$match" ]]; then
			echo "$base_name"
			return 0
		fi
	else
		# Fallback: grep-based check
		if grep -qF "\"$base_name\"" "$LOCALDEV_PORTS_FILE" 2>/dev/null; then
			echo "$base_name"
			return 0
		fi
	fi

	return 1
}

# Auto-create localdev branch route after worktree creation.
# Called from cmd_add after successful worktree creation.
# If the project is not registered, auto-registers it first (t1424.1).
localdev_auto_branch() {
	local branch="$1"
	local project

	# Check if localdev-helper.sh exists
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 0

	if ! project="$(detect_localdev_project)" || [[ -z "$project" ]]; then
		# Project not registered — try to auto-register (t1424.1)
		# Delegate name inference to localdev-helper.sh to avoid logic duplication
		local inferred_name=""
		inferred_name="$("$LOCALDEV_HELPER" infer-name "$(get_repo_root)" 2>/dev/null)" || true
		[[ -z "$inferred_name" ]] && return 0

		echo ""
		echo -e "${BLUE}Localdev integration: auto-registering project '$inferred_name'...${NC}"
		if "$LOCALDEV_HELPER" add "$inferred_name" 2>&1; then
			project="$inferred_name"
		else
			echo -e "${YELLOW}Localdev auto-registration failed (non-fatal)${NC}"
			return 0
		fi
	fi

	echo ""
	echo -e "${BLUE}Localdev integration: creating branch route for $project...${NC}"
	if "$LOCALDEV_HELPER" branch "$project" "$branch" 2>&1; then
		return 0
	else
		echo -e "${YELLOW}Localdev branch route creation failed (non-fatal)${NC}"
		return 0
	fi
}

# Auto-remove localdev branch route when worktree is removed.
# Called from cmd_remove after successful worktree removal.
localdev_auto_branch_rm() {
	local branch="$1"
	local project
	project="$(detect_localdev_project)" || return 0

	echo ""
	echo -e "${BLUE}Localdev integration: removing branch route for $project/$branch...${NC}"
	"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>&1 ||
		echo -e "${YELLOW}Localdev branch route removal failed (non-fatal)${NC}"
	return 0
}
