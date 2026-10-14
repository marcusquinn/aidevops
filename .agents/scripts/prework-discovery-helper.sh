#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# prework-discovery-helper.sh — duplicate/collision discovery before edits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

_usage() {
	cat <<'EOF'
Usage: prework-discovery-helper.sh [--keywords TEXT] [--blocker TEXT] [--files path[,path]] [--since WHEN] [--repo owner/repo]

Runs recent git-log, open/merged PR, and open claimed issue searches.
Provide --keywords or --blocker. Blocker mode also searches deploy, migration and CI titles.
EOF
	return 0
}

_claimed_issues() {
	local keywords="$1"
	local blocker="$2"
	shift 2
	local terms=("$keywords")
	if [[ -n "$blocker" ]]; then
		terms+=("$blocker" deploy migration CI)
	fi
	local results='[]'
	local term matches
	for term in "${terms[@]}"; do
		[[ -n "$term" ]] || continue
		# Comma-separated labels are OR; separate title searches avoid ANDing symptoms
		# with the generic blocker categories. Bound each query and the combined list.
		if matches=$(gh_issue_list "$@" --state open --search "$term in:title label:status:claimed,origin:interactive" --limit 5 --json number,title,url,assignees); then
			results=$(printf '%s\n%s\n' "$results" "$matches" | jq -s 'add | unique_by(.number) | .[:5]')
		else
			printf 'Warning: claimed issue search failed for %s; ownership is unknown.\n' "$term" >&2
		fi
	done
	printf '%s\n' "$results" | jq -r '.[] | "#\(.number)\t\(.title)\t\(.url)\tassignees: \([.assignees[].login] | join(", "))"'
	return 0
}

main() {
	local keywords=""
	local blocker=""
	local files_csv=""
	local since="14 days ago"
	local repo=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--keywords) [[ $# -gt 0 ]] || { printf 'ERROR: --keywords requires a value\n' >&2; return 2; }; local value="$1"; keywords="$value"; shift ;;
			--blocker) [[ $# -gt 0 ]] || { printf 'ERROR: --blocker requires a value\n' >&2; return 2; }; local value="$1"; blocker="$value"; shift ;;
			--files) [[ $# -gt 0 ]] || { printf 'ERROR: --files requires a value\n' >&2; return 2; }; local value="$1"; files_csv="$value"; shift ;;
			--since) [[ $# -gt 0 ]] || { printf 'ERROR: --since requires a value\n' >&2; return 2; }; local value="$1"; since="$value"; shift ;;
			--repo) [[ $# -gt 0 ]] || { printf 'ERROR: --repo requires a value\n' >&2; return 2; }; local value="$1"; repo="$value"; shift ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	if [[ -z "$keywords" && -z "$blocker" ]]; then
		printf 'ERROR: --keywords or --blocker is required\n' >&2
		return 2
	fi
	printf '## Prework discovery\n\n'
	if [[ -n "$files_csv" ]]; then
		IFS=',' read -r -a files <<<"$files_csv"
		printf '### Recent commits on target files\n\n'
		git log --since="$since" --oneline -- "${files[@]}" || true
		printf '\n'
	fi
	local repo_args=()
	if [[ -n "$repo" ]]; then
		repo_args=(--repo "$repo")
	fi
	if command -v gh >/dev/null 2>&1; then
		printf '### Recently merged related PRs\n\n'
		gh_pr_list "${repo_args[@]}" --state merged --search "${keywords:-$blocker}" --limit 5 || true
		printf '\n### Open related PRs\n\n'
		gh_pr_list "${repo_args[@]}" --state open --search "${keywords:-$blocker}" --limit 5 || true
		printf '\n### Open claimed issues\n\n'
		_claimed_issues "$keywords" "$blocker" "${repo_args[@]}"
	else
		printf 'gh unavailable; skipped PR and issue collision checks.\n'
	fi
	return 0
}

main "$@"
