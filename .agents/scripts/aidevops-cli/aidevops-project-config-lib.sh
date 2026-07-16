#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ -n "${_AIDEVOPS_PROJECT_CONFIG_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_PROJECT_CONFIG_LIB_LOADED=1

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

_project_config_write_migration_plan() {
	local repo="$1"
	local plan_dir plan_file repo_key temp_file
	plan_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/work}"
	repo_key=$(printf '%s' "$repo" | cksum | cut -d' ' -f1)
	plan_file="${plan_dir}/project-config-migration-${repo_key}.json"
	mkdir -p "$plan_dir" || return 1
	temp_file=$(mktemp "${plan_file}.XXXXXX") || return 1
	if ! jq -n --arg repo "$repo" '{
		repo:$repo,
		files:[".aidevops.json",".gitignore"],
		worker_brief:"In an isolated linked worktree, ensure .aidevops.json is ignored, run git rm --cached -- .aidevops.json, verify the working-tree file is byte-identical, commit the index-only migration, and open a PR. Never delete the local file."
	}' >"$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	chmod 600 "$temp_file"
	mv "$temp_file" "$plan_file"
	print_warning "Tracked .aidevops.json requires a linked-worktree PR; repair plan: $plan_file"
	return 0
}

_project_config_migrate_linked_worktree() {
	local repo="$1"
	_project_config_is_tracked "$repo" || return 0
	_project_config_is_linked_worktree "$repo" || return 1
	git -C "$repo" rm --cached -- .aidevops.json >/dev/null || return 1
	print_info "Staged .aidevops.json index migration in the linked worktree; local file preserved"
	return 0
}
