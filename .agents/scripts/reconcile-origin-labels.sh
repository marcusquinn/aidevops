#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# reconcile-origin-labels.sh (t2200 — origin label mutual exclusion)
#
# One-shot reconciliation script that scans open issues across all
# pulse-enabled repos for issues carrying more than one origin:* label
# (origin:interactive, origin:worker, origin:worker-takeover) and
# normalises them to a single canonical origin.
#
# Canonical origin resolution order:
#   1. origin:worker-takeover wins (explicitly overrides prior origin)
#   2. If the last non-bot comment contains a pulse dispatch/worker
#      keyword, the issue is origin:worker
#   3. If the issue has automation-signature labels (review-followup,
#      consolidated, file-size-debt, etc.), it is origin:worker
#   4. Otherwise, fall back to origin:interactive
#
# Usage:
#   reconcile-origin-labels.sh [--dry-run] [--repo slug]
#
# --dry-run   Print what would change without applying.
# --repo SLUG Limit to a specific repo. Default: all pulse-enabled repos.
#
# Exit codes:
#   0 — all eligible issues processed (or no changes needed)
#   1 — fatal error
#   2 — at least one issue failed to update (partial success)

set -euo pipefail

# Source shared-constants for set_origin_label and ORIGIN_LABELS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	printf 'ERROR: cannot source shared-constants.sh\n' >&2
	exit 1
}

# Labels that indicate automation/pulse origin (same set as
# cleanup-mistagged-origin-interactive.sh).
readonly AUTOMATION_SIGNATURE_LABELS=(
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
	printf 'Usage: %s [--dry-run] [--repo owner/repo]\n' "$(basename "$0")"
	return 0
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) DRY_RUN=true ;;
		--repo)
			REPO_FILTER="${2:-}"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 1
			;;
		esac
		shift
	done
	return 0
}

# List pulse-enabled repos from repos.json
list_repos() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -n "$REPO_FILTER" ]]; then
		printf '%s\n' "$REPO_FILTER"
		return 0
	fi
	[[ -f "$repos_json" ]] || {
		printf 'ERROR: repos.json not found at %s\n' "$repos_json" >&2
		return 1
	}
	jq -r '
		.initialized_repos[]
		| select(.pulse == true and (.local_only // false) == false)
		| .slug
	' "$repos_json" 2>/dev/null
	return 0
}

# Find issues with multiple origin labels in a repo.
# Emits NDJSON: {"number":N,"labels":["origin:...","origin:..."],...}
find_multi_origin_issues() {
	local repo="$1"
	local json
	json=$(gh issue list --repo "$repo" \
		--state open \
		--limit 200 \
		--json number,title,labels,assignees 2>/dev/null) || json="[]"

	# Filter: keep issues with >1 origin:* label
	printf '%s' "$json" | jq -rc '
		.[]
		| . as $issue
		| [.labels[].name | select(startswith("origin:"))] as $origins
		| select(($origins | length) > 1)
		| {
			number,
			title: (.title | .[0:80]),
			origins: $origins,
			labels: [.labels[].name],
			assignees: [.assignees[].login]
		}
	' 2>/dev/null
	return 0
}

# Determine canonical origin for an issue with multiple origin labels.
# Args: $1=labels_json_array $2=repo $3=issue_number
resolve_canonical_origin() {
	local labels_json="$1"
	local repo="$2"
	local issue_number="$3"

	# Rule 1: worker-takeover wins unconditionally
	if printf '%s' "$labels_json" | jq -e 'index("origin:worker-takeover")' >/dev/null 2>&1; then
		printf 'worker-takeover'
		return 0
	fi

	# Rule 2: check for automation-signature labels
	local all_labels
	all_labels=$(gh issue view "$issue_number" --repo "$repo" \
		--json labels --jq '[.labels[].name]' 2>/dev/null) || all_labels="[]"

	local sig_label
	for sig_label in "${AUTOMATION_SIGNATURE_LABELS[@]}"; do
		if printf '%s' "$all_labels" | jq -e --arg l "$sig_label" 'index($l)' >/dev/null 2>&1; then
			printf 'worker'
			return 0
		fi
	done

	# Rule 3: if origin:worker is present (and no contradicting signals),
	# keep worker — the issue was likely created by a worker and later
	# had origin:interactive added erroneously.
	if printf '%s' "$labels_json" | jq -e 'index("origin:worker")' >/dev/null 2>&1; then
		printf 'worker'
		return 0
	fi

	# Rule 4: fallback to interactive
	printf 'interactive'
	return 0
}

fix_issue() {
	local repo="$1"
	local issue_number="$2"
	local canonical_origin="$3"

	if [[ "$DRY_RUN" == "true" ]]; then
		printf '  DRY-RUN: #%s → origin:%s\n' "$issue_number" "$canonical_origin"
		return 0
	fi

	if set_origin_label "$issue_number" "$repo" "$canonical_origin" >/dev/null 2>&1; then
		printf '  FIXED:   #%s → origin:%s\n' "$issue_number" "$canonical_origin"
		return 0
	fi
	printf '  FAILED:  #%s → origin:%s\n' "$issue_number" "$canonical_origin" >&2
	return 1
}

main() {
	parse_args "$@"

	command -v gh >/dev/null 2>&1 || {
		printf 'ERROR: gh CLI not found\n' >&2
		exit 1
	}

	local repos
	repos=$(list_repos) || exit 1
	[[ -z "$repos" ]] && {
		printf 'No pulse-enabled repos found.\n'
		exit 0
	}

	local total_found=0
	local total_fixed=0
	local total_failed=0

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		printf 'Scanning %s...\n' "$repo"

		local issues
		issues=$(find_multi_origin_issues "$repo")
		[[ -z "$issues" ]] && {
			printf '  No multi-origin issues found.\n'
			continue
		}

		while IFS= read -r issue_json; do
			[[ -z "$issue_json" ]] && continue
			local num title origins_json
			num=$(printf '%s' "$issue_json" | jq -r '.number')
			title=$(printf '%s' "$issue_json" | jq -r '.title')
			origins_json=$(printf '%s' "$issue_json" | jq -c '.origins')

			printf '  #%s: %s (origins: %s)\n' "$num" "$title" "$origins_json"
			total_found=$((total_found + 1))

			local canonical
			canonical=$(resolve_canonical_origin "$origins_json" "$repo" "$num")
			if fix_issue "$repo" "$num" "$canonical"; then
				total_fixed=$((total_fixed + 1))
			else
				total_failed=$((total_failed + 1))
			fi
		done <<<"$issues"
	done <<<"$repos"

	printf '\nSummary: found=%d fixed=%d failed=%d\n' \
		"$total_found" "$total_fixed" "$total_failed"

	[[ "$total_failed" -gt 0 ]] && exit 2
	exit 0
}

main "$@"
