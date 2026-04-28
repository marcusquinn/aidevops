#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Issue/PR Creation, Comments, Parent Linking
# =============================================================================
# Functions for creating issues and PRs with origin-label awareness,
# posting comments with auto-signature, and auto-linking sub-issues
# to parent issues at creation time.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-create.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, etc.)
#   - shared-gh-wrappers-session.sh (detect_session_origin, session_origin_label,
#     _gh_wrapper_args_have_assignee, _gh_wrapper_args_have_label,
#     _gh_wrapper_auto_assignee, _gh_wrapper_auto_sig)
#   - shared-gh-wrappers-rest-fallback.sh (_gh_should_fallback_to_rest,
#     _gh_issue_create_rest, _gh_pr_create_rest, _gh_issue_comment_rest)
#   - _gh_validate_edit_args, _gh_edit_audit_rejection (from orchestrator)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_CREATE_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_CREATE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# t2436: Extract the tNNN task ID from a --title "tNNN: ..." argument.
# Also accepts an explicit --todo-task-id tNNN flag (callers that know the ID).
# Returns the task ID (e.g., "t2436") or empty string on stdout. Non-blocking.
#
# t2688: Uses module-level globals instead of `local -n` namerefs for
# compatibility with bash 3.2 AND zsh. Namerefs (bash 4.3+) fail with
# `local:2: bad option: -n` under zsh, and are unavailable on macOS system
# bash 3.2 in the rare case the re-exec guard in shared-constants.sh cannot
# fire (e.g., file sourced directly into a zsh interactive shell via a
# user's .zshrc chain). Canonical pattern: claim-task-id.sh:643,757.
_GH_WRAPPER_EXTRACT_TODO=""
_GH_WRAPPER_EXTRACT_TITLE=""
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

# Internal: detect the parent issue number using two ordered methods.
# Method 1: dot-notation in title (tNNN.M: → parent tNNN).
# Method 2: `Parent:` line in body — delegates to _gh_parse_parent_from_body.
# This consolidates the shared detection shape so _gh_auto_link_sub_issue does
# not mix inline Method-1 logic with a helper-delegated Method 2.
#
# Echoes the parent issue number on stdout, empty string if no parent found.
# Non-blocking — every detection / resolution step returns silently on failure.
#
# Arguments:
#   $1 - issue title
#   $2 - issue body
#   $3 - repo slug (owner/repo)
_gh_detect_parent_issue() {
	local title="$1"
	local body="$2"
	local repo="$3"
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

	echo "$parent_num"
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
	# Whitelist-based parsing: only flags listed here consume the next positional
	# argument. Unknown flags (--assignee, --label, --project, …) are shifted
	# without consuming their value, so a flag value that happens to look like
	# --title or --repo is never mis-identified as one of our targets.
	# _a/_v capture $1/$2 into locals before use, satisfying the positional-param
	# style rule; shift-2 then consumes both the flag and its value atomically.
	local title=""
	local repo=""
	local body=""
	local _a _v _bf
	while [[ $# -gt 0 ]]; do
		_a="$1"
		_v="${2:-}"
		case "$_a" in
		--title)
			if [[ $# -gt 1 ]]; then title="$_v"; shift 2; else shift; fi
			;;
		--title=*)
			title="${_a#--title=}"; shift
			;;
		--repo)
			if [[ $# -gt 1 ]]; then repo="$_v"; shift 2; else shift; fi
			;;
		--repo=*)
			repo="${_a#--repo=}"; shift
			;;
		--body)
			if [[ $# -gt 1 ]]; then body="$_v"; shift 2; else shift; fi
			;;
		--body=*)
			body="${_a#--body=}"; shift
			;;
		--body-file)
			if [[ $# -gt 1 && -r "$_v" ]]; then body=$(<"$_v"); fi
			if [[ $# -gt 1 ]]; then shift 2; else shift; fi
			;;
		--body-file=*)
			_bf="${_a#--body-file=}"
			if [[ -n "$_bf" && -r "$_bf" ]]; then body=$(<"$_bf"); fi
			shift
			;;
		*)
			shift
			;;
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

	# Detect parent using both methods (dot-notation title, then Parent: body line).
	local parent_num
	parent_num=$(_gh_detect_parent_issue "$title" "$body" "$repo")
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

# t2767: Partial-success recovery for gh pr create.
# When gh pr create returns non-zero, GitHub may have successfully created the
# PR but a follow-up update call (label application, body normalisation, etc.)
# failed with a transient GraphQL error. This helper checks whether a PR already
# exists for the given branch in the repo, returning its URL if found.
#
# Usage: recovered_url=$(_gh_recover_pr_if_exists "$branch" "$repo")
# Returns: PR URL (HTTPS) or empty string. Always exits 0 (fail-open).
#
# Callers must treat a non-empty return value as the PR URL to continue with
# and log a recovery warning so operators know a transient error occurred.
_gh_recover_pr_if_exists() {
	local branch="$1" repo="${2:-}"
	[[ -z "$branch" ]] && return 0
	local url_candidate=""
	url_candidate=$(gh pr list --head "$branch" ${repo:+--repo "$repo"} --state open \
		--json number,url --jq '.[0].url // empty' 2>/dev/null || true)
	printf '%s\n' "${url_candidate:-}"
	return 0
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
