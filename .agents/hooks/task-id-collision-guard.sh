#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# task-id-collision-guard.sh — git commit-msg hook and CI check.
#
# Scans commit subjects (and bodies) for t\d+ references and rejects commits
# where a referenced t-ID appears to be invented — i.e., greater than the
# current .task-counter on the merge base AND not cross-referenced via a
# linked GitHub issue title that confirms the ID was claimed by someone else.
#
# Modes:
#   Default (commit-msg hook):
#     Called with $1 = path to the commit message file.
#     Exits 0 (allow) or 1 (reject with actionable error).
#
#   check-pr <PR_NUMBER>:
#     Scans every commit in the PR range (merge-base..HEAD).
#     Used by CI to catch commits authored outside the hook.
#     Exits 0 (all clean) or 1 (one or more violations).
#
# Environment:
#   TASK_ID_GUARD_DISABLE=1   — bypass for this invocation (equivalent to --no-verify)
#   TASK_ID_GUARD_DEBUG=1     — verbose stderr trace
#
# Fail-open cases (exit 0 with warning):
#   - gh CLI unavailable or unauthenticated
#   - .task-counter not present on merge base
#   - offline state
#   - git command failures

set -u

# ---------------------------------------------------------------------------
# Bypass
# ---------------------------------------------------------------------------

if [[ "${TASK_ID_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[task-id-guard][INFO] TASK_ID_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_debug() {
	[[ "${TASK_ID_GUARD_DEBUG:-0}" == "1" ]] && printf '[task-id-guard][DEBUG] %s\n' "$1" >&2
	return 0
}

_warn() {
	printf '[task-id-guard][WARN] %s\n' "$1" >&2
	return 0
}

_info() {
	printf '[task-id-guard][INFO] %s\n' "$1" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Read the .task-counter value at a given git ref.
# Returns the integer or empty string on failure.
# ---------------------------------------------------------------------------
_read_counter_at_ref() {
	local ref="${1:-}"
	if [[ -z "$ref" ]]; then
		return 1
	fi
	local val
	val=$(git show "${ref}:.task-counter" 2>/dev/null | tr -d '[:space:]')
	if [[ "$val" =~ ^[0-9]+$ ]]; then
		printf '%s' "$val"
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Determine the merge base between HEAD and the default branch (main/master).
# Falls back to the root commit.
# ---------------------------------------------------------------------------
_find_merge_base() {
	local base=""
	# Try main first, then master
	for branch in main master; do
		if git rev-parse --verify "origin/${branch}" >/dev/null 2>&1; then
			base=$(git merge-base HEAD "origin/${branch}" 2>/dev/null) && break
		elif git rev-parse --verify "$branch" >/dev/null 2>&1; then
			base=$(git merge-base HEAD "$branch" 2>/dev/null) && break
		fi
	done
	if [[ -z "$base" ]]; then
		# Fallback: root commit of the current branch
		base=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
	fi
	printf '%s' "$base"
	return 0
}

# ---------------------------------------------------------------------------
# Extract all tNNN references from text.
# Outputs one per line.
# ---------------------------------------------------------------------------
_extract_tids() {
	local text="${1:-}"
	# Match t followed by one or more digits (word-boundary aware via grep -o)
	printf '%s' "$text" | grep -oE 't[0-9]+' | sort -u
	return 0
}

# ---------------------------------------------------------------------------
# Extract issue numbers from Resolves|Closes|Fixes footer lines.
# Outputs one per line.
# ---------------------------------------------------------------------------
_extract_closing_issues() {
	local text="${1:-}"
	printf '%s' "$text" | grep -iE '(Resolves|Closes|Fixes)[[:space:]]+#[0-9]+' |
		grep -oE '#[0-9]+' | tr -d '#' | sort -u
	return 0
}

# ---------------------------------------------------------------------------
# Core check: given a commit message, check if any t\d+ reference is invented.
# Args:
#   $1 = full commit message text
#   $2 = merge-base git ref (for reading .task-counter)
#   $3 = commit subject (for display in errors), optional
# Returns 0 (clean), 1 (violation found), 2 (fail-open — skip).
# ---------------------------------------------------------------------------
_check_message() {
	local msg="${1:-}"
	local merge_base="${2:-}"
	local subject="${3:-<unknown>}"

	if [[ -z "$msg" ]]; then
		_debug "Empty commit message — allowing"
		return 0
	fi

	# Extract first line as the subject if not provided
	if [[ "$subject" == "<unknown>" ]]; then
		subject=$(printf '%s' "$msg" | head -1)
	fi

	# Find all t-ID references
	local tids
	tids=$(_extract_tids "$msg")
	if [[ -z "$tids" ]]; then
		_debug "No t-IDs in commit — allowing"
		return 0
	fi

	_debug "Found t-IDs: $(printf '%s' "$tids" | tr '\n' ' ')"

	# Read counter at merge base
	local counter=""
	if [[ -n "$merge_base" ]]; then
		counter=$(_read_counter_at_ref "$merge_base")
	fi

	if [[ -z "$counter" ]]; then
		_warn ".task-counter not readable at merge base '${merge_base}' — fail-open"
		return 2
	fi

	_debug "Merge-base counter value: $counter"

	# Extract closing issue numbers from the commit footer
	local closing_issues
	closing_issues=$(_extract_closing_issues "$msg")
	_debug "Closing issues: $(printf '%s' "$closing_issues" | tr '\n' ' ')"

	# Check each t-ID
	local violations=""
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		local num
		num=$(printf '%s' "$tid" | tr -d 't')

		if ! [[ "$num" =~ ^[0-9]+$ ]]; then
			_debug "Non-numeric suffix for $tid — skipping"
			continue
		fi

		# If numeric_id <= counter, the ID is claimed (or pre-dates the counter)
		if [[ "$num" -le "$counter" ]]; then
			_debug "$tid ≤ counter ($counter) — allowed"
			continue
		fi

		_debug "$tid ($num) > counter ($counter) — suspicious, checking linked issues"

		# The ID is beyond the current counter. Check if any linked issue title
		# contains this t-ID (cross-reference confirmation).
		local confirmed=0

		if [[ -z "$closing_issues" ]]; then
			# No closing issues — cannot possibly cross-reference. Reject.
			_debug "$tid: no closing issues — marking as violation"
			violations="${violations}  ${tid} — numeric ID ${num} > current counter ${counter}, and not confirmed via a linked issue title\n"
			continue
		fi

		# Has closing issues. Need gh to verify — check availability first.
		if ! command -v gh >/dev/null 2>&1; then
			_warn "gh not available — fail-open (CI will validate on push)"
			return 2
		fi

		local iss_num
		local gh_had_error=0
		while IFS= read -r iss_num; do
			[[ -z "$iss_num" ]] && continue
			local title
			title=$(gh issue view "$iss_num" --json title --jq '.title' 2>/dev/null)
			local gh_rc=$?
			if [[ "$gh_rc" -ne 0 || -z "$title" ]]; then
				_debug "gh issue view #${iss_num} failed (rc=${gh_rc}) — marking gh_had_error"
				gh_had_error=1
				continue
			fi
			_debug "Issue #${iss_num} title: $title"
			if printf '%s' "$title" | grep -qE "(^|[^0-9])${tid}([^0-9]|$)"; then
				_debug "$tid confirmed via linked issue #${iss_num}"
				confirmed=1
				break
			fi
		done <<<"$closing_issues"

		# If all gh calls failed (offline, unauthenticated, API error) → fail-open
		if [[ "$gh_had_error" -eq 1 && "$confirmed" -eq 0 ]]; then
			_warn "gh API error during cross-reference check — fail-open (CI will validate on push)"
			return 2
		fi

		if [[ "$confirmed" -eq 0 ]]; then
			violations="${violations}  ${tid} — numeric ID ${num} > current counter ${counter}, and not confirmed via a linked issue title\n"
		fi
	done <<<"$tids"

	if [[ -n "$violations" ]]; then
		printf '\n[task-id-guard][BLOCK] Commit subject references invented task ID(s):\n\n' >&2
		printf '  Subject: %s\n\n' "$subject" >&2
		printf '%b\n' "$violations" >&2
		printf '  To fix:\n' >&2
		printf '    1. Remove the t-ID from the commit subject/body, OR\n' >&2
		printf '    2. Claim the ID first: claim-task-id.sh --title "..." → then use the allocated ID, OR\n' >&2
		printf '    3. If cross-referencing another person'"'"'s task, add "Resolves/Closes/Fixes #NNN" footer\n' >&2
		printf '       where the linked issue title contains the t-ID.\n' >&2
		printf '  Bypass (sets audit trail): TASK_ID_GUARD_DISABLE=1 git commit ...  or git commit --no-verify\n\n' >&2
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Commit-msg hook mode (default).
# $1 = path to commit message file
# ---------------------------------------------------------------------------
_run_hook() {
	local msg_file="${1:-}"
	if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
		_warn "commit-msg: no message file provided — fail-open"
		return 0
	fi

	local msg
	msg=$(cat "$msg_file")
	local subject
	subject=$(head -1 "$msg_file")

	# Skip merge commits, fixup commits, and squash commits
	if printf '%s' "$subject" | grep -qE '^(Merge|fixup!|squash!)'; then
		_debug "Merge/fixup/squash commit — skipping"
		return 0
	fi

	local merge_base
	merge_base=$(_find_merge_base)
	_debug "Merge base: $merge_base"

	local rc
	_check_message "$msg" "$merge_base" "$subject"
	rc=$?

	if [[ "$rc" -eq 2 ]]; then
		# Fail-open
		return 0
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# CI mode: check-pr <PR_NUMBER>
# Scans every commit in the PR range (merge-base..HEAD).
# ---------------------------------------------------------------------------
_run_check_pr() {
	local pr_number="${1:-}"
	if [[ -z "$pr_number" ]]; then
		printf '[task-id-guard][ERROR] check-pr requires a PR number\n' >&2
		return 1
	fi

	local merge_base
	merge_base=$(_find_merge_base)
	_debug "Merge base for PR #${pr_number}: $merge_base"

	if [[ -z "$merge_base" ]]; then
		_warn "Could not determine merge base — fail-open"
		return 0
	fi

	# Get commits in the PR range
	local commits
	commits=$(git log "${merge_base}..HEAD" --format='%H' 2>/dev/null)
	if [[ -z "$commits" ]]; then
		_info "No commits in PR range — nothing to check"
		return 0
	fi

	local total_violations=0
	local commit_hash
	while IFS= read -r commit_hash; do
		[[ -z "$commit_hash" ]] && continue
		local commit_msg
		commit_msg=$(git log -1 --format='%s%n%n%b' "$commit_hash" 2>/dev/null)
		local subject
		subject=$(git log -1 --format='%s' "$commit_hash" 2>/dev/null)

		_debug "Checking commit $commit_hash: $subject"

		# Skip merge commits
		if printf '%s' "$subject" | grep -qE '^(Merge|fixup!|squash!)'; then
			_debug "Skipping merge/fixup/squash: $commit_hash"
			continue
		fi

		local rc
		_check_message "$commit_msg" "$merge_base" "$subject"
		rc=$?
		if [[ "$rc" -eq 1 ]]; then
			printf '[task-id-guard][VIOLATION] commit %s\n' "$commit_hash" >&2
			total_violations=$((total_violations + 1))
		fi
	done <<<"$commits"

	if [[ "$total_violations" -gt 0 ]]; then
		printf '\n[task-id-guard][SUMMARY] %d violation(s) found in PR #%s\n' "$total_violations" "$pr_number" >&2
		return 1
	fi

	_info "PR #${pr_number}: all commits clean"
	return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
	local mode="${1:-}"
	case "$mode" in
	check-pr)
		shift
		_run_check_pr "$@"
		return $?
		;;
	help | --help | -h)
		sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
		return 0
		;;
	*)
		# Default: commit-msg hook mode. $1 is the message file path.
		_run_hook "${1:-}"
		return $?
		;;
	esac
}

main "$@"
