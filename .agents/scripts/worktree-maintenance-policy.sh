#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only adapter to the shared Pulse forensic/task retention policy.
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=pulse-cleanup-worktree-state.sh
source "${SCRIPT_DIR}/pulse-cleanup-worktree-state.sh"

maintenance_policy() {
	local wt_path="$1"
	local branch="$2"
	local repo="$3"
	local archive_blocked="${4:-false}"
	local issue="" branch_pr="" prs="" numbers="" number="" state=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	_pc_unattributed_archive_policy_clear "$wt_path" || return 1
	issue=$(_pc_issue_from_branch "$branch") || issue=""
	# Enrichment branches encode an issue but predate the generic gh-N naming.
	if [[ "$branch" =~ ^feature/enrichment-([1-9][0-9]*)- ]]; then
		issue="${BASH_REMATCH[1]}"
	fi
	if [[ -n "$issue" ]]; then
		_pc_compact_archive_policy_clear "$wt_path" "$issue" "$repo" issue "" "$archive_blocked" || return 1
	fi
	# Closed PRs can retain incident labels too; an open-only lookup is insufficient.
	prs=$(gh pr list --repo "$repo" --head "$branch" --state all --limit 100 --json number,state) || return 1
	jq -e 'type == "array" and length < 100 and all(.[];
		(.number | type == "number" and . > 0 and floor == .) and
		(.state == "OPEN" or .state == "CLOSED" or .state == "MERGED"))' <<<"$prs" >/dev/null || return 1
	if jq -e 'any(.[]; .state == "OPEN")' <<<"$prs" >/dev/null; then
		printf '%s\n' "open-pr"
		return 1
	fi
	numbers=$(jq -r '.[].number' <<<"$prs") || return 1
	while IFS= read -r number; do
		[[ -n "$number" ]] || continue
		_pc_compact_archive_policy_clear "$wt_path" "$number" "$repo" pr "" "$archive_blocked" || return 1
	done <<<"$numbers"
	# Repair branches can refer to a PR whose head has a different branch name.
	branch_pr=$(_pc_pr_from_branch "$branch") || branch_pr=""
	if [[ -n "$branch_pr" ]]; then
		state=$(gh pr view "$branch_pr" --repo "$repo" --json state --jq '.state') || return 1
		[[ "$state" == "CLOSED" || "$state" == "MERGED" ]] || return 1
		_pc_compact_archive_policy_clear "$wt_path" "$branch_pr" "$repo" pr "" "$archive_blocked" || return 1
	fi
	return 0
}

maintenance_main() {
	local wt_path="${1:-}"
	local branch="${2:-}"
	local repo="${3:-}"
	local option="${4:-}"
	if [[ "$#" -eq 4 && "$option" == --archive-blocked ]]; then
		maintenance_policy "$wt_path" "$branch" "$repo" true || return 1
	else
		[[ "$#" -eq 3 ]] || return 1
		maintenance_policy "$wt_path" "$branch" "$repo" || return 1
	fi
	return 0
}

maintenance_main "$@"
