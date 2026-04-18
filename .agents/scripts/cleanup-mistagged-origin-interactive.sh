#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# cleanup-mistagged-origin-interactive.sh (GH#18670 / Fix 7 — cleanup)
#
# Finds and re-labels issues that were created by pulse shell stages
# but inherited `origin:interactive` from the pre-fix bug in
# `detect_session_origin()` defaulting to "interactive" when no headless
# env var is set.
#
# Pulse-signature labels that indicate an issue was automation-generated:
#   - review-followup
#   - source:review-scanner
#   - consolidated
#   - consolidation-task
#   - file-size-debt
#   - function-complexity-debt
#   - code-quality
#   - recheck-simplicity
#
# Any issue carrying ANY of these labels AND `origin:interactive` was
# mislabeled by the bug. Fix:
#   1. Remove `origin:interactive` label
#   2. Add `origin:worker` label
#   3. Unassign the maintainer IF they are currently assigned (pulse
#      shell stages auto-assigned via _gh_wrapper_auto_assignee)
#
# The cleanup is idempotent: running it twice is safe. Each fix step
# uses `gh issue edit` which is idempotent at the GitHub API level.
#
# Usage:
#   cleanup-mistagged-origin-interactive.sh [--dry-run] [--repo slug]
#
# --dry-run   Print the changes that would be made without applying them.
# --repo SLUG Limit cleanup to a specific repo. Default: all pulse-enabled
#             repos from ~/.config/aidevops/repos.json.
#
# Exit codes:
#   0 — all eligible issues processed (or no changes needed)
#   1 — fatal error (missing gh, invalid repos.json, etc.)
#   2 — at least one issue failed to update (partial success)

set -euo pipefail

readonly PULSE_SIGNATURE_LABELS=(
	"review-followup"
	"source:review-scanner"
	"consolidated"
	"consolidation-task"
	"file-size-debt"
	"function-complexity-debt"
	"code-quality"
	"recheck-simplicity"
)

DRY_RUN=false
REPO_FILTER=""

usage() {
	cat <<EOF
cleanup-mistagged-origin-interactive.sh [--dry-run] [--repo owner/repo]

Re-labels issues mistagged origin:interactive by the pre-Fix-7 pulse
shell stages (GH#18670). Removes origin:interactive, adds origin:worker,
unassigns the maintainer. Idempotent.

Options:
  --dry-run          Print changes without applying.
  --repo SLUG        Limit to one repo. Default: all pulse-enabled repos.
  -h, --help         Show this message.
EOF
	return 0
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo)
			REPO_FILTER="${2:-}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'unknown argument: %s\n' "$1" >&2
			usage
			exit 1
			;;
		esac
	done
	return 0
}

resolve_repos() {
	if [[ -n "$REPO_FILTER" ]]; then
		printf '%s\n' "$REPO_FILTER"
		return 0
	fi
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		printf 'ERROR: %s not found\n' "$repos_json" >&2
		return 1
	fi
	jq -r '
		.initialized_repos[]
		| select(.pulse == true and (.local_only // false) == false and .slug != "")
		| .slug
	' "$repos_json" 2>/dev/null
	return 0
}

list_mistagged_issues_in_repo() {
	local repo="$1"
	# Query: open issues with origin:interactive that ALSO have at least
	# one pulse-signature label. gh issue list accepts multiple --label
	# flags with AND semantics, but we need AND-with-any-of-7 which is
	# OR across the signature set. Strategy: query with origin:interactive
	# once, then filter client-side in jq by label intersection.
	local issues_json
	issues_json=$(gh issue list --repo "$repo" \
		--label "origin:interactive" \
		--state open \
		--limit 100 \
		--json number,title,labels,assignees 2>/dev/null) || issues_json="[]"

	# Client-side filter: keep only issues whose labels intersect with
	# any signature label. jq renders NDJSON-style one-per-line.
	local signatures_json
	signatures_json=$(printf '%s\n' "${PULSE_SIGNATURE_LABELS[@]}" | jq -R . | jq -s .)

	printf '%s' "$issues_json" | jq -rc --argjson sigs "$signatures_json" '
		.[]
		| select(
			(.labels | map(.name)) as $names
			| any($sigs[]; . as $sig | $names | index($sig))
		)
		| {
			number,
			title: (.title | .[0:80]),
			labels: [.labels[].name],
			assignees: [.assignees[].login]
		}
	' 2>/dev/null
	return 0
}

fix_issue() {
	local repo="$1"
	local issue_number="$2"
	local assignees_csv="$3"
	local maintainer="$4"

	local action_summary="#${issue_number}: remove origin:interactive, add origin:worker"
	local -a assignees_arr=()
	if [[ -n "$assignees_csv" ]]; then
		# shellcheck disable=SC2034  # assignees_arr is populated here and iterated below
		IFS=',' read -ra assignees_arr <<<"$assignees_csv"
	fi

	# Build an unassign list for the maintainer if they are currently
	# attached. We only unassign the maintainer (the login that the
	# pre-fix _gh_wrapper_auto_assignee would have applied) — other
	# assignees (human collaborators) are preserved. The array guard
	# handles empty-assignee case under `set -u` on bash 3.2.
	local -a unassign_flags=()
	if [[ "${#assignees_arr[@]}" -gt 0 ]]; then
		local a
		for a in "${assignees_arr[@]}"; do
			if [[ "$a" == "$maintainer" ]]; then
				unassign_flags+=(--remove-assignee "$a")
				action_summary="${action_summary}, unassign ${a}"
			fi
		done
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		printf '  DRY-RUN: %s\n' "$action_summary"
		return 0
	fi

	# t2200: use set_origin_label for mutual exclusion instead of raw flags.
	# Expand unassign_flags safely when empty (bash 3.2 set -u compat).
	if set_origin_label "$issue_number" "$repo" "worker" \
		${unassign_flags[@]+"${unassign_flags[@]}"} >/dev/null 2>&1; then
		printf '  FIXED:   %s\n' "$action_summary"
		return 0
	fi
	printf '  FAILED:  %s\n' "$action_summary" >&2
	return 1
}

resolve_maintainer_for_repo() {
	local repo="$1"
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]]; then
		jq -r --arg slug "$repo" '
			.initialized_repos[]
			| select(.slug == $slug)
			| .maintainer // (.slug | split("/")[0])
		' "$repos_json" 2>/dev/null | head -1
		return 0
	fi
	# Fallback: first segment of the slug
	printf '%s' "${repo%%/*}"
	return 0
}

process_repo() {
	local repo="$1"
	printf '\n== %s ==\n' "$repo"

	local maintainer
	maintainer=$(resolve_maintainer_for_repo "$repo")
	if [[ -z "$maintainer" ]]; then
		printf '  skip: could not resolve maintainer for %s\n' "$repo"
		return 0
	fi

	local issues
	issues=$(list_mistagged_issues_in_repo "$repo")
	if [[ -z "$issues" ]]; then
		printf '  no mistagged issues found\n'
		return 0
	fi

	local failed=0 fixed=0
	while IFS= read -r issue_json; do
		[[ -n "$issue_json" ]] || continue
		local issue_number assignees_csv
		issue_number=$(printf '%s' "$issue_json" | jq -r '.number')
		assignees_csv=$(printf '%s' "$issue_json" | jq -r '.assignees | join(",")')
		if fix_issue "$repo" "$issue_number" "$assignees_csv" "$maintainer"; then
			fixed=$((fixed + 1))
		else
			failed=$((failed + 1))
		fi
	done <<<"$issues"

	printf '  summary: %d fixed, %d failed\n' "$fixed" "$failed"
	return "$failed"
}

main() {
	parse_args "$@"

	if ! command -v gh >/dev/null 2>&1; then
		printf 'ERROR: gh CLI not found\n' >&2
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf 'ERROR: jq not found\n' >&2
		return 1
	fi

	local repos
	if ! repos=$(resolve_repos); then
		return 1
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		printf 'DRY-RUN mode — no changes will be applied\n'
	fi

	local total_failed=0
	while IFS= read -r repo; do
		[[ -n "$repo" ]] || continue
		if ! process_repo "$repo"; then
			total_failed=$((total_failed + $?))
		fi
	done <<<"$repos"

	if [[ "$total_failed" -gt 0 ]]; then
		printf '\nPartial success: %d issue(s) failed to update\n' "$total_failed" >&2
		return 2
	fi
	printf '\nCleanup complete.\n'
	return 0
}

main "$@"
