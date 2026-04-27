#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# reconcile-stuck-claims.sh (GH#21057 — Phase 1 auto-release GitHub gap)
#
# One-shot reconciler that heals issues left in the stuck-claim state: the
# Phase 1 auto-release path in scan-stale previously deleted the local stamp
# but skipped the GitHub-side cleanup (status:in-review + self-assignment
# persisted), causing the footprint-overlap cache to treat those issues as
# in-flight indefinitely and blocking dispatch on every issue touching an
# overlapping file path.
#
# This script is the systemic heal after deploying the fix in
# interactive-session-helper.sh (GH#21057). Run once after deploy to clear
# the backlog. Idempotent; safe to re-run.
#
# Stuck-claim definition:
#   - Issue is OPEN
#   - Carries origin:interactive label
#   - Carries status:in-review OR status:claimed
#   - Is assigned to $current_user
#   - Has NO live stamp at ~/.aidevops/.agent-workspace/claim-stamps/<slug>-<num>.json
#
# Usage:
#   reconcile-stuck-claims.sh [--dry-run] [--repo slug] [--apply]
#
# --dry-run   (default) Print what would change without applying.
# --apply     Actually release the stuck claims.
# --repo SLUG Limit to a specific repo. Default: all pulse-enabled repos.
#
# Exit codes:
#   0 — all eligible issues processed (or no changes needed)
#   1 — fatal error
#   2 — at least one issue failed to update (partial success)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	printf 'ERROR: cannot source shared-constants.sh\n' >&2
	exit 1
}

# Source the interactive-session helper so we can call _isc_cmd_release.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/interactive-session-helper.sh" 2>/dev/null || {
	printf 'ERROR: cannot source interactive-session-helper.sh\n' >&2
	exit 1
}

# 1=dry-run (default, safe); 0=apply
DRY_RUN=1
REPO_FILTER=""

usage() {
	printf 'Usage: %s [--dry-run] [--apply] [--repo owner/repo]\n' "$(basename "$0")"
	printf '\n'
	printf 'One-shot reconciler for stuck interactive claims (GH#21057).\n'
	printf 'Default: --dry-run (safe, no changes made).\n'
	return 0
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--apply) DRY_RUN=0 ;;
		--repo)
			REPO_FILTER="${2:-}"
			shift
			;;
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
	return 0
}

# List pulse-enabled repos from repos.json (same pattern as reconcile-origin-labels.sh).
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

# Check whether a live stamp exists for the given issue+slug.
# Returns 0 if stamp is absent (issue is stuck), 1 if stamp is present (skip).
_has_no_live_stamp() {
	local issue="$1"
	local slug="$2"
	local stamp_dir="${HOME}/.aidevops/.agent-workspace/claim-stamps"

	# Normalise slug: owner/repo → owner-repo for filename matching
	local slug_safe
	slug_safe="${slug//\//-}"

	local stamp_path="${stamp_dir}/${slug_safe}-${issue}.json"

	# If stamp exists, the claim is still live — do NOT release.
	[[ -f "$stamp_path" ]] && return 1

	# No stamp → issue is potentially stuck.
	return 0
}

# Find stuck claims in a given repo.
# Emits NDJSON lines: {"number":N,"title":"...","labels":["..."]}
find_stuck_claims() {
	local repo="$1"
	local current_user="$2"

	local json
	json=$(gh issue list --repo "$repo" \
		--state open \
		--assignee "$current_user" \
		--limit 200 \
		--json number,title,labels,assignees 2>/dev/null) || json="[]"

	# Filter: origin:interactive AND (status:in-review OR status:claimed)
	printf '%s' "$json" | jq -rc --arg user "$current_user" '
		.[]
		| . as $issue
		| [.labels[].name] as $labels
		| select(
			($labels | index("origin:interactive")) != null
			and (
				($labels | index("status:in-review")) != null
				or ($labels | index("status:claimed")) != null
			)
			and (
				[.assignees[].login] | index($user) != null
			)
		)
		| {
			number,
			title: (.title | .[0:80]),
			labels: $labels
		}
	' 2>/dev/null
	return 0
}

release_stuck_claim() {
	local repo="$1"
	local issue_number="$2"
	local title="$3"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf '  DRY-RUN: #%s → release --unassign (%s)\n' "$issue_number" "$title"
		return 0
	fi

	# Use _isc_cmd_release with --unassign (the fix from GH#21057).
	# This clears status:in-review → status:available AND removes self-assignment.
	if _isc_cmd_release --unassign "$issue_number" "$repo"; then
		printf '  RELEASED: #%s → status:available + unassigned (%s)\n' \
			"$issue_number" "$title"
		return 0
	fi
	# _isc_cmd_release is fail-open (exit 0 always), so failure is already
	# logged via _isc_warn. Report here for summary counters.
	printf '  FAILED:   #%s — see warning above (%s)\n' "$issue_number" "$title" >&2
	return 1
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

	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || {
		printf 'ERROR: cannot resolve current gh user (is gh auth valid?)\n' >&2
		exit 1
	}
	[[ -z "$current_user" ]] && {
		printf 'ERROR: gh user is empty\n' >&2
		exit 1
	}

	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf 'DRY-RUN mode (use --apply to release). Scanning for stuck claims...\n'
		printf 'Current user: %s\n\n' "$current_user"
	else
		printf 'APPLY mode. Releasing stuck claims for user: %s\n\n' "$current_user"
	fi

	local repos
	repos=$(list_repos) || exit 1
	[[ -z "$repos" ]] && {
		printf 'No pulse-enabled repos found.\n'
		exit 0
	}

	local total_found=0
	local total_released=0
	local total_failed=0
	local total_skipped=0

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		printf 'Scanning %s...\n' "$repo"

		local issues
		issues=$(find_stuck_claims "$repo" "$current_user")
		if [[ -z "$issues" ]]; then
			printf '  No stuck claims found.\n'
			continue
		fi

		while IFS= read -r issue_json; do
			[[ -z "$issue_json" ]] && continue
			local num title
			num=$(printf '%s' "$issue_json" | jq -r '.number')
			title=$(printf '%s' "$issue_json" | jq -r '.title')

			total_found=$((total_found + 1))

			# Skip if a live stamp exists (claim is active, not stuck).
			if ! _has_no_live_stamp "$num" "$repo"; then
				printf '  SKIP:     #%s — live stamp present, claim is active\n' "$num"
				total_skipped=$((total_skipped + 1))
				continue
			fi

			if release_stuck_claim "$repo" "$num" "$title"; then
				total_released=$((total_released + 1))
			else
				total_failed=$((total_failed + 1))
			fi
		done <<<"$issues"
	done <<<"$repos"

	printf '\nSummary: found=%d released=%d skipped=%d failed=%d\n' \
		"$total_found" "$total_released" "$total_skipped" "$total_failed"

	if [[ "$total_found" -eq 0 ]]; then
		printf 'No stuck claims found.\n'
	fi

	if [[ "$DRY_RUN" -eq 1 && "$total_found" -gt 0 ]]; then
		printf '\nRe-run with --apply to release %d stuck claim(s).\n' \
			"$((total_found - total_skipped))"
	fi

	[[ "$total_failed" -gt 0 ]] && exit 2
	exit 0
}

main "$@"
