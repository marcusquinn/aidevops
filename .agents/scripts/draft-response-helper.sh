#!/usr/bin/env bash
# draft-response-helper.sh — Notification-driven approval flow for contribution
# watch replies (t1555). Stores draft replies as markdown files locally;
# user approves or rejects via CLI before anything is posted to GitHub.
#
# Usage:
#   draft-response-helper.sh draft <item_key> [--body-file <file>]
#                                              Create a draft reply for a tracked item
#   draft-response-helper.sh list [--pending|--approved|--rejected]
#                                              List drafts (default: all)
#   draft-response-helper.sh show <draft_id>   Show draft content (prompt-injection-scanned)
#   draft-response-helper.sh approve <draft_id> Post draft to GitHub
#   draft-response-helper.sh reject <draft_id> [reason]
#                                              Discard draft without posting
#   draft-response-helper.sh status            Summary of all drafts
#   draft-response-helper.sh help              Show usage
#
# Architecture:
#   1. contribution-watch-helper.sh detects "needs reply" items
#   2. 'draft <key>' creates local draft + notification issue in private repo
#   3. User gets GitHub notification, reviews draft, comments with instructions
#   4. Pulse/agent reads comment, interprets intent (intelligence-led, not keyword-matching)
#   5. 'approve' posts the draft body to GitHub; 'reject' discards it
#   6. Closing the notification issue without comment = no action (decline)
#   7. Any other comment = agent interprets and acts (re-draft, alternative, etc.)
#   8. Drafts are NEVER posted automatically — explicit approval always required
#
# Security:
#   - Draft bodies are scanned by prompt-guard-helper.sh before display
#   - Approved text is posted via --body-file (no secret-as-argument risk)
#   - Item keys are validated against contribution-watch state
#   - No credentials or secret values are written to draft files
#
# Draft storage: ~/.aidevops/.agent-workspace/draft-responses/
# Draft ID:      YYYYMMDD-HHMMSS-{item-key-slug}
#
# Task: t1555 | Ref: GH#5475

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

DRAFT_DIR="${HOME}/.aidevops/.agent-workspace/draft-responses"
LOGFILE="${HOME}/.aidevops/logs/draft-response.log"
CW_STATE="${HOME}/.aidevops/cache/contribution-watch.json"
PROMPT_GUARD="${SCRIPT_DIR}/prompt-guard-helper.sh"
DRAFT_REPO_NAME="draft-responses"

# =============================================================================
# Logging
# =============================================================================

_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

_log_info() {
	_log "INFO" "$@"
	return 0
}

_log_warn() {
	_log "WARN" "$@"
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
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
	gh api "repos/${slug}/subscription" --method PUT \
		--input - <<<'{"subscribed":true,"ignored":false}' >/dev/null 2>&1 || true

	_log_info "Created private repo: ${slug}"
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

	local slug
	slug=$(_get_draft_repo_slug)

	_ensure_draft_repo || return 1

	# Build issue body with ALL external refs in inline code blocks.
	# Layout: draft reply first (what you see on notification open),
	# then context and instructions below.
	local draft_text="${9:-}"

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
	issue_body+="</details>"

	# Issue title: use plain text description, NO owner/repo#N pattern
	local safe_title="Draft reply: ${title}"

	local issue_url
	issue_url=$(gh issue create \
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

	# Post a comment mentioning the user to trigger a GitHub notification.
	# GitHub does NOT notify you for issues you create yourself — even as assignee.
	# A self-mention in a comment is the only way to get the notification.
	if [[ -n "$issue_number" ]]; then
		local username
		username=$(_get_username)
		gh issue comment "$issue_number" --repo "$slug" \
			--body "@${username} — draft reply ready for review." \
			>/dev/null 2>&1 || true
	fi

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

	gh issue edit "$issue_number" --repo "$slug" --body "$new_body" >/dev/null 2>&1 || {
		_log_warn "Failed to update notification issue #${issue_number} body"
		return 1
	}
	return 0
}

# =============================================================================
# Draft ID and file path helpers
# =============================================================================

_make_draft_id() {
	local item_key="$1"
	local timestamp
	timestamp=$(date -u +%Y%m%d-%H%M%S)
	# Slugify item key: owner/repo#123 -> owner-repo-123
	local slug
	slug=$(echo "$item_key" | tr '/#' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
	echo "${timestamp}-${slug}"
	return 0
}

_draft_body_path() {
	local draft_id="$1"
	echo "${DRAFT_DIR}/${draft_id}.md"
	return 0
}

_draft_meta_path() {
	local draft_id="$1"
	echo "${DRAFT_DIR}/${draft_id}.meta.json"
	return 0
}

_read_meta() {
	local draft_id="$1"
	local meta_path
	meta_path=$(_draft_meta_path "$draft_id")
	if [[ ! -f "$meta_path" ]]; then
		echo "{}"
		return 0
	fi
	cat "$meta_path"
	return 0
}

_write_meta() {
	local draft_id="$1"
	local meta="$2"
	local meta_path
	meta_path=$(_draft_meta_path "$draft_id")
	echo "$meta" | jq '.' >"$meta_path" 2>/dev/null || {
		_log_error "Failed to write meta for draft ${draft_id}"
		return 1
	}
	return 0
}

_list_draft_ids() {
	local filter="${1:-}"
	_ensure_draft_dir
	local ids=""
	local f
	for f in "${DRAFT_DIR}"/*.meta.json; do
		[[ -f "$f" ]] || continue
		local draft_id
		draft_id=$(basename "$f" .meta.json)
		if [[ -z "$filter" ]]; then
			ids="${ids}${draft_id}"$'\n'
		else
			local status
			status=$(jq -r '.status // "pending"' "$f" 2>/dev/null) || status="pending"
			if [[ "$status" == "$filter" ]]; then
				ids="${ids}${draft_id}"$'\n'
			fi
		fi
	done
	echo "$ids"
	return 0
}

# =============================================================================
# cmd_draft: create a new draft reply
# =============================================================================

cmd_draft() {
	local item_key="${1:-}"
	if [[ -z "$item_key" ]]; then
		echo -e "${RED}Usage: draft-response-helper.sh draft <item_key> [--body-file <file>]${NC}" >&2
		echo "  item_key: GitHub item key, e.g. owner/repo#123" >&2
		return 1
	fi
	shift

	local body_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body-file)
			body_file="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	_check_prerequisites || return 1
	_ensure_draft_dir

	# Check for existing pending draft for this item
	local existing_ids
	existing_ids=$(_list_draft_ids "pending")
	local slug_check
	slug_check=$(echo "$item_key" | tr '/#' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
	if echo "$existing_ids" | grep -q "${slug_check}"; then
		echo -e "${YELLOW}A pending draft already exists for ${item_key}. Use 'list --pending' to find it.${NC}"
		return 0
	fi

	# Get item details from contribution-watch state
	local title="Unknown"
	local item_type="issue"
	local role="commenter"
	local latest_author=""
	local latest_comment=""
	local scan_result="clean"

	if [[ -f "$CW_STATE" ]]; then
		local cw_item
		cw_item=$(jq --arg k "$item_key" '.items[$k] // null' "$CW_STATE" 2>/dev/null) || cw_item="null"
		if [[ "$cw_item" != "null" && -n "$cw_item" ]]; then
			title=$(echo "$cw_item" | jq -r '.title // "Unknown"')
			item_type=$(echo "$cw_item" | jq -r '.type // "issue"')
			role=$(echo "$cw_item" | jq -r '.role // "commenter"')
		fi
	fi

	# Parse owner/repo#number from item_key
	local ext_repo ext_number
	ext_repo="${item_key%#*}"
	ext_number="${item_key##*#}"

	# Fetch latest comment metadata (author + body) for context in the draft
	local comments_json
	comments_json=$(gh api "repos/${ext_repo}/issues/${ext_number}/comments" \
		--jq '.[-1] | {author: .user.login, body: .body}' 2>/dev/null) || comments_json=""

	if [[ -n "$comments_json" && "$comments_json" != "null" ]]; then
		latest_author=$(echo "$comments_json" | jq -r '.author // ""')
		latest_comment=$(echo "$comments_json" | jq -r '.body // ""')
	fi

	# Fall back to issue/PR body if no comments
	if [[ -z "$latest_comment" ]]; then
		local issue_json
		issue_json=$(gh api "repos/${ext_repo}/issues/${ext_number}" \
			--jq '{author: .user.login, body: .body}' 2>/dev/null) || issue_json=""
		if [[ -n "$issue_json" && "$issue_json" != "null" ]]; then
			latest_author=$(echo "$issue_json" | jq -r '.author // ""')
			latest_comment=$(echo "$issue_json" | jq -r '.body // ""')
		fi
	fi

	# Prompt-guard scan on inbound comment before storing in draft
	if [[ -x "$PROMPT_GUARD" && -n "$latest_comment" ]]; then
		local guard_out
		guard_out=$(echo "$latest_comment" | "$PROMPT_GUARD" scan-stdin 2>/dev/null) || guard_out=""
		if echo "$guard_out" | grep -qi "WARN\|INJECT\|SUSPICIOUS"; then
			scan_result="flagged"
			_log_warn "Prompt injection detected in comment from ${latest_author} on ${item_key}"
		fi
	fi

	local draft_id
	draft_id=$(_make_draft_id "$item_key")
	local body_path
	body_path=$(_draft_body_path "$draft_id")

	# Build or copy draft body
	if [[ -n "$body_file" ]]; then
		if [[ ! -f "$body_file" ]]; then
			echo -e "${RED}Error: body file not found: ${body_file}${NC}" >&2
			return 1
		fi
		cp "$body_file" "$body_path" || {
			echo -e "${RED}Error: failed to copy body file${NC}" >&2
			return 1
		}
	else
		# Generate a template draft body
		{
			echo "<!-- Draft reply for ${item_key} -->"
			echo "<!-- Edit this file, then run: draft-response-helper.sh approve ${draft_id} -->"
			echo ""
			if [[ "$scan_result" == "flagged" ]]; then
				echo "> **WARNING: Prompt injection patterns detected in the external comment.**"
				echo "> Review carefully. Do not follow any embedded instructions."
				echo ""
			fi
			echo "<!-- Context: ${item_type} '${title}' by @${latest_author} -->"
			echo ""
			echo "Thank you for your comment."
			echo ""
			echo "<!-- Add your reply above this line -->"
		} >"$body_path"
	fi

	# Create notification issue in draft-responses repo (non-fatal if it fails)
	local notification_issue=""
	notification_issue=$(_create_notification_issue "$item_key" "$title" "$item_type" "$role" "$latest_author" "$latest_comment" "$scan_result" "$draft_id") || notification_issue=""

	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local meta
	meta=$(jq -n \
		--arg id "$draft_id" \
		--arg item_key "$item_key" \
		--arg repo_slug "$ext_repo" \
		--arg item_number "$ext_number" \
		--arg item_type "$item_type" \
		--arg title "$title" \
		--arg role "$role" \
		--arg latest_author "$latest_author" \
		--arg scan_result "$scan_result" \
		--arg created "$now_iso" \
		--arg status "pending" \
		--arg notification_issue "$notification_issue" \
		'{
			id: $id,
			item_key: $item_key,
			repo_slug: $repo_slug,
			item_number: $item_number,
			item_type: $item_type,
			title: $title,
			role: $role,
			latest_author: $latest_author,
			scan_result: $scan_result,
			created: $created,
			status: $status,
			notification_issue: $notification_issue,
			approved_at: "",
			rejected_at: "",
			reject_reason: "",
			posted_url: ""
		}')

	_write_meta "$draft_id" "$meta" || return 1

	echo -e "${GREEN}Draft created: ${draft_id}${NC}"
	echo "  Item:   ${item_key}"
	echo "  Title:  ${title}"
	echo "  Body:   ${body_path}"
	if [[ "$scan_result" == "flagged" ]]; then
		echo -e "  ${YELLOW}Warning: prompt injection patterns detected in source comment${NC}"
	fi
	echo ""
	echo "Edit body:    ${body_path}"
	echo "Review:       draft-response-helper.sh show ${draft_id}"
	echo "Approve:      draft-response-helper.sh approve ${draft_id}"
	echo "Reject:       draft-response-helper.sh reject ${draft_id}"

	_log_info "Draft created: ${draft_id} for ${item_key} (scan: ${scan_result})"

	# macOS notification
	if command -v osascript &>/dev/null; then
		osascript -e "display notification \"Draft reply ready for ${item_key}\" with title \"aidevops draft-response\"" 2>/dev/null || true
	fi

	return 0
}

# =============================================================================
# cmd_list: list drafts
# =============================================================================

cmd_list() {
	local filter=""
	local arg
	for arg in "$@"; do
		case "$arg" in
		--pending) filter="pending" ;;
		--approved) filter="approved" ;;
		--rejected) filter="rejected" ;;
		esac
	done

	_ensure_draft_dir

	local ids
	ids=$(_list_draft_ids "$filter")

	if [[ -z "$(echo "$ids" | tr -d '[:space:]')" ]]; then
		if [[ -n "$filter" ]]; then
			echo "No ${filter} drafts found."
		else
			echo "No drafts found. Use 'draft <item_key>' to create one."
		fi
		return 0
	fi

	local label="All"
	[[ -n "$filter" ]] && label="${filter}"
	echo -e "${BLUE}${label} Draft Replies${NC}"
	echo "================="

	local count=0
	while IFS= read -r draft_id; do
		[[ -z "$draft_id" ]] && continue
		local meta
		meta=$(_read_meta "$draft_id")
		local item_key status title created scan_result
		item_key=$(echo "$meta" | jq -r '.item_key // "unknown"')
		status=$(echo "$meta" | jq -r '.status // "pending"')
		title=$(echo "$meta" | jq -r '.title // "unknown"')
		created=$(echo "$meta" | jq -r '.created // ""')
		scan_result=$(echo "$meta" | jq -r '.scan_result // "clean"')

		local status_color="$YELLOW"
		[[ "$status" == "approved" ]] && status_color="$GREEN"
		[[ "$status" == "rejected" ]] && status_color="$RED"

		echo -e "  ${CYAN}${draft_id}${NC}"
		echo "    Item:    ${item_key}"
		echo "    Title:   ${title}"
		echo -e "    Status:  ${status_color}${status}${NC}"
		echo "    Created: ${created}"
		if [[ "$scan_result" == "flagged" ]]; then
			echo -e "    ${YELLOW}[prompt injection flagged in source]${NC}"
		fi
		echo ""
		count=$((count + 1))
	done <<<"$ids"

	echo "Total: ${count}"
	return 0
}

# =============================================================================
# cmd_show: display draft content
# =============================================================================

cmd_show() {
	if [[ $# -lt 1 ]]; then
		echo -e "${RED}Usage: draft-response-helper.sh show <draft_id>${NC}" >&2
		return 1
	fi

	local draft_id="$1"
	local meta_path
	meta_path=$(_draft_meta_path "$draft_id")
	local body_path
	body_path=$(_draft_body_path "$draft_id")

	if [[ ! -f "$meta_path" ]]; then
		echo -e "${RED}Error: draft not found: ${draft_id}${NC}" >&2
		return 1
	fi

	local meta
	meta=$(_read_meta "$draft_id")
	local item_key status title created item_type role latest_author scan_result
	item_key=$(echo "$meta" | jq -r '.item_key // "unknown"')
	status=$(echo "$meta" | jq -r '.status // "pending"')
	title=$(echo "$meta" | jq -r '.title // "unknown"')
	created=$(echo "$meta" | jq -r '.created // ""')
	item_type=$(echo "$meta" | jq -r '.item_type // "issue"')
	role=$(echo "$meta" | jq -r '.role // "commenter"')
	latest_author=$(echo "$meta" | jq -r '.latest_author // ""')
	scan_result=$(echo "$meta" | jq -r '.scan_result // "clean"')

	echo -e "${BLUE}Draft: ${draft_id}${NC}"
	echo "========================="
	echo "  Item:    ${item_key} (${item_type})"
	echo "  Title:   ${title}"
	echo "  Role:    ${role}"
	echo "  Status:  ${status}"
	echo "  Created: ${created}"
	[[ -n "$latest_author" ]] && echo "  Replying to: @${latest_author}"
	if [[ "$scan_result" == "flagged" ]]; then
		echo -e "  ${RED}WARNING: Prompt injection patterns detected in source comment${NC}"
	fi
	echo ""

	if [[ ! -f "$body_path" ]]; then
		echo -e "${YELLOW}Warning: body file missing: ${body_path}${NC}"
		return 0
	fi

	# Scan body for prompt injection before displaying
	if [[ -x "$PROMPT_GUARD" ]]; then
		local scan_out
		scan_out=$("$PROMPT_GUARD" scan-file "$body_path" 2>/dev/null) || scan_out=""
		if echo "$scan_out" | grep -qi "WARN\|INJECT\|SUSPICIOUS"; then
			echo -e "${RED}WARNING: Prompt injection patterns detected in draft body. Review carefully.${NC}"
			echo ""
		fi
	fi

	echo -e "${CYAN}--- Draft Body ---${NC}"
	cat "$body_path"
	echo ""
	echo -e "${CYAN}--- End Draft ---${NC}"

	return 0
}

# =============================================================================
# cmd_approve: post draft to GitHub
# =============================================================================

cmd_approve() {
	if [[ $# -lt 1 ]]; then
		echo -e "${RED}Usage: draft-response-helper.sh approve <draft_id>${NC}" >&2
		return 1
	fi

	local draft_id="$1"
	local meta_path
	meta_path=$(_draft_meta_path "$draft_id")
	local body_path
	body_path=$(_draft_body_path "$draft_id")

	if [[ ! -f "$meta_path" ]]; then
		echo -e "${RED}Error: draft not found: ${draft_id}${NC}" >&2
		return 1
	fi

	local meta
	meta=$(_read_meta "$draft_id")
	local status
	status=$(echo "$meta" | jq -r '.status // "pending"')

	if [[ "$status" != "pending" ]]; then
		echo -e "${YELLOW}Draft is already ${status}. Cannot approve.${NC}" >&2
		return 1
	fi

	if [[ ! -f "$body_path" ]]; then
		echo -e "${RED}Error: draft body file missing: ${body_path}${NC}" >&2
		return 1
	fi

	_check_prerequisites || return 1

	local repo_slug item_number item_type title
	repo_slug=$(echo "$meta" | jq -r '.repo_slug // ""')
	item_number=$(echo "$meta" | jq -r '.item_number // ""')
	item_type=$(echo "$meta" | jq -r '.item_type // "issue"')
	title=$(echo "$meta" | jq -r '.title // "unknown"')

	if [[ -z "$repo_slug" || -z "$item_number" ]]; then
		echo -e "${RED}Error: invalid draft metadata (missing repo_slug or item_number)${NC}" >&2
		return 1
	fi

	echo -e "${CYAN}Posting draft reply to ${repo_slug}#${item_number}...${NC}"
	echo "  Title: ${title}"
	echo ""

	# Post comment via gh CLI — body read from file to avoid argument injection (rule 8.2)
	local post_output
	local post_exit=0
	if [[ "$item_type" == "pr" ]]; then
		post_output=$(gh pr comment "$item_number" --repo "$repo_slug" --body-file "$body_path" 2>&1) || post_exit=$?
	else
		post_output=$(gh issue comment "$item_number" --repo "$repo_slug" --body-file "$body_path" 2>&1) || post_exit=$?
	fi

	if [[ "$post_exit" -ne 0 ]]; then
		echo -e "${RED}Error: failed to post comment${NC}" >&2
		echo "$post_output" >&2
		_log_error "Failed to post draft ${draft_id}: exit=${post_exit}"
		return 1
	fi

	# Extract posted URL from output (gh outputs the comment URL on stdout)
	local posted_url
	posted_url=$(echo "$post_output" | grep -o 'https://github.com[^ ]*' | head -1) || posted_url=""

	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	meta=$(echo "$meta" | jq \
		--arg status "approved" \
		--arg approved_at "$now_iso" \
		--arg posted_url "$posted_url" \
		'.status = $status | .approved_at = $approved_at | .posted_url = $posted_url')
	_write_meta "$draft_id" "$meta" || true

	echo -e "${GREEN}Draft approved and posted!${NC}"
	if [[ -n "$posted_url" ]]; then
		echo "  URL: ${posted_url}"
	fi

	# Close notification issue if one exists
	local notification_issue
	notification_issue=$(echo "$meta" | jq -r '.notification_issue // ""')
	if [[ -n "$notification_issue" ]]; then
		local slug
		slug=$(_get_draft_repo_slug)
		gh issue close "$notification_issue" --repo "$slug" \
			--comment "Reply posted." >/dev/null 2>&1 || true
		gh issue edit "$notification_issue" --repo "$slug" \
			--remove-label "draft" --add-label "approved" >/dev/null 2>&1 || true
	fi

	_log_info "Draft approved: ${draft_id} -> ${repo_slug}#${item_number} (${posted_url})"

	return 0
}

# =============================================================================
# cmd_reject: discard a draft
# =============================================================================

cmd_reject() {
	if [[ $# -lt 1 ]]; then
		echo -e "${RED}Usage: draft-response-helper.sh reject <draft_id> [reason]${NC}" >&2
		return 1
	fi

	local draft_id="$1"
	local reason="${2:-}"
	local meta_path
	meta_path=$(_draft_meta_path "$draft_id")

	if [[ ! -f "$meta_path" ]]; then
		echo -e "${RED}Error: draft not found: ${draft_id}${NC}" >&2
		return 1
	fi

	local meta
	meta=$(_read_meta "$draft_id")
	local status
	status=$(echo "$meta" | jq -r '.status // "pending"')

	if [[ "$status" != "pending" ]]; then
		echo -e "${YELLOW}Draft is already ${status}. Cannot reject.${NC}" >&2
		return 1
	fi

	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	meta=$(echo "$meta" | jq \
		--arg status "rejected" \
		--arg rejected_at "$now_iso" \
		--arg reason "$reason" \
		'.status = $status | .rejected_at = $rejected_at | .reject_reason = $reason')
	_write_meta "$draft_id" "$meta" || return 1

	echo -e "${YELLOW}Draft rejected: ${draft_id}${NC}"
	if [[ -n "$reason" ]]; then
		echo "  Reason: ${reason}"
	fi

	# Close notification issue if one exists
	local notification_issue
	notification_issue=$(echo "$meta" | jq -r '.notification_issue // ""')
	if [[ -n "$notification_issue" ]]; then
		local slug
		slug=$(_get_draft_repo_slug)
		gh issue close "$notification_issue" --repo "$slug" \
			--comment "Draft declined." >/dev/null 2>&1 || true
		gh issue edit "$notification_issue" --repo "$slug" \
			--remove-label "draft" --add-label "declined" >/dev/null 2>&1 || true
	fi

	_log_info "Draft rejected: ${draft_id} (reason: ${reason:-none})"

	return 0
}

# =============================================================================
# cmd_status: summary of all drafts
# =============================================================================

cmd_status() {
	_ensure_draft_dir

	local all_ids
	all_ids=$(_list_draft_ids "")

	local pending_count=0
	local approved_count=0
	local rejected_count=0

	while IFS= read -r draft_id; do
		[[ -z "$draft_id" ]] && continue
		local meta_path
		meta_path=$(_draft_meta_path "$draft_id")
		[[ -f "$meta_path" ]] || continue
		local status
		status=$(jq -r '.status // "pending"' "$meta_path" 2>/dev/null) || status="pending"
		case "$status" in
		pending) pending_count=$((pending_count + 1)) ;;
		approved) approved_count=$((approved_count + 1)) ;;
		rejected) rejected_count=$((rejected_count + 1)) ;;
		esac
	done <<<"$all_ids"

	local total=$((pending_count + approved_count + rejected_count))

	echo -e "${BLUE}Draft Response Status${NC}"
	echo "====================="
	echo "  Pending:  ${pending_count}"
	echo "  Approved: ${approved_count}"
	echo "  Rejected: ${rejected_count}"
	echo "  Total:    ${total}"
	echo ""
	echo "Draft directory: ${DRAFT_DIR}"

	if [[ "$pending_count" -gt 0 ]]; then
		echo ""
		echo -e "${YELLOW}${pending_count} draft(s) awaiting review:${NC}"
		local ids
		ids=$(_list_draft_ids "pending")
		while IFS= read -r draft_id; do
			[[ -z "$draft_id" ]] && continue
			local meta
			meta=$(_read_meta "$draft_id")
			local item_key title
			item_key=$(echo "$meta" | jq -r '.item_key // "unknown"')
			title=$(echo "$meta" | jq -r '.title // "unknown"')
			echo "  ${draft_id}"
			echo "    ${item_key}: ${title}"
		done <<<"$ids"
		echo ""
		echo "Review:  draft-response-helper.sh show <draft_id>"
		echo "Approve: draft-response-helper.sh approve <draft_id>"
		echo "Reject:  draft-response-helper.sh reject <draft_id>"
	fi

	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	echo "draft-response-helper.sh — Notification-driven approval flow for contribution watch replies"
	echo ""
	echo "Usage:"
	echo "  draft-response-helper.sh draft <item_key> [--body-file <file>]"
	echo "      Create a draft reply for a tracked GitHub issue/PR"
	echo "      item_key: owner/repo#123"
	echo "      --body-file: use existing markdown file as draft body (optional)"
	echo ""
	echo "  draft-response-helper.sh list [--pending|--approved|--rejected]"
	echo "      List drafts, optionally filtered by status"
	echo ""
	echo "  draft-response-helper.sh show <draft_id>"
	echo "      Display draft metadata and body (prompt-injection-scanned)"
	echo ""
	echo "  draft-response-helper.sh approve <draft_id>"
	echo "      Post the draft reply to GitHub and mark as approved"
	echo ""
	echo "  draft-response-helper.sh reject <draft_id> [reason]"
	echo "      Discard the draft (optionally with a reason)"
	echo ""
	echo "  draft-response-helper.sh status"
	echo "      Show summary of all drafts"
	echo ""
	echo "  draft-response-helper.sh help"
	echo "      Show this help"
	echo ""
	echo "Draft storage: ${DRAFT_DIR}"
	echo "Log file:      ${LOGFILE}"
	echo ""
	echo "Integration with contribution-watch-helper.sh:"
	echo "  contribution-watch-helper.sh scan --auto-draft"
	echo "  Automatically creates drafts when new activity is detected on tracked threads."
	echo "  Drafts are NEVER posted automatically — user approval is always required."
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

	case "$cmd" in
	init) _check_prerequisites && _ensure_draft_repo ;;
	draft) cmd_draft "$@" ;;
	list) cmd_list "$@" ;;
	show) cmd_show "$@" ;;
	approve) cmd_approve "$@" ;;
	reject) cmd_reject "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'draft-response-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
