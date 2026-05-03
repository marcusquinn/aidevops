#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# audit-worktree-removal-helper.sh — Canonical audit logger for worktree-removal events (t2976).
#
# Every worktree removal event — taken or skipped — should leave exactly one structured
# log line in cleanup_worktrees.log. This helper centralises that write so callers
# never need to construct the format themselves.
#
# Usage (source this file, then call the function):
#   # shellcheck source=audit-worktree-removal-helper.sh
#   source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
#   log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/path/to/wt" "branch-merged" "permanent"
#
# Event types (use the constants below to avoid repeated literal violations):
#   _WTAR_REMOVED          "removed"        — worktree was actually removed
#   _WTAR_SKIPPED          "skipped"        — removal was blocked
#   _WTAR_FIXTURE_REMOVED  "fixture-removed" — removed during test teardown
#
# Reason values (non-exhaustive — free-form, kept short):
#   branch-merged     — PR/branch has merged; worktree no longer needed
#   age-eligible      — orphan exceeded age threshold (crashed/abandoned worker)
#   manual            — operator called remove directly
#   owned-skip        — owned by another active session (registry or pgrep match)
#   grace-period      — within WORKTREE_CLEAN_GRACE_HOURS, not safe to remove yet
#   open-pr           — branch has an open PR; active work in progress
#   zero-commit-dirty — 0 commits ahead + dirty files = in-progress, not merged
#   empty-branch      — 0 commits ahead = pre-work branch (t3545/GH#22606)
#   active-claim      — interactive-session claim stamp present (t2916/GH#21074)
#   current-worktree  — caller is inside this worktree (GH#22154)
#   dirty-skip        — uncommitted changes present, --force-merged not set
#   fixture           — test fixture teardown path
#
# Environment:
#   AIDEVOPS_CLEANUP_LOG — override log file path (default: ~/.aidevops/logs/cleanup_worktrees.log)
#
# Compatibility: bash 3.2+ (macOS default). Uses printf, not echo -e.
# Fail-open: log write failures are silently swallowed — callers must not depend on
# this helper succeeding for their own logic.

# Guard against double-sourcing
[[ "${_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED:-}" == "1" ]] && return 0
_AUDIT_WORKTREE_REMOVAL_HELPER_LOADED=1

# =============================================================================
# Event-type constants — callers should use these instead of inline string
# literals to stay below the pre-commit repeated-literal ratchet threshold.
# =============================================================================
_WTAR_REMOVED="removed"
_WTAR_SKIPPED="skipped"
_WTAR_FIXTURE_REMOVED="fixture-removed"

# =============================================================================
# log_worktree_removal_event — write one structured log line per event
#
# Args:
#   $1  event_type  — use $_WTAR_REMOVED / $_WTAR_SKIPPED / $_WTAR_FIXTURE_REMOVED
#   $2  caller      — basename of the calling script (e.g. "worktree-helper.sh")
#   $3  wt_path     — absolute path to the worktree
#   $4  reason      — short reason string (see Reason values above)
#   $5  mode        — optional removal mode: trash, permanent, fixture, skipped
#
# Output format (append to AIDEVOPS_CLEANUP_LOG):
#   [2026-04-27T11:22:33Z] [worktree-helper.sh] worktree-removed: /path/to/wt — branch-merged — mode=permanent
#
# Returns 0 always (fail-open).
# =============================================================================
log_worktree_removal_event() {
	local event_type="$1"
	local caller="$2"
	local wt_path="$3"
	local reason="$4"
	local mode="${5:-unknown}"
	local log_file="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"

	# Ensure log directory exists (silent; don't fail callers on permission errors)
	mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

	# Write one structured line and swallow any write error (fail-open)
	printf '[%s] [%s] worktree-%s: %s — %s — mode=%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$caller" \
		"$event_type" \
		"$wt_path" \
		"$reason" \
		"$mode" \
		>>"$log_file" 2>/dev/null || true

	return 0
}

# Return 0 when any live process has its current working directory inside the
# candidate worktree. `pgrep -f "$path"` only sees argv; commands such as
# linters often run with cwd inside the worktree while their argv contains no
# path, so deletion would make them fail with getcwd/uv_cwd ENOENT.
_worktree_has_process_cwd() {
	local wt_path="$1"
	local wt_path_real="$2"

	if [[ -d /proc ]]; then
		local cwd_link=""
		local cwd_target=""
		for cwd_link in /proc/[0-9]*/cwd; do
			[[ -e "$cwd_link" ]] || continue
			cwd_target=$(readlink "$cwd_link" 2>/dev/null || true)
			[[ -n "$cwd_target" ]] || continue
			case "$cwd_target" in
			"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
				return 0
				;;
			esac
		done
	fi

	if command -v lsof >/dev/null 2>&1; then
		local lsof_output=""
		lsof_output=$(lsof -n -F f +D "$wt_path_real" 2>/dev/null || true)
		case "$lsof_output" in
			fcwd | fcwd$'\n'* | *$'\n'fcwd | *$'\n'fcwd$'\n'*)
				return 0
				;;
		esac
	fi

	return 1
}

# =============================================================================
# worktree_removal_guard — shared destructive-path guard for production cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — reason to log on skip
#
# Refuses registered canonical repos, the caller's current working directory,
# and worktrees that still have any live process cwd inside them.
# Returns 0 when callers may continue, 1 when removal must be skipped.
# =============================================================================
worktree_removal_guard() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"

	if [[ -z "$wt_path" ]]; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "empty-path" "skipped"
		return 1
	fi

	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$wt_path"; then
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "canonical-skip" "skipped"
			return 1
		fi
	fi

	local wt_path_real="$wt_path"
	if [[ -e "$wt_path" ]]; then
		wt_path_real=$(cd "$wt_path" 2>/dev/null && pwd -P) || wt_path_real="$wt_path"
	fi

	local current_dir=""
	current_dir=$(pwd -P 2>/dev/null || true)
	if [[ -n "$current_dir" ]]; then
		case "$current_dir" in
		"$wt_path" | "$wt_path"/* | "$wt_path_real" | "$wt_path_real"/*)
			log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "current-worktree" "skipped"
			return 1
			;;
		esac
	fi

	if _worktree_has_process_cwd "$wt_path" "$wt_path_real"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$wt_path" "active-cwd" "skipped"
		return 1
	fi

	: "$reason"
	return 0
}

# =============================================================================
# remove_worktree_path_permanently — guarded direct delete for verified cleanup
#
# Args:
#   $1  wt_path  — absolute path candidate
#   $2  caller   — audit caller constant
#   $3  reason   — audit reason on removal
#
# Returns 0 when path is gone, 1 on guard/delete failure.
# =============================================================================
remove_worktree_path_permanently() {
	local wt_path="$1"
	local caller="$2"
	local reason="$3"

	worktree_removal_guard "$wt_path" "$caller" "$reason" || return 1
	[[ ! -e "$wt_path" ]] && return 0

	if rm -rf "$wt_path" 2>/dev/null; then
		log_worktree_removal_event "$_WTAR_REMOVED" "$caller" "$wt_path" "$reason" "permanent"
		return 0
	fi

	return 1
}
