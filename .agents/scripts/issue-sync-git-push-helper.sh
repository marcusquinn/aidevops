#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Conflict-safe git push helper for Issue Sync workflow TODO.md updates.

set -euo pipefail

issue_sync_git_path() {
	local rel_path="$1"
	git rev-parse --git-path "$rel_path"
	return 0
}

issue_sync_rebase_in_progress() {
	local rebase_merge
	local rebase_apply
	rebase_merge=$(issue_sync_git_path "rebase-merge")
	rebase_apply=$(issue_sync_git_path "rebase-apply")
	[[ -d "$rebase_merge" || -d "$rebase_apply" ]]
	return $?
}

issue_sync_abort_rebase_if_needed() {
	if issue_sync_rebase_in_progress; then
		echo "::warning::Aborting leftover rebase before retrying TODO.md push"
		git rebase --abort >/dev/null 2>&1 || true
	fi
	return 0
}

issue_sync_reset_to_origin_branch() {
	local branch="$1"
	git reset --hard "origin/${branch}"
	return 0
}

issue_sync_neutralize_rebase_conflict() {
	local branch="$1"
	local attempt="$2"
	echo "::warning::TODO.md rebase conflict on push attempt ${attempt}; aborting rebase and resetting to origin/${branch}. A later issue-sync run will re-pull missing refs."
	git rebase --abort >/dev/null 2>&1 || true
	issue_sync_reset_to_origin_branch "$branch"
	return 0
}

issue_sync_push_todo_with_rebase_retry() {
	local branch="$1"
	local attempts="$2"
	local attempt

	for attempt in $(seq 1 "$attempts"); do
		echo "Push attempt ${attempt}..."
		issue_sync_abort_rebase_if_needed
		git fetch origin "$branch" --quiet

		if ! git rebase "origin/${branch}"; then
			issue_sync_neutralize_rebase_conflict "$branch" "$attempt"
			return 0
		fi

		if git push origin "HEAD:${branch}"; then
			echo "Push succeeded on attempt ${attempt}"
			return 0
		fi

		echo "Push failed on attempt ${attempt}; retrying from a clean rebase state"
		issue_sync_abort_rebase_if_needed
		sleep $((attempt * 3))
	done

	echo "::error::Failed to push TODO.md update after ${attempts} attempts"
	return 1
}

issue_sync_git_push_usage() {
	cat <<'EOF'
Usage: issue-sync-git-push-helper.sh push-todo [branch] [attempts]

Pushes the current TODO.md sync commit after rebasing onto origin/<branch>.
On rebase conflict, aborts the rebase, resets to origin/<branch>, and exits 0
to prevent repeated failed workflow notifications from an unresolved index.
EOF
	return 0
}

main() {
	local command="${1:-}"
	local branch="${2:-main}"
	local attempts="${3:-3}"

	case "$command" in
		push-todo)
			issue_sync_push_todo_with_rebase_retry "$branch" "$attempts"
			return $?
			;;
		-h|--help|help|"")
			issue_sync_git_push_usage
			return 0
			;;
		*)
			echo "Unknown command: $command" >&2
			issue_sync_git_push_usage >&2
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
