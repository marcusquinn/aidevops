#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(git rev-parse --show-toplevel)" || exit 1
_FULL_LOOP_RELEASE_PATH=""

cleanup_release_worktree() {
	local release_path="${_FULL_LOOP_RELEASE_PATH:-}"
	if [[ -n "$release_path" && -d "$release_path" ]]; then
		git -C "$REPO_ROOT" worktree remove "$release_path" >/dev/null 2>&1 || true
	fi
	return 0
}

main() {
	local release_type="${1:-patch}"
	local source_pr="${2:-}"
	local deployment_scope="${3:-incremental}"
	case "$release_type" in patch | minor | major) ;; *) return 1 ;; esac
	case "$deployment_scope" in incremental | full) ;; *) return 1 ;; esac
	[[ "$source_pr" =~ ^[0-9]+$ ]] || return 1

	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-${source_pr}-$$"
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	git -C "$REPO_ROOT" worktree add --detach "$release_path" origin/main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT

	local version_manager="${AIDEVOPS_FULL_LOOP_VERSION_MANAGER:-$release_path/.agents/scripts/version-manager.sh}"
	[[ -f "$version_manager" ]] || return 1
	AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
		AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
		AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
		bash "$version_manager" release "$release_type" --source-pr "$source_pr"
	return $?
}

main "$@"
