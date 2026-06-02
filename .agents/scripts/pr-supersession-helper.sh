#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pr-supersession-helper.sh — Detect PRs superseded by their current base.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

_psh_log() {
	local msg="$1"
	printf '[pr-supersession] %s\n' "$msg" >&2
	return 0
}

_psh_usage() {
	cat <<'EOF'
pr-supersession-helper.sh — classify whether a PR is superseded by base

Usage:
  pr-supersession-helper.sh classify --repo OWNER/REPO --pr N [--repo-path PATH] [--json]
  pr-supersession-helper.sh help

Output classes:
  fully_superseded     Base already contains the PR deliverable and no meaningful diff remains.
  partially_superseded Base contains some deliverable signals, but PR still has relevant changes.
  stale_baseline_only  Current branch diff no longer overlaps the PR's original changed files.
  still_needed         Deliverable is not present on base, or branch diff still carries it.
  unknown              Required metadata or git comparison was unavailable.

The helper is advisory. It prints a suggested close comment for superseded cases
but never closes the PR.
EOF
	return 0
}

_psh_require_tools() {
	local missing=0
	for tool in gh jq git; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			_psh_log "missing required tool: $tool"
			missing=1
		fi
	done
	[[ "$missing" -eq 0 ]] || return 1
	return 0
}

_psh_compact_lines_json() {
	jq -Rn '[inputs | select(length > 0)]'
	return 0
}

_psh_fetch_pr_json() {
	local repo_slug="$1"
	local pr_number="$2"

	gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,title,body,baseRefName,headRefName,files,author,url \
		2>/dev/null
	return $?
}

_psh_default_repo_path() {
	local repo_slug="$1"
	local repo_path=""

	if git rev-parse --show-toplevel >/dev/null 2>&1; then
		repo_path=$(git rev-parse --show-toplevel 2>/dev/null) || repo_path=""
		if [[ -n "$repo_path" ]]; then
			printf '%s\n' "$repo_path"
			return 0
		fi
	fi

	repo_path=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .path // empty' \
		"${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}" 2>/dev/null | head -n 1) || repo_path=""
	repo_path="${repo_path/#\~/$HOME}"
	[[ -n "$repo_path" ]] || return 1
	printf '%s\n' "$repo_path"
	return 0
}

_psh_original_files_json() {
	local pr_json="$1"
	printf '%s' "$pr_json" | jq -r '.files[]?.path // empty' 2>/dev/null | _psh_compact_lines_json
	return 0
}

_psh_diff_files_json() {
	local repo_path="$1"
	local base_ref="$2"
	local head_ref="$3"

	if [[ -z "$repo_path" || ! -d "$repo_path/.git" ]]; then
		printf '[]\n'
		return 1
	fi

	git -C "$repo_path" fetch --quiet origin "$base_ref" 2>/dev/null || true
	git -C "$repo_path" fetch --quiet origin "$head_ref" 2>/dev/null || true

	local base="origin/${base_ref}"
	local head="origin/${head_ref}"
	if ! git -C "$repo_path" rev-parse --verify "$base" >/dev/null 2>&1; then
		printf '[]\n'
		return 1
	fi
	if ! git -C "$repo_path" rev-parse --verify "$head" >/dev/null 2>&1; then
		head="$head_ref"
	fi
	if ! git -C "$repo_path" rev-parse --verify "$head" >/dev/null 2>&1; then
		printf '[]\n'
		return 1
	fi

	git -C "$repo_path" diff --name-only "${base}...${head}" 2>/dev/null | _psh_compact_lines_json
	return 0
}

_psh_extract_deliverable_terms_json() {
	local pr_json="$1"
	local text=""

	text=$(printf '%s' "$pr_json" | jq -r '[.title // "", .body // ""] | join("\n")' 2>/dev/null) || text=""
	printf '%s\n' "$text" \
		| tr '`"' ' ' \
		| tr -cs '[:alnum:]_.-/' '\n' \
		| awk 'length($0) >= 4 && $0 !~ /^(https?|github|com|this|that|with|from|have|will|should|would|when|then|base|branch|pull|request|issue|task|files|edit|new|run|test|tests|helper|detect|current|remaining|summary|stale|superseded)$/ {print}' \
		| sort -u \
		| _psh_compact_lines_json
	return 0
}

_psh_base_term_hits_json() {
	local repo_path="$1"
	local base_ref="$2"
	local terms_json="$3"

	local base="origin/${base_ref}"
	local terms_count
	terms_count=$(printf '%s' "$terms_json" | jq 'length' 2>/dev/null) || terms_count=0
	[[ "$terms_count" =~ ^[0-9]+$ ]] || terms_count=0
	if [[ "$terms_count" -eq 0 || -z "$repo_path" || ! -d "$repo_path/.git" ]]; then
		printf '[]\n'
		return 0
	fi
	git -C "$repo_path" fetch --quiet origin "$base_ref" 2>/dev/null || true
	if ! git -C "$repo_path" rev-parse --verify "$base" >/dev/null 2>&1; then
		printf '[]\n'
		return 0
	fi

	local tmp
	tmp=$(mktemp) || return 1
	printf '%s' "$terms_json" | jq -r '.[]' | while IFS= read -r term; do
		[[ -n "$term" ]] || continue
		if git -C "$repo_path" grep -F --quiet -- "$term" "$base" 2>/dev/null; then
			printf '%s\n' "$term"
		fi
	done >"$tmp"
	_psh_compact_lines_json <"$tmp"
	rm -f "$tmp" 2>/dev/null || true
	return 0
}

_psh_intersection_count() {
	local left_json="$1"
	local right_json="$2"

	jq -n --argjson left "$left_json" --argjson right "$right_json" \
		'[$left[] | select(. as $x | $right | index($x))] | length'
	return 0
}

_psh_build_comment() {
	local classification="$1"
	local pr_number="$2"
	local base_ref="$3"
	local rationale="$4"

	cat <<EOF
Supersession check for PR #${pr_number}: **${classification}**.

Rationale: ${rationale}

Suggested action: close this PR as superseded only after a maintainer verifies the current \
\`${base_ref}\` branch contains the intended deliverable. This helper is advisory and did not close anything.
EOF
	return 0
}

_psh_extract_closing_issue_from_pr_json() {
	local pr_json="$1"
	local body title body_issue title_issue

	body=$(printf '%s' "$pr_json" | jq -r '.body // empty' 2>/dev/null) || body=""
	title=$(printf '%s' "$pr_json" | jq -r '.title // empty' 2>/dev/null) || title=""
	body_issue=$(printf '%s' "$body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+') || body_issue=""
	title_issue=$(printf '%s' "$title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+') || title_issue=""

	[[ -n "$body_issue" ]] || return 0
	if [[ -n "$title_issue" ]]; then
		printf '%s' "$title_issue"
		return 0
	fi
	printf '%s' "$body_issue"
	return 0
}

_psh_find_merged_closer_for_closed_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local current_pr="$3"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$current_pr" =~ ^[0-9]+$ ]] || return 1

	local issue_json issue_state closer_numbers closer_number pr_state merged_at
	issue_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,closedByPullRequestsReferences 2>/dev/null) || return 1
	issue_state=$(printf '%s' "$issue_json" | jq -r '.state // empty' 2>/dev/null) || issue_state=""
	[[ "$issue_state" == "CLOSED" ]] || return 1

	closer_numbers=$(printf '%s' "$issue_json" | jq -r '.closedByPullRequestsReferences[]?.number // empty' 2>/dev/null) || closer_numbers=""
	while IFS= read -r closer_number; do
		[[ "$closer_number" =~ ^[0-9]+$ ]] || continue
		[[ "$closer_number" != "$current_pr" ]] || continue
		pr_state=$(gh pr view "$closer_number" --repo "$repo_slug" \
			--json state,mergedAt --jq '.state // empty' 2>/dev/null) || pr_state=""
		merged_at=$(gh pr view "$closer_number" --repo "$repo_slug" \
			--json mergedAt --jq '.mergedAt // empty' 2>/dev/null) || merged_at=""
		if [[ "$pr_state" == "MERGED" || -n "$merged_at" ]]; then
			printf '%s' "$closer_number"
			return 0
		fi
	done <<EOF
$closer_numbers
EOF
	return 1
}

_psh_classify_json() {
	local pr_json="$1"
	local repo_path="$2"
	local as_json="$3"

	local pr_number title base_ref head_ref original_files diff_files terms hits
	pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty')
	title=$(printf '%s' "$pr_json" | jq -r '.title // empty')
	base_ref=$(printf '%s' "$pr_json" | jq -r '.baseRefName // empty')
	head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')
	original_files=$(_psh_original_files_json "$pr_json")
	terms=$(_psh_extract_deliverable_terms_json "$pr_json")
	diff_files=$(_psh_diff_files_json "$repo_path" "$base_ref" "$head_ref" 2>/dev/null) || diff_files="[]"
	hits=$(_psh_base_term_hits_json "$repo_path" "$base_ref" "$terms")

	local original_count diff_count terms_count hit_count overlap_count classification rationale comment
	original_count=$(printf '%s' "$original_files" | jq 'length')
	diff_count=$(printf '%s' "$diff_files" | jq 'length')
	terms_count=$(printf '%s' "$terms" | jq 'length')
	hit_count=$(printf '%s' "$hits" | jq 'length')
	overlap_count=$(_psh_intersection_count "$original_files" "$diff_files")

	classification="still_needed"
	rationale="base does not yet contain enough deliverable signals, or the current diff still overlaps the PR deliverable"

	if [[ -z "$base_ref" || -z "$head_ref" ]]; then
		classification="unknown"
		rationale="PR metadata did not include base/head refs"
	elif [[ "$diff_count" -eq 0 && "$hit_count" -gt 0 ]]; then
		classification="fully_superseded"
		rationale="current branch has no diff against origin/${base_ref}, and base contains ${hit_count}/${terms_count} deliverable term(s)"
	elif [[ "$original_count" -gt 0 && "$diff_count" -gt 0 && "$overlap_count" -eq 0 && "$hit_count" -gt 0 ]]; then
		classification="stale_baseline_only"
		rationale="current diff no longer overlaps the PR's original files, while base contains ${hit_count}/${terms_count} deliverable term(s)"
	elif [[ "$terms_count" -gt 0 && "$hit_count" -gt 0 && "$hit_count" -lt "$terms_count" ]]; then
		classification="partially_superseded"
		rationale="base contains ${hit_count}/${terms_count} deliverable term(s), but some signals or file overlap remain unresolved"
	elif [[ "$terms_count" -gt 0 && "$hit_count" -ge "$terms_count" && "$overlap_count" -eq 0 ]]; then
		classification="fully_superseded"
		rationale="base contains all deliverable terms and the current diff no longer overlaps original PR files"
	fi

	comment=$(_psh_build_comment "$classification" "$pr_number" "$base_ref" "$rationale")

	if [[ "$as_json" == "1" ]]; then
		jq -n \
			--arg classification "$classification" \
			--arg rationale "$rationale" \
			--arg comment "$comment" \
			--arg title "$title" \
			--argjson pr "${pr_number:-0}" \
			--argjson original_files "$original_files" \
			--argjson diff_files "$diff_files" \
			--argjson deliverable_terms "$terms" \
			--argjson base_hits "$hits" \
			'{classification:$classification, rationale:$rationale, suggested_close_comment:$comment, pr:$pr, title:$title, original_files:$original_files, current_diff_files:$diff_files, deliverable_terms:$deliverable_terms, base_hits:$base_hits}'
	else
		printf 'classification=%s\n' "$classification"
		printf 'rationale=%s\n' "$rationale"
		printf '\n%s\n' "$comment"
	fi
	return 0
}

_psh_cmd_classify() {
	local repo_slug=""
	local pr_number=""
	local repo_path=""
	local as_json=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--repo)
				repo_slug="${2:-}"
				shift 2
				;;
			--pr)
				pr_number="${2:-}"
				shift 2
				;;
			--repo-path)
				repo_path="${2:-}"
				shift 2
				;;
			--json)
				as_json=1
				shift
				;;
			*)
				_psh_log "unknown argument: $arg"
				return 2
				;;
		esac
	done

	[[ -n "$repo_slug" && -n "$pr_number" ]] || { _psh_usage; return 2; }
	_psh_require_tools || return 1
	if [[ -z "$repo_path" ]]; then
		repo_path=$(_psh_default_repo_path "$repo_slug" 2>/dev/null) || repo_path=""
	fi

	local pr_json
	pr_json=$(_psh_fetch_pr_json "$repo_slug" "$pr_number") || return 1
	_psh_classify_json "$pr_json" "$repo_path" "$as_json"
	return 0
}

main() {
	local cmd="${1:-help}"
	case "$cmd" in
		classify)
			shift
			_psh_cmd_classify "$@"
			return $?
			;;
		help|--help|-h)
			_psh_usage
			return 0
			;;
		*)
			_psh_usage
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
