#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(git rev-parse --show-toplevel)" || exit 1
_FULL_LOOP_RELEASE_PATH=""
source "${SCRIPT_DIR}/full-loop-helper-state.sh"

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
	local repo=""
	local receipt_path=""
	local release_status=""
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	if [[ -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || return 1
	fi
	case "$release_status" in
	"$_FULL_LOOP_RELEASE_PUBLISHED")
		printf 'release:published already recorded for PR #%s; skipping duplicate publication\n' "$source_pr"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		printf 'Cannot replace terminal release:not-requested evidence for PR #%s\n' "$source_pr" >&2
		return 1
		;;
	"" | "$_FULL_LOOP_PHASE_FAILED") ;;
	*)
		printf 'Cannot replace unknown release:%s evidence for PR #%s\n' "$release_status" "$source_pr" >&2
		return 1
		;;
	esac

	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-${source_pr}-$$"
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	git -C "$REPO_ROOT" worktree add --detach "$release_path" origin/main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT

	local version_manager="${AIDEVOPS_FULL_LOOP_VERSION_MANAGER:-$release_path/.agents/scripts/version-manager.sh}"
	[[ "$version_manager" = /* ]] || version_manager="$PWD/$version_manager"
	[[ -f "$version_manager" ]] || return 1
	if ! (
		trap - EXIT
		cd "$release_path" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
			AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
			bash "$version_manager" release "$release_type" --source-pr "$source_pr"
	); then
		return 1
	fi
	_full_loop_write_release_receipt "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED"
	return $?
}

main "$@"
