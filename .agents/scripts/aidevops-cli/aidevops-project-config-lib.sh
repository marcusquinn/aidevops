#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ -n "${_AIDEVOPS_PROJECT_CONFIG_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_PROJECT_CONFIG_LIB_LOADED=1

_project_config_read_version() {
	local config_file="$1"
	jq -er '.version | select(type == "string" and length > 0)' "$config_file" 2>/dev/null
	return $?
}

_project_config_write_version() {
	local config_file="$1"
	local version="$2"
	local temp_file=""
	[[ -f "$config_file" && -n "$version" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || return 1
	if ! cp -p "$config_file" "$temp_file" ||
		! jq --arg version "$version" 'if type == "object" then .version = $version else error("project config must be an object") end' "$config_file" >"$temp_file" 2>/dev/null ||
		[[ ! -s "$temp_file" ]]; then
		rm -f "$temp_file"
		return 1
	fi
	if ! mv "$temp_file" "$config_file"; then
		rm -f "$temp_file"
		return 1
	fi
	return 0
}

_project_config_is_tracked() {
	local repo="$1"
	git -C "$repo" ls-files --error-unmatch -- .aidevops.json >/dev/null 2>&1
	return $?
}

_project_config_is_linked_worktree() {
	local repo="$1"
	local git_dir common_dir
	git_dir=$(git -C "$repo" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	common_dir=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$git_dir" != "$common_dir" ]]
	return $?
}

_PROJECT_CONFIG_MIGRATION_MARKER="<!-- aidevops:project-config-migration -->"
_PROJECT_CONFIG_MIGRATION_MAX_REPOS="${AIDEVOPS_PROJECT_CONFIG_MIGRATION_MAX_REPOS:-3}"

_project_config_repo_slug() {
	local repo="$1"
	local remote="" slug=""
	remote=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
	case "$remote" in
	git@github.com:*) slug="${remote#git@github.com:}" ;;
	ssh://git@github.com/*) slug="${remote#ssh://git@github.com/}" ;;
	https://github.com/*) slug="${remote#https://github.com/}" ;;
	*) return 1 ;;
	esac
	slug="${slug%.git}"
	[[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
	printf '%s' "$slug"
	return 0
}

_project_config_can_file_migration() {
	local repo_slug="$1"
	local helper_dir="${BASH_SOURCE[0]%/*}"
	[[ "$helper_dir" == "${BASH_SOURCE[0]}" ]] && helper_dir="."
	# #aidevops:trust-boundary — public issue creation requires the same
	# authenticated collaborator permission proof as managed issue-state writes.
	# shellcheck source=../shared-gh-wrappers.sh
	source "${helper_dir}/../shared-gh-wrappers.sh" || return 1
	_gh_current_user_allows_repo_write "$repo_slug"
	return $?
}

_project_config_migration_exists() {
	local repo_slug="$1"
	local marker="$_PROJECT_CONFIG_MIGRATION_MARKER"
	local existing=""
	existing=$(gh issue list --repo "$repo_slug" --state open --search "${marker} in:body" \
		--limit 1 --json number --jq '.[0].number // empty' 2>/dev/null) || return 1
	if [[ -n "$existing" ]]; then
		return 0
	fi
	existing=$(gh pr list --repo "$repo_slug" --state open --search "${marker} in:body" \
		--limit 1 --json number --jq '.[0].number // empty' 2>/dev/null) || return 1
	[[ -n "$existing" ]]
	return $?
}

_project_config_write_migration_issue() {
	local repo_slug="$1"
	local body_file="$2"
	local helper_dir="${BASH_SOURCE[0]%/*}"
	[[ "$helper_dir" == "${BASH_SOURCE[0]}" ]] && helper_dir="."
	"${helper_dir}/../gh-write-helper.sh" issue create --repo "$repo_slug" \
		--title "chore: stop tracking local .aidevops.json" --body-file "$body_file" \
		--label "auto-dispatch" --label "tier:simple" >/dev/null
	return $?
}

_project_config_queue_migration() {
	local repo="$1"
	local repo_slug="" body_file="" queue_limit="$_PROJECT_CONFIG_MIGRATION_MAX_REPOS"
	[[ "$queue_limit" =~ ^[1-9][0-9]*$ ]] || queue_limit=3
	repo_slug=$(_project_config_repo_slug "$repo") || {
		print_warning "Tracked .aidevops.json needs a linked-worktree migration; no GitHub origin is available"
		return 0
	}
	_project_config_can_file_migration "$repo_slug" || {
		print_warning "Tracked .aidevops.json needs a linked-worktree migration; GitHub write access is unavailable"
		return 0
	}
	if _project_config_migration_exists "$repo_slug"; then
		print_info "Tracked .aidevops.json migration is already queued for this repository"
		return 0
	fi
	[[ "${_PROJECT_CONFIG_MIGRATIONS_QUEUED:-0}" -lt "$queue_limit" ]] || {
		print_info "Tracked .aidevops.json migration queue limit reached for this update"
		return 0
	}
	body_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-project-config-migration.XXXXXX") || return 1
	trap 'rm -f "${body_file:-}"' RETURN
	printf '%s\n' "$_PROJECT_CONFIG_MIGRATION_MARKER" "## Goal" "" \
		"Stop tracking \`.aidevops.json\` while preserving its local bytes." "" \
		"## Files Scope" "" "- \`.aidevops.json\`" "- \`.gitignore\`" "" \
		"## Implementation" "" \
		"In a fresh linked worktree, add \`.aidevops.json\` to \`.gitignore\`, run \`git rm --cached -- .aidevops.json\`, and commit the index-only migration. Never delete the local file or edit a canonical checkout." "" \
		"## Verification" "" \
		"- Confirm \`.aidevops.json\` remains byte-identical in the worktree." \
		"- Confirm \`git ls-files -- .aidevops.json\` is empty and \`.gitignore\` contains the entry." >"$body_file"
	if _project_config_write_migration_issue "$repo_slug" "$body_file"; then
		_PROJECT_CONFIG_MIGRATIONS_QUEUED=$((_PROJECT_CONFIG_MIGRATIONS_QUEUED + 1))
		print_info "Queued tracked .aidevops.json migration for this repository"
	else
		print_warning "Tracked .aidevops.json needs a linked-worktree migration; queueing failed"
	fi
	return 0
}

_project_config_write_migration_plan() {
	local repo="$1"
	_project_config_queue_migration "$repo"
	return $?
}

_project_config_migrate_linked_worktree() {
	local repo="$1"
	_project_config_is_tracked "$repo" || return 0
	_project_config_is_linked_worktree "$repo" || return 1
	git -C "$repo" rm --cached -- .aidevops.json >/dev/null || return 1
	print_info "Staged .aidevops.json index migration in the linked worktree; local file preserved"
	return 0
}
