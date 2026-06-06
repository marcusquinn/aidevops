#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# headless-runtime-helper-cmds.sh — CLI subcommand handlers
# =============================================================================
# CLI command implementations extracted from headless-runtime-helper.sh:
#   cmd_select, cmd_backoff, cmd_session, cmd_metrics
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-helper-cmds.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - headless-runtime-lib.sh (choose_model, db_query, resolve_model_tier,
#     clear_provider_backoff, record_provider_backoff, extract_provider,
#     sql_escape, _execute_metrics_analysis, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_CMDS_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_CMDS_LOADED=1

# SCRIPT_DIR fallback for when sourced directly (e.g., in tests)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# CLI subcommands — select, backoff, session
# =============================================================================

cmd_select() {
	local role="worker"
	local model_override=""
	local tier_override=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--role)
			role="${2:-}"
			shift 2
			;;
		--model)
			model_override="${2:-}"
			shift 2
			;;
		--tier)
			tier_override="${2:-}"
			shift 2
			;;
		*)
			print_error "Unknown option for select: ${1:-}"
			return 1
			;;
		esac
	done

	local selected
	selected=$(choose_model "$role" "$model_override" "$tier_override") || return $?
	printf '%s\n' "$selected"
	return 0
}

cmd_backoff() {
	local action="${1:-status}"
	shift || true
	case "$action" in
	status)
		db_query "SELECT provider || '|' || reason || '|' || retry_after || '|' || updated_at FROM provider_backoff ORDER BY provider;"
		return 0
		;;
	clear)
		local key="${1:-}"
		[[ -n "$key" ]] || {
			print_error "Usage: backoff clear <provider-or-model>"
			return 1
		}
		clear_provider_backoff "$key"
		return 0
		;;
	set)
		local key="${1:-}"
		local reason="${2:-provider_error}"
		local retry_seconds="${3:-300}"
		[[ -n "$key" ]] || {
			print_error "Usage: backoff set <provider-or-model> <reason> [retry_seconds]"
			return 1
		}
		local provider
		provider=$(extract_provider "$key" 2>/dev/null || printf '%s' "$key")
		local tmp_file
		tmp_file=$(mktemp)
		printf 'manual backoff %s %s %s\n' "$key" "$reason" "$retry_seconds" >"$tmp_file"
		record_provider_backoff "$provider" "$reason" "$tmp_file" "$key"
		if [[ "$retry_seconds" != "300" ]]; then
			if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
				print_error "retry_seconds must be an integer"
				return 1
			fi
			local retry_after
			retry_after=$(date -u -v+"${retry_seconds}"S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${retry_seconds} seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "")
			db_query "UPDATE provider_backoff SET retry_after = '$(sql_escape "$retry_after")' WHERE provider = '$(sql_escape "$key")';" >/dev/null
		fi
		rm -f "$tmp_file"
		return 0
		;;
	*)
		print_error "Unknown backoff action: $action"
		return 1
		;;
	esac
}

cmd_session() {
	local action="${1:-status}"
	shift || true
	case "$action" in
	status)
		db_query "SELECT provider || '|' || session_key || '|' || session_id || '|' || model || '|' || updated_at FROM provider_sessions ORDER BY provider, session_key;"
		return 0
		;;
	clear)
		local provider="${1:-}"
		local session_key="${2:-}"
		[[ -n "$provider" && -n "$session_key" ]] || {
			print_error "Usage: session clear <provider> <session_key>"
			return 1
		}
		clear_session_id "$provider" "$session_key"
		return 0
		;;
	*)
		print_error "Unknown session action: $action"
		return 1
		;;
	esac
}

# =============================================================================
# Metrics subcommand
# =============================================================================

cmd_metrics() {
	local role_filter="pulse"
	local hours="24"
	local model_filter=""
	local fast_threshold_secs="120"

	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--role)
			role_filter="${2:-pulse}"
			shift 2
			;;
		--hours)
			hours="${2:-24}"
			shift 2
			;;
		--model)
			model_filter="${2:-}"
			shift 2
			;;
		--fast-threshold)
			fast_threshold_secs="${2:-120}"
			shift 2
			;;
		*)
			print_error "Unknown option for metrics: ${1:-}"
			return 1
			;;
		esac
	done

	if [[ ! "$hours" =~ ^[0-9]+$ ]]; then
		print_error "--hours must be an integer"
		return 1
	fi
	if [[ ! "$fast_threshold_secs" =~ ^[0-9]+$ ]]; then
		print_error "--fast-threshold must be an integer"
		return 1
	fi

	if [[ ! -f "$METRICS_FILE" ]]; then
		print_info "No runtime metrics recorded yet: $METRICS_FILE"
		return 0
	fi

	_execute_metrics_analysis "$role_filter" "$hours" "$model_filter" "$fast_threshold_secs"
	return 0
}
