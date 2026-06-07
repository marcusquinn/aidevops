#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Repository State Guard
# =============================================================================
# Guards aidevops issue-state writes (dispatch claims, claim releases, labels,
# locks) so public workflow markers are only emitted where the authenticated
# user has maintainer-equivalent access. External upstream repositories may be
# valid PR targets, but they must not receive aidevops internal coordination
# spam.

[[ -n "${_SHARED_REPO_STATE_GUARD_LOADED:-}" ]] && return 0
_SHARED_REPO_STATE_GUARD_LOADED=1

if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	_SHARED_REPO_STATE_GUARD_DIR="${BASH_SOURCE[0]%/*}"
	if [[ -f "${_SHARED_REPO_STATE_GUARD_DIR}/github-app-auth-helper.sh" ]]; then
		# shellcheck source=./github-app-auth-helper.sh
		source "${_SHARED_REPO_STATE_GUARD_DIR}/github-app-auth-helper.sh"
	fi
	if [[ -f "${_SHARED_REPO_STATE_GUARD_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=./shared-gh-wrappers-rest-fallback.sh
		source "${_SHARED_REPO_STATE_GUARD_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
	if [[ -f "${_SHARED_REPO_STATE_GUARD_DIR}/shared-gh-collaborator-permission.sh" ]]; then
		# shellcheck source=./shared-gh-collaborator-permission.sh
		source "${_SHARED_REPO_STATE_GUARD_DIR}/shared-gh-collaborator-permission.sh"
	fi
	unset _SHARED_REPO_STATE_GUARD_DIR
fi

#######################################
# Resolve the authenticated GitHub login.
# Returns: login on stdout, empty on failure.
#######################################
aidevops_repo_state_current_user() {
	local login=""
	login=$(gh api user --jq '.login // ""' || printf '')
	if [[ "$login" == *'"login"'* ]] && command -v jq >/dev/null 2>&1; then
		login=$(printf '%s' "$login" | jq -r '.login // ""' || printf '')
	fi
	if [[ -z "$login" ]]; then
		printf ''
		return 0
	fi
	printf '%s' "$login"
	return 0
}

#######################################
# Check whether aidevops may mutate issue workflow state for a repo.
#
# Args:
#   $1 = repo slug (owner/repo)
#   $2 = optional authenticated login override
# Returns: 0 when state writes are allowed, 1 otherwise.
#######################################
aidevops_can_manage_repo_issue_state() {
	local slug="${1:-}"
	local user="${2:-}"

	if [[ "${AIDEVOPS_TEST_MODE:-}" == "1" && \
		"${AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS:-}" == "1" ]]; then
		return 0
	fi

	if [[ -z "$slug" || "$slug" != */* ]]; then
		return 1
	fi

	if [[ -z "$user" ]]; then
		user=$(aidevops_repo_state_current_user)
	fi
	if [[ -z "$user" ]]; then
		return 1
	fi

	local repo_owner="${slug%%/*}"
	if [[ "$user" == "$repo_owner" ]]; then
		return 0
	fi

	local permission=""
	# #aidevops:trust-boundary — issue-state writes require confirmed write+ access;
	# API lookup failures fail closed but remain distinct from confirmed non-access.
	if declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		_gh_collaborator_permission_lookup "$slug" "$user" permission || return 1
	else
		permission=$(gh api "/repos/${slug}/collaborators/${user}/permission" \
			--jq '.permission // ""' 2>/dev/null || printf '')
	fi
	case "$permission" in
		admin | maintain | write)
			return 0
			;;
	esac

	return 1
}

#######################################
# Check whether aidevops may run public repo routines for a repo.
#
# Routine jobs (quality sweeps, health dashboards, merge/repair loops) can
# create comments/issues and consume API budget. Unlike narrow issue-state
# markers, these jobs require maintainer-equivalent authority; write-only
# collaborators and external contributors should keep results local.
#
# Args:
#   $1 = repo slug (owner/repo)
#   $2 = optional authenticated login override
# Returns: 0 when routines are allowed, 1 otherwise.
#######################################
aidevops_can_run_repo_routines() {
	local slug="${1:-}"
	local user="${2:-}"

	if [[ "${AIDEVOPS_TEST_MODE:-}" == "1" && \
		"${AIDEVOPS_REPO_ROUTINE_GUARD_TEST_BYPASS:-}" == "1" ]]; then
		return 0
	fi

	if [[ -z "$slug" || "$slug" != */* ]]; then
		return 1
	fi

	if [[ -z "$user" ]]; then
		user=$(aidevops_repo_state_current_user)
	fi
	if [[ -z "$user" ]]; then
		return 1
	fi

	local repo_owner="${slug%%/*}"
	if [[ "$user" == "$repo_owner" ]]; then
		return 0
	fi

	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	if [[ -f "$repos_json" ]]; then
		local registered_maintainer=""
		registered_maintainer=$(jq -r \
			--arg slug "$slug" \
			'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
			"$repos_json" 2>/dev/null | sed -n '1p')
		if [[ -n "$registered_maintainer" && "$registered_maintainer" == "$user" ]]; then
			return 0
		fi
	fi

	local permission=""
	permission=$(gh api "repos/${slug}/collaborators/${user}/permission" \
		--jq '.permission // ""' 2>/dev/null || printf '')
	case "$permission" in
		admin | maintain)
			return 0
			;;
	esac

	return 1
}
