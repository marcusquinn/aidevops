#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# draft-response-approvals.sh -- Approval Flow and check-approvals Command
# =============================================================================
# Handles the intelligent approval scanning loop that reads notification issues
# in the draft-responses repo, interprets user comments via LLM, and dispatches
# the resulting action (approve/decline/redraft/custom).
#
# Covered functions:
#   - Role-based compose caps (_check_compose_cap)
#   - LLM-based comment interpretation (_interpret_approval_comment)
#   - User comment detection on notification issues
#   - Redraft handling and meta persistence
#   - Action dispatch for single notification issues
#   - Safety net: auto-decline no-reply drafts after 24h
#   - cmd_check_approvals (main entry point for approval scanning)
#
# Usage: source "${SCRIPT_DIR}/draft-response-approvals.sh"
#
# Dependencies:
#   - draft-response-notification.sh (loaded by orchestrator)
#   - draft-response-storage.sh (loaded by orchestrator; provides _read_meta etc.)
#   - shared-constants.sh (colors, print_error, etc.)
#   - gh CLI, jq, ai-research-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DRAFT_RESPONSE_APPROVALS_LOADED:-}" ]] && return 0
_DRAFT_RESPONSE_APPROVALS_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Role-based compose caps (t1556)
# =============================================================================

# Track compose counts per item in the meta file.
# - author role: 1 compose per new external comment (unlimited total, but
#   only re-compose when new activity arrives)
# - participant role: 1 compose total (never auto-recompose)

_check_compose_cap() {
	local item_key="$1"
	local role="$2"

	# Normalize 'commenter' to 'participant' — both have the same cap behaviour
	if [[ "$role" == "commenter" ]]; then
		role="participant"
	fi

	# participant items: check compose_count in meta (default 1 when draft exists,
	# meaning the initial draft creation already counts as the first compose)
	if [[ "$role" == "participant" ]]; then
		local slug_check
		slug_check=$(printf '%s' "$item_key" | tr '/#' '-' | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
		local all_ids
		all_ids=$(_list_draft_ids "")
		local found_id=""
		while IFS= read -r _id; do
			[[ -z "$_id" ]] && continue
			if printf '%s' "$_id" | grep -q "$slug_check"; then
				found_id="$_id"
				break
			fi
		done <<<"$all_ids"

		if [[ -n "$found_id" ]]; then
			# Read compose_count from meta — defaults to 1 (initial draft = first compose)
			local _meta
			_meta=$(_read_meta "$found_id")
			local compose_count
			compose_count=$(echo "$_meta" | jq -r '.compose_count // 1') || compose_count=1
			if [[ "$compose_count" -ge 1 ]]; then
				_log_info "Compose cap reached for participant item ${item_key} (compose_count=${compose_count})"
				return 1
			fi
		fi
	fi

	# author items: always allowed (capped by caller — only compose when
	# new external comment arrives since last compose)
	return 0
}

# =============================================================================
# Intelligent layer: LLM-based comment interpretation (t1556)
# =============================================================================

# Interprets a user's comment on a notification issue to determine the action.
# Uses ai-research-helper.sh with sonnet tier (good balance of cost and quality
# for structured interpretation tasks).
#
# Returns a JSON object on stdout:
#   {"action": "approve|decline|redraft|custom|other", "text": "...", "extra": "..."}
#
# - approve: post the current draft as-is
# - decline: close without posting
# - redraft: compose a new draft using the instructions in "text"
# - custom: user provided the exact reply text in "text" — post it directly
# - other: additional action described in "extra" (e.g., "also close the external issue")

_interpret_approval_comment() {
	local user_comment="$1"
	local draft_text="$2"
	local item_key="$3"
	local role="$4"

	local ai_helper="${SCRIPT_DIR}/ai-research-helper.sh"
	if [[ ! -x "$ai_helper" ]]; then
		_log_error "ai-research-helper.sh not found or not executable"
		echo '{"action":"error","text":"ai-research-helper.sh not available","extra":""}'
		return 1
	fi

	# Build the interpretation prompt
	local prompt
	prompt="You are interpreting a user's comment on a draft-response notification issue.

The user was shown a draft reply to an external GitHub thread and asked to review it.
They commented on the notification issue with instructions.

Your job: determine what action the user wants.

Context:
- External thread: ${item_key}
- User's role: ${role} (author = created the thread, participant = commented on it)
- Current draft reply that was shown to the user:
---
${draft_text}
---

User's comment on the notification issue:
---
${user_comment}
---

Respond with EXACTLY one JSON object (no markdown, no explanation, just JSON):
{
  \"action\": \"approve|decline|redraft|custom|other\",
  \"text\": \"<reply text for custom, or redraft instructions, or empty>\",
  \"extra\": \"<additional action description if any, or empty>\"
}

Decision rules:
- If the comment means 'yes', 'approved', 'lgtm', 'send it', 'post it', 'go ahead', or similar affirmative → action: approve
- If the comment means 'no', 'don't send', 'skip', 'decline', 'cancel', 'nevermind' → action: decline
- If the comment asks to change/rewrite/modify the draft (e.g., 'make it shorter', 'add a thank you', 'be more formal') → action: redraft, text: the instructions
- If the comment IS the reply itself (the user wrote out exactly what to post) → action: custom, text: the exact reply to post
- If the comment requests an additional action beyond replying (e.g., 'approve and also close the issue', 'post it and subscribe to the repo') → action: approve (or custom), extra: description of the additional action
- If unclear → action: decline (safe default — never post without clear intent)"

	local response
	response=$("$ai_helper" --prompt "$prompt" --model sonnet --max-tokens 500 2>/dev/null) || {
		_log_error "LLM interpretation call failed"
		echo '{"action":"error","text":"LLM call failed","extra":""}'
		return 1
	}

	# Validate JSON response
	if ! echo "$response" | jq -e '.action' &>/dev/null 2>&1; then
		_log_error "LLM returned invalid JSON: ${response}"
		echo '{"action":"error","text":"Invalid LLM response","extra":""}'
		return 1
	fi

	echo "$response"
	return 0
}

# =============================================================================
# check-approvals: scan notification issues for user comments (t1556)
# =============================================================================

# Deterministic layer: list open draft-label issues in the draft-responses repo,
# find user comments newer than the last bot comment, and pass actionable ones
# to the intelligent layer for interpretation.
#
# This runs as part of the contribution-watch scan cycle (hourly via launchd).
# No LLM cost for issues with no new user comments.

# Find the latest actionable user comment on a notification issue.
# Outputs two lines: <comment_body>\n<comment_timestamp>
# Returns 1 if no actionable comment found.
_check_approvals_find_user_comment() {
	local slug="$1"
	local issue_number="$2"
	local username="$3"
	local draft_id="$4"

	# Get comments on this notification issue (paginate with max page size)
	local comments
	comments=$(gh api --paginate "repos/${slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {author: .user.login, body: .body, created: .created_at, author_type: .user.type}]' \
		2>/dev/null) || comments="[]"

	local comment_count
	comment_count=$(echo "$comments" | jq 'length' 2>/dev/null) || comment_count=0

	if [[ "$comment_count" -eq 0 ]]; then
		return 1
	fi

	# Find the last bot comment timestamp (github-actions[bot] or any [bot])
	local last_bot_time
	last_bot_time=$(echo "$comments" | jq -r '
		[.[] | select(.author | test("\\[bot\\]$"; "i") or . == "github-actions")] |
		sort_by(.created) | last | .created // ""
	' 2>/dev/null) || last_bot_time=""

	# Read last_handled_comment from draft meta to avoid reprocessing
	# agent follow-up comments (e.g., redraft status updates posted by
	# the agent itself appear as the same $username).
	# This is the primary guard against the self-consumption loop: every
	# hourly scan checks this timestamp and skips comments already handled.
	local meta_for_handled
	meta_for_handled=$(_read_meta "$draft_id")
	local last_handled
	last_handled=$(echo "$meta_for_handled" | jq -r '.last_handled_comment // ""')

	# Determine the cutoff: the later of last_bot_time and last_handled
	local cutoff_time="$last_bot_time"
	if [[ -n "$last_handled" ]] && [[ "$last_handled" > "$cutoff_time" ]]; then
		cutoff_time="$last_handled"
	fi

	# Find user comments newer than the cutoff
	local user_comments
	if [[ -n "$cutoff_time" ]]; then
		user_comments=$(echo "$comments" | jq -c --arg cutoff "$cutoff_time" --arg user "$username" '
			[.[] |
			 select(.author == $user) |
			 select(.created > $cutoff) |
			 select(.author | test("\\[bot\\]$"; "i") | not)
			]
		' 2>/dev/null) || user_comments="[]"
	else
		# No cutoff — any user comment is actionable
		user_comments=$(echo "$comments" | jq -c --arg user "$username" '
			[.[] |
			 select(.author == $user) |
			 select(.author | test("\\[bot\\]$"; "i") | not)
			]
		' 2>/dev/null) || user_comments="[]"
	fi

	local user_comment_count
	user_comment_count=$(echo "$user_comments" | jq 'length' 2>/dev/null) || user_comment_count=0

	if [[ "$user_comment_count" -eq 0 ]]; then
		return 1
	fi

	# Output: body on stdout (caller reads via command substitution)
	# Timestamp written to a temp file passed as arg 5
	local ts_file="$5"
	local latest_body
	latest_body=$(echo "$user_comments" | jq -r 'sort_by(.created) | last | .body // ""' 2>/dev/null) || latest_body=""
	local latest_ts
	latest_ts=$(echo "$user_comments" | jq -r 'sort_by(.created) | last | .created // ""' 2>/dev/null) || latest_ts=""

	if [[ -z "$latest_body" ]]; then
		return 1
	fi

	[[ -n "$ts_file" ]] && printf '%s' "$latest_ts" >"$ts_file"
	printf '%s' "$latest_body"
	return 0
}

# Handle the redraft action for a single issue in check-approvals.
_check_approvals_handle_redraft() {
	local draft_id="$1"
	local issue_number="$2"
	local role="$3"
	local action_text="$4"
	local meta="$5"

	# Normalize role for cap check: 'commenter' -> 'participant'
	local cap_role="$role"
	if [[ "$cap_role" == "commenter" ]]; then
		cap_role="participant"
	fi

	# Enforce compose cap on redraft — participants get 1 total compose
	local current_compose_count
	current_compose_count=$(echo "$meta" | jq -r '.compose_count // 1') || current_compose_count=1
	if [[ "$cap_role" == "participant" && "$current_compose_count" -ge 1 ]]; then
		echo "    Action: redraft — blocked by compose cap (participant, compose_count=${current_compose_count})"
		_log_info "check-approvals: redraft blocked for ${draft_id} (participant cap, compose_count=${current_compose_count})"
		return 1
	fi

	echo "    Action: redraft — composing new draft with user instructions"
	# Update the notification issue body with a note that re-draft is pending
	_update_notification_draft "$issue_number" "*Re-drafting based on your instructions: ${action_text}*"
	_log_info "check-approvals: redraft requested for ${draft_id}, instructions: ${action_text}"
	# The actual re-drafting requires an LLM compose call which is beyond
	# the scope of this deterministic helper. Log the request for the next
	# interactive session or pulse worker to pick up.
	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# Increment compose_count to track re-drafts
	local new_compose_count=$((current_compose_count + 1))
	local updated_meta
	updated_meta=$(echo "$meta" | jq \
		--arg instructions "$action_text" \
		--arg ts "$now_iso" \
		--argjson cc "$new_compose_count" \
		'.redraft_requested = $ts | .redraft_instructions = $instructions | .compose_count = $cc')
	_write_meta "$draft_id" "$updated_meta"
	return 0
}

# Persist the last_handled_comment timestamp after processing an issue.
# CRITICAL: Use the current time (after the action), not the user's comment time.
# Actions like cmd_approve post follow-up comments under the user's auth — those
# comments have timestamps AFTER the user's comment. If we only set the cutoff to
# the user's comment time, the agent's own follow-up would be picked up as a "new
# user comment" on the next scan, causing an infinite self-consumption loop.
_check_approvals_persist_handled() {
	local draft_id="$1"

	local post_action_time
	post_action_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local updated_meta
	updated_meta=$(_read_meta "$draft_id")
	updated_meta=$(echo "$updated_meta" | jq \
		--arg ts "$post_action_time" \
		'.last_handled_comment = $ts')
	_write_meta "$draft_id" "$updated_meta"
	return 0
}

# Dispatch the action determined by the intelligent layer for one issue.
# Returns the number of actions taken (0 or 1) via stdout.
_check_approvals_dispatch_action() {
	local draft_id="$1"
	local issue_number="$2"
	local action="$3"
	local action_text="$4"
	local action_extra="$5"
	local body_path="$6"
	local meta="$7"
	local role="$8"
	local latest_user_comment="$9"

	_log_info "check-approvals: issue #${issue_number} action=${action} extra=${action_extra}"

	local action_taken=0
	case "$action" in
	approve)
		echo "    Action: approve — posting draft to external repo"
		cmd_approve "$draft_id"
		action_taken=1
		;;
	decline)
		echo "    Action: decline — closing without posting"
		cmd_reject "$draft_id" "User declined via notification comment"
		action_taken=1
		;;
	redraft)
		if _check_approvals_handle_redraft \
			"$draft_id" "$issue_number" "$role" "$action_text" "$meta"; then
			action_taken=1
		fi
		;;
	custom)
		echo "    Action: custom reply — posting user-provided text verbatim"
		# Post the user's raw comment verbatim — bypass LLM rewriting.
		# The classifier identified this as "the user wrote the exact reply",
		# so we use the original comment, not the LLM's interpretation.
		if [[ -n "$latest_user_comment" ]]; then
			printf '%s' "$latest_user_comment" >"$body_path"
			cmd_approve "$draft_id"
			action_taken=1
		else
			_log_warn "check-approvals: custom action but no user comment text"
		fi
		;;
	error)
		_log_error "check-approvals: interpretation error for issue #${issue_number}: ${action_text}"
		;;
	*)
		_log_warn "check-approvals: unknown action '${action}' for issue #${issue_number}"
		;;
	esac

	# Handle extra actions if any
	if [[ -n "$action_extra" && "$action_extra" != "null" ]]; then
		_log_info "check-approvals: extra action requested: ${action_extra}"
		# Extra actions are logged for the next interactive session to handle.
		# We don't execute arbitrary actions from LLM output in automated context.
		echo "    Note: additional action requested — ${action_extra} (queued for interactive session)"
	fi

	echo "$action_taken"
	return 0
}

# Interpret the user comment and dispatch the resulting action for one issue.
# Args: draft_id issue_number issue_title latest_user_comment latest_user_comment_time
#       body_path meta role item_key
# Outputs the number of actions taken (0 or 1) via stdout.
_check_approvals_interpret_and_act() {
	local draft_id="$1"
	local issue_number="$2"
	local issue_title="$3"
	local latest_user_comment="$4"
	local latest_user_comment_time="$5"
	local body_path="$6"
	local meta="$7"
	local role="$8"
	local item_key="$9"

	# Read the current draft text
	local draft_text=""
	if [[ -f "$body_path" ]]; then
		draft_text=$(cat "$body_path")
	fi

	# Pass to intelligent layer for interpretation
	echo "  Processing issue #${issue_number}: ${issue_title}"
	local interpretation
	interpretation=$(_interpret_approval_comment "$latest_user_comment" "$draft_text" "$item_key" "$role") || {
		_log_error "check-approvals: interpretation failed for issue #${issue_number}"
		# Still persist last_handled to avoid re-triggering on the same
		# comment if the LLM is temporarily unavailable
		if [[ -n "$latest_user_comment_time" ]]; then
			local err_meta
			err_meta=$(_read_meta "$draft_id")
			err_meta=$(echo "$err_meta" | jq \
				--arg ts "$latest_user_comment_time" \
				'.last_handled_comment = $ts')
			_write_meta "$draft_id" "$err_meta"
		fi
		echo "0"
		return 0
	}

	local action action_text action_extra
	action=$(echo "$interpretation" | jq -r '.action // "error"')
	action_text=$(echo "$interpretation" | jq -r '.text // ""')
	action_extra=$(echo "$interpretation" | jq -r '.extra // ""')

	local action_taken
	action_taken=$(_check_approvals_dispatch_action \
		"$draft_id" "$issue_number" "$action" "$action_text" "$action_extra" \
		"$body_path" "$meta" "$role" "$latest_user_comment")

	_check_approvals_persist_handled "$draft_id"

	echo "$action_taken"
	return 0
}

# Process a single open draft issue in check-approvals.
# Returns the number of actions taken (0 or 1) via stdout.
_check_approvals_process_issue() {
	local issue="$1"
	local slug="$2"
	local username="$3"

	local issue_number
	issue_number=$(echo "$issue" | jq -r '.number')
	local issue_title
	issue_title=$(echo "$issue" | jq -r '.title // "unknown"')
	local issue_body
	issue_body=$(echo "$issue" | jq -r '.body // ""')

	# Extract draft_id from issue body (in the Context table).
	# Single sed pass — avoids multi-process grep|sed|tr pipeline.
	# SC2016: single quotes are intentional — backticks are literal markdown, not shell expansion.
	local draft_id
	# shellcheck disable=SC2016
	draft_id=$(echo "$issue_body" | sed -n 's/.*Draft ID | `\([^`]*\)`.*/\1/p;T;q') || draft_id=""

	if [[ -z "$draft_id" ]]; then
		_log_warn "check-approvals: issue #${issue_number} has no draft_id in body, skipping"
		echo "0"
		return 0
	fi

	# Find the latest actionable user comment
	local ts_file
	ts_file=$(mktemp) || {
		echo "0"
		return 0
	}
	local latest_user_comment
	latest_user_comment=$(_check_approvals_find_user_comment \
		"$slug" "$issue_number" "$username" "$draft_id" "$ts_file") || {
		rm -f "$ts_file"
		echo "0"
		return 0
	}
	local latest_user_comment_time
	latest_user_comment_time=$(cat "$ts_file" 2>/dev/null) || latest_user_comment_time=""
	rm -f "$ts_file"

	_log_info "check-approvals: issue #${issue_number} has actionable user comment for draft ${draft_id}"

	# Prompt-guard scan on user comment before LLM processing
	if [[ -x "$PROMPT_GUARD" ]]; then
		local guard_out
		guard_out=$(echo "$latest_user_comment" | "$PROMPT_GUARD" scan-stdin 2>/dev/null) || guard_out=""
		if echo "$guard_out" | grep -qi "WARN\|INJECT\|SUSPICIOUS"; then
			_log_warn "check-approvals: prompt injection detected in user comment on issue #${issue_number}"
		fi
	fi

	# Read draft meta for role info
	local meta
	meta=$(_read_meta "$draft_id")
	local role
	role=$(echo "$meta" | jq -r '.role // "participant"')
	local item_key
	item_key=$(echo "$meta" | jq -r '.item_key // ""')
	local draft_status
	draft_status=$(echo "$meta" | jq -r '.status // "pending"')

	# Skip if draft is no longer pending
	if [[ "$draft_status" != "pending" ]]; then
		_log_info "check-approvals: draft ${draft_id} is ${draft_status}, skipping"
		echo "0"
		return 0
	fi

	local body_path
	body_path=$(_draft_body_path "$draft_id")

	_check_approvals_interpret_and_act \
		"$draft_id" "$issue_number" "$issue_title" \
		"$latest_user_comment" "$latest_user_comment_time" \
		"$body_path" "$meta" "$role" "$item_key"
	return 0
}

# ==========================================================================
# Deterministic safety net (t5520): auto-decline no-reply drafts after 24h
# ==========================================================================
# When the compose agent determines no reply is needed, it should call
# 'reject' immediately (Change 1). This safety net catches cases where the
# agent failed to do so: if the draft body contains clear no-reply indicators
# AND no user comment exists on the notification issue, auto-decline after
# a 24h grace period.
#
# No-reply indicators (case-insensitive, matched against local draft body):
#   "no reply needed", "no action needed", "no action required",
#   "recommendation: decline", "no reply is needed", "decline this draft",
#   "not necessary to reply", "no response needed", "no response required"
#
# Grace period: 24h from draft creation time (stored in meta .created field).
# This prevents premature auto-decline of drafts that are still being composed.
# Returns the number of auto-declined drafts via stdout.
_check_approvals_safety_net() {
	local open_issues="$1"
	local slug="$2"
	local grace_seconds="${3:-86400}"

	local now_epoch
	now_epoch=$(date -u +%s 2>/dev/null) || now_epoch=0

	local auto_declined=0

	while IFS= read -r issue; do
		[[ -z "$issue" ]] && continue

		local sa_issue_number sa_issue_body
		sa_issue_number=$(echo "$issue" | jq -r '.number')
		sa_issue_body=$(echo "$issue" | jq -r '.body // ""')

		# Extract draft_id from issue body
		local sa_draft_id
		# shellcheck disable=SC2016
		sa_draft_id=$(echo "$sa_issue_body" | sed -n 's/.*Draft ID | `\([^`]*\)`.*/\1/p;T;q') || sa_draft_id=""
		[[ -z "$sa_draft_id" ]] && continue

		# Read draft meta
		local sa_meta
		sa_meta=$(_read_meta "$sa_draft_id")
		local sa_status
		sa_status=$(echo "$sa_meta" | jq -r '.status // "pending"')
		[[ "$sa_status" != "pending" ]] && continue

		# Check grace period: skip if draft was created less than 24h ago
		local sa_created
		sa_created=$(echo "$sa_meta" | jq -r '.created // ""')
		if [[ -n "$sa_created" && "$now_epoch" -gt 0 ]]; then
			# Convert ISO8601 to epoch (macOS date -j -f)
			local sa_created_epoch=0
			if TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$sa_created" +%s &>/dev/null 2>&1; then
				sa_created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$sa_created" +%s 2>/dev/null) || sa_created_epoch=0
			elif date -d "$sa_created" +%s &>/dev/null 2>&1; then
				# GNU date fallback (Linux)
				sa_created_epoch=$(date -d "$sa_created" +%s 2>/dev/null) || sa_created_epoch=0
			fi
			if [[ "$sa_created_epoch" -gt 0 ]]; then
				local sa_age=$((now_epoch - sa_created_epoch))
				if [[ "$sa_age" -lt "$grace_seconds" ]]; then
					_log_info "check-approvals safety-net: draft ${sa_draft_id} is only ${sa_age}s old (grace=${grace_seconds}s), skipping"
					continue
				fi
			fi
		fi

		# Check for comments from ANY non-bot user on this notification issue.
		# The safety net should NOT auto-decline if any human has commented —
		# not just the repo owner ($username). A comment from any non-bot user
		# indicates human engagement that should block auto-decline.
		# (GH#5559: was incorrectly filtering to only $username's comments)
		local sa_comments
		sa_comments=$(gh api --paginate "repos/${slug}/issues/${sa_issue_number}/comments?per_page=100" \
			--jq '[.[] | select(.user.login | test("\\[bot\\]$"; "i") | not)]' \
			2>/dev/null) || sa_comments="[]"
		local sa_user_comment_count
		sa_user_comment_count=$(echo "$sa_comments" | jq 'length' 2>/dev/null) || sa_user_comment_count=0

		# Only auto-decline if no non-bot user comment exists
		if [[ "$sa_user_comment_count" -gt 0 ]]; then
			continue
		fi

		# Check draft body for no-reply indicators
		local sa_body_path
		sa_body_path=$(_draft_body_path "$sa_draft_id")
		local sa_body_text=""
		if [[ -f "$sa_body_path" ]]; then
			sa_body_text=$(cat "$sa_body_path")
		fi

		# Also check the notification issue body (compose agent may have updated it)
		local sa_combined_text="${sa_body_text}"$'\n'"${sa_issue_body}"

		# Match no-reply indicators (case-insensitive)
		local sa_no_reply=false
		if echo "$sa_combined_text" | grep -qi \
			"no reply needed\|no action needed\|no action required\|recommendation: decline\|no reply is needed\|decline this draft\|not necessary to reply\|no response needed\|no response required\|no reply necessary"; then
			sa_no_reply=true
		fi

		if [[ "$sa_no_reply" == "true" ]]; then
			_log_info "check-approvals safety-net: auto-declining draft ${sa_draft_id} (no-reply indicators found, no user comment, grace period elapsed)"
			echo "  Safety net: auto-declining draft ${sa_draft_id} (no-reply indicators, no user comment, 24h elapsed)"
			cmd_reject "$sa_draft_id" "Auto-declined: no-reply indicators in draft body, no user comment after 24h grace period"
			auto_declined=$((auto_declined + 1))
		fi
	done < <(echo "$open_issues" | jq -c '.[]')

	echo "$auto_declined"
	return 0
}

cmd_check_approvals() {
	_check_prerequisites || return 1
	_ensure_draft_dir

	local username
	username=$(_get_username) || return 1

	local slug
	slug=$(_get_draft_repo_slug)

	# Verify the draft-responses repo exists
	if ! gh repo view "$slug" --json name &>/dev/null 2>&1; then
		_log_info "Draft-responses repo does not exist yet, skipping check-approvals"
		echo "No draft-responses repo found. Nothing to check."
		return 0
	fi

	# List open issues with 'draft' label
	local open_issues
	open_issues=$(gh issue list --repo "$slug" --label "draft" --state open \
		--json number,title,body --limit 100 2>/dev/null) || open_issues="[]"

	local issue_count
	issue_count=$(echo "$open_issues" | jq 'length' 2>/dev/null) || issue_count=0

	if [[ "$issue_count" -eq 0 ]]; then
		echo "No open draft issues to check."
		_log_info "check-approvals: no open draft issues"
		return 0
	fi

	_log_info "check-approvals: scanning ${issue_count} open draft issue(s)"
	echo "Scanning ${issue_count} open draft issue(s) for user comments..."

	local actions_taken=0

	# Iterate using jq -c '.[]' with process substitution instead of
	# index-based access — avoids re-parsing the full JSON array on each
	# iteration (Gemini review suggestion).
	while IFS= read -r issue; do
		[[ -z "$issue" ]] && continue
		local issue_actions
		issue_actions=$(_check_approvals_process_issue "$issue" "$slug" "$username")
		actions_taken=$((actions_taken + issue_actions))
	done < <(echo "$open_issues" | jq -c '.[]')

	# Run the auto-decline safety net
	local auto_declined
	auto_declined=$(_check_approvals_safety_net "$open_issues" "$slug")
	if [[ "$auto_declined" -gt 0 ]]; then
		echo "Safety net auto-declined ${auto_declined} no-reply draft(s)."
		_log_info "check-approvals safety-net: auto_declined=${auto_declined}"
		actions_taken=$((actions_taken + auto_declined))
	fi

	echo "check-approvals complete: ${actions_taken} action(s) taken from ${issue_count} issue(s)."
	_log_info "check-approvals complete: actions=${actions_taken}, issues_scanned=${issue_count}"
	echo "DRAFT_APPROVALS_PROCESSED=${actions_taken}"

	return 0
}
