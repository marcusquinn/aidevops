#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Feature Toggles & Configuration Loader (issue #2730 — JSONC config)
# =============================================================================
# Configuration-loading functions extracted from shared-constants.sh (t2427) to
# keep that file under the 2000-line file-size-debt threshold.
#
# Loads user-configurable settings from JSONC config files:
#   1. Defaults file (shipped with aidevops, overwritten on update)
#      ~/.aidevops/agents/configs/aidevops.defaults.jsonc
#   2. User overrides (~/.config/aidevops/config.jsonc)
#   3. Environment variables (highest priority)
#
# Requires jq for JSONC parsing. Falls back to legacy .conf if jq unavailable.
#
# Public API (backward-compatible flat keys):
#   - get_feature_toggle <key> [default]   — get any config value
#   - is_feature_enabled <key>             — check boolean config
#
# Internal helpers:
#   - _ft_env_map <key>                    — map legacy key to env var name
#   - _load_config                         — auto-called on source
#   - _load_feature_toggles_legacy         — .conf-file fallback loader
#
# Usage: source "${SCRIPT_DIR}/shared-feature-toggles.sh"
#        # _load_config is invoked automatically at end of this file
#
# Dependencies:
#   - config-helper.sh (sourced here — provides _jsonc_get, config_get, config_enabled)
#   - runtime-registry.sh (sourced here — central data source for AI CLI runtimes)
#   - bash 4+, jq (optional — falls back to legacy .conf without it)
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh first.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_FEATURE_TOGGLES_LOADED:-}" ]] && return 0
_SHARED_FEATURE_TOGGLES_LOADED=1

# =============================================================================
# Source dependencies (config-helper.sh, runtime-registry.sh)
# =============================================================================

# Source config-helper.sh (provides _jsonc_get, config_get, config_enabled, etc.)
# IMPORTANT: source=/dev/null tells ShellCheck NOT to follow this source directive.
# Without it, ShellCheck follows the cycle shared-constants.sh → config-helper.sh →
# shared-constants.sh infinitely, consuming exponential memory (7-14 GB observed).
# The include guard (_SHARED_CONSTANTS_LOADED) prevents infinite recursion at
# execution time, but ShellCheck is a static analyzer and ignores runtime guards.
# GH#3981: https://github.com/marcusquinn/aidevops/issues/3981
# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh (the MCP shell environment). Without this guard, sourcing from zsh
# with set -u (nounset) fails with "BASH_SOURCE[0]: parameter not set". See GH#4904.
_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
_CONFIG_HELPER="${_SC_SELF%/*}/config-helper.sh"
if [[ -r "$_CONFIG_HELPER" ]]; then
	# shellcheck source=/dev/null
	source "$_CONFIG_HELPER"
fi

# Source runtime registry (t1665.1) — central data source for all AI CLI runtimes
_RUNTIME_REGISTRY="${_SC_SELF%/*}/runtime-registry.sh"
if [[ -r "$_RUNTIME_REGISTRY" ]]; then
	# shellcheck source=/dev/null
	source "$_RUNTIME_REGISTRY"
fi

# =============================================================================
# Legacy paths (kept for backward compatibility and migration)
# =============================================================================

FEATURE_TOGGLES_DEFAULTS="${HOME}/.aidevops/agents/configs/feature-toggles.conf.defaults"
FEATURE_TOGGLES_USER="${HOME}/.config/aidevops/feature-toggles.conf"

# Prefix for dynamic toggle variables exposed by legacy mode (e.g. _FT_auto_update).
readonly _FT_VAR_PREFIX="_FT_"

# Parse one key=value line from a legacy .conf file into a _FT_* variable.
# Skips blank lines, comments, and lines with non-identifier keys.
_ft_parse_conf_line() {
	local line="$1"
	[[ -z "$line" || "$line" == \#* ]] && return 0
	local key="${line%%=*}"
	local value="${line#*=}"
	[[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 0
	printf -v "${_FT_VAR_PREFIX}${key}" '%s' "$value"
	return 0
}

# Load one .conf file by iterating _ft_parse_conf_line over its lines.
_ft_load_conf_file() {
	local path="$1"
	[[ -r "$path" ]] || return 0
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		_ft_parse_conf_line "$line"
	done <"$path"
	return 0
}

# =============================================================================
# Legacy key → environment variable name mapping
# =============================================================================
# Used by both the new JSONC system and the legacy fallback.
_ft_env_map() {
	local key="$1"
	case "$key" in
	auto_update) echo "AIDEVOPS_AUTO_UPDATE" ;;
	update_interval) echo "AIDEVOPS_UPDATE_INTERVAL" ;;
	skill_auto_update) echo "AIDEVOPS_SKILL_AUTO_UPDATE" ;;
	skill_freshness_hours) echo "AIDEVOPS_SKILL_FRESHNESS_HOURS" ;;
	tool_auto_update) echo "AIDEVOPS_TOOL_AUTO_UPDATE" ;;
	tool_freshness_hours) echo "AIDEVOPS_TOOL_FRESHNESS_HOURS" ;;
	tool_idle_hours) echo "AIDEVOPS_TOOL_IDLE_HOURS" ;;
	supervisor_pulse) echo "AIDEVOPS_SUPERVISOR_PULSE" ;;
	repo_sync) echo "AIDEVOPS_REPO_SYNC" ;;
	repo_aidevops_health) echo "AIDEVOPS_REPO_HEALTH" ;;
	openclaw_auto_update) echo "AIDEVOPS_OPENCLAW_AUTO_UPDATE" ;;
	openclaw_freshness_hours) echo "AIDEVOPS_OPENCLAW_FRESHNESS_HOURS" ;;
	upstream_watch) echo "AIDEVOPS_UPSTREAM_WATCH" ;;
	upstream_watch_hours) echo "AIDEVOPS_UPSTREAM_WATCH_HOURS" ;;
	max_interactive_sessions) echo "AIDEVOPS_MAX_SESSIONS" ;;
	*) echo "" ;;
	esac
	return 0
}

# =============================================================================
# Legacy fallback: load from .conf files when jq is not available
# =============================================================================
# Keys that should pick up environment-variable overrides in legacy mode.
# Keep in sync with _ft_env_map plus a few extras that don't yet have env vars.
readonly _FT_LEGACY_ENV_OVERRIDE_KEYS="auto_update update_interval skill_auto_update skill_freshness_hours tool_auto_update tool_freshness_hours tool_idle_hours supervisor_pulse repo_sync repo_aidevops_health openclaw_auto_update openclaw_freshness_hours upstream_watch upstream_watch_hours max_interactive_sessions manage_opencode_config manage_claude_config session_greeting safety_hooks shell_aliases onboarding_prompt"

_load_feature_toggles_legacy() {
	_ft_load_conf_file "$FEATURE_TOGGLES_DEFAULTS"
	_ft_load_conf_file "$FEATURE_TOGGLES_USER"

	local tk env_var env_val
	for tk in $_FT_LEGACY_ENV_OVERRIDE_KEYS; do
		env_var=$(_ft_env_map "$tk")
		[[ -z "$env_var" ]] && continue
		env_val="${!env_var:-}"
		[[ -z "$env_val" ]] && continue
		printf -v "${_FT_VAR_PREFIX}${tk}" '%s' "$env_val"
	done

	return 0
}

# =============================================================================
# Detect which config system to use and load accordingly
# =============================================================================
# Config-mode sentinels (avoid repeated string literals across callers).
readonly CONFIG_MODE_JSONC="jsonc"
readonly CONFIG_MODE_LEGACY="legacy"

_AIDEVOPS_CONFIG_MODE=""

_load_config() {
	# Prefer JSONC if jq is available, defaults file exists, AND config-helper.sh
	# functions (config_get/config_enabled) are loaded. Without the functions,
	# having jq + defaults is not enough — callers would fail at runtime.
	local jsonc_defaults="${JSONC_DEFAULTS:-${HOME}/.aidevops/agents/configs/aidevops.defaults.jsonc}"
	if command -v jq &>/dev/null && [[ -r "$jsonc_defaults" ]] &&
		type config_get &>/dev/null && type config_enabled &>/dev/null; then
		_AIDEVOPS_CONFIG_MODE="$CONFIG_MODE_JSONC"
		# config-helper.sh functions are already available via source above
		# Auto-migrate legacy .conf if it exists and no JSONC user config yet
		local jsonc_user="${JSONC_USER:-${HOME}/.config/aidevops/config.jsonc}"
		if [[ -f "$FEATURE_TOGGLES_USER" && ! -f "$jsonc_user" ]]; then
			if type _migrate_conf_to_jsonc &>/dev/null; then
				if ! _migrate_conf_to_jsonc; then
					echo "[WARN] Auto-migration from legacy config failed. Run 'aidevops config migrate' manually." >&2
				fi
			fi
		fi
	else
		_AIDEVOPS_CONFIG_MODE="$CONFIG_MODE_LEGACY"
		_load_feature_toggles_legacy
	fi

	return 0
}

# =============================================================================
# Backward-compatible API: get_feature_toggle / is_feature_enabled
# =============================================================================
# These accept flat legacy keys (e.g. "auto_update") and route to the
# appropriate backend (JSONC or legacy .conf).

# Resolve a legacy flat key to a dotpath via _legacy_key_to_dotpath if loaded,
# else return the key verbatim. Shared by get_feature_toggle / is_feature_enabled.
_ft_resolve_dotpath() {
	local key="$1"
	if type _legacy_key_to_dotpath &>/dev/null; then
		_legacy_key_to_dotpath "$key"
	else
		echo "$key"
	fi
	return 0
}

# Get a feature toggle / config value.
# Usage: get_feature_toggle <key> [default]
# Accepts both legacy flat keys and new dotpath keys.
get_feature_toggle() {
	local key="$1"
	local default="${2:-}"

	if [[ "$_AIDEVOPS_CONFIG_MODE" == "$CONFIG_MODE_JSONC" ]]; then
		local dotpath
		dotpath=$(_ft_resolve_dotpath "$key")
		config_get "$dotpath" "$default"
	else
		# Legacy mode: read from _FT_* variables
		local var_name="${_FT_VAR_PREFIX}${key}"
		local value="${!var_name:-}"
		if [[ -n "$value" ]]; then
			echo "$value"
		else
			echo "$default"
		fi
	fi
	return 0
}

# Check if a feature toggle / config boolean is enabled (true).
# Usage: if is_feature_enabled auto_update; then ...
is_feature_enabled() {
	local key="$1"

	if [[ "$_AIDEVOPS_CONFIG_MODE" == "$CONFIG_MODE_JSONC" ]]; then
		local dotpath
		dotpath=$(_ft_resolve_dotpath "$key")
		config_enabled "$dotpath"
		return $?
	else
		local value
		value="$(get_feature_toggle "$key" "true")"
		local lower
		lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		[[ "$lower" == "true" ]]
		return $?
	fi
}

# =============================================================================
# Auto-load config on source
# =============================================================================
# Load config immediately when this file is sourced (directly or via
# shared-constants.sh). Ensures _AIDEVOPS_CONFIG_MODE and _FT_* variables
# are populated before any caller tries to read them.
_load_config
