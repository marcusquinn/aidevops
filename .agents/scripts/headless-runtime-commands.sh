#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Commands -- CLI subcommands & argument parsing
# =============================================================================
# CLI entry points (cmd_select, cmd_backoff, cmd_session, cmd_metrics)
# and argument parsing helpers (_parse_run_args, _validate_run_args) for
# headless-runtime-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - headless-runtime-lib.sh (db_query, choose_model, resolve_model_tier, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_COMMANDS_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (test harnesses may not set it)
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
		local _arg="$1"
		case "$_arg" in
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
			print_error "Unknown option for select: $_arg"
			return 1
			;;
		esac
	done

	# When a tier is specified, resolve the concrete model for that tier and
	# use it as the explicit model override. This ensures the round-robin
	# selects from the correct tier's model pool (e.g., haiku for tier:simple,
	# opus for tier:thinking) rather than always defaulting to sonnet.
	if [[ -n "$tier_override" && -z "$model_override" ]]; then
		local tier_model=""
		tier_model=$(resolve_model_tier "$tier_override" 2>/dev/null) || tier_model=""
		if [[ -n "$tier_model" ]]; then
			model_override="$tier_model"
		fi
	fi

	local selected
	selected=$(choose_model "$role" "$model_override") || return $?
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
		db_query "DELETE FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$session_key")';" >/dev/null
		return 0
		;;
	*)
		print_error "Unknown session action: $action"
		return 1
		;;
	esac
}

# =============================================================================
# Run argument parsing and validation
# =============================================================================

# _parse_run_args: parse cmd_run flags into caller-scoped variables.
# Caller must declare: role session_key work_dir title prompt prompt_file
#                      model_override tier_override variant_override agent_name extra_args
# Returns 1 on unknown flag.
_parse_run_args() {
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--role)
			role="${2:-}"
			shift 2
			;;
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--dir)
			work_dir="${2:-}"
			shift 2
			;;
		--title)
			title="${2:-}"
			shift 2
			;;
		--prompt)
			prompt="${2:-}"
			shift 2
			;;
		--prompt-file)
			prompt_file="${2:-}"
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
		--variant)
			variant_override="${2:-}"
			shift 2
			;;
		--agent)
			agent_name="${2:-}"
			shift 2
			;;
		--runtime)
			# Explicit runtime override: "opencode" (default), "claude", etc.
			headless_runtime="${2:-}"
			shift 2
			;;
		--opencode-arg)
			extra_args+=("${2:-}")
			shift 2
			;;
		--detach)
			detach=1
			shift
			;;
		*)
			print_error "Unknown option for run: $_arg"
			return 1
			;;
		esac
	done
	return 0
}

# _validate_run_args: check required fields and resolve prompt from file if needed.
# Operates on caller-scoped variables set by _parse_run_args.
_validate_run_args() {
	[[ -n "$session_key" ]] || {
		print_error "run requires --session-key"
		return 1
	}
	[[ -n "$work_dir" ]] || {
		print_error "run requires --dir"
		return 1
	}
	[[ -n "$title" ]] || {
		print_error "run requires --title"
		return 1
	}
	if [[ -z "$prompt" && -n "$prompt_file" ]]; then
		[[ -f "$prompt_file" ]] || {
			print_error "Prompt file not found: $prompt_file"
			return 1
		}
		prompt=$(<"$prompt_file")
	fi
	[[ -n "$prompt" ]] || {
		print_error "run requires --prompt or --prompt-file"
		return 1
	}
	return 0
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
		local _arg="$1"
		case "$_arg" in
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
			print_error "Unknown option for metrics: $_arg"
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
