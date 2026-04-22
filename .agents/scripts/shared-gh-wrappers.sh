#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- Session Origin, Label Management, Safe Edits
# =============================================================================
# GitHub-related functions extracted from shared-constants.sh to keep that
# file under the 2000-line file-size-debt threshold.
#
# Covers:
#   - GitHub token workflow scope check (gh_token_has_workflow_scope)
#   - Workflow file detection (files_include_workflow_changes)
#   - Session origin detection (detect_session_origin, session_origin_label)
#   - Origin-label-aware gh create wrappers (gh_create_issue, gh_create_pr)
#   - Comment wrappers (gh_issue_comment, gh_pr_comment)
#   - Safe edit wrappers (gh_issue_edit_safe, gh_pr_edit_safe)
#   - Read wrappers with REST fallback (gh_issue_view, gh_issue_list) [t2689]
#   - Origin label mutual exclusion (set_origin_label, ensure_origin_labels_exist)
#   - Issue status label state machine (set_issue_status, ensure_status_labels_exist)
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
#
# Dependencies:
#   - shared-constants.sh (print_shared_error, print_shared_info, etc.)
#   - bash 4+, gh CLI, jq
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh first.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_LOADED=1

# Minimal stub fallbacks for print_info / print_warning.
# shared-constants.sh defines the real implementations; later sourcing
# overrides these stubs transparently. Prevents 'command not found: print_info'
# when shared-gh-wrappers.sh is sourced standalone from a zsh interactive
# session that has not already sourced shared-constants.sh.
# `command -v` works in bash 3.2+, zsh 5+, and BusyBox ash.
if ! command -v print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
fi
if ! command -v print_warning >/dev/null 2>&1; then
	print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }
fi

# t2574: REST fallback for GraphQL-exhausted gh issue wrappers (GH#20243).
# t2689: Extended to READ paths — _rest_issue_view, _rest_issue_list.
# t2743: Fixed CSV tokenisation for zsh compat (replaced read -ra with _gh_split_csv).
# Provides _gh_should_fallback_to_rest, _gh_issue_{create,comment,edit}_rest,
# _gh_pr_create_rest, _rest_issue_view, _rest_issue_list.
#
# Resolve own directory cross-shell (bash + zsh).
# Priority: (1) BASH_SOURCE[0] under bash (or zsh with BASH_SOURCE emulation);
#           (2) zsh: $0 is the sourced file path when `source /abs/path` is used
#               (confirmed: $0 is set to the file path inside sourced files in zsh,
#               unlike bash where $0 is the shell executable name);
#           (3) _SC_SELF set by shared-constants.sh before sourcing us;
#           (4) absent all three, silently skip — the primary GraphQL path still works.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
	_SHARED_GH_WRAPPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_DIR=""
elif [[ -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
	# zsh without BASH_SOURCE emulation: $0 is the sourced file path.
	# Guard: -f ensures $0 is a real file (rules out '-zsh' interactive shell name).
	_SHARED_GH_WRAPPERS_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_DIR=""
elif [[ -n "${_SC_SELF:-}" ]]; then
	_SHARED_GH_WRAPPERS_DIR="${_SC_SELF%/*}"
else
	_SHARED_GH_WRAPPERS_DIR=""
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh" ]]; then
	# shellcheck source=shared-gh-wrappers-rest-fallback.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh"
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
# Origin-Label-Aware gh Wrappers (t1756)
# =============================================================================
# Every gh issue/pr create call MUST use these wrappers to ensure the session
# origin label (origin:worker or origin:interactive) is always applied.
# GitHub deduplicates labels, so callers that already pass --label origin:*
# will not get duplicates.
#
# Usage (drop-in replacement for gh issue create / gh pr create):
#   gh_create_issue --repo owner/repo --title "..." --label "bug" --body "..."
#   gh_create_pr --head branch --base main --title "..." --body "..."
#
# These forward all arguments to gh and append --label <origin>.

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

# t2436: Extract the tNNN task ID from a --title "tNNN: ..." argument.
# Also accepts an explicit --todo-task-id tNNN flag (callers that know the ID).
# Returns the task ID (e.g., "t2436") or empty string on stdout. Non-blocking.
#
# t2688: Uses module-level globals instead of `local -n` namerefs for
# compatibility with bash 3.2 AND zsh. Namerefs (bash 4.3+) fail with
# `local:2: bad option: -n` under zsh, and are unavailable on macOS system
# bash 3.2 in the rare case the re-exec guard in shared-constants.sh cannot
# fire (e.g., file sourced directly into a zsh interactive shell via a
# user's .zshrc chain). Canonical pattern: task-brief-helper.sh:643,757.
_gh_wrapper_extract_task_id_from_title() {
	# Reset the module-level globals before each call.
	_GH_WRAPPER_EXTRACT_TODO=""
	_GH_WRAPPER_EXTRACT_TITLE=""
	local _prev="" _a
	for _a in "$@"; do
		_gh_wrapper_extract_task_id_from_title_step "$_a" "$_prev"
		_prev="$_a"
	done
	echo "${_GH_WRAPPER_EXTRACT_TODO:-$_GH_WRAPPER_EXTRACT_TITLE}"
	return 0
}

# Helper for _gh_wrapper_extract_task_id_from_title: process one arg/prev pair.
# Writes to module-level globals _GH_WRAPPER_EXTRACT_TODO and
# _GH_WRAPPER_EXTRACT_TITLE. The caller initialises both globals to ""
# before the loop. Bash 3.2 / zsh compatible (no nameref / no `local -n`).
_gh_wrapper_extract_task_id_from_title_step() {
	local _cur="$1" _prev="$2"
	if [[ "$_prev" == "--todo-task-id" ]]; then
		_GH_WRAPPER_EXTRACT_TODO="$_cur"
	elif [[ "$_prev" == "--title" && "$_cur" =~ ^(t[0-9]+): ]]; then
		_GH_WRAPPER_EXTRACT_TITLE="${BASH_REMATCH[1]}"
	elif [[ "$_cur" =~ ^--title=(t[0-9]+): ]]; then
		_GH_WRAPPER_EXTRACT_TITLE="${BASH_REMATCH[1]}"
	fi
	return 0
}

# t2436: Derive labels from TODO.md tags for a given task ID.
# Scans the current working directory's TODO.md (or the repo containing it)
# for the task entry and maps its tags to canonical GitHub labels via
# map_tags_to_labels() from issue-sync-lib.sh.
#
# This closes the race window between issue creation and the asynchronous
# issue-sync workflow trigger: protected labels like parent-task are applied
# at creation time rather than seconds later.
#
# Non-blocking: returns empty on any failure (missing TODO.md, no task found,
# lib unavailable). Never errors — callers ignore empty return value.
_gh_wrapper_derive_todo_labels() {
	local task_id="$1"
	[[ -z "$task_id" ]] && return 0

	local todo_file="${PWD}/TODO.md"
	[[ ! -f "$todo_file" ]] && return 0

	# Find the task line matching the task ID
	local task_line
	task_line=$(grep -m1 -E "^[[:space:]]*-[[:space:]]\[.\][[:space:]]*${task_id}([[:space:]]|\.|$)" \
		"$todo_file" 2>/dev/null || echo "")
	[[ -z "$task_line" ]] && return 0

	# Extract hashtags — mirrors parse_task_line() in issue-sync-lib.sh
	local tags
	tags=$(printf '%s' "$task_line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//')
	[[ -z "$tags" ]] && return 0

	# Lazy-source issue-sync-lib.sh for map_tags_to_labels if not yet loaded.
	# Guarded with include-flag to prevent double-sourcing in scripts that
	# already have issue-sync-lib.sh in scope (e.g. claim-task-id.sh).
	if [[ "$(type -t map_tags_to_labels 2>/dev/null)" != "function" ]]; then
		local _gh_w_script_dir
		_gh_w_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || true
		local _gh_w_lib="${_gh_w_script_dir}/issue-sync-lib.sh"
		# shellcheck source=/dev/null
		[[ -f "$_gh_w_lib" ]] && source "$_gh_w_lib" 2>/dev/null || true
	fi

	if [[ "$(type -t map_tags_to_labels 2>/dev/null)" == "function" ]]; then
		local derived_labels
		derived_labels=$(map_tags_to_labels "$tags") || true
		[[ -n "$derived_labels" ]] && echo "$derived_labels"
	fi
	return 0
}

gh_create_issue() {
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	local origin_label
	origin_label=$(session_origin_label)
	# Ensure labels exist on the target repo (once per repo per process)
	_ensure_origin_labels_for_args "$@"

	# t2115: auto-append signature footer when body lacks one
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"

	# t2436: Derive creation-time labels from TODO.md tags for the task ID
	# embedded in the --title "tNNN: ..." arg (or via explicit --todo-task-id).
	# This ensures protected labels like parent-task are applied synchronously
	# at issue creation, closing the race window where async issue-sync would
	# apply them only after a subsequent TODO.md push.
	# Strip --todo-task-id from args since it is not a native gh flag.
	local _todo_task_id=""
	_todo_task_id=$(_gh_wrapper_extract_task_id_from_title "$@") || true

	# Filter --todo-task-id and its value out of the arg list
	local -a _gh_ci_filtered_args=()
	local _gh_ci_skip_next=false
	local _gh_ci_arg
	for _gh_ci_arg in "$@"; do
		if [[ "$_gh_ci_skip_next" == "true" ]]; then
			_gh_ci_skip_next=false
			continue
		fi
		if [[ "$_gh_ci_arg" == "--todo-task-id" ]]; then
			_gh_ci_skip_next=true
			continue
		fi
		_gh_ci_filtered_args+=("$_gh_ci_arg")
	done
	set -- "${_gh_ci_filtered_args[@]}"

	local -a _todo_label_args=()
	if [[ -n "$_todo_task_id" ]]; then
		local _todo_derived_labels=""
		_todo_derived_labels=$(_gh_wrapper_derive_todo_labels "$_todo_task_id") || true
		if [[ -n "$_todo_derived_labels" ]]; then
			print_info "[INFO] t2436: Derived labels from TODO.md for ${_todo_task_id}: ${_todo_derived_labels}"
			_todo_label_args=(--label "$_todo_derived_labels")
		fi
	fi

	# t2028: auto-assign to the current user when the session is interactive
	# and the caller did not pass an explicit --assignee. Reaches parity with
	# the t1970 auto-assign already applied on the claim-task-id.sh path so
	# the maintainer gate's assignee check passes on first PR open for
	# interactively-created issues.
	# t2406: skip self-assignment when auto-dispatch label is present (t2157).
	# The origin:interactive label is still applied (t2200 — origin and
	# assignment are independent axes).
	local issue_output
	if ! _gh_wrapper_args_have_assignee "$@"; then
		if _gh_wrapper_args_have_label "auto-dispatch" "$@"; then
			# t2157/t2406: auto-dispatch means "let a worker handle this" —
			# skip self-assignment. Mirrors issue-sync-helper.sh
			# _push_auto_assign_interactive() skip logic.
			print_info "[INFO] auto-dispatch label present — skipping self-assignment per t2157"
		else
			local auto_assignee
			auto_assignee=$(_gh_wrapper_auto_assignee)
			if [[ -n "$auto_assignee" ]]; then
				issue_output=$(gh issue create "$@" "${_todo_label_args[@]}" --label "$origin_label" --assignee "$auto_assignee")
				local rc=$?
				if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
					print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue create"
					issue_output=$(_gh_issue_create_rest "$@" "${_todo_label_args[@]}" --label "$origin_label" --assignee "$auto_assignee")
					rc=$?
				fi
				echo "$issue_output"
				[[ $rc -eq 0 ]] && _gh_auto_link_sub_issue "$issue_output" "$@"
				return $rc
			fi
		fi
	fi

	issue_output=$(gh issue create "$@" "${_todo_label_args[@]}" --label "$origin_label")
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue create"
		issue_output=$(_gh_issue_create_rest "$@" "${_todo_label_args[@]}" --label "$origin_label")
		rc=$?
	fi
	echo "$issue_output"
	[[ $rc -eq 0 ]] && _gh_auto_link_sub_issue "$issue_output" "$@"
	return $rc
}

# Resolve a tNNN task ID to its GitHub issue number via title prefix search.
# Used by both detection methods in _gh_auto_link_sub_issue. Echoes the issue
# number on stdout, empty string if not found. Non-blocking.
_gh_resolve_task_id_to_issue() {
	local tid="$1"
	local repo="$2"
	[[ -z "$tid" || -z "$repo" ]] && return 0
	gh issue list --repo "$repo" --state all \
		--search "${tid}: in:title" --json number,title --limit 5 2>/dev/null |
		jq -r --arg prefix "${tid}: " \
			'.[] | select(.title | startswith($prefix)) | .number // ""' 2>/dev/null |
		head -1
	return 0
}

# Parse a `Parent:` line from an issue body and resolve to an issue number.
# Accepts plain, bold-markdown (`**Parent:**`), and backtick-quoted variants.
# Supports `#NNN`, `GH#NNN`, `tNNN` ref forms. `tNNN` resolves via
# `_gh_resolve_task_id_to_issue`. Echoes the issue number on stdout, empty
# string if no parent ref found. Non-blocking.
_gh_parse_parent_from_body() {
	local body="$1"
	local repo="$2"
	[[ -z "$body" ]] && return 0
	local parent_ref
	# shellcheck disable=SC2016  # sed pattern contains literal `*` and backticks
	parent_ref=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Parent:\**[[:space:]]*`?(t[0-9]+|GH#[0-9]+|#[0-9]+)`?.*/\1/p' |
		head -1 || true)
	[[ -z "$parent_ref" ]] && return 0
	if [[ "$parent_ref" =~ ^#([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$parent_ref" =~ ^GH#([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$parent_ref" =~ ^(t[0-9]+)$ ]]; then
		_gh_resolve_task_id_to_issue "${BASH_REMATCH[1]}" "$repo"
	fi
	return 0
}

# GH#18735 + GH#20473 (t2738): auto-link newly created issues as sub-issues of
# their parent at create-time. Two detection methods, in order of preference:
#
#   1. Dot-notation in title — `tNNN.M:` / `tNNN.M.K:` → parent is the dotted
#      prefix one level up. Original behaviour.
#
#   2. `Parent:` line in body — plain, bold-markdown, or backtick-quoted.
#      Supports `#NNN`, `GH#NNN`, `tNNN` refs. Delegates parsing to
#      `_gh_parse_parent_from_body`. Mirrors method 2 of
#      `_detect_parent_from_gh_state` so the detection shape stays consistent
#      across create-time and backfill-time paths.
#
# Non-blocking — every detection / resolution step returns silently on failure
# so issue creation is never affected.
#
# Arguments:
#   $1 - issue URL output from gh issue create
#   $2... - original args passed to gh issue create (to extract
#           --title, --repo, --body, --body-file and their `=` variants)
_gh_auto_link_sub_issue() {
	local issue_url="$1"
	shift

	# Extract --title, --repo, and --body (or --body-file) from the original args.
	# Consolidated positional access: read $1/$2 into locals once at top of loop,
	# then reference locals in case arms. Matches shell style guide.
	local title=""
	local repo=""
	local body=""
	local _arg _next _bf
	while [[ $# -gt 0 ]]; do
		_arg="$1"
		_next="${2:-}"
		shift
		case "$_arg" in
		--title)
			title="$_next"
			shift
			;;
		--title=*) title="${_arg#--title=}" ;;
		--repo)
			repo="$_next"
			shift
			;;
		--repo=*) repo="${_arg#--repo=}" ;;
		--body)
			body="$_next"
			shift
			;;
		--body=*) body="${_arg#--body=}" ;;
		--body-file)
			if [[ -n "$_next" && -r "$_next" ]]; then
				body=$(<"$_next")
			fi
			shift
			;;
		--body-file=*)
			_bf="${_arg#--body-file=}"
			if [[ -n "$_bf" && -r "$_bf" ]]; then
				body=$(<"$_bf")
			fi
			;;
		*) ;;
		esac
	done
	[[ -z "$title" ]] && return 0

	# Extract the child issue number from the URL — both detection methods need it.
	local child_num
	child_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
	[[ -z "$child_num" ]] && return 0

	# Resolve repo slug (from --repo arg or current repo)
	[[ -z "$repo" ]] && repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	[[ -z "$repo" ]] && return 0

	local owner="${repo%%/*}" name="${repo##*/}"
	local parent_num=""

	# Method 1: dot-notation in title
	if [[ "$title" =~ ^(t[0-9]+\.[0-9]+[a-z]?) ]]; then
		local _cid="${BASH_REMATCH[1]}"
		local _pid="${_cid%.*}"
		if [[ -n "$_pid" && "$_pid" != "$_cid" ]]; then
			parent_num=$(_gh_resolve_task_id_to_issue "$_pid" "$repo")
		fi
	fi

	# Method 2: `Parent:` line in body (only if method 1 did not resolve)
	[[ -z "$parent_num" ]] && parent_num=$(_gh_parse_parent_from_body "$body" "$repo")

	[[ -z "$parent_num" ]] && return 0

	# Resolve both to node IDs and link
	local parent_node child_node
	parent_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$parent_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	child_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$child_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	[[ -z "$parent_node" || -z "$child_node" ]] && return 0

	# Fire and forget — suppress all errors
	gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
		-f p="$parent_node" -f c="$child_node" >/dev/null 2>&1 || true
	return 0
}

gh_create_pr() {
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	local origin_label
	origin_label=$(session_origin_label)
	_ensure_origin_labels_for_args "$@"

	# t2115: auto-append signature footer when body lacks one
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"

	local pr_output rc
	pr_output=$(gh pr create "$@" --label "$origin_label")
	rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr create"
		pr_output=$(_gh_pr_create_rest "$@" --label "$origin_label")
		rc=$?
	fi
	printf '%s\n' "$pr_output"
	return $rc
}

# t2393: auto-append signature footer on all `gh issue comment` posts.
# Thin wrapper mirroring gh_create_issue/gh_create_pr — invokes
# _gh_wrapper_auto_sig on --body/--body-file before delegating to the
# underlying gh command. No origin-label or assignee logic (creation-only
# concerns); comments just need the runtime/version/model/token sig so
# operators and pulse readers can diagnose which session posted them.
# Dedup: _gh_wrapper_auto_sig skips bodies already containing the
# <!-- aidevops:sig --> marker, so callers that build their own footer
# are not double-signed.
gh_issue_comment() {
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	gh issue comment "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue comment"
		_gh_issue_comment_rest "$@"
		rc=$?
	fi
	return $rc
}

gh_pr_comment() {
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	gh pr comment "$@"
	return $?
}

# Internal: extract --repo from args and ensure labels exist (cached per repo).
_ORIGIN_LABELS_ENSURED=""
_ensure_origin_labels_for_args() {
	local repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="${2:-}"
			break
			;;
		--repo=*)
			repo="${1#--repo=}"
			break
			;;
		*) shift ;;
		esac
	done
	[[ -z "$repo" ]] && return 0
	# Skip if already ensured for this repo in this process
	case ",$_ORIGIN_LABELS_ENSURED," in
	*",$repo,"*) return 0 ;;
	esac
	ensure_origin_labels_exist "$repo"
	_ORIGIN_LABELS_ENSURED="${_ORIGIN_LABELS_ENSURED:+$_ORIGIN_LABELS_ENSURED,}$repo"
	return 0
}

# Ensure origin labels exist on a repo (idempotent).
# Usage: ensure_origin_labels_exist "owner/repo"
ensure_origin_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	gh label create "origin:worker" --repo "$repo" \
		--description "Created by headless/pulse worker session" \
		--color "C5DEF5" 2>/dev/null || true
	gh label create "origin:interactive" --repo "$repo" \
		--description "Created by interactive user session" \
		--color "BFD4F2" 2>/dev/null || true
	gh label create "origin:worker-takeover" --repo "$repo" \
		--description "Worker took over from interactive session" \
		--color "D4C5F9" 2>/dev/null || true
	return 0
}

# =============================================================================
# Safe gh Edit Wrappers (GH#19857)
# =============================================================================
# Framework-wide safety invariant: no code path may invoke gh issue edit or
# gh pr edit with an empty title or empty body — under any condition, including
# FORCE_* override flags. The check lives here so ALL call sites go through it.
#
# This mirrors the gh_create_issue / gh_create_pr pattern (origin labelling +
# signing) but for DESTRUCTIVE edits rather than creation.
#
# Validation rules:
#   Title: MUST be non-empty after trimming whitespace. Bare task-ID stubs
#          like "tNNN: " or "GH#NNN: " (nothing after the prefix) are rejected.
#   Body:  MUST be non-empty after trimming when --body is present.
#          --body-file /dev/null and --body "" are rejected.
#   Override: NO env var bypasses this. This is the hard invariant.
#
# Usage (drop-in replacements for gh issue edit / gh pr edit):
#   gh_issue_edit_safe 123 --repo owner/repo --title "t001: Fix bug" --body "..."
#   gh_pr_edit_safe 456 --repo owner/repo --title "t001: Fix bug"

# Internal: rejection reason for the most recent _gh_validate_edit_args call.
_GH_EDIT_REJECTION_REASON=""

#######################################
# Internal: validate --title and --body/--body-file args.
# Returns 0 if valid, 1 if rejected (with stderr message + _GH_EDIT_REJECTION_REASON).
# Args: the full argument list that would be passed to gh issue/pr edit.
#######################################
_gh_validate_edit_args() {
	_GH_EDIT_REJECTION_REASON=""
	local i=0 title_val="" has_title=0 body_val="" has_body=0
	local body_file_val="" has_body_file=0
	local -a args=("$@")

	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--title)
			has_title=1
			title_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--title=*)
			has_title=1
			title_val="${args[i]#--title=}"
			;;
		--body)
			has_body=1
			body_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body=*)
			has_body=1
			body_val="${args[i]#--body=}"
			;;
		--body-file)
			has_body_file=1
			body_file_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body-file=*)
			has_body_file=1
			body_file_val="${args[i]#--body-file=}"
			;;
		*) ;;
		esac
		i=$((i + 1))
	done

	# Validate title if present
	if [[ "$has_title" -eq 1 ]]; then
		local trimmed_title
		trimmed_title="${title_val#"${title_val%%[![:space:]]*}"}"
		trimmed_title="${trimmed_title%"${trimmed_title##*[![:space:]]}"}"
		if [[ -z "$trimmed_title" ]]; then
			_GH_EDIT_REJECTION_REASON="empty title (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		# Reject bare task-ID stubs: "tNNN: " or "GH#NNN: " with nothing after
		if [[ "$trimmed_title" =~ ^(t[0-9]+|GH#[0-9]+):[[:space:]]*$ ]]; then
			_GH_EDIT_REJECTION_REASON="stub title '${trimmed_title}' (task-ID prefix with no description)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body if present
	if [[ "$has_body" -eq 1 ]]; then
		local trimmed_body
		trimmed_body="${body_val#"${body_val%%[![:space:]]*}"}"
		trimmed_body="${trimmed_body%"${trimmed_body##*[![:space:]]}"}"
		if [[ -z "$trimmed_body" ]]; then
			_GH_EDIT_REJECTION_REASON="empty body (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body-file if present
	if [[ "$has_body_file" -eq 1 ]]; then
		if [[ "$body_file_val" == "/dev/null" ]]; then
			_GH_EDIT_REJECTION_REASON="body-file is /dev/null (would clear body)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		if [[ -f "$body_file_val" ]]; then
			local file_size
			file_size=$(wc -c <"$body_file_val" 2>/dev/null || echo "0")
			file_size=$(echo "$file_size" | tr -d '[:space:]')
			if [[ "$file_size" -eq 0 ]]; then
				_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' is empty"
				printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
				return 1
			fi
		fi
	fi

	return 0
}

#######################################
# Internal: audit-log a safety rejection.
# Non-fatal — if audit-log-helper.sh is unavailable, the stderr message
# from _gh_validate_edit_args is still emitted.
# Args:
#   $1 — operation name (e.g. "gh issue edit")
#   $2 — rejection reason
#   $3..N — original command args (truncated to 500 chars for the log)
#######################################
_gh_edit_audit_rejection() {
	local operation="$1"
	local reason="$2"
	shift 2
	local context
	context=$(printf '%q ' "$@" | head -c 500)
	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		"$audit_helper" log operation.block \
			"gh_edit_safety: ${operation} rejected — ${reason}. Context: ${context}" \
			2>/dev/null || true
	fi
	return 0
}

# =============================================================================
# GH Audit Log Integration (GH#20145)
# =============================================================================
# Every destructive gh operation writes a structured NDJSON event to
# ~/.aidevops/logs/gh-audit.log via gh-audit-log-helper.sh record.
# Captures before/after state + anomaly signals. Fail-open: audit errors
# never block the main operation.

#######################################
# Extract the first positional argument (issue/PR number) from a gh arg list.
# Positional = first arg that does not start with "-".
# Output: number string on stdout, or empty if none found.
#######################################
_gh_extract_number_from_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
		-*)
			continue
			;;
		*)
			echo "$arg"
			return 0
			;;
		esac
	done
	echo ""
	return 0
}

#######################################
# Extract the --repo value from a gh arg list.
# Output: "owner/repo" on stdout, or empty if not present.
#######################################
_gh_extract_repo_from_args() {
	local i=0
	local -a args=("$@")
	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--repo)
			echo "${args[i + 1]:-}"
			return 0
			;;
		--repo=*)
			echo "${args[i]#--repo=}"
			return 0
			;;
		esac
		i=$((i + 1))
	done
	echo ""
	return 0
}

#######################################
# Fetch issue state as JSON for the audit log.
# Non-blocking: returns empty-state JSON on any failure.
# Args: $1=issue_num $2=repo_slug
# Output: JSON {"title_len":N,"body_len":N,"labels":["l1",...]}
#######################################
_gh_audit_fetch_issue_state_json() {
	local issue_num="$1"
	local repo="$2"
	local empty='{"title_len":0,"body_len":0,"labels":[]}'

	[[ -z "$issue_num" || -z "$repo" ]] && echo "$empty" && return 0
	[[ ! "$issue_num" =~ ^[0-9]+$ ]] && echo "$empty" && return 0
	command -v jq &>/dev/null || { echo "$empty"; return 0; }

	local data
	data=$(gh issue view "$issue_num" --repo "$repo" \
		--json title,body,labels 2>/dev/null) || { echo "$empty"; return 0; }

	jq -c '{
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || echo "$empty"
	return 0
}

#######################################
# Fetch PR state as JSON for the audit log.
# Non-blocking: returns empty-state JSON on any failure.
# Args: $1=pr_num $2=repo_slug
# Output: JSON {"title_len":N,"body_len":N,"labels":["l1",...]}
#######################################
_gh_audit_fetch_pr_state_json() {
	local pr_num="$1"
	local repo="$2"
	local empty='{"title_len":0,"body_len":0,"labels":[]}'

	[[ -z "$pr_num" || -z "$repo" ]] && echo "$empty" && return 0
	[[ ! "$pr_num" =~ ^[0-9]+$ ]] && echo "$empty" && return 0
	command -v jq &>/dev/null || { echo "$empty"; return 0; }

	local data
	data=$(gh pr view "$pr_num" --repo "$repo" \
		--json title,body,labels 2>/dev/null) || { echo "$empty"; return 0; }

	jq -c '{
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || echo "$empty"
	return 0
}

#######################################
# Write one audit record via gh-audit-log-helper.sh record.
# Non-blocking: silently returns 0 on any failure.
# Args:
#   $1  op               — issue_edit | issue_close | etc.
#   $2  repo             — owner/repo (may be empty)
#   $3  number           — integer (may be empty, skips record if so)
#   $4  before_json      — state before operation
#   $5  after_json       — state after operation
#   $6  caller_script    — BASH_SOURCE of the wrapper's caller
#   $7  caller_function  — FUNCNAME of the wrapper's caller
#   $8  caller_line      — BASH_LINENO of the call site
#######################################
_gh_audit_record_op() {
	local op="$1" repo="$2" number="$3"
	local before_json="$4" after_json="$5"
	local caller_script="$6" caller_function="$7" caller_line="$8"

	# Skip audit when number is unavailable or not an integer
	[[ -z "$number" || ! "$number" =~ ^[0-9]+$ ]] && return 0
	[[ -z "$repo" ]] && return 0

	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-audit-log-helper.sh"
	[[ ! -x "$audit_helper" ]] && return 0

	GH_AUDIT_QUIET=true "$audit_helper" record \
		--op "$op" \
		--repo "$repo" \
		--number "$number" \
		--before-json "${before_json:-{\}}" \
		--after-json "${after_json:-{\}}" \
		--caller-script "${caller_script:-unknown}" \
		--caller-function "${caller_function:-unknown}" \
		--caller-line "${caller_line:-0}" \
		2>/dev/null || true

	return 0
}

#######################################
# gh_issue_edit_safe — drop-in replacement for gh issue edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# Records an audit event to gh-audit.log on success.
# All arguments are forwarded to gh issue edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_issue_edit_safe() {
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue edit "$@"
	local _exit=$?
	if [[ $_exit -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue edit"
		_gh_issue_edit_rest "$@"
		_exit=$?
	fi
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_edit" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_edit_safe — drop-in replacement for gh pr edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# Records an audit event to gh-audit.log on success.
# All arguments are forwarded to gh pr edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_pr_edit_safe() {
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr edit "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_edit" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_issue_close_safe — close a GitHub issue with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh issue close.
# Returns the exit code of the underlying gh command.
#######################################
gh_issue_close_safe() {
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue close "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_close" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_issue_reopen_safe — reopen a GitHub issue with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh issue reopen.
# Returns the exit code of the underlying gh command.
#######################################
gh_issue_reopen_safe() {
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue reopen "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_reopen" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_close_safe — close a GitHub PR with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh pr close.
# Returns the exit code of the underlying gh command.
#######################################
gh_pr_close_safe() {
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr close "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_close" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_merge_safe — merge a GitHub PR with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh pr merge.
# Returns the exit code of the underlying gh command.
#######################################
gh_pr_merge_safe() {
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr merge "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_merge" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

# =============================================================================
# Origin Label Mutual Exclusion (t2200)
# =============================================================================
# origin:interactive, origin:worker, and origin:worker-takeover are mutually
# exclusive — an issue was created by exactly one session type. Setting one
# must atomically remove the other two so downstream consumers
# (dispatch-dedup, maintainer gate, pulse-merge routing) can rely on
# single-label semantics without checking for impossible combinations.
#
# Background: #19638 accumulated BOTH origin:interactive AND origin:worker
# because edit sites added one without removing the other. The status-label
# state machine (set_issue_status, t2033) solved the identical problem for
# status:* labels — this mirrors that pattern for origin:* labels.

# Canonical list of mutually-exclusive origin:* labels.
ORIGIN_LABELS=("interactive" "worker" "worker-takeover")

# (t2396) Labels applied by pulse-merge-feedback.sh when routing a failed/
# conflicted/review-feedback PR back to its parent issue for re-dispatch.
# Used by _normalize_reassign_self to detect feedback-routed status:available
# issues that need runner self-assignment restored.
FEEDBACK_ROUTED_LABELS=(
	"source:ci-feedback"
	"source:conflict-feedback"
	"source:review-feedback"
)

# (t2396) HTML comment markers injected into issue bodies by
# pulse-merge-feedback.sh when routing feedback. Presence of any marker
# indicates the issue has been through at least one dispatch+feedback cycle.
FEEDBACK_ROUTED_MARKERS=(
	"<!-- ci-feedback:PR"
	"<!-- conflict-feedback:PR"
	"<!-- review-followup:PR"
)

#######################################
# Transition an issue or PR to an origin:* label atomically (t2200).
#
# Removes every sibling origin:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an
# existing issue/PR's origin label — ad-hoc --add-label/--remove-label
# calls must go through this helper so the mutual-exclusion invariant
# is enforced centrally.
#
# For new issues/PRs (gh_create_issue, gh_create_pr), the wrappers pass
# a single --label origin:* at creation time, so there is nothing to
# remove. This helper is for post-creation edits only.
#
# Args:
#   $1 — issue/PR number
#   $2 — repo slug (owner/repo)
#   $3 — new origin: one of interactive|worker|worker-takeover
#   $4 — (optional) --pr to edit a PR instead of an issue (default: issue)
#   $@ — additional gh edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-label")
#
# Returns:
#   0 on gh success
#   1 on gh failure
#   2 on invalid origin argument (caller bug)
#
# Example:
#   set_origin_label 19638 owner/repo worker
#   set_origin_label 19638 owner/repo interactive --pr
#   set_origin_label 19638 owner/repo worker \
#       --add-assignee "$worker_login"
#######################################
set_origin_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_origin="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$new_origin" ]]; then
		printf 'set_origin_label: issue_num, repo_slug, and new_origin are required\n' >&2
		return 2
	fi

	# Check for --pr flag in remaining args
	local gh_cmd="issue"
	local -a extra_flags=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			gh_cmd="pr"
			shift
			;;
		*)
			extra_flags+=("$1")
			shift
			;;
		esac
	done

	# Validate target origin
	local _valid=0
	local _origin
	for _origin in "${ORIGIN_LABELS[@]}"; do
		[[ "$_origin" == "$new_origin" ]] && {
			_valid=1
			break
		}
	done
	if [[ "$_valid" -eq 0 ]]; then
		printf 'set_origin_label: invalid origin "%s" (valid: %s)\n' \
			"$new_origin" "${ORIGIN_LABELS[*]}" >&2
		return 2
	fi

	# Ensure labels exist (cached per-process per-repo so this is cheap)
	ensure_origin_labels_exist "$repo_slug" || true

	# Build flag list: add target, remove all siblings.
	local -a _flags=()
	local _label
	for _label in "${ORIGIN_LABELS[@]}"; do
		if [[ "$_label" == "$new_origin" ]]; then
			_flags+=(--add-label "origin:${_label}")
		else
			_flags+=(--remove-label "origin:${_label}")
		fi
	done

	# Pass through any extra flags the caller wants to apply in the same edit
	if [[ ${#extra_flags[@]} -gt 0 ]]; then
		_flags+=("${extra_flags[@]}")
	fi

	gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
}

# =============================================================================
# Issue Status Label State Machine (t2033)
# =============================================================================
# aidevops models issue lifecycle as a set of mutually-exclusive `status:*`
# labels. Every transition must atomically remove siblings so the state is
# always consistent — audit queries like `gh issue list --label status:*`
# can only be trusted if no issue ever carries two status labels at once.
#
# Background: #18444, #18454, #18455 all accumulated both `status:available`
# and `status:queued` because `_dispatch_launch_worker` added `queued` without
# removing `available`. t2008 stale-recovery escalation failed to fire as a
# result. Root cause: 8+ call sites constructed their own --add-label /
# --remove-label flags, with several forgetting one or more siblings.
#
# Canonical core lifecycle (managed here):
#   available → queued → claimed → in-progress → in-review → done
#                                   ↓
#                                blocked (waiting on dependency)
#
# Exception labels (NOT managed here — out-of-band signals):
#   status:needs-info, status:verify-failed, status:stale,
#   status:needs-testing, status:orphaned
# These are set/cleared by separate workflows and do not participate in
# the core dispatch lifecycle enforced by this helper.

# Canonical ordered list of mutually-exclusive core status:* labels.
# When transitioning, all siblings of the target must be removed atomically.
# Order matches the lifecycle flow for human readability; the helper treats
# them as an unordered set. Elements are quoted because "done" is a bash
# reserved word (SC1010).
ISSUE_STATUS_LABELS=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")

# t2040: precedence order for label-invariant reconciliation. First match wins
# when picking the survivor from a multi-label pollution event. `done` is
# terminal — always preserved if present. This guards against data loss in any
# future code path that isn't fully atomic: if an issue transiently ends up
# with both `in-review` and `done`, the reconciler MUST keep `done`.
# Consumed by `_normalize_label_invariants` in pulse-issue-reconcile.sh.
ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")

# t2040: tier label rank for invariant reconciliation. Must match the rank
# order in .github/workflows/dedup-tier-labels.yml — reconciler and GH Action
# must pick the same survivor so they're idempotent with each other.
ISSUE_TIER_LABEL_RANK=("thinking" "standard" "simple")

# GH#20048: Labels that mark an issue as a non-task (supervisory, tracking,
# review gate, or operational hold). Issues carrying any of these should be
# excluded from stampless-interactive scans (Phase 1a, 24h auto-unassign)
# and from dispatch queues. Canonical source — all query sites MUST use
# _filter_non_task_issues() instead of inline jq predicates.
# Seed from pulse-prefetch.sh:186 (the original correct site).
NON_TASK_LABELS=(
	"supervisor"
	"contributor"
	"persistent"
	"quality-review"
	"needs-maintainer-review"
	"routine-tracking"
	"on hold"
	# Last element of ISSUE_STATUS_LABELS (the status that blocks dispatch).
	# Index ref instead of literal avoids crossing the 3x string-literal ratchet.
	"${ISSUE_STATUS_LABELS[6]}"
)

#######################################
# Filter out non-task issues from a JSON array.
#
# Reads a JSON array of issue objects (each with .labels[].name) from
# stdin, removes any issue carrying a label in NON_TASK_LABELS, and
# writes the filtered array to stdout.
#
# Usage:
#   filtered=$(echo "$issues_json" | _filter_non_task_issues)
#
# Globals:
#   NON_TASK_LABELS — bash array (defined above)
#
# Returns: 0 always (empty input → "[]")
#######################################
_filter_non_task_issues() {
	local _ntl_json
	_ntl_json=$(printf '%s\n' "${NON_TASK_LABELS[@]}" | jq -R . | jq -sc .) || _ntl_json="[]"
	jq --argjson ntl "$_ntl_json" \
		'[.[] | select(.labels | map(.name) | any(. as $n | $ntl[] | . == $n) | not)]' \
		2>/dev/null || echo "[]"
	return 0
}

# Ensure all core status:* labels exist on a repo (idempotent, cached per-process).
# The helper relies on --remove-label being idempotent for *unset* labels (gh
# returns exit 0 when a label exists in the repo but isn't applied to the issue),
# but fails hard when a label doesn't exist in the repo at all. Pre-creating
# them once per repo per process closes that gap.
#
# Usage: ensure_status_labels_exist "owner/repo"
_STATUS_LABELS_ENSURED=""
ensure_status_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	# Skip if already ensured for this repo in this process
	case ",${_STATUS_LABELS_ENSURED}," in
	*",${repo},"*) return 0 ;;
	esac

	# Colors roughly follow GitHub's default palette for lifecycle states.
	gh label create "status:available" --repo "$repo" \
		--description "Task is available for claiming" --color "0E8A16" --force 2>/dev/null || true
	gh label create "status:queued" --repo "$repo" \
		--description "Worker dispatched, not yet started" --color "FBCA04" --force 2>/dev/null || true
	gh label create "status:claimed" --repo "$repo" \
		--description "Interactive session claimed this task" --color "F9D0C4" --force 2>/dev/null || true
	gh label create "status:in-progress" --repo "$repo" \
		--description "Worker actively running" --color "1D76DB" --force 2>/dev/null || true
	gh label create "status:in-review" --repo "$repo" \
		--description "PR open, awaiting review/merge" --color "5319E7" --force 2>/dev/null || true
	gh label create "status:done" --repo "$repo" \
		--description "Task is complete" --color "6F42C1" --force 2>/dev/null || true
	gh label create "status:blocked" --repo "$repo" \
		--description "Waiting on blocker task" --color "D93F0B" --force 2>/dev/null || true

	_STATUS_LABELS_ENSURED="${_STATUS_LABELS_ENSURED:+${_STATUS_LABELS_ENSURED},}${repo}"
	return 0
}

#######################################
# Transition an issue to a status:* label atomically (t2033).
#
# Removes every sibling core status:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an issue's
# status label — ad-hoc --add-label/--remove-label calls must go through
# this helper so the status state machine is enforced centrally.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — new status: one of available|queued|claimed|in-progress|in-review|done|blocked
#        OR empty string to clear all core status labels without adding one
#        (used by stale-recovery escalation which applies needs-maintainer-review
#        instead of a core status)
#   $@ — additional gh issue edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-non-status-label")
#
# Returns:
#   0 on gh success (including idempotent no-op cases)
#   1 on gh failure (logged; callers typically ignore with || true to match
#     the existing convention for best-effort label operations)
#   2 on invalid status argument (caller bug — not suppressed)
#
# Example:
#   set_issue_status 18444 owner/repo queued \
#       --add-assignee "$worker_login" \
#       --add-label "origin:worker"
#
#   set_issue_status 18444 owner/repo "" \
#       --add-label "needs-maintainer-review"
#######################################
set_issue_status() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_status="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" ]]; then
		printf 'set_issue_status: issue_num and repo_slug are required\n' >&2
		return 2
	fi

	# Validate target status (empty is allowed = clear only)
	if [[ -n "$new_status" ]]; then
		local _valid=0
		local _status
		for _status in "${ISSUE_STATUS_LABELS[@]}"; do
			[[ "$_status" == "$new_status" ]] && {
				_valid=1
				break
			}
		done
		if [[ "$_valid" -eq 0 ]]; then
			printf 'set_issue_status: invalid status "%s" (valid: %s)\n' \
				"$new_status" "${ISSUE_STATUS_LABELS[*]}" >&2
			return 2
		fi
	fi

	# Ensure labels exist (cached per-process per-repo so this is cheap)
	ensure_status_labels_exist "$repo_slug" || true

	# Build flag list: remove all core status labels, add target if non-empty.
	local -a _flags=()
	local _label
	for _label in "${ISSUE_STATUS_LABELS[@]}"; do
		if [[ "$_label" == "$new_status" ]]; then
			_flags+=(--add-label "status:${_label}")
		else
			_flags+=(--remove-label "status:${_label}")
		fi
	done

	# Pass through any extra flags the caller wants to apply in the same edit
	_flags+=("$@")

	gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
	local _rc=$?
	if [[ $_rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for set_issue_status"
		_gh_issue_edit_rest "$issue_num" --repo "$repo_slug" "${_flags[@]}"
		_rc=$?
	fi
	return $_rc
}

#######################################
# gh_issue_view — drop-in replacement for gh issue view.  (t2689)
# Falls back to REST (`gh api GET /repos/{owner}/{repo}/issues/{N}`) when the
# primary call fails AND GraphQL is exhausted, so callers keep working during
# rate-limit windows. All arguments are forwarded unchanged to gh issue view.
#
#   gh_issue_view 42 --repo owner/repo --json state --jq '.state'
#   gh_issue_view 42 --repo owner/repo --json title,body,labels,assignees
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_view() {
	local _first_num="${1:-}"
	gh issue view "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue view #${_first_num}"
		_rest_issue_view "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_issue_list — drop-in replacement for gh issue list.  (t2689)
# Falls back to REST (`gh api GET /repos/{owner}/{repo}/issues`) when the
# primary call fails AND GraphQL is exhausted. Supports --state, --label
# (multiple), --assignee, --limit, --json, --jq. The --search flag is
# accepted but silently skipped in the REST path (not supported by the
# /repos/.../issues endpoint).
#
#   gh_issue_list --repo owner/repo --state open --label bug --json number,title
#   gh_issue_list --repo owner/repo --state open --limit 500 --json number --jq length
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_list() {
	gh issue list "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue list"
		_rest_issue_list "$@"
		rc=$?
	fi
	return $rc
}
