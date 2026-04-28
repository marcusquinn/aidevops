#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Interactive Session Stamp Management -- Crash-recovery stamp CRUD
# =============================================================================
# Stamp write/delete, stampless claim detection, and claim comment posting.
# Extracted from interactive-session-helper.sh (GH#21320).
#
# Usage: source "${SCRIPT_DIR}/interactive-session-helper-stamp.sh"
#
# Dependencies:
#   - shared-constants.sh (_compute_argv_hash, gh_issue_comment, _filter_non_task_issues)
#   - Logging functions from interactive-session-helper.sh (_isc_info, _isc_warn, _isc_err)
#   - CLAIM_STAMP_DIR, _isc_slug_flat, _isc_stamp_path from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISC_STAMP_LIB_LOADED:-}" ]] && return 0
_ISC_STAMP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Write a stamp JSON file for a claim. Idempotent — overwrites on re-call so
# the `claimed_at` timestamp refreshes for crash-recovery tie-breaks.
_isc_write_stamp() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"

	mkdir -p "$CLAIM_STAMP_DIR" 2>/dev/null || {
		_isc_warn "cannot create stamp dir: $CLAIM_STAMP_DIR (continuing)"
		return 0
	}

	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")

	local timestamp hostname
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	hostname=$(hostname 2>/dev/null || echo "unknown")

	# t2421: compute argv hash for PID-reuse-resistant liveness checks.
	# Stored in the stamp so scan-stale can verify PID identity later.
	local argv_hash=""
	argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || echo "")

	# Escape user-supplied fields via jq's string literals to avoid JSON injection
	jq -n \
		--arg issue "$issue" \
		--arg slug "$slug" \
		--arg worktree "$worktree_path" \
		--arg claimed_at "$timestamp" \
		--arg pid "$$" \
		--arg hostname "$hostname" \
		--arg user "$user" \
		--arg argv_hash "$argv_hash" \
		'{
			issue: ($issue | tonumber),
			slug: $slug,
			worktree_path: $worktree,
			claimed_at: $claimed_at,
			pid: ($pid | tonumber),
			hostname: $hostname,
			user: $user,
			owner_argv_hash: $argv_hash
		}' >"$stamp_file" 2>/dev/null || {
		_isc_warn "failed to write stamp: $stamp_file"
		return 0
	}
	return 0
}

# Delete a stamp file. No-op when the file doesn't exist.
_isc_delete_stamp() {
	local issue="$1"
	local slug="$2"
	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")
	rm -f "$stamp_file" 2>/dev/null || true
	return 0
}

# List stampless origin:interactive claims for a single repo (t2148).
#
# Detection rule: an issue is a "stampless interactive claim" when all of:
#   - state: OPEN
#   - .labels[] contains "origin:interactive"
#   - .assignees[] contains runner_user
#   - no matching stamp file exists at $(_isc_stamp_path issue slug)
#
# These are the zombie claims that block pulse dispatch forever:
# `_has_active_claim()` (in dispatch-dedup-helper.sh) treats
# `origin:interactive` as an active claim regardless of stamp state,
# but `_isc_cmd_scan_stale` Phase 1 only iterates `$CLAIM_STAMP_DIR`
# so stampless ones are invisible. Typical cause: `claim-task-id.sh`
# auto-assigned runner on issue creation (per t1970 for maintainer-gate
# protection), but the interactive session never ran the formal claim
# flow, so no stamp was written.
#
# Args:
#   $1 runner_user — GH login of current runner (from `gh api user`)
#   $2 slug        — owner/repo
# Stdout: newline-separated JSON lines `{"number":N,"updated_at":"...",
#         "slug":"..."}` (one per stampless claim). Empty on failure.
# Exit: 0 always (fail-open for discovery — a transient gh/jq error
#       should not mask genuine claims on the next scan).
_isc_list_stampless_interactive_claims() {
	local runner_user="$1"
	local slug="$2"

	[[ -n "$runner_user" && -n "$slug" ]] || return 0

	local json
	json=$(gh issue list --repo "$slug" \
		--assignee "$runner_user" \
		--label origin:interactive \
		--state open \
		--json number,updatedAt,labels \
		--limit 200 2>/dev/null) || return 0

	[[ -n "$json" && "$json" != "null" ]] || return 0

	# GH#20048: filter out non-task issues (routine-tracking, supervisor, etc.)
	# before the stampless scan so they are never surfaced as false positives.
	json=$(printf '%s' "$json" | _filter_non_task_issues) || return 0
	[[ -n "$json" && "$json" != "[]" ]] || return 0

	# Emit (number, updated_at) tuples; shell filters stampless.
	local rows
	rows=$(printf '%s' "$json" | jq -r '
		.[] | "\(.number)\t\(.updatedAt)"
	' 2>/dev/null) || return 0

	[[ -n "$rows" ]] || return 0

	local issue updated_at stamp
	while IFS=$'\t' read -r issue updated_at; do
		[[ "$issue" =~ ^[0-9]+$ ]] || continue
		stamp=$(_isc_stamp_path "$issue" "$slug")
		if [[ ! -f "$stamp" ]]; then
			# Emit compact (single-line) JSON so callers can parse row-by-row
			# via `while IFS= read -r row`. Pretty-printed multi-line output
			# breaks line-based parsing (see t2148 Test 14 regression).
			jq -nc \
				--arg slug "$slug" \
				--arg updated_at "$updated_at" \
				--arg issue "$issue" \
				'{number: ($issue | tonumber), updated_at: $updated_at, slug: $slug}' \
				2>/dev/null || true
		fi
	done <<<"$rows"

	return 0
}

# Post a claim comment on the issue for audit trail visibility.
# Mirrors worker dispatch comments but for interactive sessions.
# Best-effort — all errors are swallowed so the caller never stalls.
#
# Arguments:
#   $1 = issue number, $2 = repo slug, $3 = user login, $4 = worktree path
_isc_post_claim_comment() {
	local issue="$1"
	local slug="$2"
	local user="$3"
	local worktree_path="$4"

	local hostname
	hostname=$(hostname 2>/dev/null || echo "unknown")
	local worktree_note=""
	if [[ -n "$worktree_path" ]]; then
		worktree_note=" in \`${worktree_path##*/}\`"
	fi

	# <!-- ops:start --> / <!-- ops:end --> markers let the agent skip this
	# comment when reading issue threads (see build.txt 8d).
	local body
	body=$(
		cat <<EOF
<!-- ops:start -->
> Interactive session claimed by @${user}${worktree_note} on ${hostname}.
> Pulse dispatch blocked via \`status:in-review\` + self-assignment.
<!-- ops:end -->
EOF
	)

	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "claim comment failed on #$issue — continuing (audit trail incomplete)"
	}
	return 0
}
