#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# prework-discovery-helper.sh — duplicate/collision discovery before edits.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: prework-discovery-helper.sh --keywords TEXT [--files path[,path]] [--since WHEN] [--repo owner/repo]

Runs recent git-log and open/merged PR searches before implementation.
EOF
	return 0
}

main() {
	local keywords=""
	local files_csv=""
	local since="14 days ago"
	local repo=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--keywords) [[ $# -gt 0 ]] || { printf 'ERROR: --keywords requires a value\n' >&2; return 2; }; local value="$1"; keywords="$value"; shift ;;
			--files) [[ $# -gt 0 ]] || { printf 'ERROR: --files requires a value\n' >&2; return 2; }; local value="$1"; files_csv="$value"; shift ;;
			--since) [[ $# -gt 0 ]] || { printf 'ERROR: --since requires a value\n' >&2; return 2; }; local value="$1"; since="$value"; shift ;;
			--repo) [[ $# -gt 0 ]] || { printf 'ERROR: --repo requires a value\n' >&2; return 2; }; local value="$1"; repo="$value"; shift ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	if [[ -z "$keywords" ]]; then
		printf 'ERROR: --keywords is required\n' >&2
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
		# t3460: Intentional raw gh exception. Related-PR discovery requires
		# GitHub search semantics; gh_pr_list's REST fallback drops --search.
		gh pr list "${repo_args[@]}" --state merged --search "$keywords" --limit 5 || true
		printf '\n### Open related PRs\n\n'
		# t3460: Intentional raw gh exception. Related-PR discovery requires
		# GitHub search semantics; gh_pr_list's REST fallback drops --search.
		gh pr list "${repo_args[@]}" --state open --search "$keywords" --limit 5 || true
	else
		printf 'gh unavailable; skipped PR collision checks.\n'
	fi
	return 0
}

main "$@"
