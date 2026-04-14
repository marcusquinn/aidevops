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
