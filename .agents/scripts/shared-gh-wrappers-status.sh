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
#   - shared-gh-wrappers-rest-fallback.sh (_rest_should_fallback,
#     _rest_args_have_search, _rest_issue_view, _rest_issue_list,
#     _rest_issue_search, _rest_pr_list)
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
		'[.[] | select((.labels // []) | map(.name) | any(. as $n | $ntl[] | . == $n) | not)]' \
		2>/dev/null || echo "[]"
	return 0
}

#######################################
# Return 0 when a gh_pr_list argv shape is safe to serve from the short-lived
# cross-process PR snapshot cache. The cache is deliberately scoped to open PR
# list reads because those dominate pulse dedup/merge pressure and can tolerate
# a small freshness window while keeping dispatch pipelines full.
# Args: gh-style argv
#######################################
_gh_pr_list_snapshot_cacheable() {
	_rest_args_have_search "$@" && return 1
	_rest_pr_list_can_preserve_args "$@" || return 1
	local _state="open"
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--state) _state="${2:-open}"; shift 2 ;;
		--state=*) _state="${_arg#--state=}"; shift ;;
		*) shift ;;
		esac
	done
	[[ "$_state" == "open" ]] && return 0
	return 1
}

#######################################
# Build a filesystem-safe key for an exact gh_pr_list argv shape.
# Args: gh-style argv
# Stdout: cache key
#######################################
_gh_pr_list_snapshot_key() {
	local _joined=""
	local _arg
	for _arg in "$@"; do
		_joined="${_joined}${_arg}"$'\034'
	done
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$_joined" | shasum | awk '{print $1}'
	else
		printf '%s' "$_joined" | cksum | awk '{print $1}'
	fi
	return 0
}

#######################################
# Read a cached gh_pr_list snapshot when present and fresh.
# Args: gh-style argv
# Stdout: cached command output
#######################################
_gh_pr_list_snapshot_get() {
	local _ttl="${AIDEVOPS_GH_PR_LIST_CACHE_TTL:-15}"
	[[ "${AIDEVOPS_GH_PR_LIST_CACHE_DISABLE:-0}" == "1" ]] && return 1
	[[ "$_ttl" =~ ^[0-9]+$ && "$_ttl" -gt 0 ]] || return 1
	_gh_pr_list_snapshot_cacheable "$@" || return 1
	local _key _path _now _mtime _age
	_key="$(_gh_pr_list_snapshot_key "$@")"
	_path="${AIDEVOPS_GH_PR_LIST_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-list-snapshots}/${_key}.json"
	[[ -f "$_path" ]] || return 1
	_now=$(date +%s 2>/dev/null || printf '0')
	_mtime=$(perl -e 'print((stat($ARGV[0]))[9] || 0)' "$_path" 2>/dev/null || printf '0')
	[[ "$_now" =~ ^[0-9]+$ && "$_mtime" =~ ^[0-9]+$ ]] || return 1
	_age=$(( _now - _mtime ))
	[[ "$_age" -ge 0 && "$_age" -le "$_ttl" ]] || return 1
	printf '%s' "$(<"$_path")"
	return 0
}

#######################################
# Store a successful gh_pr_list snapshot for a short freshness window.
# Args: $1 = command output, $2.. = gh-style argv
#######################################
_gh_pr_list_snapshot_put() {
	local _body="$1"; shift
	local _ttl="${AIDEVOPS_GH_PR_LIST_CACHE_TTL:-15}"
	[[ "${AIDEVOPS_GH_PR_LIST_CACHE_DISABLE:-0}" == "1" ]] && return 0
	[[ "$_ttl" =~ ^[0-9]+$ && "$_ttl" -gt 0 ]] || return 0
	_gh_pr_list_snapshot_cacheable "$@" || return 0
	local _dir _key _path _tmp
	_dir="${AIDEVOPS_GH_PR_LIST_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-list-snapshots}"
	mkdir -p "$_dir" 2>/dev/null || return 0
	_key="$(_gh_pr_list_snapshot_key "$@")"
	_path="${_dir}/${_key}.json"
	_tmp=$(mktemp "${_dir}/.pr-list-${_key}.XXXXXX" 2>/dev/null) || return 0
	printf '%s' "$_body" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_path" 2>/dev/null || rm -f "$_tmp"
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
	gh_record_call graphql set_issue_status 2>/dev/null || true
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
	if [[ $_rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for set_issue_status"
		_rest_issue_edit "$issue_num" --repo "$repo_slug" "${_flags[@]}"
		_rc=$?
	fi
	return $_rc
}

#######################################
# gh_issue_view — drop-in replacement for gh issue view.  (t2689)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/issues/{N}`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. All arguments are
# forwarded unchanged to the selected path.
#
#   gh_issue_view 42 --repo owner/repo --json state --jq '.state'
#   gh_issue_view 42 --repo owner/repo --json title,body,labels,assignees
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_view() {
	local _first_num="${1:-}"
	if _rest_read_first_enabled; then
		print_info "[INFO] gh-wrapper: REST-first read mode, routing issue view #${_first_num} to REST"
		_rest_issue_view "$@"
		return $?
	fi
	if { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest rest-core gh_issue_view; } || _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue view #${_first_num} to REST"
		_rest_issue_view "$@"
		return $?
	fi
	gh_record_call graphql gh_issue_view 2>/dev/null || true
	_gh_with_timeout read gh issue view "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue view #${_first_num}"
		_rest_issue_view "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_pr_list — drop-in replacement for gh pr list.  (t2772)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/pulls`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. Supports --state,
# --head, --base, --limit, --json, --jq, -q. --search remains GraphQL-only
# because the REST pulls endpoint has no equivalent search semantics.
#
#   gh_pr_list --repo owner/repo --state open --json number,title
#   gh_pr_list --repo owner/repo --state open --limit 200 --json number --jq 'length'
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_pr_list() {
	local _has_search=1
	_rest_args_have_search "$@" || _has_search=0
	local _cached_output=""
	if _cached_output=$(_gh_pr_list_snapshot_get "$@" 2>/dev/null); then
		printf '%s' "$_cached_output"
		return 0
	fi
	local _out="" _rc=0
	if [[ $_has_search -eq 0 ]] && _rest_read_first_enabled && _rest_pr_list_can_preserve_args "$@"; then
		print_info "[INFO] gh-wrapper: REST-first read mode, routing pr list to REST"
		_out=$(_rest_pr_list "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_list_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	if [[ $_has_search -eq 0 ]] && { { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest rest-core gh_pr_list; } || _rest_should_fallback; }; then
		print_info "[INFO] gh-wrapper: GraphQL budget low, routing pr list to REST"
		_out=$(_rest_pr_list "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_list_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	gh_record_call graphql gh_pr_list 2>/dev/null || true
	_out=$(_gh_with_timeout read gh pr list "$@")
	local rc=$?
	if [[ $rc -ne 0 && $_has_search -eq 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr list"
		_out=$(_rest_pr_list "$@")
		rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		_gh_pr_list_snapshot_put "$_out" "$@"
		printf '%s' "$_out"
	fi
	return $rc
}

#######################################
# gh_pr_view — drop-in replacement for gh pr view.  (t3460)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/pulls/{N}`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. All arguments are
# forwarded unchanged to the selected path; the REST translator supports the
# common --repo, --json, --jq, and -q read shapes.
#
#   gh_pr_view 123 --repo owner/repo --json body --jq '.body // empty'
#   gh_pr_view 123 --repo owner/repo --json labels --jq '[.labels[].name] | join(",")'
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_pr_view() {
	local _first_num="${1:-}"
	if _rest_read_first_enabled && _rest_pr_view_can_preserve_args "$@"; then
		print_info "[INFO] gh-wrapper: REST-first read mode, routing pr view #${_first_num} to REST"
		_rest_pr_view "$@"
		return $?
	fi
	if _rest_pr_view_can_preserve_args "$@" && { { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest rest-core gh_pr_view; } || _rest_should_fallback; }; then
		print_info "[INFO] gh-wrapper: GraphQL budget low, routing pr view #${_first_num} to REST"
		_rest_pr_view "$@"
		return $?
	fi
	gh_record_call graphql gh_pr_view 2>/dev/null || true
	_gh_with_timeout read gh pr view "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr view #${_first_num}"
		_rest_pr_view "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_issue_list — drop-in replacement for gh issue list.  (t2689, t2995)
# Routes directly to REST when GraphQL remaining is below the fallback threshold,
# and still falls back to REST if the primary call fails during an exhaustion
# window.
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
	local _has_search=1
	_rest_args_have_search "$@" || _has_search=0
	local _pool="rest-core"
	[[ $_has_search -eq 1 ]] && _pool="rest-search"
	if _rest_read_first_enabled; then
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: REST-first read mode, routing issue list to /search/issues (--search preserved, t2995)"
			_rest_issue_search "$@"
		else
			print_info "[INFO] gh-wrapper: REST-first read mode, routing issue list to REST"
			_rest_issue_list "$@"
		fi
		return $?
	fi
	if { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest "$_pool" gh_issue_list; } || _rest_should_fallback; then
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue list to /search/issues (--search preserved, t2995)"
			_rest_issue_search "$@"
		else
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue list to REST"
			_rest_issue_list "$@"
		fi
		return $?
	fi
	gh_record_call graphql gh_issue_list 2>/dev/null || true
	_gh_with_timeout read gh issue list "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		# t2995: use search-aware REST fallback when --search is supplied.
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
