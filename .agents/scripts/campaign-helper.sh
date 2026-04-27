#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# campaign-helper.sh — _campaigns/ plane P6: performance integration + learnings promotion
#
# Manages the post-launch lifecycle of campaigns:
#   - Extends `campaign launch` to create results.md + learnings.md templates
#   - `campaign promote` cross-plane promotion to _performance/ and _knowledge/
#   - `campaign feedback` surfaces _feedback/ insights for campaign research
#
# Usage:
#   campaign-helper.sh launch <id> [--repo <path>]
#       Move _campaigns/active/<id>/ → launched/<id>/, stamp dates,
#       create results.md + learnings.md templates.
#   campaign-helper.sh promote <id> [--results] [--learnings] [--repo <path>]
#       --results    Push metrics to _performance/marketing/<id>.md
#       --learnings  Promote insights to _knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md
#   campaign-helper.sh feedback [<id>] [--repo <path>]
#       Surface _feedback/ insights as campaign research input.
#       If <id> given, writes to _campaigns/active/<id>/research/feedback-insights.md
#   campaign-helper.sh help
#       Show this help.
#
# Prerequisites: _campaigns/ plane (P1), campaign CLI (P2). Graceful error if absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CAMPAIGNS_DIR_NAME="_campaigns"
readonly CAMPAIGNS_ACTIVE_DIR="active"
readonly CAMPAIGNS_LAUNCHED_DIR="launched"
readonly CAMPAIGNS_RESULTS_FILE="results.md"
readonly CAMPAIGNS_LEARNINGS_FILE="learnings.md"

# ---------------------------------------------------------------------------
# Error helpers — centralise repeated messages to satisfy string-literal ratchet
# ---------------------------------------------------------------------------

_err_opt_unknown() {
	local _o="${1:-}"
	print_error "Unknown option: ${_o}"
	return 1
}

_err_results_missing() {
	local results_file="${1:-}"
	print_error "results.md not found — fill it in first: ${results_file}"
	return 1
}

_err_learnings_missing() {
	local learnings_file="${1:-}"
	print_error "learnings.md not found — fill it in first: ${learnings_file}"
	return 1
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_resolve_campaigns_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CAMPAIGNS_DIR_NAME}"
	return 0
}

_require_campaigns_plane() {
	local campaigns_dir="$1"
	if [[ ! -d "$campaigns_dir" ]]; then
		print_error "_campaigns/ plane not found at: ${campaigns_dir}"
		print_error "Run 'aidevops campaign init' first (requires P1 to be deployed)."
		return 1
	fi
	return 0
}

_require_launched_campaign() {
	local campaigns_dir="$1" campaign_id="$2"
	local launched_dir="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}/${campaign_id}"
	if [[ ! -d "$launched_dir" ]]; then
		print_error "Launched campaign not found: ${campaign_id}"
		print_error "Path checked: ${launched_dir}"
		print_error "Run: aidevops campaign launch ${campaign_id}"
		return 1
	fi
	echo "$launched_dir"
	return 0
}

_current_ym() {
	date -u '+%Y-%m'
	return 0
}

_current_date() {
	date -u '+%Y-%m-%d'
	return 0
}

_write_results_fallback() {
	local dest="$1" campaign_id="$2" launched_date="$3"
	cat >"$dest" <<RESULTS
# Campaign Results: ${campaign_id}

**Launched:** ${launched_date}
**Status:** in-progress

## Metrics

| Metric | Value |
|--------|-------|
| Impressions | |
| Clicks | |
| CTR (%) | |
| Conversions | |
| Cost | |
| Revenue / Value | |
| ROI | |

## Channel Breakdown

| Channel | Impressions | Clicks | Conversions | Cost |
|---------|-------------|--------|-------------|------|
| | | | | |

## Audience Highlights

<!-- Key audience segments that over- or under-performed expectations. -->

## Summary

<!-- Brief narrative of the campaign performance. What happened, what mattered. -->

---

_Promote with: \`aidevops campaign promote ${campaign_id} --results\`_
RESULTS
	return 0
}

_write_learnings_fallback() {
	local dest="$1" campaign_id="$2" launched_date="$3"
	cat >"$dest" <<LEARNINGS
# Campaign Learnings: ${campaign_id}

**Launched:** ${launched_date}
**Reviewed:** 

## What Worked

<!-- Creative, targeting, or channel elements that performed well. -->

## What Didn't Work

<!-- Underperformers and their likely root causes. -->

## Audience Insights

<!-- Unexpected audience segments, behaviours, or engagement patterns. -->

## Channel Insights

<!-- Platform-specific observations: algorithmic changes, creative fatigue, format preferences. -->

## Recommendations for Next Campaign

1. 
2. 
3. 

## Open Questions

<!-- Hypotheses needing more data. Experiments to run next time. -->

---

_Promote with: \`aidevops campaign promote ${campaign_id} --learnings\`_
LEARNINGS
	return 0
}

# ---------------------------------------------------------------------------
# cmd_launch — move active/<id> → launched/<id>, stamp, create templates
# ---------------------------------------------------------------------------

cmd_launch() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign launch <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local active_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	if [[ ! -d "$active_dir" ]]; then
		print_error "Active campaign not found: ${campaign_id}"
		print_error "Path checked: ${active_dir}"
		return 1
	fi

	local launched_base="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}"
	mkdir -p "$launched_base"
	local launched_dir="${launched_base}/${campaign_id}"

	if [[ -d "$launched_dir" ]]; then
		print_error "Campaign already launched: ${campaign_id}"
		print_error "Launched path exists: ${launched_dir}"
		return 1
	fi

	local launch_date
	launch_date="$(_current_date)"

	# Move active → launched (git-aware)
	if command -v git >/dev/null 2>&1 && git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" mv "$active_dir" "$launched_dir" 2>/dev/null || mv "$active_dir" "$launched_dir"
	else
		mv "$active_dir" "$launched_dir"
	fi

	# Create results.md and learnings.md templates (P6 deliverable)
	local results_file="${launched_dir}/${CAMPAIGNS_RESULTS_FILE}"
	local learnings_file="${launched_dir}/${CAMPAIGNS_LEARNINGS_FILE}"

	[[ ! -f "$results_file" ]] && _write_results_fallback "$results_file" "$campaign_id" "$launch_date"
	[[ ! -f "$learnings_file" ]] && _write_learnings_fallback "$learnings_file" "$campaign_id" "$launch_date"

	print_success "Campaign launched: ${campaign_id}"
	echo "  Launched path:   ${launched_dir}"
	echo "  Results:         ${results_file}"
	echo "  Learnings:       ${learnings_file}"
	echo ""
	echo "Next steps:"
	echo "  1. Fill in ${CAMPAIGNS_RESULTS_FILE} with post-launch metrics"
	echo "  2. Run: aidevops campaign promote ${campaign_id} --results"
	echo "  3. Fill in ${CAMPAIGNS_LEARNINGS_FILE} with retrospective insights"
	echo "  4. Run: aidevops campaign promote ${campaign_id} --learnings"
	return 0
}

# ---------------------------------------------------------------------------
# Promote sub-helpers — cross-plane write functions
# ---------------------------------------------------------------------------

_promote_results() {
	local launched_dir="$1" campaign_id="$2" repo_path="$3"
	local results_file="${launched_dir}/${CAMPAIGNS_RESULTS_FILE}"
	[[ ! -f "$results_file" ]] && { _err_results_missing "$results_file"; return 1; }

	local perf_dir="${repo_path}/_performance/marketing"
	mkdir -p "$perf_dir"
	local dest="${perf_dir}/${campaign_id}.md"
	cp "$results_file" "$dest"
	print_success "Promoted results to: ${dest}"
	return 0
}

_promote_learnings() {
	local launched_dir="$1" campaign_id="$2" repo_path="$3"
	local learnings_file="${launched_dir}/${CAMPAIGNS_LEARNINGS_FILE}"
	[[ ! -f "$learnings_file" ]] && { _err_learnings_missing "$learnings_file"; return 1; }

	local ym
	ym="$(_current_ym)"
	local insights_dir="${repo_path}/_knowledge/insights/marketing/${ym}"
	mkdir -p "$insights_dir"
	local dest="${insights_dir}/${campaign_id}-learnings.md"
	cp "$learnings_file" "$dest"
	print_success "Promoted learnings to: ${dest}"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_promote — cross-plane promotion dispatcher
# ---------------------------------------------------------------------------

cmd_promote() {
	local campaign_id='' repo_path='' do_results=false do_learnings=false

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--results) do_results=true; shift ;;
		--learnings) do_learnings=true; shift ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	if [[ -z "$campaign_id" ]]; then
		print_error "Usage: campaign promote <id> [--results] [--learnings]"
		return 1
	fi
	if [[ "$do_results" == false && "$do_learnings" == false ]]; then
		print_error "Specify at least one of: --results, --learnings"
		return 1
	fi
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local launched_dir
	launched_dir="$(_require_launched_campaign "$campaigns_dir" "$campaign_id")" || return 1

	local exit_code=0
	[[ "$do_results" == true ]] && { _promote_results "$launched_dir" "$campaign_id" "$repo_path" || exit_code=1; }
	[[ "$do_learnings" == true ]] && { _promote_learnings "$launched_dir" "$campaign_id" "$repo_path" || exit_code=1; }
	return "$exit_code"
}

# ---------------------------------------------------------------------------
# cmd_feedback — surface _feedback/ insights for campaign research
# ---------------------------------------------------------------------------

cmd_feedback() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local feedback_dir="${repo_path}/_feedback"
	if [[ ! -d "$feedback_dir" ]]; then
		print_warning "_feedback/ plane not found at: ${feedback_dir}"
		print_warning "No feedback insights available. Provision _feedback/ first."
		return 0
	fi

	local insights_count=0
	local insight_files=()
	while IFS= read -r -d '' f; do
		insight_files+=("$f")
		insights_count=$((insights_count + 1))
	done < <(find "$feedback_dir" -name "*.md" -print0 2>/dev/null || true)

	if [[ $insights_count -eq 0 ]]; then
		print_info "No feedback insights found in: ${feedback_dir}"
		return 0
	fi

	print_info "Found ${insights_count} feedback file(s) in _feedback/"

	if [[ -z "$campaign_id" ]]; then
		print_info "Feedback files:"
		for f in "${insight_files[@]}"; do
			echo "  ${f#"$repo_path"/}"
		done
		echo ""
		echo "Import into a campaign: aidevops campaign feedback <id>"
		return 0
	fi

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	local active_campaign_dir="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}/${campaign_id}"
	if [[ ! -d "$active_campaign_dir" ]]; then
		print_error "Active campaign not found: ${campaign_id}"
		return 1
	fi

	local research_dir="${active_campaign_dir}/research"
	mkdir -p "$research_dir"
	local dest="${research_dir}/feedback-insights.md"
	{
		printf "# Feedback Insights for Campaign: %s\n\n" "$campaign_id"
		printf "_Collected from _feedback/ on %s_\n\n" "$(_current_date)"
		printf "## Sources\n\n"
		for f in "${insight_files[@]}"; do
			printf "- %s\n" "${f#"$repo_path"/}"
		done
		printf "\n## Content\n\n"
		for f in "${insight_files[@]}"; do
			printf "### %s\n\n" "$(basename "$f")"
			cat "$f"
			printf "\n\n"
		done
	} >"$dest"
	print_success "Feedback insights written to: ${dest}"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	cat <<HELP
campaign-helper.sh — _campaigns/ plane P6: performance integration + learnings promotion

Commands:
  launch <id> [--repo <path>]
      Move _campaigns/active/<id>/ → launched/<id>/
      Creates results.md + learnings.md templates for post-launch tracking.

  promote <id> [--results] [--learnings] [--repo <path>]
      --results    Push launched/<id>/results.md to _performance/marketing/<id>.md
      --learnings  Push launched/<id>/learnings.md to
                   _knowledge/insights/marketing/<YYYY-MM>/<id>-learnings.md

  feedback [<id>] [--repo <path>]
      Surface _feedback/ insights as campaign research input.
      If <id> given, writes aggregated insights to
      _campaigns/active/<id>/research/feedback-insights.md

  help   Show this help.

Examples:
  campaign-helper.sh launch q2-brand-awareness
  campaign-helper.sh promote q2-brand-awareness --results --learnings
  campaign-helper.sh feedback q2-brand-awareness

Prerequisites:
  _campaigns/ plane (P1 — aidevops t2962 #21250)
  Campaign CLI surface (P2 — aidevops t2963 #21251)
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	launch) cmd_launch "$@" ;;
	promote) cmd_promote "$@" ;;
	feedback) cmd_feedback "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
