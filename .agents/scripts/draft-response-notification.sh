#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# draft-response-notification.sh -- Notification Repo and Bot Filtering
# =============================================================================
# Handles creation and management of the private draft-responses GitHub repo
# used to notify the user about pending draft replies. Also provides bot-account
# filtering used by the approval and draft-creation flows.
#
# Covered functions:
#   - Prerequisites checking and draft directory setup
#   - GitHub username and draft repo slug resolution
#   - Draft repo creation and subscription (idempotent)
#   - Notification issue creation and body building
#   - Notification issue body update (draft section replacement)
#   - Bot account detection (_is_bot_account)
#
# Usage: source "${SCRIPT_DIR}/draft-response-notification.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - shared-gh-wrappers.sh (gh_create_issue, gh_issue_edit_safe, gh_issue_comment)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DRAFT_RESPONSE_NOTIFICATION_LOADED:-}" ]] && return 0
_DRAFT_RESPONSE_NOTIFICATION_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Prerequisites and storage setup
# =============================================================================

_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}" >&2
		return 1
	fi
	return 0
}

_ensure_draft_dir() {
	mkdir -p "$DRAFT_DIR" 2>/dev/null || true
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
	return 0
}

_get_username() {
	gh api user --jq '.login' 2>/dev/null
}

_get_draft_repo_slug() {
	local username
	username=$(_get_username)
	echo "${username}/${DRAFT_REPO_NAME}"
	return 0
}

# Ensure the private draft-responses repo exists. Idempotent.
_ensure_draft_repo() {
	local slug
	slug=$(_get_draft_repo_slug)
	if gh repo view "$slug" --json name &>/dev/null 2>&1; then
		return 0
	fi
	_log_info "Creating private repo: ${slug}"
	gh repo create "$DRAFT_REPO_NAME" --private \
		--description "Private draft responses for external contribution replies (managed by aidevops)" \
		--clone=false >/dev/null 2>&1 || {
		_log_error "Failed to create repo: ${slug}"
		return 1
	}
	gh label create "draft" --repo "$slug" --description "Pending draft response" --color "FBCA04" 2>/dev/null || true
	gh label create "approved" --repo "$slug" --description "Approved and posted" --color "0E8A16" 2>/dev/null || true
	gh label create "declined" --repo "$slug" --description "Declined" --color "B60205" 2>/dev/null || true

	# Watch the repo so issue creation triggers GitHub notifications
	local gh_output
	if ! gh_output=$(gh api "repos/${slug}/subscription" --method PUT \
		--input - <<<'{"subscribed":true,"ignored":false}' 2>&1); then
		_log_warn "Failed to subscribe to repository ${slug} for notifications: ${gh_output}"
	fi

	_log_info "Created private repo: ${slug}"
	return 0
}

# =============================================================================
# Notification issue body building
# =============================================================================

# Build the issue body for a notification issue.
# All external refs MUST be in inline code backticks to prevent cross-references.
# Layout: draft reply first, then context and instructions.
_build_notification_issue_body() {
	local item_key="$1"
	local item_type="$2"
	local role="$3"
	local latest_author="$4"
	local latest_comment="$5"
	local scan_result="$6"
	local draft_id="$7"
	local draft_text="${8:-}"

	local issue_body=""

	if [[ "$scan_result" == "flagged" ]]; then
		issue_body+="> **WARNING: Prompt injection patterns detected in the external comment. Review carefully.**"
		issue_body+=$'\n\n'
	fi

	issue_body+="## Draft Reply"
	issue_body+=$'\n\n'
	if [[ -n "$draft_text" ]]; then
		issue_body+="${draft_text}"
	else
		issue_body+="*Draft pending — will be composed shortly.*"
	fi
	issue_body+=$'\n\n'
	issue_body+="---"
	issue_body+=$'\n\n'

	issue_body+="<details><summary>Context</summary>"
	issue_body+=$'\n\n'
	issue_body+="| Field | Value |"
	issue_body+=$'\n'
	issue_body+="| --- | --- |"
	issue_body+=$'\n'
	# Build full URL in a code block — prevents cross-reference while being copyable
	local _source_url="https://github.com/${item_key%#*}/issues/${item_key##*#}"
	issue_body+="| Source | \`${_source_url}\` |"
	issue_body+=$'\n'
	issue_body+="| Type | ${item_type} |"
	issue_body+=$'\n'
	issue_body+="| Role | ${role} |"
	issue_body+=$'\n'
	issue_body+="| Latest by | ${latest_author} |"
	issue_body+=$'\n'
	issue_body+="| Draft ID | \`${draft_id}\` |"
	issue_body+=$'\n\n'
	issue_body+="### Their comment"
	issue_body+=$'\n\n'
	issue_body+="${latest_comment}"
	issue_body+=$'\n\n'
	issue_body+="</details>"
	issue_body+=$'\n\n'

	issue_body+="<details><summary>How to respond</summary>"
	issue_body+=$'\n\n'
	issue_body+="Comment on this issue with what you'd like to do — your comment will be interpreted by the AI agent and acted on accordingly."
	issue_body+=$'\n\n'
	issue_body+="To approve and post the draft reply, comment: **approve** or **send it**."
	issue_body+=$'\n\n'
	issue_body+="To decline without replying, comment: **no reply**, **decline**, or **close**. The issue will be closed automatically."
	issue_body+=$'\n\n'
	issue_body+="To request a rewrite, describe the changes you want."
	issue_body+=$'\n\n'
	issue_body+="**Note:** If the draft itself recommends no reply, the agent will auto-decline this issue without requiring your input."
	issue_body+=$'\n\n'
	issue_body+="</details>"

	echo "$issue_body"
	return 0
}

# Create a notification issue in the draft-responses repo.
# CRITICAL: All external refs (owner/repo#N, GitHub URLs) MUST be wrapped in
# inline code backticks to prevent GitHub from creating cross-reference timeline
# entries on the external repo. Without this, the external maintainer sees a
# "mentioned this" link pointing to our private repo — revealing our workflow.
_create_notification_issue() {
	local item_key="$1"
	local title="$2"
	local item_type="$3"
	local role="$4"
	local latest_author="$5"
	local latest_comment="$6"
	local scan_result="$7"
	local draft_id="$8"
	local draft_text="${9:-}"

	local slug
	slug=$(_get_draft_repo_slug)

	_ensure_draft_repo || return 1

	local issue_body
	issue_body=$(_build_notification_issue_body \
		"$item_key" "$item_type" "$role" "$latest_author" \
		"$latest_comment" "$scan_result" "$draft_id" "$draft_text")

	# Issue title: use plain text description, NO owner/repo#N pattern
	local safe_title="Draft reply: ${title}"

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$issue_body" 2>/dev/null || true)
	issue_body="${issue_body}${sig_footer}"

	local issue_url
	issue_url=$(gh_create_issue \
		--repo "$slug" \
		--title "$safe_title" \
		--body "$issue_body" \
		--assignee "$(_get_username)" \
		--label "draft" 2>&1) || {
		_log_warn "Failed to create notification issue (non-fatal)"
		echo ""
		return 0
	}

	local issue_number
	issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$') || issue_number=""

	# Notification is handled by the GitHub Actions workflow in the draft-responses
	# repo (.github/workflows/notify.yml). The workflow posts a @mention comment
	# from github-actions[bot], which triggers a real GitHub notification.
	# Self-mentions (same user creating the issue) are suppressed by GitHub.

	echo "$issue_number"
	return 0
}

# Update the draft reply section in an existing notification issue body.
# Called when the compose step generates the actual draft text.
_update_notification_draft() {
	local issue_number="$1"
	local draft_text="$2"

	local slug
	slug=$(_get_draft_repo_slug)

	# Get current body
	local current_body
	current_body=$(gh issue view "$issue_number" --repo "$slug" --json body --jq '.body' 2>/dev/null) || return 1

	# Replace the draft section: everything between "## Draft Reply" and "---"
	# Use a temp file approach since sed with multiline is fragile
	local new_body
	new_body=$(echo "$current_body" | awk -v draft="$draft_text" '
		/^## Draft Reply/ { print; print ""; print draft; found=1; skip=1; next }
		/^---$/ && skip { skip=0 }
		skip { next }
		{ print }
	')

	gh_issue_edit_safe "$issue_number" --repo "$slug" --body "$new_body" >/dev/null 2>&1 || {
		_log_warn "Failed to update notification issue #${issue_number} body"
		return 1
	}
	return 0
}

# =============================================================================
# Bot filtering (t1556)
# =============================================================================

# Known bot account suffixes and exact names to skip when scanning comments.
# No point drafting replies to automated messages.
BOT_SUFFIXES="[bot]"
BOT_EXACT_NAMES=("github-actions" "dependabot" "renovate" "codecov" "sonarcloud")

_is_bot_account() {
	local login="$1"
	if [[ -z "$login" ]]; then
		return 1
	fi

	# Check suffix match (e.g., "dependabot[bot]", "github-actions[bot]")
	local lower_login
	lower_login=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
	if [[ "$lower_login" == *"$BOT_SUFFIXES" ]]; then
		return 0
	fi

	# Check exact name match
	local bot_name
	for bot_name in "${BOT_EXACT_NAMES[@]}"; do
		if [[ "$lower_login" == "$bot_name" ]]; then
			return 0
		fi
	done

	return 1
}
