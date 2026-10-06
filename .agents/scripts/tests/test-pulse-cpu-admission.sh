#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced production admission path; no live dispatch or host load generation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_base="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
[[ -d "$temp_base" ]] || exit 1
test_dir=$(mktemp -d "${temp_base}/pulse-cpu-admission.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export HOME="$test_dir"
mkdir -p "${HOME}/.aidevops/logs"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
# shellcheck source=../pulse-capacity.sh
source "$SCRIPT_DIR/pulse-capacity.sh"
# shellcheck source=../pulse-capacity-alloc.sh
source "$SCRIPT_DIR/pulse-capacity-alloc.sh"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/pulse-dispatch-lib.sh"
# shellcheck source=../pulse-dispatch-current-state-guardrails.sh
source "$SCRIPT_DIR/pulse-dispatch-current-state-guardrails.sh"

assert_equal() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

# Stub OS telemetry, not the CPU-pressure implementation.
os=Darwin MOCK_LOAD=41.2 MOCK_CORES=16 memory_mb=131072 logicalcpu_missing=0 telemetry_missing=0
uname() {
	printf '%s\n' "$os"
	return 0
}
sysctl() {
	local flag="$1" key="$2"
	[[ "$flag" == "-n" ]] || return 1
	case "$key" in
	vm.loadavg)
		[[ "$telemetry_missing" == 0 ]] || return 1
		printf '{ %s 30.0 25.0 }\n' "$MOCK_LOAD"
		;;
	hw.logicalcpu)
		[[ "$logicalcpu_missing" == 0 ]] || return 1
		printf '%s\n' "$MOCK_CORES"
		;;
	hw.ncpu) printf '%s\n' "$MOCK_CORES" ;;
	hw.pagesize) printf '4096\n' ;;
	*) return 1 ;;
	esac
	return 0
}
vm_stat() {
	printf 'Pages free: %s.\n' "$((memory_mb * 256))"
	return 0
}
nproc() {
	printf '%s\n' "$MOCK_CORES"
	return 0
}
MOCK_IDLE=5 idle_missing=0
iostat() {
	[[ "$idle_missing" == 0 ]] || return 1
	printf '      cpu    load average\n us sy id   1m   5m   15m\n 10 10 80 1.00 1.00 1.00\n 40 20 %s 1.00 1.00 1.00\n' "$MOCK_IDLE"
	return 0
}
sleep() { return 0; }
stat_reads_file="${test_dir}/proc-stat-reads"
awk() {
	local program="$1"
	# Keep production parsing/comparison; replace only Linux proc telemetry.
	if [[ "${*: -1}" == /proc/stat ]]; then
		[[ "$idle_missing" == 0 ]] || return 1
		# Monotonic counters whose per-read delta yields exactly MOCK_IDLE percent.
		local reads=0
		reads=$(cat "$stat_reads_file" 2>/dev/null || printf '0')
		reads=$((reads + 1))
		printf '%s\n' "$reads" >"$stat_reads_file"
		printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n' "$((reads * (100 - MOCK_IDLE)))" "$((reads * MOCK_IDLE))" | command awk "$program" || return 1
	elif [[ "${*: -1}" == /proc/loadavg ]]; then
		[[ "$telemetry_missing" == 0 ]] || return 1
		printf '%s 30.0 25.0 1/100 123\n' "$MOCK_LOAD" | command awk "$program" || return 1
	elif [[ "${*: -1}" == /proc/meminfo ]]; then
		printf 'MemAvailable: %s kB\n' "$((memory_mb * 1024))" | command awk "$program" || return 1
	else
		command awk "$@" || return 1
	fi
	return 0
}

RAM_RESERVE_MB=6144 RAM_PER_WORKER_MB=512 MAX_WORKERS_CAP=20 MAX_LOAD_PER_CORE=1.5
for os in Darwin Linux; do
	MOCK_LOAD=41.2
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 closed 1.5 5' "$os saturated telemetry"
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 0 "$os preflight closes admission"
	log_text=$(<"$LOGFILE")
	[[ "$log_text" == *'load=41.2/16 max_load_per_core=1.5 cpu_gate=closed cpu_idle_pct=5'* ]]
	# GH#33754: high load with idle cores keeps admission open (I/O-inflated load).
	MOCK_IDLE=40
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 open_idle 1.5 40' "$os idle cores keep admission open"
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 20 "$os open_idle preserves RAM target"
	MOCK_IDLE=25
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 open_idle 1.5 25' "$os idle equal to threshold admits"
	MOCK_IDLE=24
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 closed 1.5 24' "$os idle below threshold closes"
	MOCK_IDLE=40 CPU_IDLE_ADMIT_PERCENT=0
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 closed 1.5 na' "$os zero disables idle override"
	CPU_IDLE_ADMIT_PERCENT=invalid
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 open_idle 1.5 40' "$os invalid idle threshold falls back to 25"
	unset CPU_IDLE_ADMIT_PERCENT
	idle_missing=1
	assert_equal "$(_pulse_cpu_pressure)" '41.2 16 closed 1.5 na' "$os unavailable idle telemetry stays closed"
	idle_missing=0 MOCK_IDLE=5
	MOCK_LOAD=24.0
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 20 "$os threshold equality stays open and cap binds"
	MOCK_LOAD=8.0 memory_mb=8192
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 4 "$os RAM bound preserved"
	memory_mb=131072
	telemetry_missing=1
	assert_equal "$(_pulse_cpu_pressure)" 'unknown unknown unknown 1.5 na' "$os unavailable sensor fails open explicitly"
	telemetry_missing=0
done
os=Darwin logicalcpu_missing=1
assert_equal "$(_pulse_cpu_core_count)" 16 'Darwin falls back to hw.ncpu'
logicalcpu_missing=0
MOCK_LOAD=24.1
assert_equal "$(_pulse_cpu_pressure)" '24.1 16 closed 1.5 5' 'just above threshold closes'
MAX_LOAD_PER_CORE=3
assert_equal "$(_pulse_cpu_pressure)" '24.1 16 open 3 na' 'configured threshold opens without sampling idle'
for MAX_LOAD_PER_CORE in invalid 0 -1; do
	assert_equal "$(_pulse_cpu_pressure)" '24.1 16 open 4.0 na' 'invalid threshold falls back to full-use default'
done
unset MAX_LOAD_PER_CORE
MOCK_LOAD=45.1
assert_equal "$(_pulse_cpu_pressure)" '45.1 16 open 4.0 na' 'default admits a fully busy host'
MOCK_LOAD=64.1
assert_equal "$(_pulse_cpu_pressure)" '64.1 16 closed 4.0 5' 'default closes on severe run-queue thrash'
MAX_LOAD_PER_CORE=1.5 MOCK_LOAD=invalid
assert_equal "$(_pulse_cpu_pressure)" 'unknown unknown unknown 1.5 na' 'malformed load fails open explicitly'
MOCK_LOAD=41.2 MOCK_CORES=0
assert_equal "$(_pulse_cpu_pressure)" 'unknown unknown unknown 1.5 na' 'zero cores avoids division'
MOCK_CORES=16

# Exercise the real dispatch-capacity coordinator (same cap helper as refill).
# Stub unrelated external provider/REST/state counters, preserving slot arithmetic.
_dispatch_rest_core_progress_allows_next() { return 0; }
_dispatch_stats_gauge() { return 0; }
_dispatch_ramp_phase_start() { return 0; }
count_active_workers() {
	printf '%s\n' "$active"
	return 0
}
_pulse_capacity_selected_provider() {
	printf '\n'
	return 0
}
_pulse_capacity_provider_account_counts() {
	printf '0 -1 0 0\n'
	return 0
}
_pulse_capacity_auth_error_recovery() { return 1; }
_pulse_capacity_auth_error_cycles() {
	printf '0\n'
	return 0
}
_pulse_capacity_recent_health_counts() {
	printf '0 0 0 0 0\n'
	return 0
}
_pulse_capacity_account_multiplier() {
	printf '24 default\n'
	return 0
}
_pulse_capacity_emit_gauges() { return 0; }
AIDEVOPS_MIN_WORKER_CONCURRENCY=6
MOCK_LOAD=41.2 active=0
printf '20\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
assert_equal "$(_dispatch_compute_capacity)" '0 0 0' 'saturated startup cannot invoke minimum floor'
active=7
assert_equal "$(_dispatch_compute_capacity)" '0 7 0' 'saturated dispatch preserves active count with no slots'
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 7 6)" '0 0' 'refill resamples pressure with stale open target'
# GH#33754: open_idle admits only idle-core headroom (16 cores x 40% = 6 slots).
MOCK_IDLE=40
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 7 6)" '13 0' 'open_idle caps launches to idle-core headroom'
assert_equal "$(_dispatch_compute_capacity)" '13 7 6' 'open_idle dispatch admits idle headroom'
[[ "$(<"$LOGFILE")" == *'cpu_gate=open_idle cpu_idle_pct=40 idle_slots=6 active_workers=7 admission=idle_headroom'* ]]
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 0 6)" '6 1' 'open_idle floor stays within idle headroom'
MOCK_IDLE=5
MOCK_LOAD=8.0
assert_equal "$(_dispatch_compute_capacity)" '20 7 13' 'admission resumes with headroom'
printf '0\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
active=0
assert_equal "$(_dispatch_compute_capacity)" '0 0 0' 'closed preflight file is not reopened by floor'

# Check the installed config loader path without user configuration or credentials.
# shellcheck source=../config-helper.sh
source "$SCRIPT_DIR/config-helper.sh"
export AIDEVOPS_MAX_LOAD_PER_CORE=2.25
assert_equal "$(config_get orchestration.max_load_per_core 1.5)" 2.25 'config environment override mapping'
export AIDEVOPS_CPU_IDLE_ADMIT_PERCENT=40
assert_equal "$(config_get orchestration.cpu_idle_admit_percent 25)" 40 'idle admit environment override mapping'
printf 'CPU admission verification passed\n'
