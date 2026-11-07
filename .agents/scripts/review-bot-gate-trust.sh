#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Review Bot Gate -- Trusted Account TODO Evidence
# =============================================================================
# Live-evidence checks for trusted account issue-sync and pulse TODO handoff PRs.
# Functions moved verbatim from review-bot-gate-helper.sh (GH#37011).
#
# Usage: source "${_RBG_SCRIPT_DIR}/review-bot-gate-trust.sh"
#
# Dependencies: constants and sibling functions defined by review-bot-gate-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_RBG_TRUST_LIB_LOADED:-}" ]] && return 0
_RBG_TRUST_LIB_LOADED=1

_rbg_account_todo_only_live_evidence() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="$3"
	local allow_added_briefs="${4:-0}"
	local author_login=""
	local permission=""
	local changed_files=""

	author_login=$(jq -r '.user.login // empty' <<<"$pr_metadata_json" 2>/dev/null) || return 1
	[[ "$author_login" =~ ^[A-Za-z0-9-]+$ ]] || return 1

	permission=$(gh api "repos/${repo}/collaborators/${author_login}/permission" \
		--jq '.permission // empty') || return 2
	case "$permission" in
	admin | maintain | write) ;;
	*) return 1 ;;
	esac

	if [[ "$allow_added_briefs" == "1" ]]; then
		#aidevops:trust-boundary -- GH#34149: TODO.md must change, and every
		# other file must be a newly added brief capture under todo/tasks/.
		changed_files=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/files?per_page=100" \
			--jq '.[] | [.filename, .status] | @tsv') || return 2
		_rbg_todo_with_added_briefs_only "$changed_files" || return 1
		return 0
	fi
	changed_files=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/files?per_page=100" \
		--jq '.[].filename') || return 2
	[[ "$changed_files" == "TODO.md" ]] || return 1
	return 0
}

# Input: "<filename>\t<status>" lines. Exactly one TODO.md modification plus
# zero or more added todo/tasks/tNNN-brief.md files; anything else fails.
_rbg_todo_with_added_briefs_only() {
	local changed_files="$1"
	local filename="" status="" todo_seen=0
	[[ -n "$changed_files" ]] || return 1
	while IFS=$'\t' read -r filename status; do
		if [[ "$filename" == "TODO.md" && "$status" == "modified" && "$todo_seen" -eq 0 ]]; then
			todo_seen=1
			continue
		fi
		[[ "$status" == "added" && "$filename" =~ ^todo/tasks/t[0-9]+(\.[0-9]+)*-brief\.md$ ]] || return 1
	done <<<"$changed_files"
	[[ "$todo_seen" -eq 1 ]] || return 1
	return 0
}

_rbg_is_trusted_account_issue_sync_pr() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="$3"
	local expected_head_sha="$4"
	local evidence_rc=0

	_rbg_is_account_issue_sync_pr_metadata "$repo" "$pr_metadata_json" "$expected_head_sha" || return 1
	_rbg_account_todo_only_live_evidence "$pr_number" "$repo" "$pr_metadata_json" || evidence_rc=$?
	return "$evidence_rc"
}

_rbg_is_trusted_pulse_todo_handoff_pr() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="$3"
	local expected_head_sha="$4"
	local evidence_rc=0

	_rbg_is_pulse_todo_handoff_pr_metadata "$repo" "$pr_metadata_json" "$expected_head_sha" || return 1
	_rbg_account_todo_only_live_evidence "$pr_number" "$repo" "$pr_metadata_json" 1 || evidence_rc=$?
	return "$evidence_rc"
}
