#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Repo Management Library
# =============================================================================
# Repository registration, discovery, and validation functions extracted from
# aidevops.sh to keep the orchestrator under the 2000-line file-size threshold.
#
# Covers:
#   1. init_repos_file / get_repo_slug / register_repo / get_registered_repos
#   2. Repo defaults, scope, mission-control resolution
#   3. Planning file checks, protected-branch validation
#
# Usage: source "${SCRIPT_DIR}/aidevops-repos-lib.sh"
#
# Dependencies:
#   - INSTALL_DIR, AGENTS_DIR, CONFIG_DIR, REPOS_FILE (set by aidevops.sh)
#   - print_* helpers and utility functions (defined in aidevops.sh before sourcing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_REPOS_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_REPOS_LIB_LOADED=1


# Initialize repos.json if it doesn't exist
init_repos_file() {
	if [[ ! -f "$REPOS_FILE" ]]; then
		mkdir -p "$CONFIG_DIR"
		echo '{"initialized_repos": [], "git_parent_dirs": ["~/Git"]}' >"$REPOS_FILE"
	elif command -v jq &>/dev/null; then
		# Migrate: add git_parent_dirs if missing from existing repos.json
		if ! jq -e '.git_parent_dirs' "$REPOS_FILE" &>/dev/null; then
			local temp_file="${REPOS_FILE}.tmp"
			if jq '. + {"git_parent_dirs": ["~/Git"]}' "$REPOS_FILE" >"$temp_file"; then
				mv "$temp_file" "$REPOS_FILE"
			else
				rm -f "$temp_file"
			fi
		fi
		# Migrate: backfill slug for entries missing it (detect from git remote)
		local needs_slug
		needs_slug=$(jq '[.initialized_repos[] | select(.slug == null or .slug == "")] | length' "$REPOS_FILE" 2>/dev/null) || needs_slug="0"
		if [[ "$needs_slug" -gt 0 ]]; then
			local temp_file="${REPOS_FILE}.tmp"
			local repo_path slug
			# Build a map of path->slug for repos missing slugs
			while IFS= read -r repo_path; do
				# Expand ~ to $HOME for git operations
				local expanded_path="${repo_path/#\~/$HOME}"
				slug=$(get_repo_slug "$expanded_path" 2>/dev/null) || slug=""
				if [[ -n "$slug" ]]; then
					jq --arg path "$repo_path" --arg slug "$slug" \
						'(.initialized_repos[] | select(.path == $path and (.slug == null or .slug == ""))) |= . + {slug: $slug}' \
						"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
				fi
			done < <(jq -r '.initialized_repos[] | select(.slug == null or .slug == "") | .path' "$REPOS_FILE" 2>/dev/null)
		fi
	fi
	return 0
}

# Detect GitHub slug (owner/repo) from git remote origin
# Usage: get_repo_slug <path>
get_repo_slug() {
	local repo_path="$1"
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	# Strip protocol/host prefix and .git suffix to get owner/repo
	local slug
	slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "$slug"
		return 0
	fi
	return 1
}

# Check whether a repo name follows mission-control naming.
# Usage: _is_mission_control_repo_name <repo-name>
_is_mission_control_repo_name() {
	local repo_name="$1"
	case "$repo_name" in
	mission-control | *-mission-control | mission-control-*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Resolve mission-control scope from slug and current actor.
# Usage: _resolve_mission_control_scope <owner/repo> <current-login>
# Prints: personal | org (or empty if not mission-control)
_resolve_mission_control_scope() {
	local slug="$1"
	local current_login="$2"

	if [[ -z "$slug" ]] || [[ "$slug" != */* ]]; then
		echo ""
		return 1
	fi

	local owner repo
	owner="${slug%%/*}"
	repo="${slug##*/}"

	if ! _is_mission_control_repo_name "$repo"; then
		echo ""
		return 1
	fi

	if [[ -n "$current_login" && "$owner" == "$current_login" ]]; then
		echo "personal"
		return 0
	fi

	echo "org"
	return 0
}

# Compute default repos.json registration values.
# Usage: _compute_repo_registration_defaults <path> <slug> <local_only> <maintainer>
# Prints eval-safe key=value lines: DEFAULT_PULSE, DEFAULT_PRIORITY
_compute_repo_registration_defaults() {
	local repo_path="$1"
	local slug="$2"
	local is_local_only="$3"
	local maintainer="$4"

	local default_pulse=false
	local default_priority=""

	if [[ "$is_local_only" == "true" ]]; then
		default_pulse=false
	else
		default_pulse=true
	fi

	if [[ "$slug" == */* ]]; then
		local owner repo
		owner="${slug%%/*}"
		repo="${slug##*/}"

		if [[ "$repo" == "$owner" ]] && [[ "$repo_path" == "$HOME/Git/$owner" ]]; then
			default_pulse=false
			default_priority="profile"
		elif _is_mission_control_repo_name "$repo"; then
			default_pulse=true
			if [[ "$owner" == "$maintainer" ]]; then
				default_priority="product"
			else
				default_priority="tooling"
			fi
		fi
	fi

	printf 'DEFAULT_PULSE=%q\n' "$default_pulse"
	printf 'DEFAULT_PRIORITY=%q\n' "$default_priority"
	return 0
}

# Infer the init_scope for a repo when not explicitly set.
# Priority: .aidevops.json > repos.json entry > context inference.
# Returns one of: minimal, standard, public
# Usage: _infer_init_scope <project_root> [is_local_only]
# Pass is_local_only="true" when the caller already has it to avoid redundant I/O.
_infer_init_scope() {
	local project_root="$1"
	local is_local_only="${2:-}"

	# 1. Check .aidevops.json
	if [[ -f "$project_root/.aidevops.json" ]]; then
		local json_scope
		json_scope=$(jq -r '.init_scope // empty' "$project_root/.aidevops.json" 2>/dev/null || echo "")
		if [[ -n "$json_scope" ]]; then
			echo "$json_scope"
			return 0
		fi
	fi

	# 2. Check repos.json entry — single jq pass reads both init_scope and local_only
	if command -v jq &>/dev/null && [[ -f "${REPOS_FILE:-$HOME/.config/aidevops/repos.json}" ]]; then
		local repos_file="${REPOS_FILE:-$HOME/.config/aidevops/repos.json}"
		local canonical_path
		canonical_path=$(cd "$project_root" 2>/dev/null && pwd -P) || canonical_path="$project_root"
		local repo_data
		repo_data=$(jq -r --arg path "$canonical_path" \
			'.initialized_repos[] | select(.path == $path) | "\(.init_scope // "")|\(.local_only // "false")"' \
			"$repos_file" 2>/dev/null | head -n 1 || echo "")
		if [[ -n "$repo_data" ]]; then
			local repo_scope="${repo_data%|*}"
			local repo_local="${repo_data#*|}"
			if [[ -n "$repo_scope" ]]; then
				echo "$repo_scope"
				return 0
			fi
			# Repo found but no explicit scope — pick up local_only for context inference below
			[[ -z "$is_local_only" ]] && is_local_only="$repo_local"
		fi
	fi

	# 3. Context inference
	# Use pre-computed is_local_only when available; fall back to git remote check
	if [[ "$is_local_only" == "true" ]]; then
		echo "minimal"
		return 0
	fi

	if ! git -C "$project_root" remote get-url origin &>/dev/null 2>&1; then
		echo "minimal"
		return 0
	fi

	# Default: standard (backward compatible)
	echo "standard"
	return 0
}

# Check whether a given scope level includes a feature tier.
# Scope hierarchy: minimal < standard < public
# Usage: _scope_includes <current_scope> <required_level>
# Returns 0 (true) if current_scope >= required_level, 1 (false) otherwise.
_scope_includes() {
	local current="$1"
	local required="$2"

	# Map scope to numeric level
	local current_level=0 required_level=0
	case "$current" in
		minimal)  current_level=0 ;;
		standard) current_level=1 ;;
		public)   current_level=2 ;;
		*)        current_level=1 ;; # unknown defaults to standard
	esac
	case "$required" in
		minimal)  required_level=0 ;;
		standard) required_level=1 ;;
		public)   required_level=2 ;;
		*)        required_level=1 ;;
	esac

	[[ $current_level -ge $required_level ]]
}

# Resolve a worktree path to its canonical main-worktree path, if applicable.
# Usage: resolve_canonical_repo_path <path>
# Prints the canonical path to stdout. If the input is already the main
# worktree, a non-git path, or git is unavailable, prints the input unchanged.
#
# Why this exists: `find ~/Git -name .aidevops.json` in auto-discovery and
# similar scans pick up .aidevops.json files that exist in linked worktrees
# (because worktrees inherit the working tree contents), and without this
# guard each worktree gets registered as a separate repo. That's what caused
# tabby-profile-sync to emit a profile for a worktree directory.
resolve_canonical_repo_path() {
	local input_path="$1"
	local common_dir
	common_dir=$(git -C "$input_path" rev-parse --git-common-dir 2>/dev/null) || {
		printf '%s\n' "$input_path"
		return 0
	}
	local own_git_dir
	own_git_dir=$(git -C "$input_path" rev-parse --git-dir 2>/dev/null) || {
		printf '%s\n' "$input_path"
		return 0
	}

	# Resolve both to absolute paths for a reliable comparison.
	# git -C <path> returns paths relative to <path> when they are relative.
	local common_abs own_abs
	if [[ "$common_dir" = /* ]]; then
		common_abs=$(cd "$common_dir" 2>/dev/null && pwd -P)
	else
		common_abs=$(cd "$input_path/$common_dir" 2>/dev/null && pwd -P)
	fi
	if [[ "$own_git_dir" = /* ]]; then
		own_abs=$(cd "$own_git_dir" 2>/dev/null && pwd -P)
	else
		own_abs=$(cd "$input_path/$own_git_dir" 2>/dev/null && pwd -P)
	fi

	if [[ -z "$common_abs" || -z "$own_abs" || "$common_abs" == "$own_abs" ]]; then
		# Main worktree or degraded resolution — pass through.
		printf '%s\n' "$input_path"
		return 0
	fi

	# Linked worktree — ask git for the main worktree's working tree path.
	local main_path
	main_path=$(git -C "$input_path" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
	if [[ -n "$main_path" && "$main_path" != "$input_path" && -d "$main_path" ]]; then
		printf '%s\n' "$main_path"
		return 0
	fi

	printf '%s\n' "$input_path"
	return 0
}

# Register a repo in repos.json
# Usage: register_repo <path> <version> <features>
register_repo() {
	local repo_path="$1"
	local version="$2"
	local features="$3"

	init_repos_file

	# Normalize path (resolve symlinks, remove trailing slash)
	if ! repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P); then
		print_warning "Cannot access path: $repo_path"
		return 1
	fi

	# Resolve linked worktrees to their canonical main-worktree path.
	# Every registration path (cmd_init, auto-discovery, scan) runs through
	# register_repo, so the guard here catches all of them — not just the
	# cmd_init path that previously checked only when WORKTREE_PATH was set.
	local canonical_path
	canonical_path=$(resolve_canonical_repo_path "$repo_path")
	if [[ -n "$canonical_path" && "$canonical_path" != "$repo_path" ]]; then
		print_info "Resolved worktree to canonical repo: $repo_path → $canonical_path"
		if ! repo_path=$(cd "$canonical_path" 2>/dev/null && pwd -P); then
			print_warning "Cannot access canonical path: $canonical_path"
			return 1
		fi
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed - repo tracking disabled"
		return 0
	fi

	# Auto-detect GitHub slug from git remote
	local slug=""
	local is_local_only="false"
	if ! slug=$(get_repo_slug "$repo_path" 2>/dev/null); then
		slug=""
		# No remote origin — mark as local_only
		if ! git -C "$repo_path" remote get-url origin &>/dev/null; then
			is_local_only="true"
		fi
	fi

	# Auto-detect maintainer from gh API (current authenticated user)
	# Only runs once per registration — preserved on subsequent updates
	local maintainer=""
	if command -v gh &>/dev/null; then
		maintainer=$(gh api user --jq '.login' 2>/dev/null) || maintainer=""
	fi

	local DEFAULT_PULSE="false"
	local DEFAULT_PRIORITY=""
	eval "$(_compute_repo_registration_defaults "$repo_path" "$slug" "$is_local_only" "$maintainer")"

	# Infer default init_scope; pass is_local_only (already computed) to skip redundant I/O
	local default_init_scope
	default_init_scope=$(_infer_init_scope "$repo_path" "$is_local_only")

	# Check if repo already registered
	if jq -e --arg path "$repo_path" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
		# Update existing entry, preserving pulse/priority/local_only/maintainer/init_scope if already set
		local temp_file="${REPOS_FILE}.tmp"
		jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
			--arg slug "$slug" --argjson local_only "$is_local_only" --arg maintainer "$maintainer" \
			--argjson pulse_default "$DEFAULT_PULSE" --arg priority_default "$DEFAULT_PRIORITY" \
			--arg init_scope_default "$default_init_scope" \
			'(.initialized_repos[] | select(.path == $path)) |= (
				. + {path: $path, version: $version, features: ($features | split(",")), updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
				| if $slug != "" then .slug = $slug else . end
				| if $local_only then .local_only = true else . end
				| if .pulse == null then .pulse = (if $local_only then false else $pulse_default end) else . end
				| if (.priority == null or .priority == "") and $priority_default != "" then .priority = $priority_default else . end
				| if (.maintainer == null or .maintainer == "") and $maintainer != "" then .maintainer = $maintainer else . end
				| if (.init_scope == null or .init_scope == "") then .init_scope = $init_scope_default else . end
			)' \
			"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	else
		# Add new entry with slug, defaults, maintainer, and init_scope
		local temp_file="${REPOS_FILE}.tmp"
		jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
			--arg slug "$slug" --arg maintainer "$maintainer" \
			--argjson local_only "$is_local_only" --argjson pulse_default "$DEFAULT_PULSE" \
			--arg priority_default "$DEFAULT_PRIORITY" --arg init_scope "$default_init_scope" \
			'.initialized_repos += [(
				{
					path: $path,
					maintainer: $maintainer,
					version: $version,
					features: ($features | split(",")),
					pulse: $pulse_default,
					init_scope: $init_scope,
					initialized: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
				}
				| if $slug != "" then . + {slug: $slug} else . end
				| if $local_only then . + {local_only: true, pulse: false} else . end
				| if $priority_default != "" then . + {priority: $priority_default} else . end
			)]' \
			"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	fi
	return 0
}

# Get list of registered repos
get_registered_repos() {
	init_repos_file

	if ! command -v jq &>/dev/null; then
		echo "[]"
		return 0
	fi

	jq -r '.initialized_repos[] | .path' "$REPOS_FILE" 2>/dev/null || echo ""
	return 0
}

# Get the maintainer GitHub username for a repo
# Fallback chain: maintainer field > slug owner > empty string
# Usage: get_repo_maintainer <slug>
get_repo_maintainer() {
	local slug="$1"

	if ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$REPOS_FILE" 2>/dev/null) || maintainer=""

	if [[ -n "$maintainer" ]]; then
		echo "$maintainer"
		return 0
	fi

	# Fallback: extract owner from slug (owner/repo -> owner)
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "${slug%%/*}"
		return 0
	fi

	echo ""
	return 0
}

# Check if a repo needs upgrade (version behind current)
check_repo_needs_upgrade() {
	local repo_path="$1"
	local current_version
	current_version=$(get_version)

	if ! command -v jq &>/dev/null; then
		return 1
	fi

	local repo_version
	repo_version=$(jq -r --arg path "$repo_path" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE" 2>/dev/null)

	if [[ -z "$repo_version" || "$repo_version" == "null" ]]; then
		return 1
	fi

	# Compare versions (simple string comparison works for semver)
	if [[ "$repo_version" != "$current_version" ]]; then
		return 0 # needs upgrade
	fi
	return 1 # up to date
}

# Check if a planning file needs upgrading (version mismatch or missing TOON markers)
# Usage: check_planning_file_version <file> <template>
# Returns 0 if upgrade needed, 1 if up to date
check_planning_file_version() {
	local file="$1" template="$2"
	if [[ -f "$file" ]]; then
		if ! grep -q "TOON:meta" "$file" 2>/dev/null; then
			return 0
		fi
		local current_ver template_ver
		current_ver=$(grep -A1 "TOON:meta" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
		template_ver=$(grep -A1 "TOON:meta" "$template" 2>/dev/null | tail -1 | cut -d',' -f1)
		if [[ -n "$template_ver" ]] && [[ "$current_ver" != "$template_ver" ]]; then
			return 0
		fi
		return 1
	else
		# No file = no upgrade needed (init would create it)
		return 1
	fi
}

# Check if a repo's planning templates need upgrading
# Returns 0 if any planning file needs upgrade
check_planning_needs_upgrade() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local plans_file="$repo_path/todo/PLANS.md"
	local todo_template="$AGENTS_DIR/templates/todo-template.md"
	local plans_template="$AGENTS_DIR/templates/plans-template.md"

	[[ ! -f "$todo_template" ]] && return 1

	if check_planning_file_version "$todo_file" "$todo_template"; then
		return 0
	fi
	if [[ -f "$plans_template" ]] && check_planning_file_version "$plans_file" "$plans_template"; then
		return 0
	fi
	return 1
}

# Detect if current directory has aidevops but isn't registered
detect_unregistered_repo() {
	local project_root

	# Check if in a git repo
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		return 1
	fi

	project_root=$(git rev-parse --show-toplevel 2>/dev/null)

	# Check for .aidevops.json
	if [[ ! -f "$project_root/.aidevops.json" ]]; then
		return 1
	fi

	init_repos_file

	if ! command -v jq &>/dev/null; then
		return 1
	fi

	# Check if already registered
	if jq -e --arg path "$project_root" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
		return 1 # already registered
	fi

	# Not registered - return the path
	echo "$project_root"
	return 0
}

# Check if on protected branch and offer worktree creation
# Returns 0 if safe to proceed, 1 if user cancelled
# Sets WORKTREE_PATH if worktree was created
check_protected_branch() {
	local branch_type="${1:-chore}"
	local branch_suffix="${2:-aidevops-setup}"

	# Not in a git repo - skip check
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		return 0
	fi

	local current_branch
	current_branch=$(git branch --show-current 2>/dev/null || echo "")

	# Not on a protected branch - safe to proceed
	if [[ ! "$current_branch" =~ ^(main|master)$ ]]; then
		return 0
	fi

	local project_root
	project_root=$(git rev-parse --show-toplevel)
	local repo_name
	repo_name=$(basename "$project_root")
	local suggested_branch="$branch_type/$branch_suffix"

	local choice
	# In non-interactive (non-TTY) contexts, auto-select option 1 (create worktree)
	# without prompting. This prevents read from blocking or getting EOF in CI/AI
	# assistant environments, which could cause silent script termination with set -e.
	if [[ -t 0 ]]; then
		echo ""
		print_warning "On protected branch '$current_branch'"
		echo ""
		echo "Options:"
		echo "  1. Create worktree: $suggested_branch (recommended)"
		echo "  2. Continue on $current_branch (commits directly to main)"
		echo "  3. Cancel"
		echo ""
		read -r -p "Choice [1]: " choice
		choice="${choice:-1}"
	else
		# Non-interactive: auto-create worktree (safest default)
		choice="1"
		print_info "Non-interactive mode: auto-selecting worktree creation for '$suggested_branch'"
	fi

	case "$choice" in
	1)
		# Create worktree
		local worktree_dir
		worktree_dir="$(dirname "$project_root")/${repo_name}-${branch_type}-${branch_suffix}"

		print_info "Creating worktree at $worktree_dir..."

		local worktree_created=false
		if [[ -f "$AGENTS_DIR/scripts/worktree-helper.sh" ]]; then
			if bash "$AGENTS_DIR/scripts/worktree-helper.sh" add "$suggested_branch"; then
				worktree_created=true
			else
				print_error "Failed to create worktree via worktree-helper.sh"
				return 1
			fi
		else
			# Fallback without helper script
			if git worktree add -b "$suggested_branch" "$worktree_dir"; then
				worktree_created=true
			else
				print_error "Failed to create worktree"
				return 1
			fi
		fi

		if [[ "$worktree_created" == "true" ]]; then
			export WORKTREE_PATH="$worktree_dir"
			echo ""
			print_success "Worktree created at: $worktree_dir"
			print_info "Switching to: $worktree_dir"
			echo ""
			# Change to worktree directory for the remainder of this process
			cd "$worktree_dir" || return 1
			return 0
		fi
		;;
	2)
		print_warning "Continuing on $current_branch - changes will commit directly"
		return 0
		;;
	3 | *)
		print_info "Cancelled"
		return 1
		;;
	esac
}

