#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# routine-comment-responder.sh — Detect and respond to user comments on
# routine-tracking issues. Called by the pulse to dispatch lightweight
# workers that answer questions and apply change requests.
#
# Usage:
#   routine-comment-responder.sh scan <repo_slug> <repo_path>
#   routine-comment-responder.sh dispatch <repo_slug> <repo_path> <issue_number> <comment_id>
#
# scan:     Finds routine-tracking issues with unanswered user comments.
#           Outputs one line per actionable comment: issue_number|comment_id|author|body_preview
#
# dispatch: Dispatches a lightweight worker to respond to a specific comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="${ROUTINE_COMMENT_LOGFILE:-${HOME}/.aidevops/.agent-workspace/cron/routine-comments/responder.log}"
STATE_DIR="${ROUTINE_COMMENT_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/cron/routine-comments}"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_log() {
	local msg="$1"
	echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $msg" >>"$LOGFILE"
	return 0
}

_get_self_login() {
	gh api user --jq '.login' 2>/dev/null || echo ""
	return 0
}

_responded_file_for_repo() {
	local repo_slug="$1"
	printf '%s\n' "${STATE_DIR}/${repo_slug//\//_}_responded.txt"
	return 0
}

_comment_already_recorded() {
	local responded_file="$1"
	local comment_id="$2"
	local comment_line_regex="^${comment_id}$"
	if grep -q "$comment_line_regex" "$responded_file" 2>/dev/null; then
		return 0
	fi
	return 1
}

_mark_comment_skipped() {
	local responded_file="$1"
	local comment_id="$2"
	local reason="$3"
	if _comment_already_recorded "$responded_file" "$comment_id"; then
		return 0
	fi
	printf '%s\n' "$comment_id" >>"$responded_file"
	_log "dispatch: comment ${comment_id} marked skipped (${reason})"
	return 0
}

_routine_ops_comment_regex() {
	printf '%s\n' '^(DISPATCH_CLAIM|DISPATCH_RELEASED|CLAIM_RELEASED|<!-- ops:|<!-- routine-description|<!-- aidevops:sig|## (Cascade Tier Escalation|BLOCKED|Closing|Routine|Worker|Dispatch|Audit|MERGE_SUMMARY)|### (Worker|Audit)|\[aidevops\])'
	return 0
}

_is_routine_ops_comment() {
	local body="$1"
	local ops_regex
	ops_regex=$(_routine_ops_comment_regex)
	if printf '%s' "$body" | grep -qE "$ops_regex"; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# scan <repo_slug> <repo_path>
# Finds routine-tracking issues with unanswered user comments.
# A comment is "unanswered" if:
#   - It's from a non-bot user (not [bot] suffix, not the repo owner acting as automation)
#   - No subsequent comment from a bot or the system exists after it
#   - It hasn't been responded to in a previous scan (tracked in state file)
# ---------------------------------------------------------------------------
cmd_scan() {
	local repo_slug="$1"
	local repo_path="$2"

	local self_login
	self_login=$(_get_self_login)
	if [[ -z "$self_login" ]]; then
		_log "scan: cannot detect GitHub login — skipping"
		return 0
	fi

	# Get routine-tracking issues
	local issues_json
	issues_json=$(gh issue list --repo "$repo_slug" --label "routine-tracking" \
		--state open --json number --jq '.[].number' 2>/dev/null) || issues_json=""

	if [[ -z "$issues_json" ]]; then
		_log "scan: no routine-tracking issues found in ${repo_slug}"
		return 0
	fi

	local responded_file
	responded_file=$(_responded_file_for_repo "$repo_slug")
	touch "$responded_file"

	local ops_regex
	ops_regex=$(_routine_ops_comment_regex)

	local found=0
	while IFS= read -r issue_number; do
		[[ -z "$issue_number" ]] && continue

		# Get comments on this issue
		local comments_json
		comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--jq '.[] | {id, author: .user.login, is_bot: (.user.type == "Bot"), created: .created_at, body: .body}' 2>/dev/null) || continue

		[[ -z "$comments_json" ]] && continue

		# Process each comment — find user comments that haven't been responded to
		echo "$comments_json" | jq -r --arg ops_regex "$ops_regex" 'select(.is_bot == false) | select(.body | test($ops_regex) | not) | "\(.id)|\(.author)|\(.body | split("\n")[0] | .[0:100])"' 2>/dev/null |
			while IFS='|' read -r comment_id author body_preview; do
				[[ -z "$comment_id" ]] && continue

				# Skip if this is the repo owner posting dispatch/ops content
				# (the self_login check catches automated comments from the user's account)
				if [[ "$author" == "$self_login" ]]; then
					# Check if this looks like a genuine user comment (not automation)
					# Automation comments start with specific markers
					if _is_routine_ops_comment "$body_preview"; then
						continue
					fi
				fi

				# Skip if already responded to
				if _comment_already_recorded "$responded_file" "$comment_id"; then
					continue
				fi

				echo "${issue_number}|${comment_id}|${author}|${body_preview}"
				found=$((found + 1))
			done
	done <<<"$issues_json"

	_log "scan: found ${found} unanswered comments in ${repo_slug}"
	return 0
}

# ---------------------------------------------------------------------------
# dispatch <repo_slug> <repo_path> <issue_number> <comment_id>
# Dispatches a lightweight worker to respond to a specific comment.
# Uses a focused prompt — NOT /full-loop.
# ---------------------------------------------------------------------------
cmd_dispatch() {
	local repo_slug="$1"
	local repo_path="$2"
	local issue_number="$3"
	local comment_id="$4"

	local responded_file
	responded_file=$(_responded_file_for_repo "$repo_slug")
	touch "$responded_file"

	# Double-check the comment still exists and hasn't been responded to
	if _comment_already_recorded "$responded_file" "$comment_id"; then
		_log "dispatch: comment ${comment_id} on #${issue_number} already responded to — skipping"
		return 0
	fi

	# Get the comment body
	local comment_body lookup_error
	lookup_error=""
	comment_body=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments/${comment_id}" \
		--jq '.body' 2>&1) || {
		lookup_error="$comment_body"
		comment_body=""
	}
	if [[ -z "$comment_body" ]]; then
		local lookup_summary="empty response"
		if [[ -n "$lookup_error" ]]; then
			lookup_summary="${lookup_error%%$'\n'*}"
		fi
		_log "dispatch: comment ${comment_id} on #${issue_number} lookup failed — skipping (${lookup_summary})"
		_mark_comment_skipped "$responded_file" "$comment_id" "lookup failed"
		return 0
	fi

	if _is_routine_ops_comment "$comment_body"; then
		_log "dispatch: comment ${comment_id} on #${issue_number} is routine ops/audit content — skipping"
		_mark_comment_skipped "$responded_file" "$comment_id" "routine ops/audit content"
		return 0
	fi

	local comment_author
	comment_author=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments/${comment_id}" \
		--jq '.user.login' 2>/dev/null) || comment_author="unknown"

	# Get the issue body for context
	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body,title \
		--jq '"\(.title)\n\n\(.body)"' 2>/dev/null) || issue_body=""

	# Build the focused prompt
	local prompt
	prompt="Respond to a user comment on routine tracking issue #${issue_number} in ${repo_slug}.

IMPORTANT: This is a routine-tracking issue — a dashboard for execution metrics.
You are NOT implementing anything. You are responding to a user's comment.

## Issue context (read-only — do not edit the issue body)

${issue_body}

## User comment from @${comment_author}

${comment_body}

## Instructions

Read the AGENTS.md in this repo for full guidance on handling comments.

Summary:
1. If it's a QUESTION about the routine: answer using the issue body description,
   routine logs at ~/.aidevops/.agent-workspace/cron/<routine-id>/, and
   routine-log-helper.sh status. Post your answer as a comment on issue #${issue_number}.

2. If it's a CHANGE REQUEST (e.g. change schedule, disable, enable):
   - Edit TODO.md in this repo to apply the change (direct to main, no PR needed)
   - Post a comment on issue #${issue_number} confirming the change with before/after values
   - If the change requires modifying framework code, explain that and suggest filing
     an issue on the main aidevops repo instead

3. If it's a BUG REPORT about the routine itself:
   - Post a comment acknowledging the report
   - Create an issue on the main aidevops repo with the bug details

4. Post your response as a comment on issue #${issue_number} using:
   gh issue comment ${issue_number} --repo ${repo_slug} --body \"your response\"

5. Keep responses concise and helpful. No signature footers needed for comment responses."

	# Dispatch via headless-runtime-helper
	local session_key="routine-comment-${issue_number}-${comment_id}"

	_log "dispatch: responding to comment ${comment_id} by @${comment_author} on #${issue_number} in ${repo_slug}"

	if [[ -f "${SCRIPT_DIR}/headless-runtime-helper.sh" ]]; then
		"${SCRIPT_DIR}/headless-runtime-helper.sh" run \
			--role worker \
			--session-key "$session_key" \
			--dir "$repo_path" \
			--title "Routine comment response #${issue_number}" \
			--prompt "$prompt" \
			--model "anthropic/claude-haiku-4-5" &

		# Mark as responded immediately (the worker will handle the actual response)
		echo "$comment_id" >>"$responded_file"
		_log "dispatch: worker dispatched for comment ${comment_id} on #${issue_number}"
	else
		_log "dispatch: headless-runtime-helper.sh not found — cannot dispatch"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local cmd="${1:-}"
	shift || true

	case "$cmd" in
	scan)
		if [[ $# -lt 2 ]]; then
			echo "Usage: routine-comment-responder.sh scan <repo_slug> <repo_path>" >&2
			return 1
		fi
		cmd_scan "$@"
		;;
	dispatch)
		if [[ $# -lt 4 ]]; then
			echo "Usage: routine-comment-responder.sh dispatch <repo_slug> <repo_path> <issue_number> <comment_id>" >&2
			return 1
		fi
		cmd_dispatch "$@"
		;;
	*)
		echo "Usage: routine-comment-responder.sh {scan|dispatch} ..." >&2
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
