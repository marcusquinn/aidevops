#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# git-hooks-path-lib.sh — shared resolver for the directory Git executes hooks from.
#
# When core.hooksPath is set (Beads sets it to .beads/hooks) Git runs hooks only
# from that directory. Installers that write to <git-common-dir>/hooks install
# hooks that never run. Source this file and use aidevops_git_hooks_dir instead.
#
# Functions:
#   aidevops_git_hooks_dir [repo_dir]     Absolute effective hooks dir on stdout.
#   aidevops_beads_section <hook_path>    Print a single complete trailing Beads
#                                         section; return 1 if ambiguous.
#   aidevops_inactive_hooks_report [dir]  Print aidevops hooks sitting in
#                                         <common-dir>/hooks that Git ignores
#                                         because core.hooksPath points elsewhere.

# Include guard
[[ -n "${_AIDEVOPS_GIT_HOOKS_PATH_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_GIT_HOOKS_PATH_LIB_LOADED=1

#######################################
# Resolve the effective hooks dir (absolute). Honours core.hooksPath; otherwise
# the common-dir hooks directory shared by all worktrees.
# Args: $1 = optional repo directory (default: current directory)
#######################################
aidevops_git_hooks_dir() {
	local repo_dir="${1:-.}"
	local hooks_dir="" repo_root=""
	# Git >= 2.31 resolves the path itself (correct from subdirectories too).
	if hooks_dir=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) &&
		[[ "$hooks_dir" == /* ]]; then
		printf '%s' "$hooks_dir"
		return 0
	fi
	# Older Git: relative results are anchored at the worktree top level.
	hooks_dir=$(git -C "$repo_dir" rev-parse --git-path hooks 2>/dev/null) || return 1
	if [[ "$hooks_dir" != /* ]]; then
		repo_root=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
		hooks_dir="${repo_root}/${hooks_dir}"
	fi
	printf '%s' "$hooks_dir"
	return 0
}

#######################################
# Extract only a single complete trailing Beads section. Fail closed if the
# markers are ambiguous or other code follows it.
#######################################
aidevops_beads_section() {
	local hook_path="$1"
	awk '
		/^# --- BEGIN BEADS INTEGRATION v[^ ]+ ---$/ {
			if (started++) invalid = 1
			version = $(NF - 1)
			active = 1
			print
			next
		}
		/^# --- END BEADS INTEGRATION( v[^ ]+)? ---$/ {
			if (!active || ended++) invalid = 1
			if (NF == 7 && $(NF - 1) != version) invalid = 1
			active = 0
			print
			next
		}
		/BEADS INTEGRATION/ { invalid = 1 }
		active { print; next }
		ended && /[^[:space:]]/ { invalid = 1 }
		END { if (invalid || active || started != ended) exit 1 }
	' "$hook_path"
	return $?
}

#######################################
# Report aidevops-managed hooks in <common-dir>/hooks that never run because
# core.hooksPath points at a different directory. Prints one path per line.
# Returns 0 always; empty output means nothing inactive.
#######################################
aidevops_inactive_hooks_report() {
	local repo_dir="${1:-.}"
	local configured="" effective="" common_dir="" legacy_dir="" hook_file=""
	configured=$(git -C "$repo_dir" config --get core.hooksPath 2>/dev/null || true)
	[[ -n "$configured" ]] || return 0
	effective=$(aidevops_git_hooks_dir "$repo_dir") || return 0
	common_dir=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
	legacy_dir="${common_dir}/hooks"
	[[ "$legacy_dir" != "$effective" && -d "$legacy_dir" ]] || return 0
	for hook_file in "$legacy_dir"/*; do
		[[ -f "$hook_file" ]] || continue
		if grep -qE '^# aidevops-|^# guard:|aidevops' "$hook_file" 2>/dev/null; then
			printf '%s\n' "$hook_file"
		fi
	done
	return 0
}
