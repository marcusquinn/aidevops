#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-shared.sh - Shared utility functions for the stats subsystem
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 1)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Globals read:
#   - LOGFILE, REPOS_JSON
# Globals written:
#   - none (caches written to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_SHARED_LOADED:-}" ]] && return 0
_STATS_SHARED_LOADED=1

#######################################
# Validate a repo slug matches the expected owner/repo format.
# Rejects path traversal, quotes, and other injection vectors.
# Arguments:
#   $1 - repo slug to validate
# Returns: 0 if valid, 1 if invalid
#######################################
_validate_repo_slug() {
	local slug="$1"
	# Must be non-empty, match owner/repo with only alphanumeric, hyphens,
	# underscores, and dots (GitHub's allowed characters)
	if [[ "$slug" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		return 0
	fi
	echo "[stats] Invalid repo slug rejected: ${slug}" >>"$LOGFILE"
	return 1
}

# check_session_count: now provided by worker-lifecycle-common.sh (sourced by caller).
# Previously duplicated here (17 lines) — see t1431. Consolidated to eliminate
# divergence risk and ensure single source of truth.

#######################################
# Determine runner role for a repo: supervisor or contributor
#
# Resolution order (first match wins):
#   1. In-process env-var cache (per pulse cycle, no I/O)
#   2. repos.json maintainer field (deterministic, no API)
#   3. Persistent disk cache with 24h TTL (~/.aidevops/logs/)
#   4. GitHub API permission check (fallback)
#
# Layers 1-3 prevent the bug where a transient API failure (rate
# limit, network) defaulted to "contributor" and created duplicate
# [Contributor:user] health issues alongside the correct [Supervisor]
# ones. See t1929 for the full root-cause analysis.
#
# Arguments:
#   $1 - runner GitHub login
#   $2 - repo slug (owner/repo)
# Output: "supervisor" or "contributor" to stdout
#######################################
_get_runner_role() {
	local runner_user="$1"
	local repo_slug="$2"

	# Validate slug before using in API path (defense-in-depth)
	if ! _validate_repo_slug "$repo_slug"; then
		echo "contributor"
		return 0
	fi

	# Layer 1: in-process env-var cache (per pulse cycle)
	local cache_key="__RUNNER_ROLE_${repo_slug//[^a-zA-Z0-9]/_}"
	local cached_role="${!cache_key:-}"
	if [[ -n "$cached_role" ]]; then
		echo "$cached_role"
		return 0
	fi

	# Layer 2: repos.json maintainer field (deterministic, no API needed).
	# If the runner matches the registered maintainer, they are supervisor.
	# This is the primary defense against API failure causing role misdetection.
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	if [[ -f "$repos_json" ]]; then
		local registered_maintainer
		registered_maintainer=$(jq -r \
			--arg slug "$repo_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
			"$repos_json" 2>/dev/null | head -1)
		if [[ -n "$registered_maintainer" && "$registered_maintainer" == "$runner_user" ]]; then
			export "$cache_key=supervisor"
			_persist_role_cache "$runner_user" "$repo_slug" "supervisor"
			echo "supervisor"
			return 0
		fi
	fi

	# Layer 3: persistent disk cache with 24h TTL.
	# Survives across pulse cycles; prevents API failure from flipping role.
	local disk_cache_dir="${HOME}/.aidevops/logs"
	local slug_safe="${repo_slug//\//-}"
	local disk_cache_file="${disk_cache_dir}/runner-role-${runner_user}-${slug_safe}"
	if [[ -f "$disk_cache_file" ]]; then
		local disk_role disk_ts now_ts
		IFS='|' read -r disk_role disk_ts <"$disk_cache_file" 2>/dev/null || disk_role=""
		disk_ts="${disk_ts//[^0-9]/}"
		disk_ts="${disk_ts:-0}"
		now_ts=$(date +%s)
		# 24h TTL (86400 seconds)
		if [[ -n "$disk_role" && $((now_ts - disk_ts)) -lt 86400 ]]; then
			export "$cache_key=$disk_role"
			echo "$disk_role"
			return 0
		fi
	fi

	# Layer 4: GitHub API permission check (fallback).
	# On failure, use expired disk cache if available rather than defaulting
	# to "contributor" — this prevents role flip-flop on transient errors.
	local role=""
	local api_path="repos/${repo_slug}/collaborators/${runner_user}/permission"
	local response
	response=$(gh api "$api_path" --jq '.permission // empty' 2>/dev/null) || response=""

	case "$response" in
	admin | maintain | write)
		role="supervisor"
		;;
	read | none)
		role="contributor"
		;;
	"")
		# API failure — use expired disk cache if available (stale > wrong)
		if [[ -f "$disk_cache_file" ]]; then
			local stale_role _stale_ts
			IFS='|' read -r stale_role _stale_ts <"$disk_cache_file" 2>/dev/null || stale_role=""
			if [[ -n "$stale_role" ]]; then
				echo "[stats] _get_runner_role: API failed for ${repo_slug}, using stale cache: ${stale_role}" >>"${LOGFILE:-/dev/null}"
				role="$stale_role"
			fi
		fi
		# No cache at all — default to contributor (fail closed)
		[[ -z "$role" ]] && role="contributor"
		;;
	*)
		# Unknown permission value — fail closed
		role="contributor"
		;;
	esac

	# Persist to both caches
	export "$cache_key=$role"
	_persist_role_cache "$runner_user" "$repo_slug" "$role"

	echo "$role"
	return 0
}

# Write role to persistent disk cache.
# Format: "role|epoch_timestamp" — simple, no JSON dependency.
# Arguments:
#   $1 - runner_user
#   $2 - repo_slug
#   $3 - role (supervisor|contributor)
_persist_role_cache() {
	local runner_user="$1"
	local repo_slug="$2"
	local role="$3"
	local disk_cache_dir="${HOME}/.aidevops/logs"
	local slug_safe="${repo_slug//\//-}"
	local disk_cache_file="${disk_cache_dir}/runner-role-${runner_user}-${slug_safe}"
	mkdir -p "$disk_cache_dir" 2>/dev/null || true
	printf '%s|%s\n' "$role" "$(date +%s)" >"$disk_cache_file" 2>/dev/null || true
	return 0
}

#######################################
# Normalize a dashboard identity token for alias comparisons.
# Arguments:
#   $1 - identity token
# Output: lower-case trimmed token
#######################################
_normalize_dashboard_identity_token() {
	local token="$1"
	token="${token#"${token%%[![:space:]]*}"}"
	token="${token%"${token##*[![:space:]]}"}"
	printf '%s' "$token" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Resolve the identity-alias config path.
# Output: config path, or empty when no config exists
#######################################
_dashboard_identity_alias_config_path() {
	local configured_path="${AIDEVOPS_IDENTITY_ALIASES_CONF:-}"
	if [[ -n "$configured_path" && -f "$configured_path" ]]; then
		printf '%s' "$configured_path"
		return 0
	fi

	local repo_config=""
	if [[ -n "${SCRIPT_DIR:-}" ]]; then
		repo_config="${SCRIPT_DIR%/scripts}/configs/identity-aliases.conf"
		if [[ -f "$repo_config" ]]; then
			printf '%s' "$repo_config"
			return 0
		fi
	fi

	local deployed_config="${HOME}/.aidevops/agents/configs/identity-aliases.conf"
	if [[ -f "$deployed_config" ]]; then
		printf '%s' "$deployed_config"
	fi
	return 0
}

#######################################
# Print canonical identity and aliases for a dashboard runner.
# Config format: canonical=alias-one,alias-two
# Arguments:
#   $1 - runner user/login
# Output: canonical on line 1, aliases one per following line
#######################################
_dashboard_identity_aliases() {
	local runner_user="$1"
	local normalized_runner
	normalized_runner=$(_normalize_dashboard_identity_token "$runner_user")
	local canonical="$normalized_runner"
	local aliases="$normalized_runner"
	local config_path
	config_path=$(_dashboard_identity_alias_config_path)

	if [[ -n "$config_path" ]]; then
		local line lhs rhs alias normalized_lhs normalized_alias candidate_aliases _identity_alias_parts
		while IFS= read -r line || [[ -n "$line" ]]; do
			line="${line%%#*}"
			[[ "$line" == *"="* ]] || continue
			lhs="${line%%=*}"
			rhs="${line#*=}"
			normalized_lhs=$(_normalize_dashboard_identity_token "$lhs")
			[[ -n "$normalized_lhs" ]] || continue
			candidate_aliases="$normalized_lhs"
			IFS=',' read -r -a _identity_alias_parts <<<"$rhs"
			for alias in "${_identity_alias_parts[@]}"; do
				normalized_alias=$(_normalize_dashboard_identity_token "$alias")
				[[ -n "$normalized_alias" ]] || continue
				candidate_aliases="${candidate_aliases}"$'\n'"${normalized_alias}"
			done
			if printf '%s\n' "$candidate_aliases" | grep -Fx -- "$normalized_runner" >/dev/null 2>&1; then
				canonical="$normalized_lhs"
				aliases="$candidate_aliases"
				break
			fi
		done <"$config_path"
	fi

	printf '%s\n' "$canonical"
	printf '%s\n' "$aliases" | awk 'NF && !seen[$0]++'
	return 0
}

#######################################
# Resolve a runner to the canonical dashboard identity only.
# Arguments:
#   $1 - runner user/login
# Output: canonical identity
#######################################
_resolve_dashboard_canonical_identity() {
	local runner_user="$1"
	_dashboard_identity_aliases "$runner_user" | sed -n '1p'
	return 0
}
