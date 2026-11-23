#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Shared classification for Renovate Dependency Dashboard tracking issues.

[[ -n "${_RENOVATE_DEPENDENCY_DASHBOARD_HELPER_LOADED:-}" ]] && return 0
_RENOVATE_DEPENDENCY_DASHBOARD_HELPER_LOADED=1

# Return success only for Renovate's metadata-only Dependency Dashboard issue.
# Args: $1 = issue JSON containing .author.login and .title
_is_renovate_dependency_dashboard_issue() {
	local issue_meta_json="$1"
	local author_login="" issue_title="" title_lower="" app_slug=""

	[[ -n "$issue_meta_json" ]] || return 1
	author_login=$(printf '%s' "$issue_meta_json" | jq -r '.author.login // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]') || author_login=""
	issue_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // empty' 2>/dev/null) || issue_title=""
	title_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')

	# GH#38544: gh GraphQL reads emit GitHub App authors as app/<slug>; REST
	# reads (and the gh_issue_view REST fallback) emit <slug>[bot]. Both shapes
	# are reserved for Apps, so a human login named "renovate" never matches.
	# Hosted Renovate is slug "renovate"; self-hosted apps are e.g. "<org>-renovate".
	case "$author_login" in
	app/*) app_slug="${author_login#app/}" ;;
	*'[bot]') app_slug="${author_login%'[bot]'}" ;;
	*) return 1 ;;
	esac
	[[ "$app_slug" == *renovate* ]] || return 1
	[[ "$title_lower" == *"dependency dashboard"* ]] || return 1
	return 0
}

return 0
