#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# lint-resource-benchmark.sh — bounded, serialized lint resource profiler.
#
# The helper never writes command arguments, repository paths, or raw command
# output to its JSONL report. It composes the existing process-tree sampler with
# sandbox-exec-helper.sh's process-group timeout cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly RESOURCE_METRICS_HELPER="${SCRIPT_DIR}/resource-metrics-helper.sh"
readonly SANDBOX_EXEC_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
readonly DEFAULT_TIMEOUT_SECONDS=300
readonly DEFAULT_SAMPLE_INTERVAL_SECONDS=1
readonly DEFAULT_MEMORY_FREE_FLOOR_PCT=15
readonly DEFAULT_SWAP_GROWTH_LIMIT_MB=1024
readonly DEFAULT_REPORT_FILE="${HOME}/.aidevops/logs/lint-resource-benchmarks.jsonl"
readonly LINT_BENCHMARK_PLATFORM_DARWIN="Darwin"
readonly LINT_BENCHMARK_VALUE_UNKNOWN="unknown"

_LINT_BENCHMARK_LOCK_HELD=false
_LINT_BENCHMARK_TEMP_DIR=""
_LINT_BENCHMARK_RUNNER_PID=""
_LINT_BENCHMARK_SAMPLER_PID=""
_LINT_BENCHMARK_STOP_FILE=""
_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE=""

usage() {
	cat <<'EOF'
Usage:
  lint-resource-benchmark.sh run --profile NAME [options] -- command [args...]

Options:
  --timeout SECONDS           Hard timeout (default: 300; max: 3600)
  --interval SECONDS          Resource/safety sample interval (default: 1; max: 30)
  --cache-state STATE         cold | warm | disabled | unknown (default: unknown)
  --coverage-manifest FILE    File list to hash; paths are never emitted
  --out FILE                  Aggregate JSONL report (default: local aidevops log)
  --memory-free-floor PCT     Stop below this available-memory percentage (default: 15)
  --swap-growth-limit MB      Stop above this run-local swap growth (default: 1024)

Exit codes: command status, 73=concurrent run, 75=safety stop, 124=timeout.
EOF
	return 0
}

_lint_benchmark_validate_integer() {
	local name="$1"
	local value="$2"
	local minimum="$3"
	local maximum="$4"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		print_error "${name} must be an integer"
		return 1
	fi
	local canonical=$((10#$value))
	if [[ "$canonical" -lt "$minimum" || "$canonical" -gt "$maximum" ]]; then
		print_error "${name} must be between ${minimum} and ${maximum}"
		return 1
	fi
	printf '%s\n' "$canonical"
	return 0
}

_lint_benchmark_require_option_value() {
	local option_name="$1"
	local argument_count="$2"
	if [[ "$argument_count" -lt 2 ]]; then
		print_error "Option ${option_name} requires an argument"
		return 1
	fi
	return 0
}

_lint_benchmark_lock_dir() {
	printf '%s\n' "${AIDEVOPS_LINT_BENCHMARK_LOCK_DIR:-${TMPDIR:-/tmp}/aidevops-lint-resource-benchmark.lock}"
	return 0
}

_lint_benchmark_acquire_lock() {
	local lock_dir=""
	lock_dir=$(_lint_benchmark_lock_dir)
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"${lock_dir}/pid"
		_LINT_BENCHMARK_LOCK_HELD=true
		return 0
	fi

	local owner_pid=""
	local attempts=0
	while [[ ! -f "${lock_dir}/pid" && "$attempts" -lt 10 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	if [[ -f "${lock_dir}/pid" ]]; then
		owner_pid=$(<"${lock_dir}/pid")
	fi
	if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
		print_error "Another lint resource benchmark is active"
		return 73
	fi

	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	if ! mkdir "$lock_dir" 2>/dev/null; then
		print_error "Could not acquire lint resource benchmark lock"
		return 73
	fi
	printf '%s\n' "$$" >"${lock_dir}/pid"
	_LINT_BENCHMARK_LOCK_HELD=true
	return 0
}

_lint_benchmark_release_lock() {
	if [[ "$_LINT_BENCHMARK_LOCK_HELD" != "true" ]]; then
		return 0
	fi
	local lock_dir=""
	lock_dir=$(_lint_benchmark_lock_dir)
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	_LINT_BENCHMARK_LOCK_HELD=false
	return 0
}

_lint_benchmark_memory_free_pct() {
	local output=""
	if [[ "$(uname -s)" == "$LINT_BENCHMARK_PLATFORM_DARWIN" ]] && command -v memory_pressure >/dev/null 2>&1; then
		output=$(memory_pressure -Q 2>/dev/null || true)
		if [[ "$output" =~ System-wide[[:space:]]memory[[:space:]]free[[:space:]]percentage:[[:space:]]([0-9]+)% ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
			return 0
		fi
	elif [[ -r /proc/meminfo ]]; then
		awk '/MemTotal/ {total=$2} /MemAvailable/ {available=$2} END {if (total > 0) printf "%d\n", (available * 100) / total}' /proc/meminfo
		return 0
	fi
	printf '%s\n' "$LINT_BENCHMARK_VALUE_UNKNOWN"
	return 0
}

_lint_benchmark_swap_used_mb() {
	local output=""
	if [[ "$(uname -s)" == "$LINT_BENCHMARK_PLATFORM_DARWIN" ]]; then
		output=$(sysctl -n vm.swapusage 2>/dev/null || true)
		if [[ "$output" =~ used[[:space:]]=[[:space:]]([0-9]+)(\.[0-9]+)?M ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
			return 0
		fi
	elif [[ -r /proc/meminfo ]]; then
		awk '/SwapTotal/ {total=$2} /SwapFree/ {free=$2} END {printf "%d\n", (total-free)/1024}' /proc/meminfo
		return 0
	fi
	printf '%s\n' "0"
	return 0
}

_lint_benchmark_thermal_state() {
	if [[ "$(uname -s)" != "$LINT_BENCHMARK_PLATFORM_DARWIN" ]] || ! command -v pmset >/dev/null 2>&1; then
		printf '%s\n' "$LINT_BENCHMARK_VALUE_UNKNOWN"
		return 0
	fi
	local output=""
	output=$(pmset -g therm 2>/dev/null || true)
	if [[ "$output" == *"No thermal warning level has been recorded"* ]] &&
		[[ "$output" == *"No performance warning level has been recorded"* ]]; then
		printf '%s\n' "normal"
		return 0
	fi
	local limit=""
	limit=$(printf '%s\n' "$output" | awk -F= '/CPU_Speed_Limit|Scheduler_Limit/ {gsub(/[^0-9]/,"",$2); if ($2 != "" && ($2+0) < 100) {print $2; exit}}')
	if [[ -n "$limit" ]] || [[ "$output" == *"Thermal Warning Level"* ]]; then
		printf '%s\n' "pressure"
		return 0
	fi
	printf '%s\n' "$LINT_BENCHMARK_VALUE_UNKNOWN"
	return 0
}

_lint_benchmark_test_safety_reason() {
	if [[ "${AIDEVOPS_TEST_MODE:-0}" != "1" ]]; then
		return 1
	fi
	local trigger_file="${LINT_RESOURCE_TEST_SAFETY_FILE:-}"
	if [[ -n "$trigger_file" && -s "$trigger_file" ]]; then
		local reason=""
		reason=$(<"$trigger_file")
		printf '%s\n' "${reason:-test_safety_stop}"
		return 0
	fi
	return 1
}

_lint_benchmark_safety_reason() {
	local baseline_swap_mb="$1"
	local memory_free_floor_pct="$2"
	local swap_growth_limit_mb="$3"
	local test_reason=""
	if test_reason=$(_lint_benchmark_test_safety_reason); then
		printf '%s\n' "$test_reason"
		return 0
	fi

	local memory_free_pct=""
	memory_free_pct=$(_lint_benchmark_memory_free_pct)
	if [[ "$memory_free_pct" =~ ^[0-9]+$ ]] && [[ "$memory_free_pct" -lt "$memory_free_floor_pct" ]]; then
		printf '%s\n' "memory_pressure"
		return 0
	fi

	local swap_used_mb=""
	swap_used_mb=$(_lint_benchmark_swap_used_mb)
	if [[ "$swap_used_mb" =~ ^[0-9]+$ ]] && ((swap_used_mb - baseline_swap_mb > swap_growth_limit_mb)); then
		printf '%s\n' "swap_growth"
		return 0
	fi

	if [[ "$(_lint_benchmark_thermal_state)" == "pressure" ]]; then
		printf '%s\n' "thermal_pressure"
		return 0
	fi
	printf '%s\n' ""
	return 0
}

_lint_benchmark_coverage_digest() {
	local manifest_file="$1"
	if [[ -z "$manifest_file" ]]; then
		printf '%s\n' "$LINT_BENCHMARK_VALUE_UNKNOWN"
		return 0
	fi
	if [[ ! -f "$manifest_file" ]]; then
		print_error "Coverage manifest not found"
		return 1
	fi
	if command -v shasum >/dev/null 2>&1; then
		LC_ALL=C sort -u "$manifest_file" | shasum -a 256 | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		LC_ALL=C sort -u "$manifest_file" | sha256sum | awk '{print $1}'
	else
		print_error "No SHA-256 command available"
		return 1
	fi
	return 0
}

_lint_benchmark_stop_sampler() {
	if [[ -n "$_LINT_BENCHMARK_STOP_FILE" ]]; then
		printf '%s\n' "stop" >"$_LINT_BENCHMARK_STOP_FILE" 2>/dev/null || true
	fi
	if [[ -n "$_LINT_BENCHMARK_SAMPLER_PID" ]] && kill -0 "$_LINT_BENCHMARK_SAMPLER_PID" 2>/dev/null; then
		wait "$_LINT_BENCHMARK_SAMPLER_PID" 2>/dev/null || true
	fi
	_LINT_BENCHMARK_SAMPLER_PID=""
	return 0
}

_lint_benchmark_terminate_runner() {
	local runner_pid="$1"
	if [[ ! "$runner_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$runner_pid" 2>/dev/null; then
		return 0
	fi
	kill -TERM "$runner_pid" 2>/dev/null || true
	local attempts=0
	while kill -0 "$runner_pid" 2>/dev/null && [[ "$attempts" -lt 10 ]]; do
		sleep 0.2
		attempts=$((attempts + 1))
	done
	if kill -0 "$runner_pid" 2>/dev/null; then
		kill -KILL "$runner_pid" 2>/dev/null || true
	fi
	wait "$runner_pid" 2>/dev/null || true
	return 0
}

_lint_benchmark_terminate_snapshot_processes() {
	local snapshot_file="$1"
	local runner_pid="$2"
	[[ -f "$snapshot_file" ]] || return 0
	local self_pgid=""
	self_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)
	local process_ids=""
	local process_groups=""
	local pid=""
	local pgid=""
	local last_seen=""
	local current_pgid=""
	while IFS=$'\t' read -r pid pgid last_seen; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$pid" == "$runner_pid" || "$pid" == "$$" ]] && continue
		current_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
		[[ -n "$current_pgid" && "$current_pgid" == "$pgid" ]] || continue
		process_ids="${process_ids} ${pid}"
		if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "$self_pgid" ]]; then
			case " ${process_groups} " in
			*" ${pgid} "*) ;;
			*) process_groups="${process_groups} ${pgid}" ;;
			esac
		fi
	done <"$snapshot_file"

	for pgid in $process_groups; do
		kill -TERM -- "-${pgid}" 2>/dev/null || true
	done
	for pid in $process_ids; do
		kill -TERM "$pid" 2>/dev/null || true
	done
	sleep 0.5
	for pgid in $process_groups; do
		kill -KILL -- "-${pgid}" 2>/dev/null || true
	done
	for pid in $process_ids; do
		kill -KILL "$pid" 2>/dev/null || true
	done
	return 0
}

_lint_benchmark_cleanup() {
	local cleanup_runner_pid="$_LINT_BENCHMARK_RUNNER_PID"
	if [[ -n "$_LINT_BENCHMARK_RUNNER_PID" ]]; then
		_lint_benchmark_terminate_runner "$_LINT_BENCHMARK_RUNNER_PID"
	fi
	_lint_benchmark_stop_sampler
	if [[ -n "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" ]]; then
		_lint_benchmark_terminate_snapshot_processes "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" "$cleanup_runner_pid"
	fi
	if [[ -n "$_LINT_BENCHMARK_TEMP_DIR" && -d "$_LINT_BENCHMARK_TEMP_DIR" ]]; then
		rm -rf "$_LINT_BENCHMARK_TEMP_DIR"
	fi
	_lint_benchmark_release_lock
	return 0
}

_lint_benchmark_write_report() {
	local metrics_file="$1"
	local report_file="$2"
	local profile="$3"
	local cache_state="$4"
	local coverage_digest="$5"
	local result="$6"
	local stop_reason="$7"
	local exit_code="$8"
	local memory_free_pct_start="$9"
	local swap_used_mb_start="${10}"
	local thermal_state_start="${11}"
	local report=""
	report=$(
		PROFILE="$profile" CACHE_STATE="$cache_state" COVERAGE_DIGEST="$coverage_digest" \
			RESULT="$result" STOP_REASON="$stop_reason" EXIT_CODE="$exit_code" \
			MEMORY_FREE_PCT_START="$memory_free_pct_start" SWAP_USED_MB_START="$swap_used_mb_start" \
			THERMAL_STATE_START="$thermal_state_start" python3 - "$metrics_file" <<'PY'
import datetime
import json
import os
import sys

metrics = {}
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        lines = [line for line in handle if line.strip()]
    if lines:
        metrics = json.loads(lines[-1])
except (OSError, ValueError):
    metrics = {}

report = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "profile": os.environ["PROFILE"],
    "cache_state": os.environ["CACHE_STATE"],
    "coverage_digest": os.environ["COVERAGE_DIGEST"],
    "result": os.environ["RESULT"],
    "stop_reason": os.environ["STOP_REASON"],
    "exit_code": int(os.environ["EXIT_CODE"]),
    "memory_free_pct_start": os.environ["MEMORY_FREE_PCT_START"],
    "swap_used_mb_start": int(os.environ["SWAP_USED_MB_START"]),
    "thermal_state_start": os.environ["THERMAL_STATE_START"],
    "elapsed_s": int(metrics.get("elapsed_s", 0)),
    "cpu_seconds": float(metrics.get("cpu_seconds", 0)),
    "peak_rss_kb": int(metrics.get("peak_rss_kb", 0)),
    "avg_rss_kb": int(metrics.get("avg_rss_kb", 0)),
    "peak_process_count": int(metrics.get("peak_process_count", 0)),
    "sample_count": int(metrics.get("sample_count", 0)),
}
print(json.dumps(report, separators=(",", ":"), sort_keys=True))
PY
	)
	if [[ "$report_file" != "-" ]]; then
		mkdir -p "$(dirname "$report_file")"
		printf '%s\n' "$report" >>"$report_file"
	fi
	printf '%s\n' "$report"
	return 0
}

_lint_benchmark_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--profile)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			profile="$2"
			shift 2
			;;
		--timeout)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			timeout_seconds="$2"
			shift 2
			;;
		--interval)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			sample_interval_seconds="$2"
			shift 2
			;;
		--cache-state)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			cache_state="$2"
			shift 2
			;;
		--coverage-manifest)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			coverage_manifest="$2"
			shift 2
			;;
		--out)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			report_file="$2"
			shift 2
			;;
		--memory-free-floor)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			memory_free_floor_pct="$2"
			shift 2
			;;
		--swap-growth-limit)
			_lint_benchmark_require_option_value "$1" "$#" || return 1
			swap_growth_limit_mb="$2"
			shift 2
			;;
		--)
			shift
			command_args=("$@")
			return 0
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

run_benchmark() {
	local profile=""
	local timeout_seconds="$DEFAULT_TIMEOUT_SECONDS"
	local sample_interval_seconds="$DEFAULT_SAMPLE_INTERVAL_SECONDS"
	local cache_state="$LINT_BENCHMARK_VALUE_UNKNOWN"
	local coverage_manifest=""
	local report_file="$DEFAULT_REPORT_FILE"
	local memory_free_floor_pct="$DEFAULT_MEMORY_FREE_FLOOR_PCT"
	local swap_growth_limit_mb="$DEFAULT_SWAP_GROWTH_LIMIT_MB"
	local -a command_args=()

	_lint_benchmark_parse_args "$@" || return 1
	if [[ ! "$profile" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
		print_error "--profile must use 1-64 safe characters"
		return 1
	fi
	case "$cache_state" in
	cold | warm | disabled | unknown) ;;
	*)
		print_error "Invalid --cache-state"
		return 1
		;;
	esac
	if [[ ${#command_args[@]} -eq 0 ]]; then
		print_error "A command is required after --"
		return 1
	fi
	timeout_seconds=$(_lint_benchmark_validate_integer timeout "$timeout_seconds" 1 3600) || return 1
	sample_interval_seconds=$(_lint_benchmark_validate_integer interval "$sample_interval_seconds" 1 30) || return 1
	memory_free_floor_pct=$(_lint_benchmark_validate_integer memory-free-floor "$memory_free_floor_pct" 1 99) || return 1
	swap_growth_limit_mb=$(_lint_benchmark_validate_integer swap-growth-limit "$swap_growth_limit_mb" 1 1048576) || return 1
	[[ -x "$RESOURCE_METRICS_HELPER" && -x "$SANDBOX_EXEC_HELPER" ]] || {
		print_error "Required resource or sandbox helper is unavailable"
		return 1
	}

	local coverage_digest=""
	coverage_digest=$(_lint_benchmark_coverage_digest "$coverage_manifest") || return 1
	_lint_benchmark_acquire_lock || return $?
	_LINT_BENCHMARK_TEMP_DIR=$(mktemp -d)
	_LINT_BENCHMARK_STOP_FILE="${_LINT_BENCHMARK_TEMP_DIR}/stop"
	local metrics_file="${_LINT_BENCHMARK_TEMP_DIR}/metrics.jsonl"
	_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE="${_LINT_BENCHMARK_TEMP_DIR}/process-tree.tsv"
	trap '_lint_benchmark_cleanup' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	local memory_free_pct_start=""
	local swap_used_mb_start=""
	local thermal_state_start=""
	memory_free_pct_start=$(_lint_benchmark_memory_free_pct)
	swap_used_mb_start=$(_lint_benchmark_swap_used_mb)
	thermal_state_start=$(_lint_benchmark_thermal_state)

	local preflight_reason=""
	preflight_reason=$(_lint_benchmark_safety_reason "$swap_used_mb_start" "$memory_free_floor_pct" "$swap_growth_limit_mb")
	if [[ -n "$preflight_reason" ]]; then
		_lint_benchmark_write_report "$metrics_file" "$report_file" "$profile" "$cache_state" \
			"$coverage_digest" "safety_stop" "$preflight_reason" 75 "$memory_free_pct_start" \
			"$swap_used_mb_start" "$thermal_state_start"
		return 75
	fi

	"$SANDBOX_EXEC_HELPER" run --timeout "$timeout_seconds" --stream-stdout -- "${command_args[@]}" &
	_LINT_BENCHMARK_RUNNER_PID="$!"
	"$RESOURCE_METRICS_HELPER" sample \
		--pid "$_LINT_BENCHMARK_RUNNER_PID" \
		--role "lint-profile" \
		--session-key "$profile" \
		--out "$metrics_file" \
		--stop-file "$_LINT_BENCHMARK_STOP_FILE" \
		--process-snapshot-file "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" \
		--interval "$sample_interval_seconds" >/dev/null 2>&1 &
	_LINT_BENCHMARK_SAMPLER_PID="$!"

	local stop_reason=""
	while kill -0 "$_LINT_BENCHMARK_RUNNER_PID" 2>/dev/null; do
		stop_reason=$(_lint_benchmark_safety_reason "$swap_used_mb_start" "$memory_free_floor_pct" "$swap_growth_limit_mb")
		if [[ -n "$stop_reason" ]]; then
			"$RESOURCE_METRICS_HELPER" snapshot \
				--pid "$_LINT_BENCHMARK_RUNNER_PID" \
				--process-snapshot-file "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" >/dev/null 2>&1 || true
			_lint_benchmark_terminate_runner "$_LINT_BENCHMARK_RUNNER_PID"
			break
		fi
		sleep "$sample_interval_seconds"
	done

	local exit_code=0
	local completed_runner_pid="$_LINT_BENCHMARK_RUNNER_PID"
	if [[ -n "$stop_reason" ]]; then
		exit_code=75
	else
		wait "$_LINT_BENCHMARK_RUNNER_PID" || exit_code=$?
	fi
	_LINT_BENCHMARK_RUNNER_PID=""
	_lint_benchmark_stop_sampler
	_lint_benchmark_terminate_snapshot_processes "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" "$completed_runner_pid"
	_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE=""

	local result="failed"
	if [[ "$exit_code" -eq 0 ]]; then
		result="success"
	elif [[ "$exit_code" -eq 124 ]]; then
		result="timeout"
	elif [[ "$exit_code" -eq 75 ]]; then
		result="safety_stop"
	fi
	_lint_benchmark_write_report "$metrics_file" "$report_file" "$profile" "$cache_state" \
		"$coverage_digest" "$result" "$stop_reason" "$exit_code" "$memory_free_pct_start" \
		"$swap_used_mb_start" "$thermal_state_start"
	return "$exit_code"
}

main() {
	local command_name="${1:-}"
	case "$command_name" in
	run)
		shift
		run_benchmark "$@"
		;;
	help | --help | -h | "") usage ;;
	*)
		print_error "Unknown command: $command_name"
		usage
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
