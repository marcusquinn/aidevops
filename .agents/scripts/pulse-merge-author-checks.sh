#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-author-checks.sh — PR Author Permission Helpers
# =============================================================================
# Author permission check helpers extracted from pulse-merge.sh (GH#21426)
# to bring the parent file below the 2000-line file-size-debt threshold.
#
# Covers three focused helpers:
#   - _is_collaborator_author      -- tests admin/maintain/write permission
#   - _is_owner_or_member_author   -- stricter: admin/maintain only (t2411)
#   - _check_interactive_pr_gates  -- draft + hold-for-review gate (t2411)
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-author-checks.sh"
#        (sourced by pulse-merge.sh immediately after shared-phase-filing.sh)
#
# Dependencies:
#   - gh CLI (GitHub API calls)
#   - LOGFILE variable (set by pulse-merge.sh module defaults or orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_AUTHOR_CHECKS_LOADED:-}" ]] && return 0
_PULSE_MERGE_AUTHOR_CHECKS_LOADED=1

# Guard LOGFILE in case this sub-library is sourced standalone outside the
# pulse-merge.sh orchestrator bootstrap.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

#######################################
# Check if a PR author is a collaborator (admin/maintain/write).
# Args: $1=author login, $2=repo slug
# Returns: 0=collaborator, 1=not collaborator or error
#######################################
_is_collaborator_author() {
	local author="$1"
	local repo_slug="$2"
	local perm_url="repos/${repo_slug}/collaborators/${author}/permission"
	local perm_response
	perm_response=$(gh api -i "$perm_url" 2>/dev/null | head -1)
	if [[ "$perm_response" == *"200"* ]]; then
		local perm
		perm=$(gh api "$perm_url" --jq '.permission' 2>/dev/null)
		case "$perm" in
		admin | maintain | write) return 0 ;;
		esac
	fi
	return 1
}

#######################################
# Check if a PR author is an OWNER or org MEMBER (admin or maintain level).
# Stricter than _is_collaborator_author — does NOT accept write-only
# collaborators (outside contributors). Used by the origin:interactive
# auto-merge gate (t2411).
# Args: $1=author login, $2=repo slug
# Returns: 0=owner or member, 1=collaborator/not collaborator or error
#######################################
_is_owner_or_member_author() {
	local author="$1"
	local repo_slug="$2"
	local perm_url="repos/${repo_slug}/collaborators/${author}/permission"
	local perm_response
	perm_response=$(gh api -i "$perm_url" 2>/dev/null | head -1)
	if [[ "$perm_response" == *"200"* ]]; then
		local perm
		perm=$(gh api "$perm_url" --jq '.permission' 2>/dev/null)
		case "$perm" in
		admin | maintain) return 0 ;;
		esac
	fi
	return 1
}

#######################################
# Check origin:interactive-specific gates (t2411): draft status and the
# hold-for-review opt-out label. Called from _check_pr_merge_gates when
# the PR carries origin:interactive. These checks apply regardless of
# author role — OWNER, MEMBER, and COLLABORATOR interactive PRs are all
# subject to draft and hold-for-review blocking.
#
# Args: $1=pr_number, $2=repo_slug, $3=labels_str, $4=is_draft
# Returns: 0=gates pass (continue to review bot gate), 1=blocked (skip PR)
#######################################
_check_interactive_pr_gates() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"

	if [[ "$is_draft" == "true" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — origin:interactive draft PR not eligible for auto-merge (t2411)" >>"$LOGFILE"
		return 1
	fi
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — origin:interactive PR has hold-for-review opt-out label (t2411)" >>"$LOGFILE"
		return 1
	fi
	return 0
}
