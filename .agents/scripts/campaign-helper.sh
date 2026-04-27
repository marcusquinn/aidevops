#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# campaign-helper.sh — _campaigns/ plane CLI surface (P2) + performance/learnings (P6)
#
# P2 commands (campaign lifecycle management):
#   campaign-helper.sh new <name> [--channel <ch>] [--repo <path>]
#       Scaffold _campaigns/active/<id>/ with brief.md + research/ + creative/
#       Campaign IDs auto-provisioned via sequential .campaign-counter (c001, c002, ...).
#   campaign-helper.sh list [--repo <path>]
#       Show all campaigns across active/, launched/, archive/ with status.
#   campaign-helper.sh status <id> [--repo <path>]
#       Detailed dossier for a campaign (brief + file inventory + lifecycle state).
#   campaign-helper.sh archive <id> [--repo <path>]
#       Move _campaigns/launched/<id>/ → archive/<id>/
#
# P6 commands (post-launch cross-plane integration):
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
# Prerequisites: _campaigns/ plane (P1 — t2962 #21250). Graceful error if absent.

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
readonly CAMPAIGNS_ARCHIVE_DIR="archive"
readonly CAMPAIGNS_COUNTER_FILE=".campaign-counter"
readonly CAMPAIGNS_BRIEF_FILE="brief.md"
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

# Slugify a human name into a lowercase-hyphen slug (ASCII-safe, no jq needed)
_slugify() {
	local input="${1:-}"
	# lowercase, replace non-alphanumeric runs with hyphens, strip leading/trailing hyphens
	local slug
	slug="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
	echo "$slug"
	return 0
}

# Allocate the next campaign ID from .campaign-counter (c001, c002, ...)
# Writes the incremented counter back. Creates the counter file at 0 if absent.
_next_campaign_id() {
	local campaigns_dir="$1"
	local counter_file="${campaigns_dir}/${CAMPAIGNS_COUNTER_FILE}"
	local current=0
	if [[ -f "$counter_file" ]]; then
		current="$(cat "$counter_file" 2>/dev/null || echo "0")"
		[[ "$current" =~ ^[0-9]+$ ]] || current=0
	fi
	local next=$(( current + 1 ))
	printf '%d' "$next" > "$counter_file"
	printf 'c%03d' "$next"
	return 0
}

# Write brief.md for a new campaign
_write_campaign_brief() {
	local dest="$1" campaign_id="$2" name="$3" channel="${4:-}" created="$5"
	cat >"$dest" <<BRIEF
# Campaign Brief: ${name}

**ID:** ${campaign_id}
**Name:** ${name}
**Channel:** ${channel:-unset}
**Created:** ${created}
**Status:** active

## Goal

<!-- What does this campaign aim to achieve? Be specific: metric, target, timeline. -->

## Audience

<!-- Who are we reaching? Demographics, psychographics, pain points, platform. -->

## Message

<!-- Core message. What do we want them to feel / do? -->

## Creative Direction

<!-- Visual style, tone, format requirements, brand constraints. -->

## Distribution Plan

<!-- Channels, scheduling, budget allocation, posting cadence. -->

## Success Criteria

<!-- How will we know it worked? Metrics, thresholds, timeframes. -->

---

_Next: fill in sections above, then run: \`aidevops campaign status ${campaign_id}\`_
_To launch: \`aidevops campaign launch ${campaign_id}\`_
BRIEF
	return 0
}

# ---------------------------------------------------------------------------
# cmd_new — scaffold active/<id>/ directory + brief.md
# ---------------------------------------------------------------------------

cmd_new() {
	local name='' channel='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--channel) channel="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) name="$_cur"; shift ;;
		esac
	done

	[[ -z "$name" ]] && { print_error "Usage: campaign new <name> [--channel <ch>]"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local active_base="${campaigns_dir}/${CAMPAIGNS_ACTIVE_DIR}"
	mkdir -p "$active_base"

	local slug
	slug="$(_slugify "$name")"
	local campaign_id
	campaign_id="$(_next_campaign_id "$campaigns_dir")"
	local dir_name="${campaign_id}-${slug}"
	local campaign_dir="${active_base}/${dir_name}"

	if [[ -d "$campaign_dir" ]]; then
		print_error "Campaign directory already exists: ${campaign_dir}"
		return 1
	fi

	mkdir -p "${campaign_dir}/research"
	mkdir -p "${campaign_dir}/creative"
	[[ -n "$channel" ]] && mkdir -p "${campaign_dir}/distribution/${channel}"

	local created
	created="$(_current_date)"
	_write_campaign_brief "${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}" "$dir_name" "$name" "$channel" "$created"

	print_success "Campaign created: ${dir_name}"
	echo "  Path:    ${campaign_dir}"
	echo "  Brief:   ${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	echo "  Channel: ${channel:-unset}"
	echo ""
	echo "Next steps:"
	echo "  1. Edit brief:   ${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	echo "  2. Status:       aidevops campaign status ${dir_name}"
	echo "  3. Launch:       aidevops campaign launch ${dir_name}"
	return 0
}

# ---------------------------------------------------------------------------
# _list_campaigns_in — enumerate campaigns in a phase directory
# ---------------------------------------------------------------------------

_list_campaigns_in() {
	local campaigns_dir="$1" phase="$2"
	local phase_dir="${campaigns_dir}/${phase}"
	[[ ! -d "$phase_dir" ]] && return 0

	local found=false
	local item
	for item in "${phase_dir}"/*/; do
		[[ -d "$item" ]] || continue
		found=true
		local id
		id="$(basename "$item")"
		local brief_file="${item}${CAMPAIGNS_BRIEF_FILE}"
		local channel='' created=''
		if [[ -f "$brief_file" ]]; then
			channel="$(grep -m1 '^\*\*Channel:\*\*' "$brief_file" 2>/dev/null | sed 's/\*\*Channel:\*\* *//' || true)"
			created="$(grep -m1 '^\*\*Created:\*\*' "$brief_file" 2>/dev/null | sed 's/\*\*Created:\*\* *//' || true)"
		fi
		printf '  %-10s  %-32s  %-14s  %s\n' "[$phase]" "$id" "${channel:-—}" "${created:-—}"
	done
	[[ "$found" == false ]] && return 0
	return 0
}

# ---------------------------------------------------------------------------
# cmd_list — show all campaigns across phases
# ---------------------------------------------------------------------------

cmd_list() {
	local repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) shift ;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	printf '  %-10s  %-32s  %-14s  %s\n' "Phase" "ID" "Channel" "Created"
	printf '  %s\n' "-----------------------------------------------------------------------"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_ACTIVE_DIR"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_LAUNCHED_DIR"
	_list_campaigns_in "$campaigns_dir" "$CAMPAIGNS_ARCHIVE_DIR"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_status — detailed dossier for a single campaign
# ---------------------------------------------------------------------------

cmd_status() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign status <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	# Locate the campaign across all phases
	local campaign_dir='' phase=''
	local p
	for p in "$CAMPAIGNS_ACTIVE_DIR" "$CAMPAIGNS_LAUNCHED_DIR" "$CAMPAIGNS_ARCHIVE_DIR"; do
		local candidate="${campaigns_dir}/${p}/${campaign_id}"
		if [[ -d "$candidate" ]]; then
			campaign_dir="$candidate"
			phase="$p"
			break
		fi
	done

	if [[ -z "$campaign_dir" ]]; then
		print_error "Campaign not found: ${campaign_id}"
		print_error "Searched: active/, launched/, archive/"
		return 1
	fi

	print_info "Campaign: ${campaign_id}  [${phase}]"
	echo "  Path: ${campaign_dir}"
	echo ""

	local brief_file="${campaign_dir}/${CAMPAIGNS_BRIEF_FILE}"
	if [[ -f "$brief_file" ]]; then
		echo "--- Brief ---"
		cat "$brief_file"
		echo ""
	fi

	echo "--- Files ---"
	find "$campaign_dir" -type f | sort | while read -r f; do
		echo "  ${f#"$campaign_dir"/}"
	done
	return 0
}

# ---------------------------------------------------------------------------
# cmd_archive — move launched/<id> → archive/<id>
# ---------------------------------------------------------------------------

cmd_archive() {
	local campaign_id='' repo_path=''

	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo) repo_path="$_nxt"; shift 2 ;;
		-*) _err_opt_unknown "$_cur"; return 1 ;;
		*) campaign_id="$_cur"; shift ;;
		esac
	done

	[[ -z "$campaign_id" ]] && { print_error "Usage: campaign archive <id>"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"

	local campaigns_dir
	campaigns_dir="$(_resolve_campaigns_dir "$repo_path")"
	_require_campaigns_plane "$campaigns_dir" || return 1

	local launched_dir="${campaigns_dir}/${CAMPAIGNS_LAUNCHED_DIR}/${campaign_id}"
	if [[ ! -d "$launched_dir" ]]; then
		print_error "Launched campaign not found: ${campaign_id}"
		print_error "Path checked: ${launched_dir}"
		print_error "Only launched campaigns can be archived."
		return 1
	fi

	local archive_base="${campaigns_dir}/${CAMPAIGNS_ARCHIVE_DIR}"
	mkdir -p "$archive_base"
	local archive_dir="${archive_base}/${campaign_id}"

	if [[ -d "$archive_dir" ]]; then
		print_error "Campaign already archived: ${campaign_id}"
		print_error "Archived path exists: ${archive_dir}"
		return 1
	fi

	local archived_date
	archived_date="$(_current_date)"

	# Move launched → archive (git-aware)
	if command -v git >/dev/null 2>&1 && git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" mv "$launched_dir" "$archive_dir" 2>/dev/null || mv "$launched_dir" "$archive_dir"
	else
		mv "$launched_dir" "$archive_dir"
	fi

	# Stamp archived date
	printf '%s\n' "$archived_date" > "${archive_dir}/archived.stamp"

	print_success "Campaign archived: ${campaign_id}"
	echo "  Archive path: ${archive_dir}"
	echo "  Archived:     ${archived_date}"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_launch — move active/<id> → launched/<id>, stamp, create templates
# ---------------------------------------------------------------------------

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

	# Stamp launch date
	printf '%s\n' "$launch_date" > "${launched_dir}/launched.stamp"

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
campaign-helper.sh — _campaigns/ plane CLI (P2) + performance integration (P6)

P2 Commands (lifecycle management):
  new <name> [--channel <ch>] [--repo <path>]
      Scaffold _campaigns/active/<id>/ with brief.md + research/ + creative/.
      Campaign ID auto-provisioned (c001, c002, ...) from .campaign-counter.

  list [--repo <path>]
      Show all campaigns across active/, launched/, archive/ with status.

  status <id> [--repo <path>]
      Detailed dossier: brief, file inventory, lifecycle state.

  archive <id> [--repo <path>]
      Move _campaigns/launched/<id>/ → archive/<id>/.

P6 Commands (post-launch cross-plane):
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
  campaign-helper.sh new "Q2 Brand Awareness" --channel paid-social
  campaign-helper.sh list
  campaign-helper.sh status c001-q2-brand-awareness
  campaign-helper.sh launch c001-q2-brand-awareness
  campaign-helper.sh promote c001-q2-brand-awareness --results --learnings
  campaign-helper.sh archive c001-q2-brand-awareness

Prerequisites:
  _campaigns/ plane (P1 — aidevops t2962 #21250)
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
	new) cmd_new "$@" ;;
	list | ls) cmd_list "$@" ;;
	status | show) cmd_status "$@" ;;
	archive) cmd_archive "$@" ;;
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
