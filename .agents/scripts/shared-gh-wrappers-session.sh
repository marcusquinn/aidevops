#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Session Origin, Token Checks, Internal Wrapper Helpers
# =============================================================================
# Functions for session origin detection, GitHub token scope checks, and
# internal wrapper utilities (arg parsing, auto-assignee, auto-signature).
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-session.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, etc.)
#   - gh CLI
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_SESSION_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_SESSION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# GitHub Token Workflow Scope Check (t1540)
# =============================================================================
# Reusable function to check if the current gh token has the `workflow` scope.
# Without this scope, git push and gh pr merge fail for branches that modify
# .github/workflows/ files. The error is:
#   "refusing to allow an OAuth App to create or update workflow without workflow scope"
#
# Usage:
#   if ! gh_token_has_workflow_scope; then
#       echo "Missing workflow scope — run: gh auth refresh -s workflow"
#   fi
#
# Returns: 0 if token has workflow scope, 1 if missing, 2 if unable to check

gh_token_has_workflow_scope() {
	if ! command -v gh &>/dev/null; then
		return 2
	fi

	local auth_output
	auth_output=$(gh auth status 2>&1) || return 2

	# gh auth status outputs scopes in various formats depending on version:
	#   Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo', 'workflow'
	#   Token scopes: admin:public_key, gist, read:org, repo, workflow
	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	return 1
}

# Check if a set of file paths includes .github/workflows/ changes.
# Accepts file paths on stdin (one per line) or as arguments.
#
# Usage:
#   git diff --name-only HEAD~1 | files_include_workflow_changes
#   files_include_workflow_changes ".github/workflows/ci.yml" "src/main.sh"
#
# Returns: 0 if workflow files found, 1 if not
files_include_workflow_changes() {
	if [[ $# -gt 0 ]]; then
		# Check arguments
		local f
		for f in "$@"; do
			if [[ "$f" == .github/workflows/* ]]; then
				return 0
			fi
		done
		return 1
	fi

	# Check stdin
	local line
	while IFS= read -r line; do
		if [[ "$line" == .github/workflows/* ]]; then
			return 0
		fi
	done
	return 1
}

# =============================================================================
# Session Origin Detection
# =============================================================================
# Detects whether the current session is a headless worker or interactive user.
# Used to tag issues, TODOs, and PRs with origin:worker or origin:interactive.
#
# Design: inverted logic — detect known headless signals, default to interactive.
# AI coding tools (OpenCode, Claude Code, Cursor, Kiro, Codex, Windsurf, etc.)
# all run bash tools without a TTY, so TTY presence is not a reliable signal.
# The headless dispatch infrastructure sets explicit env vars; everything else
# is a user session.
#
# Known headless signals (exhaustive — add new ones here as dispatch infra grows):
#   FULL_LOOP_HEADLESS=true   — pulse supervisor dispatch
#   AIDEVOPS_HEADLESS=true    — headless-runtime-helper.sh
#   OPENCODE_HEADLESS=true    — OpenCode headless mode
#   GITHUB_ACTIONS=true       — CI environment
#
# Default: interactive — covers all AI coding tools without runtime-specific checks.
#
# Usage:
#   local origin; origin=$(detect_session_origin)
#   # Returns: "worker" or "interactive"
#
#   local label; label=$(session_origin_label)
#   # Returns: "origin:worker" or "origin:interactive"

detect_session_origin() {
	# t1984: Explicit override via AIDEVOPS_SESSION_ORIGIN takes precedence
	# over the headless auto-detection. Used by the sync-todo-to-issues
	# workflow to mark issues created from human-triggered TODO.md pushes
	# as origin:interactive rather than origin:worker, so the t1970 auto-
	# assign path fires and the Maintainer Gate doesn't block downstream PRs.
	case "${AIDEVOPS_SESSION_ORIGIN:-}" in
	interactive)
		echo "interactive"
		return 0
		;;
	worker)
		echo "worker"
		return 0
		;;
	esac

	# Known headless signals — set by dispatch infrastructure only.
	# If none of these are set, the session is interactive by default.
	if [[ "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${AIDEVOPS_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${OPENCODE_HEADLESS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		echo "worker"
		return 0
	fi
	# Default: interactive.
	# Covers all AI coding tools (OpenCode, Claude Code, Cursor, Kiro, Codex,
	# Windsurf, Gemini CLI, Kimi CLI, etc.) without needing runtime-specific
	# env var checks. TTY presence is NOT checked — it is unreliable for all
	# AI coding tools which run bash tools without a TTY.
	echo "interactive"
	return 0
}

# Returns the GitHub label string for the current session origin.
# Usage: local label; label=$(session_origin_label)
session_origin_label() {
	local origin
	origin=$(detect_session_origin)
	echo "origin:${origin}"
	return 0
}

# =============================================================================
# Origin-Label-Aware gh Wrappers — Internal Helpers (t1756)
# =============================================================================
# Every gh issue/pr create call MUST use these wrappers to ensure the session
# origin label (origin:worker or origin:interactive) is always applied.
# GitHub deduplicates labels, so callers that already pass --label origin:*
# will not get duplicates.

# t2028: Internal — check if argv already contains an --assignee flag.
# Used by gh_create_issue to avoid overriding caller-supplied assignees.
_gh_wrapper_args_have_assignee() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--assignee | --assignee=*)
			return 0
			;;
		*)
			shift
			;;
		esac
	done
	return 1
}

# t2406: Internal — check if argv contains a specific label in any --label arg.
# Supports comma-separated label lists (e.g. --label "bug,auto-dispatch").
# Used by gh_create_issue to apply the t2157 auto-dispatch skip logic.
# Returns 0 if the label is found, 1 otherwise.
_gh_wrapper_args_have_label() {
	local needle="$1"
	shift
	while [[ $# -gt 0 ]]; do
		local cur="$1"
		local label_val=""
		case "$cur" in
		--label)
			local next_val="${2:-}"
			label_val="$next_val"
			shift
			;;
		--label=*)
			label_val="${cur#--label=}"
			;;
		esac
		if [[ -n "$label_val" && ",${label_val}," == *",${needle},"* ]]; then
			return 0
		fi
		shift
	done
	return 1
}

# t2028: Internal — determine the auto-assignee for a newly-created issue.
# Returns empty string when the session is worker-origin, when the user
# lookup fails, or when there is otherwise nothing to assign. Callers must
# treat empty as "skip assignment". Non-fatal: all failure modes echo empty.
#
# Mirrors the _auto_assign_issue logic at claim-task-id.sh:607 (t1970) so
# the direct gh_create_issue path reaches assignee-gate parity with the
# claim-task-id.sh path.
_gh_wrapper_auto_assignee() {
	local origin
	origin=$(detect_session_origin)
	if [[ "$origin" != "interactive" ]]; then
		return 0
	fi
	# t1984 override: sync-todo-to-issues workflow sets AIDEVOPS_SESSION_USER
	# to github.actor when the commit author is human. Prefer that explicit
	# signal over `gh api user`, which would return github-actions[bot]
	# inside a workflow run.
	if [[ -n "${AIDEVOPS_SESSION_USER:-}" ]]; then
		printf '%s' "$AIDEVOPS_SESSION_USER"
		return 0
	fi
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || true)
	if [[ -z "$current_user" ]] || [[ "$current_user" == "null" ]]; then
		return 0
	fi
	printf '%s' "$current_user"
	return 0
}

# t2115: Auto-append signature footer to --body/--body-file when missing.
# Populates global _GH_WRAPPER_SIG_MODIFIED_ARGS with the (possibly modified) args.
# Callers should invoke _gh_wrapper_auto_sig "$@" then
#   set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
# Non-fatal: if signature generation fails, original args are preserved.
_GH_WRAPPER_SIG_MODIFIED_ARGS=()
_gh_wrapper_auto_sig() {
	_GH_WRAPPER_SIG_MODIFIED_ARGS=("$@")
	local sig_helper
	sig_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-signature-helper.sh"
	[[ -x "$sig_helper" ]] || return 0

	local i=0 body_val="" body_idx=-1 is_eq_form=0
	local body_file_val="" body_file_idx=-1 bf_is_eq=0
	while [[ $i -lt ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]} ]]; do
		case "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" in
		--body)
			body_idx=$i
			body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]:-}"
			is_eq_form=0
			;;
		--body=*)
			body_idx=$i
			body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]#--body=}"
			is_eq_form=1
			;;
		--body-file)
			body_file_idx=$i
			body_file_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]:-}"
			bf_is_eq=0
			;;
		--body-file=*)
			body_file_idx=$i
			body_file_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]#--body-file=}"
			bf_is_eq=1
			;;
		esac
		i=$((i + 1))
	done

	# Handle --body case
	if [[ $body_idx -ge 0 && -n "$body_val" ]]; then
		# Already signed — skip
		[[ "$body_val" == *"<!-- aidevops:sig -->"* ]] && return 0
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body_val" 2>/dev/null || echo "")
		[[ -z "$sig_footer" ]] && return 0
		local new_body="${body_val}${sig_footer}"
		if [[ "$is_eq_form" -eq 1 ]]; then
			_GH_WRAPPER_SIG_MODIFIED_ARGS[body_idx]="--body=${new_body}"
		else
			_GH_WRAPPER_SIG_MODIFIED_ARGS[body_idx + 1]="$new_body"
		fi
		return 0
	fi

	# Handle --body-file case
	if [[ $body_file_idx -ge 0 && -n "$body_file_val" && -f "$body_file_val" ]]; then
		local file_content
		file_content=$(<"$body_file_val") || return 0
		[[ "$file_content" == *"<!-- aidevops:sig -->"* ]] && return 0
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$file_content" 2>/dev/null || echo "")
		[[ -z "$sig_footer" ]] && return 0
		printf '%s' "$sig_footer" >>"$body_file_val"
		return 0
	fi

	return 0
}
