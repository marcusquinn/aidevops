#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Evidence -- fresh, exact remote lifecycle evidence
# =============================================================================
# Shared sub-library for full-loop-helper-state.sh and full-loop-helper-merge.sh.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-evidence.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_EVIDENCE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_EVIDENCE_LIB_LOADED=1

# Read complete merged-PR evidence through bounded, cache-disabled requests.
# Stdout: validated PR JSON with state, mergedAt, and mergeCommit.
_full_loop_read_fresh_merged_pr_json() {
	local pr_number="$1"
	local repo="$2"
	local max_attempts="${FULL_LOOP_MERGED_EVIDENCE_ATTEMPTS:-4}"
	local retry_delay="${FULL_LOOP_MERGED_EVIDENCE_DELAY_SECONDS:-2}"
	local attempt=1
	local pr_json=""

	[[ "$pr_number" =~ ^[0-9]+$ && "$repo" == */* ]] || return 1
	[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=4
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=2

	while [[ "$attempt" -le "$max_attempts" ]]; do
		if pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo" \
			--json state,mergedAt,mergeCommit 2>/dev/null) &&
			printf '%s' "$pr_json" | jq -e '
				def present: ((. // "") | length > 0);
				(.state == "MERGED")
				and (.mergedAt | present)
				and (.mergeCommit | type == "object" and (.oid | present))
			' >/dev/null; then
			printf '%s\n' "$pr_json"
			return 0
		fi
		[[ "$attempt" -lt "$max_attempts" && "$retry_delay" -gt 0 ]] && sleep "$retry_delay"
		attempt=$((attempt + 1))
	done

	return 1
}
