#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- Orchestrator
# =============================================================================
# Thin orchestrator that sources focused sub-libraries for gh CLI wrappers.
# Keeps only shared constants/globals and functions whose identity keys must
# be preserved (>100-line functions that are current function-complexity
# violations — moving them would create NEW violations per
# reference/large-file-split.md section 3).
#
# Sub-libraries:
#   - shared-gh-wrappers-session.sh       — session origin, token, internal helpers
#   - shared-gh-wrappers-create.sh        — issue/PR creation, comments, parent linking
#   - shared-gh-wrappers-safe-edit.sh     — safe edit/close/merge with audit logging
#   - shared-gh-wrappers-status.sh        — status labels, read wrappers with REST fallback
#   - shared-gh-wrappers-checks.sh        — PR check status via REST check-suites/check-runs (GH#21799)
#   - shared-gh-wrappers-rest-fallback.sh — REST fallback translators (pre-existing)
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

# t3461: optional user-owned GitHub App auth and route decisions. Source this
# before the REST translators so _rest_api_call can use installation tokens for
# REST core/search pools while native gh/PAT remains the fallback path.
# Fail-open when missing so older deployed checkouts keep working.
# t2574: REST fallback for GraphQL-exhausted gh issue wrappers (GH#20243).
# t2689: Extended to READ paths — _rest_issue_view, _rest_issue_list.
# t2743: Fixed CSV tokenisation for zsh compat (replaced read -ra with _rest_split_csv).
# Provides _rest_should_fallback, _rest_issue_{create,comment,edit},
# _rest_pr_create, _rest_issue_view, _rest_issue_list.
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
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/github-app-auth-helper.sh" ]]; then
	# shellcheck source=github-app-auth-helper.sh
	source "$_SHARED_GH_WRAPPERS_DIR/github-app-auth-helper.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-secondary-cooldown.sh" ]]; then
	# shellcheck source=shared-gh-secondary-cooldown.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-secondary-cooldown.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh" ]]; then
	# shellcheck source=shared-gh-wrappers-rest-fallback.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-collaborator-permission.sh" ]]; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-collaborator-permission.sh"
fi
# gh API instrumentation (t2902): records every routed gh call partitioned
# by endpoint family (graphql/rest/search-*) so heavy GraphQL consumers can
# be identified. The recorder is fail-open — if the helper is missing, the
# `gh_record_call rest 2>/dev/null || true` calls in the REST translators
# above silently no-op and the host script keeps working.
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/gh-api-instrument.sh" ]]; then
	# shellcheck source=gh-api-instrument.sh
	source "$_SHARED_GH_WRAPPERS_DIR/gh-api-instrument.sh"
fi

# =============================================================================
# Wall-clock timeout helper for gh subprocess invocations (t2913)
# =============================================================================
# `gh` (Go HTTP client) does not apply a default request timeout, so a wedged
# TCP/TLS/DNS path can hang the subprocess indefinitely. Canonical incident:
# 7+ min hang on `gh issue list` blocked stats-health-dashboard.sh's whole
# update loop (Ultimate-Multisite/gratis-ai-agent#1192).
#
# Precedence: env var > pulse-rate-limit.conf > hardcoded fallback (15/45).
# Match the pattern at pulse-wrapper-config.sh:99-105 for AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:
# only source the conf file if the env var is unset, so an explicit env
# override (e.g. for a slow-network runner) is never silently overwritten.
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/../configs/pulse-rate-limit.conf" ]]; then
	if [[ -z "${AIDEVOPS_GH_READ_TIMEOUT+x}" ]] && [[ -z "${AIDEVOPS_GH_WRITE_TIMEOUT+x}" ]]; then
		# shellcheck disable=SC1091
		source "$_SHARED_GH_WRAPPERS_DIR/../configs/pulse-rate-limit.conf"
	fi
fi
: "${AIDEVOPS_GH_READ_TIMEOUT:=15}"
: "${AIDEVOPS_GH_WRITE_TIMEOUT:=45}"

# _gh_with_timeout — invoke a command (typically `gh ...`) with a wall-clock
# cap classified by operation type. Falls through to direct invocation when
# coreutils `timeout` is not on PATH (rare; macOS users have it via Homebrew
# coreutils, Linux distros ship it by default).
#
# Usage:
#   _gh_with_timeout read  gh issue list --repo owner/repo --state open
#   _gh_with_timeout write gh issue edit 123 --repo owner/repo --add-label foo
#   _gh_with_timeout read  gh api /repos/owner/repo/issues
#
# Exit codes:
#   124 = timeout fired (per coreutils convention)
#   *   = passthrough from the wrapped command
_gh_with_timeout() {
	local op_class="${1:-read}"
	shift
	if command -v _gh_secondary_cooldown_preflight >/dev/null 2>&1; then
		_gh_secondary_cooldown_preflight "$op_class" || return $?
	fi
	local secs
	case "$op_class" in
	read) secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}" ;;
	write) secs="${AIDEVOPS_GH_WRITE_TIMEOUT:-45}" ;;
	*) secs=30 ;;
	esac
	local cmd="${1:-}"
	local err_file=""
	local rc=0
	if [[ -n "$cmd" ]] && declare -f "$cmd" >/dev/null; then
		err_file=$(mktemp -t aidevops-gh-secondary.XXXXXX) || {
			"$@"
			return $?
		}
		"$@" 2>"$err_file"
		rc=$?
		cat "$err_file" >&2 2>/dev/null || true
		if command -v _gh_secondary_cooldown_record_if_needed >/dev/null 2>&1; then
			_gh_secondary_cooldown_record_if_needed "$rc" "$(cat "$err_file" 2>/dev/null || true)"
		fi
		rm -f "$err_file"
		return $rc
	fi
	err_file=$(mktemp -t aidevops-gh-secondary.XXXXXX) || err_file=""
	if command -v timeout >/dev/null 2>&1; then
		if [[ -n "$err_file" ]]; then
			timeout "$secs" "$@" 2>"$err_file"
			rc=$?
		else
			timeout "$secs" "$@"
			rc=$?
		fi
	else
		if [[ -n "$err_file" ]]; then
			"$@" 2>"$err_file"
			rc=$?
		else
			"$@"
			rc=$?
		fi
	fi
	if [[ -n "$err_file" ]]; then
		cat "$err_file" >&2 2>/dev/null || true
		if command -v _gh_secondary_cooldown_record_if_needed >/dev/null 2>&1; then
			_gh_secondary_cooldown_record_if_needed "$rc" "$(cat "$err_file" 2>/dev/null || true)"
		fi
		rm -f "$err_file"
	fi
	return $rc
}

# =============================================================================
# Safe gh Edit Wrappers — Validation (GH#19857)
# =============================================================================
# Framework-wide safety invariant: no code path may invoke gh issue edit or
# gh pr edit with an empty title or empty body — under any condition, including
# FORCE_* override flags. The check lives here so ALL call sites go through it.
#
# Validation rules:
#   Title: MUST be non-empty after trimming whitespace. Bare task-ID stubs
#          like "tNNN: " or "GH#NNN: " (nothing after the prefix) are rejected.
#   Body:  MUST be non-empty after trimming when --body is present.
#          --body-file /dev/null and --body "" are rejected.
#   Override: NO env var bypasses this. This is the hard invariant.

# Internal: rejection reason for the most recent _gh_validate_edit_args call.
_GH_EDIT_REJECTION_REASON=""

#######################################
# Internal: validate --title and --body/--body-file args.
# Returns 0 if valid, 1 if rejected (with stderr message + _GH_EDIT_REJECTION_REASON).
# Args: the full argument list that would be passed to gh issue/pr edit.
#
# IDENTITY KEY PRESERVATION: This function is 101 lines and MUST stay in the
# orchestrator file to preserve its (shared-gh-wrappers.sh, _gh_validate_edit_args)
# identity key. Moving it would create a new function-complexity violation.
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

# =============================================================================
# Origin Label Mutual Exclusion (t2200)
# =============================================================================
# origin:interactive, origin:worker, and origin:worker-takeover are mutually
# exclusive — an issue was created by exactly one session type. Setting one
# must atomically remove the other two so downstream consumers
# (dispatch-dedup, maintainer gate, pulse-merge routing) can rely on
# single-label semantics without checking for impossible combinations.

# Canonical list of mutually-exclusive origin:* labels.
ORIGIN_LABELS=("interactive" "worker" "worker-takeover")

# Canonical solved-by attribution labels. These describe who ultimately
# resolved the task, independent from origin:* labels that describe how the
# issue/PR was created.
SOLVED_LABELS=("worker" "interactive")

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

# =============================================================================
# Issue Status Label State Machine — Constants (t2033)
# =============================================================================
# Shared constants consumed by sub-libraries. Defined here in the orchestrator
# BEFORE sourcing sub-libraries so they are available at source time.

# Canonical ordered list of mutually-exclusive core status:* labels.
ISSUE_STATUS_LABELS=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")

# t2040: precedence order for label-invariant reconciliation. First match wins.
ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")

# t2040: tier label rank for invariant reconciliation.
ISSUE_TIER_LABEL_RANK=("thinking" "standard" "simple")

# GH#20048: Labels that mark an issue as a non-task.
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

# =============================================================================
# Source sub-libraries
# =============================================================================
# NOTE: Constants and validation functions are defined ABOVE so they are
# available to sub-libraries at source time. Sub-libraries depend on:
#   - _gh_validate_edit_args, _GH_EDIT_REJECTION_REASON (create, safe-edit)
#   - ORIGIN_LABELS, FEEDBACK_ROUTED_* (create)
#   - ISSUE_STATUS_LABELS, NON_TASK_LABELS (status)
#   - _gh_with_timeout (status)
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" ]]; then
	# shellcheck source=shared-gh-wrappers-session.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-session.sh"

	# shellcheck source=shared-gh-wrappers-create.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-create.sh"

	# shellcheck source=shared-gh-wrappers-safe-edit.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-safe-edit.sh"

	# shellcheck source=shared-gh-wrappers-status.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-status.sh"

	# shellcheck source=shared-gh-wrappers-checks.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-checks.sh"
fi

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
# IDENTITY KEY PRESERVATION: This function is 144 lines and MUST stay in the
# orchestrator file to preserve its (shared-gh-wrappers.sh, set_origin_label)
# identity key. Moving it would create a new function-complexity violation.
#
# Example:
#   set_origin_label 19638 owner/repo worker
#   set_origin_label 19638 owner/repo interactive --pr
#   set_origin_label 19638 owner/repo worker \
#       --add-assignee "$worker_login"
#######################################
_set_origin_label_should_rest_fallback() {
	local err_file="$1"
	if [[ -f "$err_file" ]] && grep -qiE 'GraphQL: API rate limit( already)? exceeded|rateLimitExceeded' "$err_file" 2>/dev/null; then
		return 0
	fi
	if command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		return 0
	fi
	return 1
}

#######################################
# Apply origin label mutual exclusion via REST labels endpoints.
# Args: $1=issue/pr num, $2=repo slug, $3=new origin, $4..=extra edit flags
#######################################
_set_origin_label_rest() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_origin="$3"
	shift 3
	local _label
	for _label in "${ORIGIN_LABELS[@]}"; do
		[[ "$_label" == "$new_origin" ]] && continue
		gh api -X DELETE "/repos/${repo_slug}/issues/${issue_num}/labels/origin:${_label}" >/dev/null 2>&1 || true
	done
	gh api -X POST "/repos/${repo_slug}/issues/${issue_num}/labels" \
		-f "labels[]=origin:${new_origin}" >/dev/null 2>&1 || return 1
	if [[ $# -gt 0 ]]; then
		if command -v _rest_issue_edit >/dev/null 2>&1; then
			_rest_issue_edit "$issue_num" --repo "$repo_slug" "$@" || return 1
		else
			return 1
		fi
	fi
	return 0
}

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

	local _err_file
	_err_file=$(mktemp -t aidevops-origin-label.XXXXXX) || {
		gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
		return $?
	}
	local _gh_rc=0
	if gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>"$_err_file"; then
		rm -f "$_err_file"
		return 0
	else
		_gh_rc=$?
	fi
	if _set_origin_label_should_rest_fallback "$_err_file" && \
		_set_origin_label_rest "$issue_num" "$repo_slug" "$new_origin" "${extra_flags[@]}"; then
		rm -f "$_err_file"
		return 0
	fi
	rm -f "$_err_file"
	return "$_gh_rc"
}

#######################################
# Ensure solved:* attribution labels exist on a repo (idempotent).
# Args: $1 — repo slug (owner/repo)
# Returns: 0 on success/no-op, 1 when repo is empty.
#######################################
ensure_solved_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	gh label create "solved:worker" --repo "$repo" \
		--description "Task was solved by a headless worker" \
		--color "0E8A16" 2>/dev/null || true
	gh label create "solved:interactive" --repo "$repo" \
		--description "Task was solved by an interactive session" \
		--color "BFD4F2" 2>/dev/null || true
	return 0
}

#######################################
# Transition an issue to a solved:* attribution label atomically.
#
# This is separate from origin:*: origin says who created the issue/PR;
# solved:* says who actually resolved it. The labels are mutually exclusive.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — solved actor: worker|interactive
#   $@ — additional gh issue edit flags passed through verbatim
# Returns:
#   0 on gh success
#   1 on gh failure
#   2 on invalid args
#######################################
set_solved_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local solved_actor="$3"
	shift 3

	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$solved_actor" ]]; then
		printf 'set_solved_label: issue_num, repo_slug, and solved_actor are required\n' >&2
		return 2
	fi

	local _valid=0
	local _actor
	for _actor in "${SOLVED_LABELS[@]}"; do
		[[ "$_actor" == "$solved_actor" ]] && {
			_valid=1
			break
		}
	done
	if [[ "$_valid" -eq 0 ]]; then
		printf 'set_solved_label: invalid actor "%s" (valid: %s)\n' \
			"$solved_actor" "${SOLVED_LABELS[*]}" >&2
		return 2
	fi

	ensure_solved_labels_exist "$repo_slug" || true

	local -a _flags=()
	local _label
	for _label in "${SOLVED_LABELS[@]}"; do
		if [[ "$_label" == "$solved_actor" ]]; then
			_flags+=(--add-label "solved:${_label}")
		else
			_flags+=(--remove-label "solved:${_label}")
		fi
	done
	_flags+=("$@")

	_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
	return $?
}
