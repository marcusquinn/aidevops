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
#   - _check_interactive_pr_gates  -- draft + throughput preference gate (t2411)
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-author-checks.sh"
#        (sourced by pulse-merge.sh immediately after shared-phase-filing.sh)
#
# Dependencies:
#   - gh CLI (GitHub API calls)
#   - jq (optional; for repos.json per-repo preferences)
#   - config_get (optional; provided by config-helper.sh in pulse-wrapper.sh)
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
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
_INTERACTIVE_PR_BOOL_FALSE=false

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
# Check whether a user/config boolean value is truthy.
# Args: $1=value
# Returns: 0=true, 1=false
#######################################
_interactive_pr_bool_enabled() {
	local value="$1"
	local lower
	lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	case "$lower" in
	1 | true | yes | on) return 0 ;;
	esac
	return 1
}

#######################################
# Read the per-repo interactive PR auto-merge preference from repos.json.
# Args: $1=repo slug
# Output: true/false/empty
# Returns: 0 always (missing jq/file/key is treated as unset)
#######################################
_interactive_pr_repo_auto_merge_setting() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local value=""

	if [[ ! -f "$repos_json" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' ""
		return 0
	fi
	value=$(jq -r --arg slug "$repo_slug" '
		first(.initialized_repos[]? | select(.slug == $slug) | .interactive_pr_auto_merge // empty) // empty
	' "$repos_json" 2>/dev/null) || value=""
	printf '%s\n' "$value"
	return 0
}

#######################################
# Read the global interactive PR auto-merge preference.
# Output: true/false
# Returns: 0 always (missing config helper defaults to false)
#######################################
_interactive_pr_global_auto_merge_setting() {
	local value="$_INTERACTIVE_PR_BOOL_FALSE"
	if type config_get >/dev/null 2>&1; then
		value=$(config_get "orchestration.interactive_pr_auto_merge" "$_INTERACTIVE_PR_BOOL_FALSE") || value="$_INTERACTIVE_PR_BOOL_FALSE"
	fi
	printf '%s\n' "$value"
	return 0
}

#######################################
# Check whether an origin:interactive PR is opted into merge throughput.
# Args: $1=pr_number, $2=repo_slug, $3=labels_str
# Returns: 0=allowed, 1=manual merge required
#######################################
_interactive_pr_auto_merge_allowed() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"

	if [[ ",${labels_str}," == *",allow-auto-merge,"* ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — allow-auto-merge label opts origin:interactive PR into automated merge throughput (GH#23238)" >>"$LOGFILE"
		return 0
	fi

	if [[ -n "${AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE+x}" && -n "${AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE:-}" ]]; then
		local env_value="${AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE:-}"
		if _interactive_pr_bool_enabled "$env_value"; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE opts origin:interactive PRs into automated merge throughput (GH#23238)" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=${env_value} requires manual merge for origin:interactive PRs (GH#23238)" >>"$LOGFILE"
		return 1
	fi

	local repo_value
	repo_value=$(_interactive_pr_repo_auto_merge_setting "$repo_slug")
	if [[ -n "$repo_value" ]]; then
		if _interactive_pr_bool_enabled "$repo_value"; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — repos.json interactive_pr_auto_merge=true opts this repo into automated merge throughput (GH#23238)" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — repos.json interactive_pr_auto_merge=${repo_value} requires manual merge for origin:interactive PRs (GH#23238)" >>"$LOGFILE"
		return 1
	fi

	local global_value
	global_value=$(_interactive_pr_global_auto_merge_setting)
	if _interactive_pr_bool_enabled "$global_value"; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — orchestration.interactive_pr_auto_merge=true opts origin:interactive PRs into automated merge throughput (GH#23238)" >>"$LOGFILE"
		return 0
	fi

	if declare -F _interactive_pr_is_stale >/dev/null 2>&1 \
		&& _interactive_pr_is_stale "$pr_number" "$repo_slug"; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — stale origin:interactive PR has no active claim; allowing automated merge throughput (GH#23425)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — origin:interactive PR requires manual merge by current preference (add allow-auto-merge, set repos.json interactive_pr_auto_merge=true, or set orchestration.interactive_pr_auto_merge=true) (GH#23238)" >>"$LOGFILE"
	return 1
}

#######################################
# Check origin:interactive-specific gates (t2411): draft status, the
# hold-for-review opt-out label, and the default manual-merge policy. Called
# from _check_pr_merge_gates when the PR carries origin:interactive. These
# checks apply regardless of author role — OWNER, MEMBER, and COLLABORATOR
# interactive PRs are all held for human merge unless explicitly opted into
# automation.
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
	if ! _interactive_pr_auto_merge_allowed "$pr_number" "$repo_slug" "$labels_str"; then
		return 1
	fi
	return 0
}
