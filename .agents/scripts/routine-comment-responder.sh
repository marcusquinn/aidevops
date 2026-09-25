#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# routine-comment-responder.sh — Detect and respond to user comments on
# routine-tracking issues. Public comments are never worker instructions.
#
# Usage:
#   routine-comment-responder.sh scan <repo_slug> <repo_path>
#   routine-comment-responder.sh dispatch <repo_slug> <repo_path> <issue_number> <comment_id>
#
# scan:     Finds routine-tracking issues with unanswered user comments.
#           Outputs one line per unanswered comment: issue_number|comment_id|author|
#
# dispatch: Records a content-free handoff; does not launch a worker.

set -euo pipefail

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
	if [[ "$body" =~ $ops_regex ]]; then
		return 0
	fi
	return 1
}

_fetch_comment() {
	local repo_slug="$1"
	local issue_number="$2"
	local comment_id="$3"
	local comment_json
	comment_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments/${comment_id}" 2>/dev/null) || comment_json=""
	if [[ -z "$comment_json" ]]; then
		printf '{}\n'
		return 0
	fi

	if ! printf '%s\n' "$comment_json" | jq . >/dev/null; then
		printf '{}\n'
		return 0
	fi

	printf '%s\n' "$comment_json"
	return 0
}

_comment_authority() {
	local repo_slug="$1"
	local comment_json="$2"
	local login permission_json permission
	login=$(printf '%s\n' "$comment_json" | jq -r '.user.login // empty') || return 1
	[[ "$login" =~ ^[a-zA-Z0-9-]{1,39}$ && "$login" != "unknown" ]] || return 1
	# aidevops:trust-boundary -- never trust scan previews or author_association as permission.
	permission_json=$(gh api "repos/${repo_slug}/collaborators/${login}/permission" 2>/dev/null) || return 1
	permission=$(printf '%s\n' "$permission_json" | jq -r '.permission // empty' 2>/dev/null) || return 1
	[[ "$permission" == "admin" || "$permission" == "maintain" || "$permission" == "write" ]]
}

_record_handoff() {
	local repo_slug="$1" issue_number="$2" comment_id="$3" reason="$4"
	local handoff_file="${STATE_DIR}/${repo_slug//\//_}_handoff.txt"
	# Do not mark answered: recovering isolation later must still see this comment.
	if ! _comment_already_recorded "$handoff_file" "$comment_id"; then
		printf '%s\n' "$comment_id" >>"$handoff_file"
		_log "dispatch: #${issue_number} comment ${comment_id} needs manual routine response (${reason}); no worker launched"
	fi
	return 0
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
	local handoff_file="${STATE_DIR}/${repo_slug//\//_}_handoff.txt"

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

		# Do not export public comment text to the caller, even as a preview.
		echo "$comments_json" | jq -r --arg ops_regex "$ops_regex" 'select(.is_bot == false) | .body |= (. // "") | select(.body | test($ops_regex) | not) | "\(.id)|\(.author)|"' |
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
				# Manual handoffs remain recoverable in their own state file,
				# but do not starve later comments on every Pulse cycle.
				if _comment_already_recorded "$handoff_file" "$comment_id"; then
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
# Records an observable manual handoff; no public content reaches a worker.
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

	local comment_json comment_body
	if ! comment_json=$(_fetch_comment "$repo_slug" "$issue_number" "$comment_id"); then
		return 0
	fi
	if [[ "$comment_json" == "{}" ]]; then
		_record_handoff "$repo_slug" "$issue_number" "$comment_id" "comment lookup unavailable"
		return 1
	fi
	comment_body=$(printf '%s\n' "$comment_json" | jq -r '.body // ""')

	if _is_routine_ops_comment "$comment_body"; then
		_log "dispatch: comment ${comment_id} on #${issue_number} is routine ops/audit content — skipping"
		_mark_comment_skipped "$responded_file" "$comment_id" "routine ops/audit content"
		return 0
	fi

	# aidevops:trust-boundary -- definitive re-fetch and independent permission check.
	# Until process-tree isolation and egress are guaranteed, even trusted authors
	# receive a content-free manual handoff, never a privileged worker.
	if ! _comment_authority "$repo_slug" "$comment_json"; then
		_record_handoff "$repo_slug" "$issue_number" "$comment_id" "unverified author"
	else
		_record_handoff "$repo_slug" "$issue_number" "$comment_id" "worker isolation unavailable"
	fi
	return 1
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
