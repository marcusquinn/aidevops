#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-cursor.sh — resume cursor for the single-pass reconcile
# =============================================================================
# GH#34299: reconcile_issues_single_pass used to restart at the first repo and
# first issue every cycle. When the pass ended by time-budget abort or stage
# timeout, every issue past the abort point was starved indefinitely (e.g. a
# parent tracker whose children had all closed never reached the close stage).
#
# The cursor records the next issue to process. The next pass rotates the slug
# list to start at the cursor slug and skips that slug's earlier issues. A pass
# that reaches the end of the rotated list clears the cursor, so the next pass
# starts from the top again and every issue is visited across cycles.
#
# Cursor file format (one line): slug<TAB>issue_number<TAB>attempts
#   issue_number empty → resume at the start of slug.
#   attempts counts resumes at the same issue that never moved past it (a
#   stage-timeout kill mid-issue). At AIDEVOPS_RECONCILE_SP_CURSOR_MAX_ATTEMPTS the
#   issue is skipped so a single slow issue cannot pin the cursor.
#
# State is held in the caller's locals (Bash 3.2 dynamic scope):
#   _sp_cursor_file _sp_cursor_slug _sp_cursor_issue _sp_cursor_attempts
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_ISSUE_RECONCILE_CURSOR_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_CURSOR_LOADED=1

#######################################
# Load and validate the cursor into the caller's _sp_cursor_* locals. A
# missing, truncated or malformed cursor resets to "start from the top".
# Env: AIDEVOPS_RECONCILE_SP_CURSOR_FILE overrides the default state path.
# Returns: 0 always
#######################################
_pir_sp_cursor_load() {
	_sp_cursor_file="${AIDEVOPS_RECONCILE_SP_CURSOR_FILE:-${HOME}/.aidevops/state/reconcile-single-pass.cursor}"
	_sp_cursor_slug=""
	_sp_cursor_issue=""
	_sp_cursor_attempts=0
	local cursor_dir="${_sp_cursor_file%/*}"
	if [[ "$cursor_dir" != "$_sp_cursor_file" && ! -d "$cursor_dir" ]]; then
		mkdir -p "$cursor_dir" 2>/dev/null || true
	fi
	[[ -r "$_sp_cursor_file" ]] || return 0
	local line="" slug="" issue="" attempts=""
	IFS= read -r line <"$_sp_cursor_file" || [[ -n "$line" ]] || return 0
	IFS=$'\t' read -r slug issue attempts <<<"$line"
	[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
	[[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || return 0
	[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
	_sp_cursor_slug="$slug"
	_sp_cursor_issue="$issue"
	_sp_cursor_attempts="$attempts"
	return 0
}

#######################################
# Record the next position to process. Builtin printf with a redirect, so
# per-issue writes do not fork. A failed write is non-fatal: the next pass
# simply starts from the top, which is the pre-GH#34299 behaviour.
# Args: $1=slug $2=issue number (may be empty) $3=attempts (default 0)
# Returns: 0 always
#######################################
_pir_sp_cursor_write() {
	local slug="$1" issue="${2:-}" attempts="${3:-0}"
	[[ -n "${_sp_cursor_file:-}" ]] || return 0
	printf '%s\t%s\t%s\n' "$slug" "$issue" "$attempts" >"$_sp_cursor_file" 2>/dev/null || true
	return 0
}

#######################################
# Remove the cursor after a pass that reached the end of the rotated list.
# Returns: 0 always
#######################################
_pir_sp_cursor_clear() {
	[[ -n "${_sp_cursor_file:-}" ]] || return 0
	rm -f "$_sp_cursor_file" 2>/dev/null || true
	return 0
}

#######################################
# Rotate a newline-separated slug list so it starts at the cursor slug.
# Unknown or empty cursor slug → original order.
# Args: $1=newline-separated slugs
# Output: rotated slugs, one per line
# Returns: 0 always
#######################################
_pir_sp_rotate_slugs() {
	local slugs="$1"
	if [[ -z "${_sp_cursor_slug:-}" ]]; then
		printf '%s\n' "$slugs"
		return 0
	fi
	printf '%s\n' "$slugs" | awk -v start="$_sp_cursor_slug" '
		NF { a[++n] = $0; if ($0 == start && !s) s = n }
		END {
			if (!s) s = 1
			for (i = s; i <= n; i++) print a[i]
			for (i = 1; i < s; i++) print a[i]
		}'
	return 0
}

#######################################
# Decide where the cursor slug's issue loop should start. Sets the caller's
# _sp_seek_issue (issue to fast-forward to, or empty) and _sp_skip_seek_issue
# (1 when that issue exhausted its attempts and must be skipped). Consumes the
# cursor so a slug is only fast-forwarded once per pass.
# Args: $1=slug $2=issues_tsv (rows start with "<number>|")
# Returns: 0 always
#######################################
_pir_sp_cursor_seek_for_slug() {
	local slug="$1" issues_tsv="$2"
	local max_attempts="${AIDEVOPS_RECONCILE_SP_CURSOR_MAX_ATTEMPTS:-2}"
	[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=2
	_sp_seek_issue=""
	_sp_skip_seek_issue=0
	[[ -n "${_sp_cursor_slug:-}" && "$slug" == "$_sp_cursor_slug" ]] || return 0
	local cursor_issue="${_sp_cursor_issue:-}"
	_sp_cursor_slug=""
	[[ -n "$cursor_issue" ]] || return 0
	case $'\n'"$issues_tsv" in
	*$'\n'"${cursor_issue}|"*) ;;
	*) return 0 ;; # issue no longer open/cached: start the slug from the top
	esac
	_sp_seek_issue="$cursor_issue"
	if [[ "${_sp_cursor_attempts:-0}" -ge "$max_attempts" ]]; then
		_sp_skip_seek_issue=1
		echo "[pulse-wrapper] reconcile_issues_single_pass: skipping ${slug}#${cursor_issue} after ${_sp_cursor_attempts} unfinished resume(s) (GH#34299)" >>"${LOGFILE:-/dev/null}"
	else
		echo "[pulse-wrapper] reconcile_issues_single_pass: resuming at ${slug}#${cursor_issue} (GH#34299)" >>"${LOGFILE:-/dev/null}"
	fi
	return 0
}
