#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse Diagnose Utilities — path resolution and retry helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DIAGNOSE_UTILS_LOADED:-}" ]] && return 0
_PULSE_DIAGNOSE_UTILS_LOADED=1

_resolve_logfile() {
	local override="${1:-}"
	if [[ -n "${PULSE_DIAGNOSE_LOGFILE:-}" ]]; then
		printf '%s\n' "$PULSE_DIAGNOSE_LOGFILE"
	elif [[ -n "$override" ]]; then
		printf '%s\n' "$override"
	else
		printf '%s\n' "$DEFAULT_LOGFILE"
	fi
	return 0
}

_resolve_logdir() {
	printf '%s\n' "${PULSE_DIAGNOSE_LOGDIR:-$DEFAULT_LOGDIR}"
	return 0
}

_resolve_metrics_file() {
	printf '%s\n' "${PULSE_DIAGNOSE_METRICS_FILE:-$DEFAULT_METRICS_FILE}"
	return 0
}

_resolve_stats_file() {
	printf '%s\n' "${PULSE_DIAGNOSE_STATS_FILE:-$DEFAULT_STATS_FILE}"
	return 0
}

_resolve_gh_api_log() {
	printf '%s\n' "${PULSE_DIAGNOSE_GH_API_LOG:-$DEFAULT_GH_API_LOG}"
	return 0
}

_resolve_blocker_log() {
	printf '%s\n' "${PULSE_DIAGNOSE_BLOCKER_LOG:-$DEFAULT_BLOCKER_LOG}"
	return 0
}

_resolve_systemd_timer_file() {
	printf '%s\n' "${PULSE_DIAGNOSE_SYSTEMD_TIMER_FILE:-$DEFAULT_SYSTEMD_TIMER_FILE}"
	return 0
}

_diagnose_cooldown_for_rate_limit_count() {
	local count="$1"
	if [[ "$count" -le 1 ]]; then
		printf '300\n'
	elif [[ "$count" -eq 2 ]]; then
		printf '1800\n'
	elif [[ "$count" -eq 3 ]]; then
		printf '7200\n'
	else
		printf '86400\n'
	fi
	return 0
}
