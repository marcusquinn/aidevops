#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#35537 worker resource policy guard: pulse admission is RAM-only. CPU load,
# CPU idle and core counts must never close, cap or pace new-worker admission.
# Policy: .agents/reference/configuration.md "Worker resource policy".
# Sourced production admission path with stubbed OS telemetry; no live dispatch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_base="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$temp_base" # CI runners start without the aidevops workspace
test_dir=$(mktemp -d "${temp_base}/pulse-ram-admission.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export HOME="$test_dir"
mkdir -p "${HOME}/.aidevops/logs"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
cpu_probe_log="${test_dir}/cpu-probes"

assert_equal() {
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$label"
	return 0
}

# Static guard: admission scripts must not read CPU load, CPU idle or core
# counts, nor revive the deprecated CPU admission settings. Comment lines are
# ignored so the policy can be documented in place.
admission_scripts=(
	pulse-capacity.sh
	pulse-capacity-alloc.sh
	pulse-wrapper-config.sh
	pulse-dispatch-lib.sh
	pulse-dispatch-lib-capacity.sh
	pulse-dispatch-engine.sh
	pulse-dispatch-current-state-guardrails.sh
)
cpu_pattern='vm\.loadavg|/proc/loadavg|getloadavg|loadavg\(|iostat|hw\.logicalcpu|hw\.ncpu|(^|[^[:alnum:]_])nproc([^[:alnum:]_]|$)|_NPROCESSORS_ONLN|availableParallelism|os\.cpus|MAX_LOAD_PER_CORE|CPU_IDLE_ADMIT_PERCENT|max_load_per_core|cpu_idle_admit_percent|_pulse_cpu_'
for script in "${admission_scripts[@]}"; do
	matches=$(grep -nE "$cpu_pattern" "$SCRIPT_DIR/$script" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
	if [[ -n "$matches" ]]; then
		printf 'FAIL: %s reads CPU telemetry for admission (GH#35537 RAM-only policy):\n%s\n' "$script" "$matches" >&2
		exit 1
	fi
done
printf 'PASS: admission scripts read no CPU load, idle or core-count telemetry\n'

# shellcheck source=../pulse-capacity.sh
source "$SCRIPT_DIR/pulse-capacity.sh"
# shellcheck source=../pulse-capacity-alloc.sh
source "$SCRIPT_DIR/pulse-capacity-alloc.sh"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/pulse-dispatch-lib.sh"
# shellcheck source=../pulse-dispatch-current-state-guardrails.sh
source "$SCRIPT_DIR/pulse-dispatch-current-state-guardrails.sh"

# Replace only process telemetry; production parsing stays intact.
MOCK_PROCESSES='' MOCK_TREE='' ps_missing=0 tree_missing=0
id() {
	local flag="$1"
	[[ "$flag" == '-u' ]] || return 1
	printf '1001\n'
	return 0
}
ps() {
	local flag="$1" fields="${2:-}"
	if [[ "$flag" == '-Ao' && "$fields" == 'pid=,ppid=,rss=' ]]; then
		[[ "$tree_missing" == 0 ]] || return 1
		printf '%s\n' "$MOCK_TREE"
		return 0
	fi
	[[ "$ps_missing" == 0 ]] || return 1
	if [[ "$flag" == '-C' ]]; then
		[[ "$fields" == *'pulse-wrapper.s'* && "${3:-}" == '-o' && "${4:-}" == 'uid=,stat=,args=' ]] || return 1
	else
		[[ "$flag" == '-axo' && "$fields" == 'uid=,stat=,args=' ]] || return 1
	fi
	printf '%s\n' "$MOCK_PROCESSES"
	return 0
}
assert_equal "$(_pulse_colocated_runner_count)" 1 'current user counts without visible wrapper'
MOCK_PROCESSES=$'1001 S /bin/bash /opt/pulse-wrapper.sh\n1001 S bash /opt/headless-runtime-helper.sh run\n1002 S bash -e /opt/pulse-wrapper.sh\n1002 S /opt/headless-runtime-helper.sh run\n1003 Z bash /opt/pulse-wrapper.sh\n1004 S bash /opt/not-pulse-wrapper.sh\n1005 S rg pulse-wrapper.sh\n1006 S bash other.sh /opt/pulse-wrapper.sh'
assert_equal "$(_pulse_colocated_runner_count)" 2 'distinct runner users ignore duplicates zombies and unrelated scripts'
MOCK_PROCESSES=$'1002 S /bin/bash /opt/headless-runtime-helper.sh run'
assert_equal "$(_pulse_colocated_runner_count)" 2 'another user worker counts between its Pulse cycles'
ps_missing=1
assert_equal "$(_pulse_colocated_runner_count)" 1 'unavailable process telemetry falls back to current user'
ps_missing=0 MOCK_PROCESSES=''

# OS telemetry stubs. CPU probes report a saturated host (load 999, 0% idle)
# and record that they were called; admission must never call them.
os=Darwin memory_mb=131072 vm_missing=0
record_cpu_probe() {
	local probe="$1"
	printf '%s\n' "$probe" >>"$cpu_probe_log"
	return 0
}
uname() {
	printf '%s\n' "$os"
	return 0
}
sysctl() {
	local flag="$1" key="$2"
	[[ "$flag" == "-n" ]] || return 1
	case "$key" in
	hw.pagesize) printf '4096\n' ;;
	vm.loadavg)
		record_cpu_probe "$key"
		printf '{ 999.00 999.00 999.00 }\n'
		;;
	hw.logicalcpu | hw.ncpu)
		record_cpu_probe "$key"
		printf '16\n'
		;;
	*) return 1 ;;
	esac
	return 0
}
vm_stat() {
	[[ "$vm_missing" == 0 ]] || return 1
	printf 'Pages free: %s.\n' "$((memory_mb * 256))"
	return 0
}
iostat() {
	record_cpu_probe iostat
	printf ' us sy id   1m   5m   15m\n 60 40 0 999.00 999.00 999.00\n'
	return 0
}
nproc() {
	record_cpu_probe nproc
	printf '16\n'
	return 0
}
getconf() {
	record_cpu_probe getconf
	printf '16\n'
	return 0
}
awk() {
	local program="$1"
	case "${*: -1}" in
	/proc/loadavg | /proc/stat)
		record_cpu_probe "${*: -1}"
		return 1
		;;
	/proc/meminfo)
		printf 'MemAvailable: %s kB\n' "$((memory_mb * 1024))" | command awk "$program" || return 1
		;;
	*) command awk "$@" || return 1 ;;
	esac
	return 0
}
MOCK_WORKER_ROOTS=''
list_active_worker_processes() {
	local pid=""
	for pid in $MOCK_WORKER_ROOTS; do
		printf '%s 01:00 bash /opt/headless-runtime-helper.sh run\n' "$pid"
	done
	return 0
}

RAM_RESERVE_MB=6144 RAM_PER_WORKER_MB=1536 MAX_WORKERS_CAP=64 MAX_WORKERS_CAP_AUTO=0
for os in Darwin Linux; do
	memory_mb=131072
	assert_equal "$(_pulse_ram_admission)" '81 131072 0 0' "$os large host: RAM slots with saturated CPU"
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 64 "$os saturated CPU leaves the RAM target at the cap"
	[[ "$(<"$LOGFILE")" == *'ram slots: 81, max workers: 64, admission_policy=ram_only'* ]]
	memory_mb=12288
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 4 "$os RAM bounds the target"
	memory_mb=6144
	assert_equal "$(_pulse_ram_admission)" '1 6144 0 0' "$os idle small host keeps one slot while a worker fits"
	memory_mb=1024
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 0 "$os exhausted RAM closes admission"
	# Young workers reserve the RAM they have not claimed yet.
	memory_mb=12288 MOCK_WORKER_ROOTS='100 200'
	MOCK_TREE=$'100 1 524288\n101 100 524288\n200 1 1572864\n300 1 9999999\n301 300 4096'
	assert_equal "$(_pulse_ram_admission)" '3 12288 512 2' "$os growth reserve counts only unclaimed worker RAM"
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 5 "$os target is running workers plus RAM slots"
	tree_missing=1
	assert_equal "$(_pulse_ram_admission)" '2 12288 3072 2' "$os unreadable process tree reserves workers in full"
	tree_missing=0
	memory_mb=6144
	assert_equal "$(_pulse_ram_admission)" '0 6144 512 2' "$os busy small host gets no solo slot"
	MOCK_WORKER_ROOTS='' MOCK_TREE=''
done
os=Darwin vm_missing=1
assert_equal "$(_pulse_ram_admission)" '1 8192 0 0' 'unreadable vm_stat degrades to a small budget, not a closed gate'
vm_missing=0

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
AIDEVOPS_MIN_WORKER_CONCURRENCY=6 MAX_WORKERS_CAP=20
memory_mb=131072 active=7
printf '20\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 7 6)" '20 0' 'saturated CPU does not cap refill'
assert_equal "$(_dispatch_compute_capacity)" '20 7 13' 'saturated CPU does not cap dispatch'
[[ "$(<"$LOGFILE")" == *'admission_policy=ram_only ram_available_mb=131072 ram_worker_growth_mb=0 ram_slots=81 ram_cap=88'* ]]
active=0
assert_equal "$(pulse_apply_provider_load_capacity_cap 1 0 6)" '6 1' 'floor refills when RAM has room'
memory_mb=12288
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 0 6)" '4 0' 'floor and stale target cannot exceed RAM headroom'
memory_mb=1024 active=7
assert_equal "$(pulse_apply_provider_load_capacity_cap 20 7 6)" '0 0' 'exhausted RAM closes refill'
assert_equal "$(_dispatch_compute_capacity)" '0 7 0' 'exhausted RAM keeps running workers with no new slots'
[[ "$(<"$LOGFILE")" == *'admission=closed reason=ram ram_available_mb=1024'* ]]
memory_mb=131072 active=0
printf '0\n' >"${HOME}/.aidevops/logs/pulse-max-workers"
assert_equal "$(_dispatch_compute_capacity)" '0 0 0' 'closed preflight file is not reopened by floor'

# GH#33770: share the auto ceiling, never divide an already-shared cached target.
MAX_WORKERS_CAP=12 MAX_WORKERS_CAP_AUTO=1
calculate_max_workers
assert_equal "$(get_max_workers_target)" 12 'solo automatic ceiling unchanged'
MOCK_PROCESSES=$'1001 S bash /opt/pulse-wrapper.sh\n1002 S bash /opt/headless-runtime-helper.sh run'
for os in Darwin Linux; do
	calculate_max_workers
	assert_equal "$(get_max_workers_target)" 6 "$os two users split automatic ceiling"
	assert_equal "$(pulse_apply_provider_load_capacity_cap 6 0 6)" '6 1' "$os refill does not divide shared target again"
done
[[ "$(<"$LOGFILE")" == *'colocated_runners=2 shared_host_worker_cap=6 worker_cap_auto=1'* ]]
assert_equal "$(pulse_apply_provider_load_capacity_cap 12 7 6)" '6 0' 'refill caps stale target without terminating existing workers'
MAX_WORKERS_CAP=4
assert_equal "$(pulse_apply_provider_load_capacity_cap 4 0 6)" '2 0' 'minimum floor cannot undo host sharing'
MAX_WORKERS_CAP=2
MOCK_PROCESSES+=$'\n1003 S bash /opt/pulse-wrapper.sh'
calculate_max_workers
assert_equal "$(get_max_workers_target)" 1 'many users retain at least one slot'
MAX_WORKERS_CAP=12 MAX_WORKERS_CAP_AUTO=0
calculate_max_workers
assert_equal "$(get_max_workers_target)" 12 'explicit per-runner ceiling is not divided'
assert_equal "$(pulse_apply_provider_load_capacity_cap 12 0 6)" '12 1' 'refill preserves explicit per-runner ceiling'

# Dynamic guard: no admission path above consulted CPU telemetry.
if [[ -s "$cpu_probe_log" ]]; then
	printf 'FAIL: admission read CPU telemetry (GH#35537 RAM-only policy): %s\n' "$(tr '\n' ' ' <"$cpu_probe_log")" >&2
	exit 1
fi
printf 'PASS: admission never consulted CPU load, idle or core counts\n'
printf 'RAM-only admission verification passed\n'
