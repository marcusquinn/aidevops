#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-stats-helper.sh — Lightweight operational counter for pulse metrics (t2424, GH#20030)
#
# Persists named counters to ~/.aidevops/logs/pulse-stats.json using jq-based
# atomic updates. Each counter records per-event timestamps so 24h rolling
# windows can be computed without a separate cron sweep.
#
# Supported counters (initial set):
#   pre_dispatch_aborts                — pre-dispatch eligibility gate aborted dispatch (all gates)
#   pre_dispatch_aborts_recent_commit  — aborts caused by gate 4 (recent closing commit on default branch)
#
# The `aidevops status` command reads this file via `pulse_stats_get_24h`
# to show operator-visible churn metrics.
#
# Usage (sourced from pre-dispatch-eligibility-helper.sh or pulse-dispatch-core.sh):
#   pulse_stats_increment <counter_name>   — add one timestamp event
#   pulse_stats_get_24h <counter_name>     — print count of events in last 24h
#
# Usage (standalone CLI):
#   pulse-stats-helper.sh increment <counter_name>
#   pulse-stats-helper.sh get-24h <counter_name>
#   pulse-stats-helper.sh get-gauge <gauge_name>
#   pulse-stats-helper.sh status           — human-readable summary
#   pulse-stats-helper.sh reset <counter_name>  — clear a counter

set -euo pipefail

# Include guard — prevent double-sourcing (GH#22091).
# pulse-stats-helper.sh is sourced by pulse-merge-stuck.sh,
# pulse-rate-limit-circuit-breaker.sh, pre-dispatch-eligibility-helper.sh,
# and pulse-dispatch-engine.sh. Without this guard every bootstrap cycle
# re-runs the SCRIPT_DIR subprocess and the shared-constants.sh source
# for each caller, stacking enough subprocess overhead to cause --dry-run
# timeouts on slow filesystems.
[[ -n "${_PULSE_STATS_HELPER_LOADED:-}" ]] && return 0
_PULSE_STATS_HELPER_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared constants if available (provides color helpers etc.).
# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

PULSE_STATS_FILE="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
_PULSE_STATS_RECOVERY_FAILURE_REPORTED=""

_pulse_stats_acquire_lock() {
	local output_var="$1"
	local candidate_lock_dir="${PULSE_STATS_FILE}.lock"
	local attempts=0 owner_missing_attempts=0 owner_pid=""
	while ((attempts < 200)); do
		if mkdir "$candidate_lock_dir" 2>/dev/null; then
			chmod 700 "$candidate_lock_dir" 2>/dev/null || true
			printf '%s\n' "$$" >"${candidate_lock_dir}/owner.pid" 2>/dev/null || true
			printf -v "$output_var" '%s' "$candidate_lock_dir"
			return 0
		fi
		if [[ -f "${candidate_lock_dir}/owner.pid" ]]; then
			IFS= read -r owner_pid <"${candidate_lock_dir}/owner.pid" || owner_pid=""
			if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
				owner_missing_attempts=0
				if ! kill -0 "$owner_pid" 2>/dev/null; then
					rm -f "${candidate_lock_dir}/owner.pid" 2>/dev/null || true
					rmdir "$candidate_lock_dir" 2>/dev/null || true
					continue
				fi
			else
				owner_missing_attempts=$((owner_missing_attempts + 1))
			fi
		else
			owner_missing_attempts=$((owner_missing_attempts + 1))
		fi
		if ((owner_missing_attempts >= 100)); then
			rm -f "${candidate_lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$candidate_lock_dir" 2>/dev/null || true
			owner_missing_attempts=0
			continue
		fi
		attempts=$((attempts + 1))
		sleep 0.01
	done
	return 1
}

_pulse_stats_release_lock() {
	local lock_dir="$1"
	[[ -n "$lock_dir" ]] || return 0
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
}

_pulse_stats_report_recovery_failure() {
	local reason="$1"
	if [[ -z "$_PULSE_STATS_RECOVERY_FAILURE_REPORTED" ]]; then
		printf 'Error: Pulse stats recovery failed (%s): %s\n' "$reason" "$PULSE_STATS_FILE" >&2
		_PULSE_STATS_RECOVERY_FAILURE_REPORTED=1
	fi
}

_pulse_stats_recover_locked() {
	local quarantine="" tmp_file="" old_umask=""
	if [[ -s "$PULSE_STATS_FILE" ]]; then
		old_umask=$(umask)
		umask 077
		quarantine=$(mktemp "${PULSE_STATS_FILE}.corrupt.$(date +%s 2>/dev/null || printf '0').XXXXXX") || {
			umask "$old_umask"
			_pulse_stats_report_recovery_failure "quarantine-file"
			return 1
		}
		if ! cp "$PULSE_STATS_FILE" "$quarantine" 2>/dev/null; then
			umask "$old_umask"
			rm -f "$quarantine" 2>/dev/null || true
			_pulse_stats_report_recovery_failure "quarantine-copy"
			return 1
		fi
		umask "$old_umask"
		chmod 600 "$quarantine" 2>/dev/null || {
			rm -f "$quarantine" 2>/dev/null || true
			_pulse_stats_report_recovery_failure "quarantine-permissions"
			return 1
		}
	fi
	tmp_file=$(mktemp "${PULSE_STATS_FILE}.repair-XXXXXX") || {
		_pulse_stats_report_recovery_failure "temporary-file"
		return 1
	}
	chmod 600 "$tmp_file" 2>/dev/null || true
	printf '{"counters":{}}\n' >"$tmp_file" || {
		rm -f "$tmp_file"
		_pulse_stats_report_recovery_failure "initialize"
		return 1
	}
	mv "$tmp_file" "$PULSE_STATS_FILE" 2>/dev/null || {
		rm -f "$tmp_file"
		_pulse_stats_report_recovery_failure "replace"
		return 1
	}
	return 0
}

_pulse_stats_mutate_locked() {
	local filter="$1"
	shift
	local tmp_file
	tmp_file=$(mktemp "${PULSE_STATS_FILE}.write-XXXXXX") || return 1
	if jq -e -s --arg object_type object "$@" \
		'if length == 1 and (.[0] | type == $object_type) and (.[0].counters | type == $object_type) and ((.[0].gauges // {}) | type == $object_type) and ((.[0].invocation_sources // {}) | type == $object_type) then .[0] | '"$filter"' else error("invalid pulse stats document") end' \
		"$PULSE_STATS_FILE" >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$PULSE_STATS_FILE" 2>/dev/null || {
			rm -f "$tmp_file"
			return 1
		}
		return 0
	fi
	rm -f "$tmp_file"
	return 1
}

#######################################
# Ensure the stats file exists. Serialized mutations validate its structure.
# Idempotent — safe to call multiple times.
#######################################
_pulse_stats_ensure_dir() {
	local dir
	dir="$(dirname "$PULSE_STATS_FILE")"
	[[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null
}

_pulse_stats_ensure_file() {
	_pulse_stats_ensure_dir || return 1
	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		printf '{"counters":{}}\n' >"$PULSE_STATS_FILE" 2>/dev/null || return 1
		return 0
	fi

	# Existing bytes are validated by the serialized mutation. Never replace an
	# invalid document here: recovery must quarantine its original evidence first.
	return 0
}

#######################################
# Increment a named counter by adding the current Unix timestamp.
# Uses jq to append to the counter's timestamp array atomically
# (single write via temp file + mv).
#
# Args:
#   $1 - counter_name (e.g. "pre_dispatch_aborts")
#
# Non-fatal: any jq/file failure is logged but does not propagate.
#######################################
pulse_stats_increment() {
	local counter_name="${1:-unknown}"
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0

	local lock_dir=""
	_pulse_stats_ensure_dir || {
		_pulse_stats_report_recovery_failure "stats-directory"
		return 0
	}
	_pulse_stats_acquire_lock lock_dir || {
		_pulse_stats_report_recovery_failure "lock-timeout"
		return 0
	}
	_pulse_stats_ensure_file || {
		_pulse_stats_release_lock "$lock_dir"
		return 0
	}
	# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
	if ! _pulse_stats_mutate_locked '.counters[$name] = ((.counters[$name] // []) + [$ts])' \
		--arg name "$counter_name" --argjson ts "$now_epoch"; then
		# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
		if ! _pulse_stats_recover_locked || ! _pulse_stats_mutate_locked '.counters[$name] = ((.counters[$name] // []) + [$ts])' \
			--arg name "$counter_name" --argjson ts "$now_epoch"; then
			_pulse_stats_report_recovery_failure "increment-retry"
		fi
	fi
	_pulse_stats_release_lock "$lock_dir"
	return 0
}

#######################################
# Return the count of events for a counter in the last 24 hours.
# Prints the count as a plain integer to stdout.
#
# Args:
#   $1 - counter_name
#
# Output: integer (0 if file missing, counter absent, or any error)
#######################################
pulse_stats_get_24h() {
	local counter_name="${1:-unknown}"

	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		printf '0\n'
		return 0
	fi

	local cutoff
	cutoff=$(($(date +%s 2>/dev/null || printf '0') - 86400))

	local count
	count=$(jq -r --arg name "$counter_name" --argjson cutoff "$cutoff" \
		'(.counters[$name] // []) | [.[] | select(. > $cutoff)] | length' \
		"$PULSE_STATS_FILE" 2>/dev/null) || count=0

	printf '%s\n' "${count:-0}"
	return 0
}

#######################################
# Print a human-readable summary of all counters (last 24h).
#######################################
pulse_stats_status() {
	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		echo "  No pulse stats recorded yet."
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	local cutoff=$((now_epoch - 86400))

	local names
	names=$(jq -r '.counters | keys[]' "$PULSE_STATS_FILE" 2>/dev/null) || names=""

	if [[ -z "$names" ]]; then
		echo "  No counters recorded yet."
		return 0
	fi

	local name count
	while IFS= read -r name; do
		[[ -z "$name" ]] && continue
		count=$(jq -r --arg name "$name" --argjson cutoff "$cutoff" \
			'(.counters[$name] // []) | [.[] | select(. > $cutoff)] | length' \
			"$PULSE_STATS_FILE" 2>/dev/null) || count=0
		printf '  %-40s %s (last 24h)\n' "${name}:" "${count:-0}"
	done <<<"$names"

	return 0
}

#######################################
# Print a human-readable summary of all gauges.
#######################################
pulse_stats_gauge_status() {
	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		echo "  No pulse gauges recorded yet."
		return 0
	fi

	local data
	data=$(jq -r '
		(.gauges // {}) as $gauges
		| ($gauges | keys[]) as $name
		| "\($name):\t\($gauges[$name].value // 0)\t\($gauges[$name].ts // 0)"
	' "$PULSE_STATS_FILE") || {
		printf 'Error: Failed to read pulse stats file: %s\n' "$PULSE_STATS_FILE" >&2
		return 1
	}

	if [[ -z "$data" ]]; then
		echo "  No pulse gauges recorded yet."
		return 0
	fi

	local name_with_colon value ts
	while IFS=$'\t' read -r name_with_colon value ts; do
		[[ -z "$name_with_colon" ]] && continue
		printf '  %-40s %s (ts=%s)\n' "$name_with_colon" "${value:-0}" "${ts:-0}"
	done <<<"$data"

	return 0
}

#######################################
# Set a named gauge to an absolute integer value (t3193).
#
# Gauges are distinct from counters: they store the LATEST observation,
# not an event stream. Use for "current cycle has N stuck PRs" or
# "consecutive zero-progress cycles" semantics where the prior value is
# overwritten, not appended.
#
# Stored under .gauges.<name> = {"value": V, "ts": <epoch>} so a reader
# can both see the value and detect staleness.
#
# Args:
#   $1 - gauge_name
#   $2 - integer value (must match ^-?[0-9]+$; non-numeric is rejected)
#
# Non-fatal: any jq/file failure is logged but does not propagate.
#######################################
pulse_stats_set_gauge() {
	local gauge_name="${1:-unknown}"
	local gauge_value="${2:-0}"

	# Reject non-integer values rather than silently writing garbage.
	if [[ ! "$gauge_value" =~ ^-?[0-9]+$ ]]; then
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0

	local lock_dir=""
	_pulse_stats_ensure_dir || {
		_pulse_stats_report_recovery_failure "stats-directory"
		return 0
	}
	_pulse_stats_acquire_lock lock_dir || {
		_pulse_stats_report_recovery_failure "lock-timeout"
		return 0
	}
	_pulse_stats_ensure_file || {
		_pulse_stats_release_lock "$lock_dir"
		return 0
	}
	# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
	if ! _pulse_stats_mutate_locked '.gauges = (.gauges // {}) | .gauges[$name] = {"value": $v, "ts": $ts}' \
		--arg name "$gauge_name" --argjson v "$gauge_value" --argjson ts "$now_epoch"; then
		# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
		if ! _pulse_stats_recover_locked || ! _pulse_stats_mutate_locked '.gauges = (.gauges // {}) | .gauges[$name] = {"value": $v, "ts": $ts}' \
			--arg name "$gauge_name" --argjson v "$gauge_value" --argjson ts "$now_epoch"; then
			_pulse_stats_report_recovery_failure "gauge-retry"
		fi
	fi
	_pulse_stats_release_lock "$lock_dir"
	return 0
}

#######################################
# Read the current value of a gauge (t3193).
# Prints the integer to stdout. Returns 0 if found, 0 with "0" output if not.
#
# Args:
#   $1 - gauge_name
#######################################
pulse_stats_get_gauge() {
	local gauge_name="${1:-unknown}"

	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		printf '0\n'
		return 0
	fi

	local value
	value=$(jq -r --arg name "$gauge_name" \
		'(.gauges[$name].value // 0) | tostring' \
		"$PULSE_STATS_FILE" 2>/dev/null) || value="0"

	printf '%s\n' "${value:-0}"
	return 0
}

#######################################
# Reset (clear) a counter's event history.
# Args: $1 - counter_name
#######################################
pulse_stats_reset() {
	local counter_name="${1:-}"
	if [[ -z "$counter_name" ]]; then
		echo "Usage: pulse_stats_reset <counter_name>" >&2
		return 1
	fi

	if [[ ! -f "$PULSE_STATS_FILE" ]]; then
		return 0
	fi

	local lock_dir=""
	_pulse_stats_acquire_lock lock_dir || return 1
	# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
	if ! _pulse_stats_mutate_locked 'del(.counters[$name])' --arg name "$counter_name"; then
		# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
		if ! _pulse_stats_recover_locked || ! _pulse_stats_mutate_locked 'del(.counters[$name])' --arg name "$counter_name"; then
			_pulse_stats_release_lock "$lock_dir"
			return 1
		fi
	fi
	_pulse_stats_release_lock "$lock_dir"
	echo "Counter '${counter_name}' reset."
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-status}"
	shift || true

	case "$cmd" in
	increment)
		if [[ $# -lt 1 ]]; then
			echo "Usage: pulse-stats-helper.sh increment <counter_name>" >&2
			return 1
		fi
		local increment_counter="$1"
		pulse_stats_increment "$increment_counter"
		return 0
		;;
	get-24h)
		if [[ $# -lt 1 ]]; then
			echo "Usage: pulse-stats-helper.sh get-24h <counter_name>" >&2
			return 1
		fi
		local get24h_counter="$1"
		pulse_stats_get_24h "$get24h_counter"
		return 0
		;;
	get-gauge)
		if [[ $# -lt 1 ]]; then
			echo "Usage: pulse-stats-helper.sh get-gauge <gauge_name>" >&2
			return 1
		fi
		local get_gauge_name="$1"
		pulse_stats_get_gauge "$get_gauge_name"
		return 0
		;;
	status)
		echo "Pulse Stats (last 24h):"
		pulse_stats_status
		echo ""
		echo "Pulse Gauges:"
		pulse_stats_gauge_status
		return 0
		;;
	reset)
		if [[ $# -lt 1 ]]; then
			echo "Usage: pulse-stats-helper.sh reset <counter_name>" >&2
			return 1
		fi
		local reset_counter="$1"
		pulse_stats_reset "$reset_counter"
		return 0
		;;
	help | --help | -h)
		echo "pulse-stats-helper.sh — Pulse operational counter (t2424)"
		echo ""
		echo "Usage:"
		echo "  pulse-stats-helper.sh increment <counter>   Add event to counter"
		echo "  pulse-stats-helper.sh get-24h <counter>     Count events last 24h"
		echo "  pulse-stats-helper.sh get-gauge <gauge>     Read current gauge value"
		echo "  pulse-stats-helper.sh status                Human-readable summary"
		echo "  pulse-stats-helper.sh reset <counter>       Clear a counter"
		echo ""
		echo "Stats file: ${PULSE_STATS_FILE}"
		return 0
		;;
	*)
		echo "Unknown command: ${cmd}. Run: pulse-stats-helper.sh help" >&2
		return 1
		;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
