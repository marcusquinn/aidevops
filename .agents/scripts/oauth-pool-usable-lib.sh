#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OAuth Pool Usability Library -- shared runtime pool resolver and usable rule
# =============================================================================
# One definition of "which pool file does the active runtime authenticate from"
# and "is at least one account runnable", shared by model-availability-helper.sh
# (Source 5) and headless-runtime-provider.sh (opencode2_oauth_pool_auth_available).
#
# Usage: source "${SCRIPT_DIR}/oauth-pool-usable-lib.sh"
#
# Dependencies: jq. shared-constants.sh (aidevops_opencode_profile_id) optional;
# the profile defaults to v1 when the function is undefined or fails.
#
# Both functions are pure and read-only; neither prints credential material.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OAUTH_POOL_USABLE_LIB_LOADED:-}" ]] && return 0
_OAUTH_POOL_USABLE_LIB_LOADED=1

# oauth_pool_runtime_file: echo the pool file the active runtime authenticates from.
oauth_pool_runtime_file() {
	local profile="v1"
	if declare -F aidevops_opencode_profile_id >/dev/null 2>&1; then
		profile=$(aidevops_opencode_profile_id 2>/dev/null) || profile="v1"
	fi
	if [[ "$profile" == "v2" ]]; then
		local v2_root="${AIDEVOPS_OPENCODE_V2_ROOT:-${HOME}/.aidevops/runtimes/opencode-v2}"
		printf '%s\n' "${AIDEVOPS_OPENCODE_V2_OAUTH_POOL_FILE:-${v2_root}/auth/oauth-pool.json}"
		return 0
	fi
	printf '%s\n' "${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	return 0
}

# oauth_pool_has_usable_account PROVIDER POOL_FILE: exit 0 when at least one
# account is runnable. Allowlist (fail closed): status missing/active/idle with
# no active cooldown, or rate-limited whose cooldown has expired.
oauth_pool_has_usable_account() {
	local provider="$1"
	local pool_file="$2"

	[[ -n "$provider" && -f "$pool_file" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	local now_ms available
	now_ms=$(($(date +%s) * 1000))
	available=$(jq -r --arg provider "$provider" --argjson now "$now_ms" '
		def n: (tonumber? // 0);
		(.[$provider] // [])
		| if type == "array" then . else [] end
		| map(select(type == "object"
			and ((((.status // "") | if . == "" then "active" else . end) | IN("active", "idle", "rate-limited"))
			and (((.cooldownUntil // 0) | n) <= $now))))
		| length
	' "$pool_file" 2>/dev/null) || available=0

	[[ "${available:-0}" =~ ^[0-9]+$ ]] || available=0
	if [[ "$available" -gt 0 ]]; then
		return 0
	fi
	return 1
}
