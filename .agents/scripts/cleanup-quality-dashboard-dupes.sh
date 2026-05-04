#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# cleanup-quality-dashboard-dupes.sh — ONE-SHOT cleanup for GH#21830
# =============================================================================
# Closes the three duplicate "Code Audit Routines" dashboard issues that
# accumulated due to the fail-open label-search bug (t3074).
#
# Survivor: #21670 (most recent, latest stats)
# Closed:   #2632, #20409, #20845
#
# Usage: bash .agents/scripts/cleanup-quality-dashboard-dupes.sh
#        REPO_SLUG=owner/repo bash .agents/scripts/cleanup-quality-dashboard-dupes.sh
#
# This script is idempotent — re-running it on already-closed issues is safe.
# =============================================================================

set -euo pipefail

REPO_SLUG="${REPO_SLUG:-marcusquinn/aidevops}"
SURVIVOR=21670
# shellcheck disable=SC2206
DUPES=(2632 20409 20845)

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	NC=$'\033[0m'
else
	GREEN="" RED="" NC=""
fi

_close_dupe() {
	local num="$1"
	local repo_slug="$2"
	local survivor="$3"

	# Check current state — skip if already closed
	local state
	state=$(gh issue view "$num" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
	state=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
	if [[ "$state" == "closed" ]]; then
		printf '  %sSKIP%s #%s (already closed)\n' "$GREEN" "$NC" "$num"
		return 0
	fi

	local close_body
	close_body="> Auto-closed: superseded by #${survivor} as duplicate quality dashboard (t3074 one-time cleanup)."
	gh issue comment "$num" --repo "$repo_slug" --body "$close_body" 2>/dev/null || true
	gh issue close "$num" --repo "$repo_slug" 2>/dev/null || {
		printf '  %sFAIL%s #%s — could not close\n' "$RED" "$NC" "$num"
		return 1
	}
	printf '  %sCLOSED%s #%s\n' "$GREEN" "$NC" "$num"
	return 0
}

main() {
	local repo_slug="$1"
	local survivor="$2"
	local failed=0

	printf 'Closing duplicate quality dashboards in %s (survivor: #%s)\n' "$repo_slug" "$survivor"

	local num
	for num in "${DUPES[@]}"; do
		_close_dupe "$num" "$repo_slug" "$survivor" || failed=$((failed + 1))
	done

	if [[ "$failed" -gt 0 ]]; then
		printf '%sFailed to close %d issue(s).%s\n' "$RED" "$failed" "$NC"
		return 1
	fi

	printf '%sDone. %d duplicates closed.%s\n' "$GREEN" "${#DUPES[@]}" "$NC"
	return 0
}

main "$REPO_SLUG" "$SURVIVOR"
