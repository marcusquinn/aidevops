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
# Print a value only when it has GitHub login syntax (App bots end in [bot]).
# Args: $1 = candidate login
#######################################
_aidevops_repo_state_valid_login() {
	local candidate="${1:-}"
	local login_re='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'
	if [[ "$candidate" =~ $login_re ]]; then
		printf '%s' "$candidate"
	fi
	return 0
}

#######################################
# Lowercase a GitHub login for case-insensitive identity comparison.
# Args: $1 = login
#######################################
_aidevops_repo_state_lower() {
	local value="${1:-}"
	printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Read the live GraphQL viewer login and, optionally, its permission on a repo.
#
# GraphQL has its own rate-limit bucket and is not admitted through the REST
# core transport governor, so it still answers when REST reads are deferred
# under core-quota pressure (GH#36184). Nothing here is cached.
#
# Args: $1 = optional repo slug (owner/repo)
# Output: "<login>|<viewerPermission>" with a slug (logins cannot contain "|",
#         and a non-whitespace delimiter keeps an empty field positional);
#         "<login>" without one.
#######################################
_aidevops_repo_state_graphql_viewer() {
	local slug="${1:-}"
	local result=""
	# GraphQL variables, not shell expansions.
	local repo_query="query(\$owner:String!,\$name:String!){viewer{login} repository(owner:\$owner,name:\$name){viewerPermission}}"
	if [[ -n "$slug" ]]; then
		result=$(gh api graphql -f query="$repo_query" \
			-f owner="${slug%%/*}" -f name="${slug#*/}" \
			--jq '[(.data.viewer.login // ""), (.data.repository.viewerPermission // "")] | join("|")' \
			2>/dev/null) || result=""
	else
		result=$(gh api graphql -f query='query{viewer{login}}' \
			--jq '.data.viewer.login // ""' 2>/dev/null) || result=""
	fi
	printf '%s' "$result"
	return 0
}

#######################################
# Resolve the authenticated GitHub login.
#
# #aidevops:trust-boundary — always a live lookup (never cached): pulse
# sessions can rotate credentials between writes. REST is tried first; the
# GraphQL viewer is a live fallback for REST transport deferral or failure.
# Returns: login on stdout, empty on failure.
#######################################
aidevops_repo_state_current_user() {
	local login=""
	login=$(gh api user --jq '.login // ""' || printf '')
	if [[ "$login" == *'"login"'* ]] && command -v jq >/dev/null 2>&1; then
		login=$(printf '%s' "$login" | jq -r '.login // ""' || printf '')
	fi
	login=$(_aidevops_repo_state_valid_login "$login")
	if [[ -z "$login" ]]; then
		login=$(_aidevops_repo_state_valid_login "$(_aidevops_repo_state_graphql_viewer)")
	fi
	printf '%s' "$login"
	return 0
}

#######################################
# Resolve a repo permission from the GraphQL viewer when REST cannot answer.
#
# #aidevops:trust-boundary — viewerPermission describes the credential, not an
# arbitrary login, so it is only trusted when the live viewer IS the user
# being checked (case-insensitive, as GitHub logins are).
#
# Args: $1 = repo slug, $2 = user login being checked
# Output: admin|maintain|write|triage_plus|triage|read (every RepositoryPermission
#         value; anything below write is a confirmed block), or empty when
#         indeterminate.
#######################################
_aidevops_repo_state_viewer_permission() {
	local slug="$1"
	local user="$2"
	local viewer="" permission=""
	IFS='|' read -r viewer permission <<<"$(_aidevops_repo_state_graphql_viewer "$slug")" || true
	viewer=$(_aidevops_repo_state_valid_login "$viewer")
	if [[ -z "$viewer" || "$(_aidevops_repo_state_lower "$viewer")" != "$(_aidevops_repo_state_lower "$user")" ]]; then
		return 0
	fi
	case "$permission" in
		ADMIN | MAINTAIN | WRITE | TRIAGE_PLUS | TRIAGE | READ)
			_aidevops_repo_state_lower "$permission"
			;;
	esac
	return 0
}

#######################################
# Check whether aidevops may mutate issue workflow state for a repo.
#
# Every caller fails closed on any non-zero status. Only claim-release paths
# distinguish 2: an unanswered lookup must not be recorded as "not managed",
# or a worker's release is dropped and its claim strands (GH#36184).
#
# Args:
#   $1 = repo slug (owner/repo)
#   $2 = optional authenticated login override
# Returns: 0 = state writes allowed; 1 = confirmed not allowed (invalid slug
#          or a read/triage/triage_plus/none verdict); 2 = indeterminate (the login or
#          permission could not be read through REST or GraphQL).
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
		return 2
	fi

	local repo_owner="${slug%%/*}"
	if [[ "$user" == "$repo_owner" ]]; then
		return 0
	fi

	local permission=""
	# #aidevops:trust-boundary — issue-state writes require confirmed write+ access;
	# API lookup failures fail closed but remain distinct from confirmed non-access.
	if declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
		_gh_collaborator_permission_lookup "$slug" "$user" permission || permission=""
	else
		permission=$(gh api "/repos/${slug}/collaborators/${user}/permission" \
			--jq '.permission // ""' 2>/dev/null || printf '')
	fi
	if [[ -z "$permission" ]]; then
		permission=$(_aidevops_repo_state_viewer_permission "$slug" "$user")
	fi
	case "$permission" in
		admin | maintain | write)
			return 0
			;;
		"")
			return 2
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
