#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub collaborator permission lookup helper
# =============================================================================

[[ -n "${_SHARED_GH_COLLABORATOR_PERMISSION_LOADED:-}" ]] && return 0
_SHARED_GH_COLLABORATOR_PERMISSION_LOADED=1

#######################################
# Look up a repository collaborator permission through App-aware REST routing.
#
# Auth selection stays in _rest_api_call/github_app_api_call: GitHub App
# installation auth is preferred when configured, with normal gh/PAT fallback.
# Callers can inspect the status globals after a non-zero return to distinguish
# transient lookup failures from confirmed non-collaborators.
#
# Globals written:
#   AIDEVOPS_GH_COLLAB_PERMISSION_HTTP
#   AIDEVOPS_GH_COLLAB_PERMISSION_REASON
#
# Args: $1=repo_slug owner/repo, $2=user login, $3=optional output variable
# Output: permission value (admin|maintain|write|triage|read|none) on lookup success.
# Returns: 0=lookup succeeded (404 maps to none), 2=lookup/API/parse failure.
#######################################
_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local user="$2"
	local out_var="${3:-}"
	local perm_url="/repos/${repo_slug}/collaborators/${user}/permission"
	local api_response=""
	local rc=0
	local http_status=""
	local line=""
	local body=""
	local in_body=0
	local permission_value=""

	AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="unknown"
	AIDEVOPS_GH_COLLAB_PERMISSION_REASON="unknown"
	export AIDEVOPS_GH_COLLAB_PERMISSION_HTTP AIDEVOPS_GH_COLLAB_PERMISSION_REASON

	if [[ -z "$repo_slug" || -z "$user" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="missing-argument"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	api_response=$(_rest_api_call read gh api -i "$perm_url" 2>&1)
	rc=$?
	while IFS= read -r line; do
		line="${line%$'\r'}"
		case "$line" in
		HTTP/*)
			http_status="${line#* }"
			http_status="${http_status%% *}"
			;;
		"")
			in_body=1
			;;
		\{* | \[* )
			in_body=1
			body="${body}${line}"$'\n'
			;;
		*)
			if [[ "$in_body" -eq 1 ]]; then
				body="${body}${line}"$'\n'
			fi
			;;
		esac
	done <<<"$api_response"

	[[ -n "$http_status" ]] && AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="$http_status"
	export AIDEVOPS_GH_COLLAB_PERMISSION_HTTP

	if [[ "$http_status" == "404" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="not-collaborator"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		if [[ -n "$out_var" ]]; then
			printf -v "$out_var" '%s' "none"
		else
			printf '%s\n' "none"
		fi
		return 0
	fi

	if [[ "$rc" -ne 0 ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="api-failure"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	if [[ "$http_status" != "200" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="unexpected-http"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
	fi

	permission_value=$(printf '%s' "$body" | jq -r '.permission // .role_name // ""' 2>/dev/null) || permission_value=""
	case "$permission_value" in
	admin | maintain | write | triage | read | none)
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="ok"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		if [[ -n "$out_var" ]]; then
			printf -v "$out_var" '%s' "$permission_value"
		else
			printf '%s\n' "$permission_value"
		fi
		return 0
		;;
	*)
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="malformed-response"
		export AIDEVOPS_GH_COLLAB_PERMISSION_REASON
		return 2
		;;
	esac
}
