#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Quality Sweep Coverage -- Bot Review Coverage and Badge Indicator
# =============================================================================
# Bot review coverage tracking and quality badge indicator functions extracted
# from stats-quality-sweep.sh to keep the orchestrator under the 2000-line
# file-size-debt threshold (GH#21422).
#
# Covers:
#   1. _check_pr_bot_coverage  -- iterate open PRs and accumulate review counts
#   2. _compute_bot_coverage   -- gather open PR list and build coverage section
#   3. _compute_badge_indicator -- map gate_status + qlty_grade to badge string
#
# Usage: source "${SCRIPT_DIR}/stats-quality-sweep-coverage.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - review-bot-gate-helper.sh (optional, for bot coverage tracking)
#   - LOGFILE, SCRIPT_DIR globals set by caller
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_QUALITY_SWEEP_COVERAGE_LOADED:-}" ]] && return 0
_STATS_QUALITY_SWEEP_COVERAGE_LOADED=1

# Defensive SCRIPT_DIR fallback — avoids external binary dependency
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Compute bot review coverage stats for open PRs.
#
# Arguments:
#   $1 - repo slug
# Output: bot_coverage_section markdown to stdout
#######################################
#######################################
# Check bot review status for each open PR and accumulate counts.
#
# Arguments:
#   $1 - pr_objects (newline-delimited compact JSON objects)
#   $2 - repo_slug
#   $3 - review_helper path
# Output: "prs_with_reviews|prs_waiting|prs_stale_waiting"
#######################################
_check_pr_bot_coverage() {
	local pr_objects="$1"
	local repo_slug="$2"
	local review_helper="$3"

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""

	while IFS= read -r pr_obj; do
		[[ -z "$pr_obj" ]] && continue
		local pr_num
		pr_num=$(echo "$pr_obj" | jq -r '.number')
		[[ -z "$pr_num" || "$pr_num" == "null" ]] && continue
		local gate_result
		gate_result=$("$review_helper" check "$pr_num" "$repo_slug" 2>>"$LOGFILE" || echo "UNKNOWN")
		case "$gate_result" in
		PASS*)
			prs_with_reviews=$((prs_with_reviews + 1))
			;;
		WAITING* | UNKNOWN*)
			prs_waiting=$((prs_waiting + 1))
			# Check if PR is older than 2 hours (stale waiting).
			local pr_created
			pr_created=$(echo "$pr_obj" | jq -r '.createdAt // empty')
			if [[ -n "$pr_created" ]]; then
				local pr_epoch
				pr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_created" +%s 2>/dev/null || date -d "$pr_created" +%s 2>/dev/null || echo "0")
				[[ "$pr_epoch" =~ ^[0-9]+$ ]] || pr_epoch=0
				if [[ "$pr_epoch" -gt 0 ]]; then
					local now_epoch
					now_epoch=$(date +%s)
					local pr_age_hours=$(((now_epoch - pr_epoch) / 3600))
					if [[ "$pr_age_hours" -ge 2 ]]; then
						local pr_title
						pr_title=$(echo "$pr_obj" | jq -r '.title[:50] // empty')
						pr_title=$(_sanitize_markdown "$pr_title")
						prs_stale_waiting="${prs_stale_waiting}  - #${pr_num}: ${pr_title} (${pr_age_hours}h old)
"
					fi
				fi
			fi
			;;
		SKIP*)
			prs_with_reviews=$((prs_with_reviews + 1))
			;;
		esac
	done <<<"$pr_objects"

	printf '%s|%s|%s' "$prs_with_reviews" "$prs_waiting" "$prs_stale_waiting"
	return 0
}

_compute_bot_coverage() {
	local repo_slug="$1"

	local open_prs_json
	open_prs_json=$(gh pr list --repo "$repo_slug" --state open \
		--limit 1000 --json number,title,createdAt 2>>"$LOGFILE") || open_prs_json="[]"
	local open_pr_count
	open_pr_count=$(echo "$open_prs_json" | jq 'length' || echo "0")
	[[ "$open_pr_count" =~ ^[0-9]+$ ]] || open_pr_count=0

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""
	local review_helper="${SCRIPT_DIR}/review-bot-gate-helper.sh"

	local helper_available=false
	if [[ "$open_pr_count" -gt 0 && -x "$review_helper" ]]; then
		helper_available=true
	fi

	if [[ "$helper_available" == true ]]; then
		# Parse open_prs_json once into per-PR objects to avoid re-parsing the
		# full JSON array on every iteration (Gemini review feedback — GH#3153).
		local pr_objects
		pr_objects=$(echo "$open_prs_json" | jq -c '.[]')
		local coverage_raw
		coverage_raw=$(_check_pr_bot_coverage "$pr_objects" "$repo_slug" "$review_helper")
		prs_with_reviews="${coverage_raw%%|*}"
		local cov_remainder="${coverage_raw#*|}"
		prs_waiting="${cov_remainder%%|*}"
		prs_stale_waiting="${cov_remainder#*|}"
	fi

	# Build bot coverage section — show N/A when helper is unavailable
	# to avoid misleading zero counts (CodeRabbit review feedback)
	local bot_coverage_section=""
	if [[ "$helper_available" == true ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | ${prs_with_reviews} |
| Awaiting bot review | ${prs_waiting} |
"
	elif [[ "$open_pr_count" -gt 0 ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | N/A |
| Awaiting bot review | N/A |

_review-bot-gate-helper.sh not available — install to enable bot coverage tracking._
"
	else
		bot_coverage_section="### Bot Review Coverage

_No open PRs._
"
	fi

	if [[ -n "$prs_stale_waiting" ]]; then
		bot_coverage_section="${bot_coverage_section}
**PRs waiting >2h for bot review (may need re-trigger):**
${prs_stale_waiting}"
	fi

	printf '%s' "$bot_coverage_section"
	return 0
}

#######################################
# Compute badge status indicator from gate status and Qlty grade.
#
# Arguments:
#   $1 - gate_status (OK/ERROR/WARN/UNKNOWN)
#   $2 - qlty_grade (A/B/C/D/F/UNKNOWN)
# Output: badge_indicator string to stdout
#######################################
_compute_badge_indicator() {
	local gate_status="$1"
	local qlty_grade="$2"

	local sonar_badge="UNKNOWN"
	case "$gate_status" in
	OK) sonar_badge="GREEN" ;;
	ERROR) sonar_badge="RED" ;;
	WARN) sonar_badge="YELLOW" ;;
	esac

	local qlty_badge="UNKNOWN"
	case "$qlty_grade" in
	A) qlty_badge="GREEN" ;;
	B) qlty_badge="GREEN" ;;
	C) qlty_badge="YELLOW" ;;
	D) qlty_badge="RED" ;;
	F) qlty_badge="RED" ;;
	esac

	local badge_indicator="UNKNOWN"
	if [[ "$sonar_badge" == "GREEN" && "$qlty_badge" == "GREEN" ]]; then
		badge_indicator="GREEN (all badges passing)"
	elif [[ "$sonar_badge" == "RED" || "$qlty_badge" == "RED" ]]; then
		local failing=""
		[[ "$sonar_badge" == "RED" ]] && failing="SonarCloud"
		[[ "$qlty_badge" == "RED" ]] && failing="${failing:+$failing + }Qlty"
		badge_indicator="RED (${failing} failing)"
	elif [[ "$sonar_badge" == "YELLOW" || "$qlty_badge" == "YELLOW" ]]; then
		local warning=""
		[[ "$sonar_badge" == "YELLOW" ]] && warning="SonarCloud"
		[[ "$qlty_badge" == "YELLOW" ]] && warning="${warning:+$warning + }Qlty"
		badge_indicator="YELLOW (${warning} needs improvement)"
	fi

	printf '%s' "$badge_indicator"
	return 0
}
