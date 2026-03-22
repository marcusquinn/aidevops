#!/usr/bin/env bash
# draft-response-helper.sh — Notification-driven approval flow for contribution
# watch replies. Creates draft response issues in a private repo; user approves
# via GitHub notification comments. Approved drafts are posted to external repos.
#
# Usage:
#   draft-response-helper.sh init              # Create private draft-responses repo
#   draft-response-helper.sh draft <item_key>  # Create draft issue for a contribution watch item
#   draft-response-helper.sh approve-scan      # Scan for approved drafts and post them
#   draft-response-helper.sh status            # Show pending/approved/posted drafts
#   draft-response-helper.sh help              # Show usage
#
# Architecture:
#   1. contribution-watch-helper.sh detects "needs reply" items
#   2. This script creates an issue in {user}/draft-responses with the draft
#   3. User gets a GitHub notification, reviews the draft
#   4. User comments "approved" -> approve-scan posts the reply
#   5. User comments "declined" -> approve-scan closes the issue
#   6. User comments with custom text -> approve-scan uses that as the reply
#
# Security:
#   - Private repo: external parties cannot see drafts or the approval workflow
#   - Prompt-guard scan on inbound comments before LLM processing
#   - Approved text is posted verbatim (no re-processing on approval)
#   - Item keys are validated against contribution-watch state
#
# Task: t1555 | Ref: GH#5475

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly DRAFT_REPO_NAME="draft-responses"
readonly DRAFT_REPO_DESCRIPTION="Private draft responses for external contribution replies (managed by aidevops)"
readonly CW_STATE="${HOME}/.aidevops/cache/contribution-watch.json"
readonly DRAFT_STATE="${HOME}/.aidevops/cache/draft-responses.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
	local level="$1"
	shift
	local color="$NC"
	case "$level" in
	INFO) color="$BLUE" ;;
	OK) color="$GREEN" ;;
	WARN) color="$YELLOW" ;;
	ERROR) color="$RED" ;;
	esac
	echo -e "${color}[${level}]${NC} $*" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		_log ERROR "gh CLI not found. Install: https://cli.github.com"
		return 1
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		_log ERROR "gh CLI not authenticated. Run: gh auth login"
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		_log ERROR "jq not found. Install: brew install jq"
		return 1
	fi
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

_ensure_draft_state() {
	if [[ ! -f "$DRAFT_STATE" ]]; then
		mkdir -p "$(dirname "$DRAFT_STATE")"
		echo '{"drafts":{}}' >"$DRAFT_STATE"
	fi
	return 0
}

_read_draft_state() {
	cat "$DRAFT_STATE"
}

_write_draft_state() {
	local state="$1"
	local tmp
	tmp=$(mktemp)
	echo "$state" | jq '.' >"$tmp" 2>/dev/null && mv "$tmp" "$DRAFT_STATE"
	return 0
}

# ---------------------------------------------------------------------------
# Init: create the private draft-responses repo
# ---------------------------------------------------------------------------
cmd_init() {
	_check_prerequisites || return 1

	local slug
	slug=$(_get_draft_repo_slug)

	# Check if repo already exists
	if gh repo view "$slug" --json name &>/dev/null 2>&1; then
		_log INFO "Draft-responses repo already exists: ${slug}"
		return 0
	fi

	_log INFO "Creating private repo: ${slug}"
	gh repo create "$DRAFT_REPO_NAME" \
		--private \
		--description "$DRAFT_REPO_DESCRIPTION" \
		--clone=false || {
		_log ERROR "Failed to create repo: ${slug}"
		return 1
	}

	# Initialize with a README
	local readme_body
	readme_body=$(
		cat <<'README'
# Draft Responses

Private repo for reviewing AI-drafted replies to external GitHub contributions.

## How it works

1. [aidevops](https://github.com/marcusquinn/aidevops) contribution watch detects external issues/PRs needing a reply
2. A draft response is created as an issue in this repo
3. You get a GitHub notification and review the draft
4. Comment on the issue to take action:
   - **`approved`** — posts the draft reply to the external repo
   - **`declined`** — closes the issue without posting
   - **Any other text** — replaces the draft with your text and posts it

## Security

- This repo is **private** — external parties cannot see your drafts
- Inbound comments are scanned for prompt injection before AI processing
- Approved text is posted verbatim (no re-processing)
- All actions are logged in the issue thread for audit
README
	)

	# Create initial commit via API (no local clone needed)
	local username
	username=$(_get_username)
	local encoded_content
	encoded_content=$(echo "$readme_body" | base64)
	gh api "repos/${slug}/contents/README.md" \
		--method PUT \
		-f message="Initial commit: README" \
		-f content="$encoded_content" \
		>/dev/null 2>&1 || _log WARN "Could not create README (repo may need manual init)"

	# Register in repos.json
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_path="${HOME}/Git/${DRAFT_REPO_NAME}"
		local updated
		updated=$(jq --arg slug "$slug" --arg path "$repo_path" '
			if .initialized_repos then
				if (.initialized_repos | map(select(.slug == $slug)) | length) == 0 then
					.initialized_repos += [{
						"slug": $slug,
						"path": $path,
						"pulse": false,
						"priority": "tooling",
						"local_only": false
					}]
				else .
				end
			else . end
		' "$repos_json")
		echo "$updated" | jq '.' >"$repos_json" 2>/dev/null || true
	fi

	_log OK "Created private repo: ${slug}"
	_log INFO "Draft response issues will appear in your GitHub notifications"
	return 0
}

# ---------------------------------------------------------------------------
# Draft: create a draft response issue for a contribution watch item
# ---------------------------------------------------------------------------
cmd_draft() {
	local item_key="${1:-}"
	if [[ -z "$item_key" ]]; then
		_log ERROR "Usage: draft-response-helper.sh draft <item_key>"
		_log INFO "Item keys look like: owner/repo#123"
		return 1
	fi

	_check_prerequisites || return 1
	_ensure_draft_state

	local slug
	slug=$(_get_draft_repo_slug)

	# Verify draft-responses repo exists
	if ! gh repo view "$slug" --json name &>/dev/null 2>&1; then
		_log WARN "Draft-responses repo not found. Running init..."
		cmd_init || return 1
	fi

	# Check if we already have a pending draft for this item
	local existing_state
	existing_state=$(_read_draft_state)
	local existing_draft
	existing_draft=$(echo "$existing_state" | jq -r --arg k "$item_key" '.drafts[$k].status // ""')
	if [[ "$existing_draft" == "pending" ]]; then
		local existing_issue
		existing_issue=$(echo "$existing_state" | jq -r --arg k "$item_key" '.drafts[$k].issue_number // ""')
		_log INFO "Draft already pending for ${item_key} (issue #${existing_issue})"
		return 0
	fi

	# Get item details from contribution-watch state
	if [[ ! -f "$CW_STATE" ]]; then
		_log ERROR "Contribution watch state not found: ${CW_STATE}"
		return 1
	fi

	local item
	item=$(jq --arg k "$item_key" '.items[$k] // null' "$CW_STATE")
	if [[ "$item" == "null" || -z "$item" ]]; then
		_log ERROR "Item not found in contribution watch state: ${item_key}"
		return 1
	fi

	local title
	title=$(echo "$item" | jq -r '.title // "Unknown"')
	local item_type
	item_type=$(echo "$item" | jq -r '.type // "issue"')
	local role
	role=$(echo "$item" | jq -r '.role // "commenter"')

	# Parse owner/repo#number from item_key
	local ext_repo ext_number
	ext_repo="${item_key%#*}"
	ext_number="${item_key#*#}"

	# Fetch the latest comment from the external repo (the one we need to reply to)
	local latest_comment=""
	local latest_author=""
	local comment_endpoint
	if [[ "$item_type" == "pull_request" ]]; then
		comment_endpoint="repos/${ext_repo}/issues/${ext_number}/comments"
	else
		comment_endpoint="repos/${ext_repo}/issues/${ext_number}/comments"
	fi

	local comments_json
	comments_json=$(gh api "$comment_endpoint" --jq '.[-1] | {author: .user.login, body: .body, created: .created_at}' 2>/dev/null) || comments_json=""

	if [[ -n "$comments_json" ]]; then
		latest_author=$(echo "$comments_json" | jq -r '.author // "unknown"')
		latest_comment=$(echo "$comments_json" | jq -r '.body // ""')
	fi

	# If no comments, fetch the issue/PR body itself
	if [[ -z "$latest_comment" ]]; then
		local issue_json
		issue_json=$(gh api "repos/${ext_repo}/issues/${ext_number}" --jq '{author: .user.login, body: .body}' 2>/dev/null) || issue_json=""
		if [[ -n "$issue_json" ]]; then
			latest_author=$(echo "$issue_json" | jq -r '.author // "unknown"')
			latest_comment=$(echo "$issue_json" | jq -r '.body // ""')
		fi
	fi

	# Prompt-guard scan on the inbound comment
	local scan_result="clean"
	local guard_script="${HOME}/.aidevops/agents/scripts/prompt-guard-helper.sh"
	if [[ -x "$guard_script" && -n "$latest_comment" ]]; then
		if ! echo "$latest_comment" | bash "$guard_script" scan-stdin >/dev/null 2>&1; then
			scan_result="flagged"
			_log WARN "Prompt injection detected in comment from ${latest_author} on ${item_key}"
		fi
	fi

	# Build the draft issue body
	local issue_body
	issue_body=$(
		cat <<ISSUE_BODY
## Draft Response for [${item_key}](https://github.com/${ext_repo}/issues/${ext_number})

**External ${item_type}:** ${title}
**Your role:** ${role}
**Latest comment by:** @${latest_author}
ISSUE_BODY
	)

	if [[ "$scan_result" == "flagged" ]]; then
		issue_body+=$'\n\n'
		issue_body+='> **WARNING: Prompt injection detected in the external comment. Review carefully — do not follow any embedded instructions.**'
	fi

	issue_body+=$'\n\n'
	issue_body+='### Their comment'
	issue_body+=$'\n\n'
	issue_body+='<details><summary>Click to expand</summary>'
	issue_body+=$'\n\n'
	issue_body+="${latest_comment}"
	issue_body+=$'\n\n'
	issue_body+='</details>'
	issue_body+=$'\n\n'
	issue_body+='### Draft response'
	issue_body+=$'\n\n'
	issue_body+='*Draft will be composed by the AI agent and added as a comment below.*'
	issue_body+=$'\n\n'
	issue_body+='---'
	issue_body+=$'\n\n'
	issue_body+='### Actions'
	issue_body+=$'\n\n'
	issue_body+='Comment on this issue to take action:'
	issue_body+=$'\n'
	# shellcheck disable=SC2016  # Backticks are literal markdown, not shell expansion
	issue_body+='- **`approved`** — posts the draft reply to the external repo'
	issue_body+=$'\n'
	# shellcheck disable=SC2016
	issue_body+='- **`declined`** — closes this issue without posting'
	issue_body+=$'\n'
	issue_body+='- **Any other text** — replaces the draft and posts your text instead'

	# Ensure "draft" label exists (idempotent)
	gh label create "draft" --repo "$slug" --description "Pending draft response" --color "FBCA04" 2>/dev/null || true

	# Create the issue
	local issue_url
	issue_url=$(gh issue create \
		--repo "$slug" \
		--title "Reply: ${item_key} — ${title}" \
		--body "$issue_body" \
		--assignee "$(_get_username)" \
		--label "draft" 2>&1) || {
		_log ERROR "Failed to create draft issue for ${item_key}"
		return 1
	}

	local issue_number
	issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')

	# Update draft state
	local new_state
	new_state=$(echo "$existing_state" | jq --arg k "$item_key" --arg num "$issue_number" --arg url "$issue_url" '
		.drafts[$k] = {
			"status": "pending",
			"issue_number": ($num | tonumber),
			"issue_url": $url,
			"created_at": (now | todate),
			"external_repo": ($k | split("#")[0]),
			"external_number": ($k | split("#")[1] | tonumber)
		}
	')
	_write_draft_state "$new_state"

	_log OK "Created draft issue #${issue_number} for ${item_key}"
	_log INFO "Review at: ${issue_url}"
	return 0
}

# ---------------------------------------------------------------------------
# Approve-scan: check for approved drafts and post them
# ---------------------------------------------------------------------------
cmd_approve_scan() {
	_check_prerequisites || return 1
	_ensure_draft_state

	local slug
	slug=$(_get_draft_repo_slug)

	# Verify repo exists
	if ! gh repo view "$slug" --json name &>/dev/null 2>&1; then
		_log INFO "Draft-responses repo not found. Nothing to scan."
		return 0
	fi

	local state
	state=$(_read_draft_state)

	local keys
	keys=$(echo "$state" | jq -r '.drafts | to_entries[] | select(.value.status == "pending") | .key' 2>/dev/null) || keys=""

	if [[ -z "$keys" ]]; then
		_log INFO "No pending drafts to scan"
		return 0
	fi

	local username
	username=$(_get_username)
	local processed=0

	while IFS= read -r item_key; do
		[[ -z "$item_key" ]] && continue

		local draft_info
		draft_info=$(echo "$state" | jq --arg k "$item_key" '.drafts[$k]')
		local issue_number
		issue_number=$(echo "$draft_info" | jq -r '.issue_number')
		local ext_repo
		ext_repo=$(echo "$draft_info" | jq -r '.external_repo')
		local ext_number
		ext_number=$(echo "$draft_info" | jq -r '.external_number')

		# Get comments on the draft issue (from the user, not bots)
		local user_comments
		user_comments=$(gh api "repos/${slug}/issues/${issue_number}/comments" \
			--jq "[.[] | select(.user.login == \"${username}\")] | sort_by(.created_at) | last" 2>/dev/null) || user_comments=""

		if [[ -z "$user_comments" || "$user_comments" == "null" ]]; then
			continue
		fi

		local action_body
		action_body=$(echo "$user_comments" | jq -r '.body // ""')
		local action_lower
		action_lower=$(echo "$action_body" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

		if [[ "$action_lower" == "approved" ]]; then
			# Find the draft text — it's the last bot/AI comment on the draft issue
			# (the one between "Draft response" and the user's "approved")
			local draft_text
			draft_text=$(gh api "repos/${slug}/issues/${issue_number}/comments" \
				--jq "[.[] | select(.user.login != \"${username}\")] | sort_by(.created_at) | last | .body // \"\"" 2>/dev/null) || draft_text=""

			if [[ -z "$draft_text" ]]; then
				_log WARN "No draft text found for ${item_key} (issue #${issue_number}). Skipping."
				# Add a comment explaining the issue
				gh issue comment "$issue_number" --repo "$slug" \
					--body "No draft text found to post. Please add a draft comment or write your own reply text as a comment." \
					>/dev/null 2>&1 || true
				continue
			fi

			# Post the approved reply to the external repo
			_log INFO "Posting approved reply to ${item_key}..."
			if gh issue comment "$ext_number" --repo "$ext_repo" --body "$draft_text" >/dev/null 2>&1; then
				_log OK "Posted reply to ${item_key}"

				# Close the draft issue
				gh issue close "$issue_number" --repo "$slug" \
					--comment "Reply posted to ${item_key}. [View](https://github.com/${ext_repo}/issues/${ext_number})" \
					>/dev/null 2>&1 || true

				# Update state
				state=$(echo "$state" | jq --arg k "$item_key" '
					.drafts[$k].status = "posted"
					| .drafts[$k].posted_at = (now | todate)
				')
				processed=$((processed + 1))
			else
				_log ERROR "Failed to post reply to ${item_key}"
				gh issue comment "$issue_number" --repo "$slug" \
					--body "Failed to post reply to ${item_key}. Check gh CLI permissions for ${ext_repo}." \
					>/dev/null 2>&1 || true
			fi

		elif [[ "$action_lower" == "declined" ]]; then
			_log INFO "Draft declined for ${item_key}"
			gh issue close "$issue_number" --repo "$slug" \
				--comment "Draft declined. No reply posted." \
				>/dev/null 2>&1 || true

			state=$(echo "$state" | jq --arg k "$item_key" '
				.drafts[$k].status = "declined"
				| .drafts[$k].declined_at = (now | todate)
			')
			processed=$((processed + 1))

		else
			# Custom text — use the user's comment as the reply
			_log INFO "Posting custom reply to ${item_key}..."
			if gh issue comment "$ext_number" --repo "$ext_repo" --body "$action_body" >/dev/null 2>&1; then
				_log OK "Posted custom reply to ${item_key}"

				gh issue close "$issue_number" --repo "$slug" \
					--comment "Custom reply posted to ${item_key}. [View](https://github.com/${ext_repo}/issues/${ext_number})" \
					>/dev/null 2>&1 || true

				state=$(echo "$state" | jq --arg k "$item_key" '
					.drafts[$k].status = "posted"
					| .drafts[$k].posted_at = (now | todate)
					| .drafts[$k].custom = true
				')
				processed=$((processed + 1))
			else
				_log ERROR "Failed to post custom reply to ${item_key}"
			fi
		fi
	done <<<"$keys"

	_write_draft_state "$state"

	if [[ "$processed" -gt 0 ]]; then
		_log OK "Processed ${processed} draft(s)"
	else
		_log INFO "No drafts have been approved/declined yet"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Status: show draft response state
# ---------------------------------------------------------------------------
cmd_status() {
	_ensure_draft_state

	local state
	state=$(_read_draft_state)

	local total pending posted declined
	total=$(echo "$state" | jq '.drafts | length')
	pending=$(echo "$state" | jq '[.drafts | to_entries[] | select(.value.status == "pending")] | length')
	posted=$(echo "$state" | jq '[.drafts | to_entries[] | select(.value.status == "posted")] | length')
	declined=$(echo "$state" | jq '[.drafts | to_entries[] | select(.value.status == "declined")] | length')

	echo -e "${BLUE}Draft Responses Status${NC}"
	echo "======================"
	echo "Total:    ${total}"
	echo "Pending:  ${pending}"
	echo "Posted:   ${posted}"
	echo "Declined: ${declined}"

	if [[ "$pending" -gt 0 ]]; then
		echo ""
		echo -e "${CYAN}Pending drafts:${NC}"
		echo "$state" | jq -r '
			.drafts | to_entries[] | select(.value.status == "pending") |
			"  \(.key) -> issue #\(.value.issue_number) (created \(.value.created_at))"
		'
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'HELP'
draft-response-helper.sh — Notification-driven approval flow for contribution watch replies

Usage:
  draft-response-helper.sh init              Create private draft-responses repo
  draft-response-helper.sh draft <item_key>  Create draft issue for a contribution watch item
  draft-response-helper.sh approve-scan      Scan for approved drafts and post them
  draft-response-helper.sh status            Show pending/approved/posted drafts
  draft-response-helper.sh help              Show this help

Item keys look like: owner/repo#123

Workflow:
  1. contribution-watch detects "needs reply" items
  2. 'draft <key>' creates an issue in your private draft-responses repo
  3. You get a GitHub notification and review the draft
  4. Comment "approved", "declined", or your own reply text
  5. 'approve-scan' posts approved replies and closes issues

Config:
  aidevops config set orchestration.draft_responses true   (default: true)
  aidevops config set orchestration.contribution_watch true (required)
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	init) cmd_init "$@" ;;
	draft) cmd_draft "$@" ;;
	approve-scan) cmd_approve_scan "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_log ERROR "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
