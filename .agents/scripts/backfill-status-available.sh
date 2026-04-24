#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# backfill-status-available.sh (t2797 — pre-t2789 heal)
#
# One-shot helper that applies status:available to open, dispatchable
# issues missing any status:* label. Covers issues filed before PR #20720
# (t2789) made claim-task-id.sh apply status:available on new issues.
#
# Usage:
#   backfill-status-available.sh [--dry-run] [--apply] [--repo owner/repo] [--json]
#
# --dry-run    Print candidate list without applying (DEFAULT when no flag given)
# --apply      Actually apply status:available (and tier:standard if no tier:* present)
# --repo SLUG  Limit to a specific repo. Default: all pulse-enabled repos.
# --json       Machine-readable output (NDJSON per changed issue)
#
# Exit codes:
#   0 — all eligible issues processed (or dry-run, or no changes needed)
#   1 — fatal error
#   2 — at least one issue failed to update (partial success)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	printf 'ERROR: cannot source shared-constants.sh\n' >&2
	exit 1
}

# Labels that mark an issue as intentionally NOT dispatchable.
# These are NEVER candidates for backfill — exclusion is unconditional.
readonly EXCLUSION_LABELS=(
	"parent-task"
	"persistent"
	"consolidation-task"
	"routine-tracking"
	"no-auto-dispatch"
)

# All status:* labels — if an issue has ANY of these it is already labelled.
readonly STATUS_LABELS=(
	"status:available"
	"status:queued"
	"status:in-progress"
	"status:in-review"
	"status:claimed"
	"status:blocked"
	"status:done"
	"status:resolved"
	"status:needs-info"
)

# Label constants (avoids repeated literals caught by the string-literal linter)
readonly LABEL_STATUS_AVAILABLE="status:available"
readonly LABEL_TIER_STANDARD="tier:standard"

# Mode flags: 1=enabled, 0=disabled
DRY_RUN=1
JSON_OUTPUT=0
REPO_FILTER=""

usage() {
	printf 'Usage: %s [--dry-run] [--apply] [--repo owner/repo] [--json]\n' "$(basename "$0")"
	printf '  Default mode is --dry-run (safe to run without flags).\n'
	return 0
}

parse_args() {
	local explicit_mode=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--dry-run)
			DRY_RUN=1
			explicit_mode="dry-run"
			;;
		--apply)
			DRY_RUN=0
			explicit_mode="apply"
			;;
		--repo)
			REPO_FILTER="${2:-}"
			shift
			;;
		--json) JSON_OUTPUT=1 ;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$arg" >&2
			usage >&2
			exit 1
			;;
		esac
		shift
	done
	[[ -z "$explicit_mode" ]] && printf 'No mode flag given — running in --dry-run mode (use --apply to apply changes).\n'
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

# Build the gh search expression that excludes all protected labels.
# Returns a string like "-label:parent-task -label:persistent ..."
build_exclusion_search() {
	local parts=()
	local lbl
	for lbl in "${EXCLUSION_LABELS[@]}"; do
		parts+=("-label:${lbl}")
	done
	local status_lbl
	for status_lbl in "${STATUS_LABELS[@]}"; do
		parts+=("-label:${status_lbl}")
	done
	printf '%s\n' "${parts[*]}"
	return 0
}

# Find open auto-dispatch issues in a repo that have no status:* label
# and do not carry any exclusion label.
# Emits NDJSON per candidate: {"number":N,"title":"...","labels":["..."]}
find_candidates() {
	local repo="$1"
	local exclusion_search
	exclusion_search=$(build_exclusion_search)

	local json
	# shellcheck disable=SC2086
	json=$(gh issue list --repo "$repo" \
		--state open \
		--limit 200 \
		--search "label:auto-dispatch ${exclusion_search}" \
		--json number,title,labels 2>/dev/null) || json="[]"

	printf '%s' "$json" | jq -rc '.[] | {number, title: (.title | .[0:80]), labels: [.labels[].name]}' 2>/dev/null
	return 0
}

# Check if an issue has any tier:* label.
has_tier_label() {
	local labels_json="$1"
	printf '%s' "$labels_json" | jq -e '[.[] | select(startswith("tier:"))] | length > 0' >/dev/null 2>&1
	return $?
}

# Apply backfill labels to a single issue.
# Args: $1=repo $2=issue_number $3=labels_json $4=title
apply_backfill() {
	local repo="$1"
	local num="$2"
	local labels_json="$3"
	local title="$4"
	local add_tier=0
	local action_label="$LABEL_STATUS_AVAILABLE"

	if ! has_tier_label "$labels_json"; then
		add_tier=1
		action_label="${LABEL_STATUS_AVAILABLE} +${LABEL_TIER_STANDARD}"
	fi

	if (( JSON_OUTPUT )); then
		local mode_str="apply"
		(( DRY_RUN )) && mode_str="dry-run"
		printf '{"mode":"%s","repo":"%s","number":%d,"title":"%s","added":[%s]}\n' \
			"$mode_str" "$repo" "$num" \
			"$(printf '%s' "$title" | sed 's/"/\\"/g')" \
			"$(if (( add_tier )); then printf '"%s","%s"' "$LABEL_STATUS_AVAILABLE" "$LABEL_TIER_STANDARD"; else printf '"%s"' "$LABEL_STATUS_AVAILABLE"; fi)"
	else
		printf '[backfill] %s#%d → %s\n' "$repo" "$num" "$action_label"
	fi

	(( DRY_RUN )) && return 0

	local labels_to_add=("$LABEL_STATUS_AVAILABLE")
	(( add_tier )) && labels_to_add+=("$LABEL_TIER_STANDARD")

	local lbl
	for lbl in "${labels_to_add[@]}"; do
		gh issue edit "$num" --repo "$repo" --add-label "$lbl" >/dev/null 2>&1 || {
			printf 'ERROR: failed to add %s to %s#%d\n' "$lbl" "$repo" "$num" >&2
			return 1
		}
	done
	return 0
}

main() {
	parse_args "$@"

	command -v gh >/dev/null 2>&1 || {
		printf 'ERROR: gh CLI not found\n' >&2
		exit 1
	}

	command -v jq >/dev/null 2>&1 || {
		printf 'ERROR: jq not found\n' >&2
		exit 1
	}

	local repos
	repos=$(list_repos) || exit 1
	[[ -z "$repos" ]] && {
		printf 'No pulse-enabled repos found.\n'
		exit 0
	}

	local total_found=0
	local total_applied=0
	local total_failed=0
	local mode_label="DRY-RUN"
	(( DRY_RUN )) || mode_label="APPLY"

	(( JSON_OUTPUT )) || printf 'Mode: %s\n\n' "$mode_label"

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		(( JSON_OUTPUT )) || printf 'Scanning %s...\n' "$repo"

		local candidates
		candidates=$(find_candidates "$repo")
		if [[ -z "$candidates" ]]; then
			(( JSON_OUTPUT )) || printf '  No candidates found.\n'
			continue
		fi

		while IFS= read -r issue_json; do
			[[ -z "$issue_json" ]] && continue
			local num title labels_json
			num=$(printf '%s' "$issue_json" | jq -r '.number')
			title=$(printf '%s' "$issue_json" | jq -r '.title')
			labels_json=$(printf '%s' "$issue_json" | jq -c '.labels')

			total_found=$((total_found + 1))

			if apply_backfill "$repo" "$num" "$labels_json" "$title"; then
				total_applied=$((total_applied + 1))
			else
				total_failed=$((total_failed + 1))
			fi
		done <<<"$candidates"
	done <<<"$repos"

	if (( ! JSON_OUTPUT )); then
		printf '\nSummary [%s]: found=%d applied=%d failed=%d\n' \
			"$mode_label" "$total_found" "$total_applied" "$total_failed"
		if (( DRY_RUN && total_found > 0 )); then
			printf 'Re-run with --apply to apply changes.\n'
		fi
	else
		printf '{"summary":{"mode":"%s","found":%d,"applied":%d,"failed":%d}}\n' \
			"$mode_label" "$total_found" "$total_applied" "$total_failed"
	fi

	[[ "$total_failed" -gt 0 ]] && exit 2
	exit 0
}

main "$@"
