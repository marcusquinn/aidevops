#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Preserve durable issue-linked work before ownership or PR creation changes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_ISSUE_OPEN_PR_GUARD_LOADED:-}" ]] && return 0
_ISSUE_OPEN_PR_GUARD_LOADED=1

ISSUE_OPEN_PR_NUMBER=""
ISSUE_OPEN_PR_HEAD_REF=""
ISSUE_OPEN_PR_HEAD_SHA=""
ISSUE_OPEN_PR_AUTHOR=""
ISSUE_OPEN_PR_HEAD_REPO=""

_issue_open_pr_guard_reset() {
	ISSUE_OPEN_PR_NUMBER=""
	ISSUE_OPEN_PR_HEAD_REF=""
	ISSUE_OPEN_PR_HEAD_SHA=""
	ISSUE_OPEN_PR_AUTHOR=""
	ISSUE_OPEN_PR_HEAD_REPO=""
	return 0
}

# Resolve same-repository open PRs from GitHub's authoritative closing-issue
# projection. The bounded complete snapshot includes drafts and conflicted PRs.
# Returns 0 for exactly one open PR, 1 for none, and 2 when evidence is
# unavailable, malformed, or ambiguous. Details are exposed in globals.
issue_open_pr_guard_resolve() {
	local issue_number="$1"
	local repo_slug="$2"
	local open_pr_json=""
	local open_pr_count=0
	local matches_json=""
	local match_count=0
	local string_type="string"

	_issue_open_pr_guard_reset
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 2
	open_pr_json=$(gh pr list --repo "$repo_slug" --state open --limit 1000 \
		--json number,headRefName,headRefOid,headRepository,author,closingIssuesReferences,isDraft 2>/dev/null) || return 2
	printf '%s' "$open_pr_json" | jq -e --arg string_type "$string_type" '
		type == "array" and all(.[];
			(.number | type) == "number" and (.headRefName | type) == $string_type and
			(.headRefOid | type) == $string_type and (.author.login | type) == $string_type and
			(.headRepository.nameWithOwner | type) == $string_type and
			(.closingIssuesReferences | type) == "array" and
			(.closingIssuesReferences | length) < 100)
	' >/dev/null 2>&1 || return 2
	open_pr_count=$(printf '%s' "$open_pr_json" | jq -r 'length' 2>/dev/null) || return 2
	[[ "$open_pr_count" -lt 1000 ]] || return 2
	matches_json=$(printf '%s' "$open_pr_json" | jq -c --argjson issue "$issue_number" --arg repo "$repo_slug" '
		[.[] | select(any(.closingIssuesReferences[]?;
			.number == $issue and
			((.repository.owner.login + "/" + .repository.name) | ascii_downcase) == ($repo | ascii_downcase)))]
	' 2>/dev/null) || return 2
	match_count=$(printf '%s' "$matches_json" | jq -r 'length' 2>/dev/null) || return 2
	[[ "$match_count" -eq 0 ]] && return 1
	[[ "$match_count" -eq 1 ]] || return 2
	ISSUE_OPEN_PR_NUMBER=$(printf '%s' "$matches_json" | jq -r '.[0].number')
	ISSUE_OPEN_PR_HEAD_REF=$(printf '%s' "$matches_json" | jq -r '.[0].headRefName')
	ISSUE_OPEN_PR_HEAD_SHA=$(printf '%s' "$matches_json" | jq -r '.[0].headRefOid')
	ISSUE_OPEN_PR_AUTHOR=$(printf '%s' "$matches_json" | jq -r '.[0].author.login')
	ISSUE_OPEN_PR_HEAD_REPO=$(printf '%s' "$matches_json" | jq -r '.[0].headRepository.nameWithOwner')
	return 0
}

_issue_open_pr_guard_local_repo() {
	local origin_url=""
	origin_url=$(git remote get-url origin 2>/dev/null) || return 1
	origin_url=${origin_url%.git}
	case "$origin_url" in
	https://github.com/*) printf '%s' "${origin_url#https://github.com/}" ;;
	git@github.com:*) printf '%s' "${origin_url#git@github.com:}" ;;
	ssh://git@github.com/*) printf '%s' "${origin_url#ssh://git@github.com/}" ;;
	ssh://git@github.com:22/*) printf '%s' "${origin_url#ssh://git@github.com:22/}" ;;
	*) return 1 ;;
	esac
	return 0
}

# Returns 0 when fresh work or an explicit replacement is safe, 3 when the
# current actor/repository/branch continues the linked PR, 1 for a durable-work
# conflict, and 2 for incomplete evidence.
issue_open_pr_guard_check() {
	local issue_number="$1"
	local repo_slug="$2"
	local current_branch="${3:-}"
	local replacement_pr="${4:-}"
	local replacement_reason="${5:-}"
	local require_ancestry="${6:-0}"
	local current_head_repo="${7:-}"
	local current_actor="${8:-}"
	local resolve_rc=0
	local normalized_current_repo=""
	local normalized_pr_repo=""
	local normalized_current_actor=""
	local normalized_pr_author=""

	issue_open_pr_guard_resolve "$issue_number" "$repo_slug" || resolve_rc=$?
	if [[ "$resolve_rc" -eq 1 ]]; then
		[[ -z "$replacement_pr" && -z "$replacement_reason" ]] && return 0
		return 2
	fi
	[[ "$resolve_rc" -eq 0 ]] || return 2
	if [[ -n "$current_branch" && "$current_branch" == "$ISSUE_OPEN_PR_HEAD_REF" ]]; then
		if [[ -z "$current_head_repo" ]]; then
			current_head_repo=$(_issue_open_pr_guard_local_repo 2>/dev/null) || return 2
		fi
		if [[ -z "$current_actor" ]]; then
			current_actor=$(gh api user --jq '.login // empty' 2>/dev/null) || return 2
			[[ -n "$current_actor" ]] || return 2
		fi
		normalized_current_repo=$(printf '%s' "$current_head_repo" | tr '[:upper:]' '[:lower:]')
		normalized_pr_repo=$(printf '%s' "$ISSUE_OPEN_PR_HEAD_REPO" | tr '[:upper:]' '[:lower:]')
		normalized_current_actor=$(printf '%s' "$current_actor" | tr '[:upper:]' '[:lower:]')
		normalized_pr_author=$(printf '%s' "$ISSUE_OPEN_PR_AUTHOR" | tr '[:upper:]' '[:lower:]')
		if [[ "$normalized_current_repo" == "$normalized_pr_repo" &&
			"$normalized_current_actor" == "$normalized_pr_author" ]]; then
			return 3
		fi
	fi

	if [[ "$replacement_pr" == "$ISSUE_OPEN_PR_NUMBER" && ${#replacement_reason} -ge 20 ]]; then
		if [[ "$require_ancestry" -eq 1 ]]; then
			git cat-file -e "${ISSUE_OPEN_PR_HEAD_SHA}^{commit}" 2>/dev/null || return 2
			git merge-base --is-ancestor "$ISSUE_OPEN_PR_HEAD_SHA" HEAD 2>/dev/null || return 1
		fi
		return 0
	fi
	return 1
}
