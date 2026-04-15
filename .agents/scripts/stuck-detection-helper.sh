#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stuck-detection-helper.sh - Advisory stuck detection for long-running workers (t1332)
#
# Deterministic utility for milestone tracking and GitHub label management.
# The AI supervisor (pulse.md) handles the reasoning — this script handles
# the mechanical parts: milestone state, label application, label removal.
#
# ADVISORY ONLY — never auto-cancels, auto-pivots, or modifies tasks.
# Label removed on subsequent success.
#
# Inspired by Ouroboros soft self-check at round milestones.
#
# Usage:
#   stuck-detection-helper.sh check-milestone <issue_number> <elapsed_min> [--repo <slug>]
#       Check if a milestone is due. Exit 0 + prints milestone if due, exit 1 if not.
#
#   stuck-detection-helper.sh label-stuck <issue_number> <milestone_min> <elapsed_min> \
#       <confidence> <reasoning> <suggested_actions> [--repo <slug>]
#       Apply stuck-detection label and post advisory comment.
#
#   stuck-detection-helper.sh label-clear <issue_number> [--repo <slug>]
#       Remove stuck-detection label on task success.
#
#   stuck-detection-helper.sh status [--repo <slug>]
#       Show current stuck detection state (which issues are flagged).
#
#   stuck-detection-helper.sh help
#       Show usage.

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

# Configurable milestones (space-separated minutes, ascending order)
STUCK_MILESTONES="${SUPERVISOR_STUCK_CHECK_MINUTES:-30 60 120}"

# Confidence threshold for stuck detection (0.0-1.0)
STUCK_CONFIDENCE_THRESHOLD="${SUPERVISOR_STUCK_CONFIDENCE_THRESHOLD:-0.7}"

# GitHub label for stuck detection
STUCK_LABEL="stuck-detection"
STUCK_LABEL_COLOR="D93F0B"
STUCK_LABEL_DESC="Advisory: AI detected worker may be stuck (t1332)"

# GitHub repo (auto-detected if unset)
SD_REPO="${SUPERVISOR_STUCK_DETECTION_REPO:-}"

# ============================================================
# COLOURS (stderr output)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================
# STATE FILE
# ============================================================

_sd_state_dir() {
	local dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	mkdir -p "$dir" 2>/dev/null || true
	echo "$dir"
	return 0
}

_sd_state_file() {
	echo "$(_sd_state_dir)/stuck-detection.state"
	return 0
}

# ============================================================
# LOGGING
# ============================================================

_sd_log_info() {
	echo -e "${BLUE}[STUCK-DETECTION]${NC} $*" >&2
	return 0
}

_sd_log_warn() {
	echo -e "${YELLOW}[STUCK-DETECTION]${NC} $*" >&2
	return 0
}

_sd_log_error() {
	echo -e "${RED}[STUCK-DETECTION]${NC} $*" >&2
	return 0
}

_sd_log_success() {
	echo -e "${GREEN}[STUCK-DETECTION]${NC} $*" >&2
	return 0
}

# ============================================================
# HELPERS
# ============================================================

_sd_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

_sd_resolve_repo_slug() {
	if [[ -n "$SD_REPO" ]]; then
		echo "$SD_REPO"
		return 0
	fi
	local repo_slug
	repo_slug=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || repo_slug=""
	echo "$repo_slug"
	return 0
}

# ============================================================
# STATE READ/WRITE
# ============================================================

_sd_read_state() {
	local state_file
	state_file=$(_sd_state_file)

	if [[ -f "$state_file" ]]; then
		local content
		content=$(cat "$state_file" 2>/dev/null) || content=""
		if printf '%s' "$content" | jq empty 2>/dev/null; then
			echo "$content"
		else
			_sd_log_warn "corrupted state file, returning defaults"
			echo '{"milestones_checked":{},"labeled_issues":[]}'
		fi
	else
		echo '{"milestones_checked":{},"labeled_issues":[]}'
	fi
	return 0
}

_sd_write_state() {
	local state_json="$1"
	local state_file
	state_file=$(_sd_state_file)

	# Atomic write via temp file + mv
	local tmp_file="${state_file}.tmp.$$"
	if ! printf '%s\n' "$state_json" >"$tmp_file"; then
		_sd_log_warn "failed to write temp state file: $tmp_file"
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
		_sd_log_warn "failed to move temp state to: $state_file"
		rm -f "$tmp_file" 2>/dev/null || true
		return 1
	fi
	return 0
}

# ============================================================
# CORE OPERATIONS
# ============================================================

# Check if a milestone is due for a given issue.
# Prints the milestone value if one is due, empty if not.
# Exit 0 = milestone due, Exit 1 = no milestone due.
cmd_check_milestone() {
	local issue_number="$1"
	local elapsed_min="$2"
	local repo_slug="${3:-}"

	if [[ -z "$issue_number" || -z "$elapsed_min" ]]; then
		_sd_log_error "usage: check-milestone <issue_number> <elapsed_min> [--repo <slug>]"
		return 1
	fi

	# Validate elapsed_min is numeric
	if ! [[ "$elapsed_min" =~ ^[0-9]+$ ]]; then
		_sd_log_error "elapsed_min must be a positive integer, got: $elapsed_min"
		return 1
	fi

	local state
	state=$(_sd_read_state) || {
		_sd_log_warn "failed to read state"
		return 1
	}

	# Build a unique key for this issue
	local issue_key="issue_${issue_number}"
	if [[ -n "$repo_slug" ]]; then
		# Sanitize repo slug for JSON key (replace / with _)
		local safe_slug="${repo_slug//\//_}"
		issue_key="${safe_slug}_issue_${issue_number}"
	fi

	# Find the highest unchecked milestone that has been reached
	local result=""
	for milestone in $STUCK_MILESTONES; do
		if [[ "$elapsed_min" -ge "$milestone" ]]; then
			# Check if this milestone was already checked for this issue
			local already_checked
			already_checked=$(printf '%s' "$state" | jq -r \
				--arg key "$issue_key" \
				--arg ms "$milestone" \
				'.milestones_checked[$key] // [] | map(select(. == ($ms | tonumber))) | length' 2>/dev/null) || already_checked="0"

			if [[ "$already_checked" == "0" ]]; then
				result="$milestone"
			fi
		fi
	done

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi

	return 1
}

# Record that a milestone was checked for an issue.
_sd_record_milestone() {
	local issue_number="$1"
	local milestone="$2"
	local repo_slug="${3:-}"

	local issue_key="issue_${issue_number}"
	if [[ -n "$repo_slug" ]]; then
		local safe_slug="${repo_slug//\//_}"
		issue_key="${safe_slug}_issue_${issue_number}"
	fi

	local state
	state=$(_sd_read_state) || return 1

	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg key "$issue_key" \
		--argjson ms "$milestone" \
		'.milestones_checked[$key] = ((.milestones_checked[$key] // []) + [$ms] | unique)') || {
		_sd_log_warn "failed to update milestone state"
		return 1
	}

	_sd_write_state "$new_state" || return 1
	return 0
}

# Validate arguments and confidence threshold for cmd_label_stuck.
# Returns 0 if valid and above threshold, 1 on error, 2 if below threshold.
# Outputs "above" or "below" to stdout when validation passes.
_sd_validate_stuck_params() {
	local issue_number="$1"
	local milestone_min="$2"
	local elapsed_min="$3"
	local confidence="$4"

	if [[ -z "$issue_number" || -z "$milestone_min" || -z "$elapsed_min" || -z "$confidence" ]]; then
		_sd_log_error "usage: label-stuck <issue_number> <milestone_min> <elapsed_min> <confidence> <reasoning> <suggested_actions> [--repo <slug>]"
		return 1
	fi

	# Validate numeric parameters before any side effects (GitHub ops, state mutations).
	# milestone_min/elapsed_min are integers used in jq --argjson and comment interpolation.
	# confidence is a float used in awk comparison — non-numeric strings cause
	# lexicographic semantics (e.g., "high" >= "0.7" is true).
	if ! [[ "$milestone_min" =~ ^[0-9]+$ ]] || ! [[ "$elapsed_min" =~ ^[0-9]+$ ]]; then
		_sd_log_error "milestone_min and elapsed_min must be positive integers (got milestone=${milestone_min}, elapsed=${elapsed_min})"
		return 1
	fi
	if ! [[ "$confidence" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		_sd_log_error "confidence must be a number, got: ${confidence}"
		return 1
	fi

	if ! [[ "$confidence" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] ||
		! [[ "$STUCK_CONFIDENCE_THRESHOLD" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; then
		_sd_log_error "confidence values must be numeric (got confidence=${confidence}, threshold=${STUCK_CONFIDENCE_THRESHOLD})"
		return 1
	fi

	local above_threshold
	above_threshold=$(awk -v c="$confidence" -v t="$STUCK_CONFIDENCE_THRESHOLD" 'BEGIN { print (c >= t) ? 1 : 0 }') || above_threshold="0"

	if [[ "$above_threshold" -ne 1 ]]; then
		echo "below"
	else
		echo "above"
	fi
	return 0
}

# Ensure gh CLI is available and resolve the repo slug.
# Prints the resolved repo slug to stdout on success.
# Returns 0 on success, 1 on failure.
_sd_ensure_gh_repo() {
	local repo_slug="$1"

	if ! command -v gh &>/dev/null; then
		_sd_log_warn "gh CLI not found, skipping GitHub label"
		return 1
	fi

	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_sd_resolve_repo_slug)
	fi
	if [[ -z "$repo_slug" ]]; then
		_sd_log_warn "could not determine GitHub repository"
		return 1
	fi

	echo "$repo_slug"
	return 0
}

# Create the stuck-detection label (if absent) and apply it to the issue.
# Returns 0 on success, 1 if the label could not be applied.
_sd_apply_stuck_label_gh() {
	local issue_number="$1"
	local repo_slug="$2"

	gh label create "$STUCK_LABEL" --repo "$repo_slug" \
		--color "$STUCK_LABEL_COLOR" \
		--description "$STUCK_LABEL_DESC" \
		--force 2>/dev/null || true

	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "$STUCK_LABEL" || {
		_sd_log_warn "failed to add label to issue #$issue_number"
		return 1
	}
	return 0
}

# Build and post the advisory comment on the issue.
# Prints the ISO timestamp used in the comment to stdout.
# Returns 0 on success, 1 if the comment could not be posted.
_sd_post_stuck_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local milestone_min="$3"
	local elapsed_min="$4"
	local confidence="$5"
	local reasoning="$6"
	local suggested_actions="$7"

	local now
	now=$(_sd_now_iso)

	local comment_body
	comment_body="## Stuck Detection Advisory (t1332)

**Time:** ${now}
**Milestone:** ${milestone_min} min check (worker running for ${elapsed_min} min)
**Confidence:** ${confidence}
**Assessment:** ${reasoning}

### Suggested Actions
${suggested_actions}

---
*This is an advisory notification only. No automated action has been taken. The worker continues running. The \`${STUCK_LABEL}\` label will be automatically removed if the task completes successfully.*"

	local comment_failed=0
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" || {
		_sd_log_warn "failed to comment on issue #$issue_number"
		comment_failed=1
	}

	echo "$now"
	return "$comment_failed"
}

# Record the labeled issue entry in the persistent state file.
_sd_record_labeled_issue_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local now="$3"

	local state
	state=$(_sd_read_state) || state='{"milestones_checked":{},"labeled_issues":[]}'
	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg issue "$issue_number" \
		--arg repo "$repo_slug" \
		--arg now "$now" \
		'.labeled_issues = ((.labeled_issues // []) + [{"issue": $issue, "repo": $repo, "labeled_at": $now}] | unique_by([.issue, .repo]))') || true
	if [[ -n "$new_state" ]]; then
		_sd_write_state "$new_state" || true
	fi
	return 0
}

# Apply stuck-detection label and post advisory comment to a GitHub issue.
# ADVISORY ONLY — does not modify task state, does not kill workers.
cmd_label_stuck() {
	local issue_number="$1"
	local milestone_min="$2"
	local elapsed_min="$3"
	local confidence="$4"
	local reasoning="$5"
	local suggested_actions="$6"
	local repo_slug="${7:-}"

	# Validate args and check confidence threshold
	local threshold_result
	threshold_result=$(_sd_validate_stuck_params "$issue_number" "$milestone_min" "$elapsed_min" "$confidence") || return 1

	if [[ "$threshold_result" == "below" ]]; then
		_sd_log_info "confidence $confidence below threshold $STUCK_CONFIDENCE_THRESHOLD for issue #$issue_number — not labeling"
		_sd_record_milestone "$issue_number" "$milestone_min" "$repo_slug" || true
		return 0
	fi

	# Ensure gh CLI available and repo resolved
	local resolved_repo
	resolved_repo=$(_sd_ensure_gh_repo "$repo_slug") || return 1
	repo_slug="$resolved_repo"

	# Allow tests to skip GitHub operations
	if [[ "${SD_SKIP_GITHUB:-}" == "true" ]]; then
		_sd_log_info "GitHub operations skipped (SD_SKIP_GITHUB=true)"
		_sd_record_milestone "$issue_number" "$milestone_min" "$repo_slug" || true
		return 0
	fi

	# Apply the label
	_sd_apply_stuck_label_gh "$issue_number" "$repo_slug" || return 1

	# Post advisory comment; capture timestamp for state recording
	local now
	now=$(_sd_post_stuck_comment "$issue_number" "$repo_slug" \
		"$milestone_min" "$elapsed_min" "$confidence" "$reasoning" "$suggested_actions")
	local comment_failed=$?

	# Record milestone and labeled issue in state (regardless of comment success,
	# since the label was applied — skipping state would cause re-labeling).
	_sd_record_milestone "$issue_number" "$milestone_min" "$repo_slug" || true
	_sd_record_labeled_issue_state "$issue_number" "$repo_slug" "$now" || true

	_sd_log_warn "labeled issue #$issue_number as stuck (confidence: $confidence, milestone: ${milestone_min}min)"
	return "$comment_failed"
}

# Remove stuck-detection label from a GitHub issue on task success.
cmd_label_clear() {
	local issue_number="$1"
	local repo_slug="${2:-}"

	if [[ -z "$issue_number" ]]; then
		_sd_log_error "usage: label-clear <issue_number> [--repo <slug>]"
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		_sd_log_warn "gh CLI not found"
		return 1
	fi

	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_sd_resolve_repo_slug)
	fi
	if [[ -z "$repo_slug" ]]; then
		_sd_log_warn "could not determine GitHub repository"
		return 1
	fi

	# Allow tests to skip GitHub operations
	if [[ "${SD_SKIP_GITHUB:-}" == "true" ]]; then
		_sd_log_info "GitHub operations skipped (SD_SKIP_GITHUB=true)"
		return 0
	fi

	# Check if the issue actually has the stuck-detection label
	local has_label
	has_label=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq "[.labels[].name] | map(select(. == \"$STUCK_LABEL\")) | length" 2>/dev/null) || has_label="0"

	if [[ "$has_label" == "0" ]]; then
		return 0
	fi

	# Remove the label
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "$STUCK_LABEL" || {
		_sd_log_warn "failed to remove label from issue #$issue_number"
		return 1
	}

	# Post resolution comment
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "Stuck detection resolved: task completed successfully. Removing \`${STUCK_LABEL}\` label." \
		2>/dev/null || true

	# Clean up state
	local state
	state=$(_sd_read_state) || state='{"milestones_checked":{},"labeled_issues":[]}'
	local issue_key="issue_${issue_number}"
	if [[ -n "$repo_slug" ]]; then
		local safe_slug="${repo_slug//\//_}"
		issue_key="${safe_slug}_issue_${issue_number}"
	fi
	local new_state
	new_state=$(printf '%s' "$state" | jq \
		--arg key "$issue_key" \
		--arg issue "$issue_number" \
		--arg repo "$repo_slug" \
		'del(.milestones_checked[$key]) | .labeled_issues = [(.labeled_issues // [])[] | select((.issue != $issue) or (.repo != $repo))]') || true
	if [[ -n "$new_state" ]]; then
		_sd_write_state "$new_state" || true
	fi

	_sd_log_success "removed stuck-detection label from issue #$issue_number"
	return 0
}

# Show current stuck detection state.
cmd_status() {
	local repo_slug="${1:-}"

	local state
	state=$(_sd_read_state) || {
		echo "Stuck Detection Status: unable to read state"
		return 0
	}

	local labeled_count
	labeled_count=$(printf '%s' "$state" | jq '.labeled_issues | length' 2>/dev/null) || labeled_count=0

	local milestones_count
	milestones_count=$(printf '%s' "$state" | jq '.milestones_checked | length' 2>/dev/null) || milestones_count=0

	echo "Stuck Detection Status"
	echo "======================"
	echo "Milestones config:    $STUCK_MILESTONES"
	echo "Confidence threshold: $STUCK_CONFIDENCE_THRESHOLD"
	echo "Issues tracked:       $milestones_count"
	echo "Issues labeled stuck: $labeled_count"
	echo ""

	if [[ "$labeled_count" -gt 0 ]]; then
		echo "Currently labeled issues:"
		printf '%s' "$state" | jq -r '.labeled_issues[] | "  #\(.issue) (\(.repo)) — labeled at \(.labeled_at)"' 2>/dev/null || echo "  (unable to parse)"
	fi

	return 0
}

# ============================================================
# CLI ENTRY POINT
# ============================================================

cmd_help() {
	echo "stuck-detection-helper.sh — Advisory stuck detection for workers (t1332)"
	echo ""
	echo "Usage:"
	echo "  stuck-detection-helper.sh check-milestone <issue> <elapsed_min> [--repo <slug>]"
	echo "      Check if a milestone is due. Exit 0 + prints milestone if due."
	echo ""
	echo "  stuck-detection-helper.sh label-stuck <issue> <milestone_min> <elapsed_min> \\"
	echo "      <confidence> <reasoning> <suggested_actions> [--repo <slug>]"
	echo "      Apply stuck-detection label and post advisory comment."
	echo ""
	echo "  stuck-detection-helper.sh label-clear <issue> [--repo <slug>]"
	echo "      Remove stuck-detection label on task success."
	echo ""
	echo "  stuck-detection-helper.sh status [--repo <slug>]"
	echo "      Show current stuck detection state."
	echo ""
	echo "  stuck-detection-helper.sh help"
	echo "      Show this help."
	echo ""
	echo "Configuration (env vars):"
	echo "  SUPERVISOR_STUCK_CHECK_MINUTES             Milestones (default: '30 60 120')"
	echo "  SUPERVISOR_STUCK_CONFIDENCE_THRESHOLD      Threshold (default: 0.7)"
	echo "  SUPERVISOR_STUCK_DETECTION_REPO            GitHub repo slug (auto-detected)"
	echo "  SUPERVISOR_DIR                             State directory"
	echo "  SD_SKIP_GITHUB                             Skip GitHub ops (for testing)"
	return 0
}

_parse_repo_flag() {
	local repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	echo "$repo"
	return 0
}

main() {
	local action="${1:-help}"
	shift || true

	# Require jq for JSON state management
	if ! command -v jq &>/dev/null; then
		echo "Error: jq is required but not found in PATH" >&2
		return 1
	fi

	case "$action" in
	check-milestone)
		local issue="${1:-}"
		local elapsed="${2:-}"
		shift 2 2>/dev/null || true
		local repo
		repo=$(_parse_repo_flag "$@")
		cmd_check_milestone "$issue" "$elapsed" "$repo"
		;;
	label-stuck)
		local issue="${1:-}"
		local milestone="${2:-}"
		local elapsed="${3:-}"
		local confidence="${4:-}"
		local reasoning="${5:-}"
		local suggested="${6:-}"
		shift 6 2>/dev/null || true
		local repo
		repo=$(_parse_repo_flag "$@")
		cmd_label_stuck "$issue" "$milestone" "$elapsed" "$confidence" "$reasoning" "$suggested" "$repo"
		;;
	label-clear)
		local issue="${1:-}"
		shift 1 2>/dev/null || true
		local repo
		repo=$(_parse_repo_flag "$@")
		cmd_label_clear "$issue" "$repo"
		;;
	status)
		local repo
		repo=$(_parse_repo_flag "$@")
		cmd_status "$repo"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo "Unknown command: $action" >&2
		echo "Run 'stuck-detection-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
