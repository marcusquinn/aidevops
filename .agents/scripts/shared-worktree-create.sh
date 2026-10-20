#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Native creation and initial ownership/lifetime registration for every producer.

# Arguments: repository, new path, commit-ish, then native Git add options.
# Caller-specific base selection, locks and cleanup remain with the caller.
# A registration failure preserves the tree and returns failure, never success
# with missing metadata or an unsafe compensating forced removal.
worktree_create_registered() {
	local repo="$1"
	local path="$2"
	local ref="$3"
	shift 3
	local branch=""
	local registry_helper="${BASH_SOURCE[0]%/*}/shared-worktree-registry.sh"
	[[ ! -e "$path" && ! -L "$path" ]] || return 1
	# shellcheck source=shared-worktree-registry.sh
	source "$registry_helper" || return 1
	git -C "$repo" worktree add "$@" -- "$path" "$ref" || return 1
	branch=$(git -C "$path" symbolic-ref --quiet --short HEAD) || branch="HEAD"
	if ! AIDEVOPS_WORKTREE_CREATING=1 register_worktree "$path" "$branch" \
		--task "${AIDEVOPS_WORKTREE_CREATE_TASK:-}" \
		--owner-pid "${AIDEVOPS_WORKTREE_CREATE_OWNER_PID:-}" \
		--session "${AIDEVOPS_WORKTREE_CREATE_SESSION:-}"; then
		printf 'Worktree retained: creation metadata registration failed: %s\n' "$path" >&2
		return 1
	fi
	return 0
}
