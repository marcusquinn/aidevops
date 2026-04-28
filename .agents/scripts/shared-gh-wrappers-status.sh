#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Status Labels, Issue Filtering, Read Wrappers
# =============================================================================
# Functions for issue status label state machine, non-task filtering, and
# gh issue/pr read wrappers with REST fallback on GraphQL exhaustion.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-status.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, etc.)
#   - shared-gh-wrappers-rest-fallback.sh (_gh_should_fallback_to_rest,
#     _rest_issue_view, _rest_issue_list, _rest_issue_search, _rest_pr_list)
#   - _gh_with_timeout (from orchestrator)
#   - ISSUE_STATUS_LABELS (from orchestrator)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_STATUS_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_STATUS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
#   NON_TASK_LABELS — bash array (defined in orchestrator)
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
	_gh_with_timeout read gh issue view "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue view #${_first_num}"
		_rest_issue_view "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_pr_list — drop-in replacement for gh pr list.  (t2772)
# Falls back to REST (`gh api GET /repos/{owner}/{repo}/pulls`) when the
# primary call fails AND GraphQL is exhausted. Supports --state, --head,
# --base, --limit, --json, --jq, -q. The --search flag is accepted but
# silently skipped in the REST path (not supported by the /repos/.../pulls
# endpoint). --json FIELDS is accepted for parity but ignored in REST path.
#
#   gh_pr_list --repo owner/repo --state open --json number,title
#   gh_pr_list --repo owner/repo --state open --limit 200 --json number --jq 'length'
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_pr_list() {
	_gh_with_timeout read gh pr list "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr list"
		_rest_pr_list "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_issue_list — drop-in replacement for gh issue list.  (t2689, t2995)
# Falls back to REST when the primary call fails AND GraphQL is exhausted.
# Supports --state, --label (multiple), --assignee, --limit, --json, --jq,
# --search.
#
# Routing (t2995):
#   - --search non-empty → _rest_issue_search uses /search/issues?q=...
#     (separate quota: 30 req/min). Preserves search semantics so the
#     caller does not silently get a label-only result on fallback.
#   - --search empty → _rest_issue_list uses /repos/{owner}/{repo}/issues.
#
# Pre-t2995 behaviour silently dropped --search in the REST path, causing
# `_large_file_gate_find_existing_debt_issue` to match the wrong issue
# during GraphQL exhaustion windows.
#
#   gh_issue_list --repo owner/repo --state open --label bug --json number,title
#   gh_issue_list --repo owner/repo --state open --limit 500 --json number --jq length
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_list() {
	_gh_with_timeout read gh issue list "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _gh_should_fallback_to_rest; then
		# t2995: use search-aware REST fallback when --search is supplied.
		# Walk argv to detect --search; the helper itself re-parses, but we
		# need to know whether to dispatch to /search/issues (which preserves
		# search semantics) or /repos/.../issues (which doesn't support it).
		local _has_search=0
		local _arg
		for _arg in "$@"; do
			case "$_arg" in
			--search|--search=*) _has_search=1; break ;;
			esac
		done
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to /search/issues for issue list (--search preserved, t2995)"
			_rest_issue_search "$@"
			rc=$?
		else
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue list"
			_rest_issue_list "$@"
			rc=$?
		fi
	fi
	return $rc
}
