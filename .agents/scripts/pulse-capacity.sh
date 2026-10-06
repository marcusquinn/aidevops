#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-capacity.sh — Worker-slot capacity counters — target workers, runnable candidates, queued count, debug formatting.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - get_max_workers_target
#   - count_runnable_candidates
#   - count_queued_without_worker
#   - pulse_count_debug_log
#   - normalize_count_output
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CAPACITY_LOADED:-}" ]] && return 0
_PULSE_CAPACITY_LOADED=1

#######################################
# Get current max workers from pulse-max-workers file
# Returns: numeric value via stdout (defaults to 1)
#######################################
get_max_workers_target() {
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "1")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	# Zero is a closed admission gate, not a corrupt/missing target.
	# The file is only rewritten by the preflight_capacity stage. Clamp to the
	# live ceiling so a lowered cap (config change, GH#32663 reset) applies to
	# refill/drain dispatch before the next full preflight recomputes it.
	if [[ "${MAX_WORKERS_CAP:-}" =~ ^[1-9][0-9]*$ ]] && ((max_workers > MAX_WORKERS_CAP)); then
		max_workers="$MAX_WORKERS_CAP"
	fi
	echo "$max_workers"
	return 0
}

#######################################
# Resolve the provider that should drive round capacity planning.
# Returns: provider token via stdout, or blank when unknown.
#######################################
_pulse_capacity_selected_provider() {
	local provider_override="${PULSE_DISPATCH_CAPACITY_PROVIDER:-}"
	if [[ -n "$provider_override" ]]; then
		printf '%s\n' "$provider_override"
		return 0
	fi

	local model="${PULSE_DISPATCH_CAPACITY_MODEL:-${PULSE_MODEL:-}}"
	if [[ "$model" == */* ]]; then
		printf '%s\n' "${model%%/*}"
		return 0
	fi

	printf '\n'
	return 0
}

#######################################
# Summarise provider account-pool availability without secrets.
# Arguments:
#   $1 - provider token
# Stdout: "<total> <available> <rate_limited> <auth_errors>".
#         available=-1 means no usable account-pool signal is configured.
#######################################
_pulse_capacity_provider_account_counts() {
	local provider="$1"
	local unavailable_counts='0 -1 0 0'
	local pool_file="${PULSE_DISPATCH_OAUTH_POOL_FILE:-${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}}"
	if [[ -z "$provider" || ! -f "$pool_file" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$unavailable_counts"
		return 0
	fi

	local now_ms="" counts=""
	now_ms=$(($(date +%s) * 1000))
	counts=$(jq -r --arg provider "$provider" --argjson now "$now_ms" --argjson zero 0 --arg status_empty '' --arg status_auth_error 'auth-error' --arg status_rate_limited 'rate-limited' '
		def n: tonumber? // 0;
		def account_status: .status // $status_empty;
		def available_account:
			(account_status) as $status
			| $status != $status_auth_error
			and (($status != $status_rate_limited) or (((.cooldownUntil // 0) | n) <= $now));
		(.[$provider] // []) as $accounts
		| ($accounts | length) as $total
		| if $total == 0 then
			[$zero, -1, $zero, $zero] | @tsv
		else
			($accounts | map(select(account_status == $status_auth_error)) | length) as $auth
			| ($accounts | map(select(
				account_status == $status_rate_limited
				and (((.cooldownUntil // 0) | n) > $now)
			)) | length) as $limited
			| ($accounts | map(select(available_account)) | length) as $available
			| [$total, $available, $limited, $auth] | @tsv
		end
	' "$pool_file" 2>/dev/null) || counts="$unavailable_counts"
	[[ -n "$counts" ]] || counts="$unavailable_counts"
	printf '%s\n' "$counts"
	return 0
}

#######################################
# Count recent terminal worker-role provider health signals. Continuation
# events remain progress evidence but never become failure/capacity pressure.
# Stdout: "<failures> <rate_limits> <service_interruptions> <provider_5xx> <progress_heartbeats>".
#######################################
_pulse_capacity_recent_health_counts() {
	local failure_override="${PULSE_DISPATCH_CAPACITY_RECENT_FAILURES:-${PULSE_DISPATCH_STAGGER_RECENT_FAILURES:-}}"
	local rate_limit_override="${PULSE_DISPATCH_CAPACITY_RECENT_RATE_LIMITS:-${PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS:-}}"
	local service_override="${PULSE_DISPATCH_CAPACITY_RECENT_SERVICE_INTERRUPTS:-}"
	local provider_5xx_override="${PULSE_DISPATCH_CAPACITY_RECENT_PROVIDER_5XX:-}"
	local progress_override="${PULSE_DISPATCH_CAPACITY_RECENT_PROGRESS_HEARTBEATS:-}"
	if [[ "$failure_override" =~ ^[0-9]+$ || "$rate_limit_override" =~ ^[0-9]+$ || "$service_override" =~ ^[0-9]+$ || "$provider_5xx_override" =~ ^[0-9]+$ || "$progress_override" =~ ^[0-9]+$ ]]; then
		[[ "$failure_override" =~ ^[0-9]+$ ]] || failure_override=0
		[[ "$rate_limit_override" =~ ^[0-9]+$ ]] || rate_limit_override=0
		[[ "$service_override" =~ ^[0-9]+$ ]] || service_override=0
		[[ "$provider_5xx_override" =~ ^[0-9]+$ ]] || provider_5xx_override=0
		[[ "$progress_override" =~ ^[0-9]+$ ]] || progress_override=0
		printf '%s %s %s %s %s\n' "$failure_override" "$rate_limit_override" "$service_override" "$provider_5xx_override" "$progress_override"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	local ttl_seconds="${PULSE_DISPATCH_CAPACITY_HEALTH_WINDOW_SECONDS:-900}"
	local health_helper="${BASH_SOURCE[0]%/*}/worker-terminal-health.py"
	[[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=900
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	[[ -f "$metrics_file" ]] || { printf '0 0 0 0 0\n'; return 0; }
	local health_counts="" successes="" failures="" rate_limits="" service_interruptions="" provider_5xx="" progress=""
	health_counts=$(python3 "$health_helper" "$metrics_file" "$evidence_file" "$ttl_seconds" "$evidence_limit") || health_counts="0 3 0 0 0 0"
	read -r successes failures rate_limits service_interruptions provider_5xx progress <<<"$health_counts"
	printf '%s %s %s %s %s\n' "$failures" "$rate_limits" "$service_interruptions" "$provider_5xx" "$progress"
	return 0
}

# The capacity caller runs in a command substitution, so cross-cycle health
# must be persisted rather than returned through shell globals.
_pulse_capacity_auth_error_state_dir() {
	printf '%s/pulse-auth-error-recovery\n' "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	return 0
}

_pulse_capacity_auth_error_only() {
	local total="$1" available="$2" auth_errors="$3"
	((total > 0 && available == 0 && auth_errors == total))
}

# Return success only when this invocation actually attempts a refresh.
_pulse_capacity_auth_error_recovery() {
	local provider="$1" total="$2" available="$3" auth_errors="$4"
	[[ "$provider" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
	_pulse_capacity_auth_error_only "$total" "$available" "$auth_errors" || return 1
	local state_dir stamp lock now last=0 throttle="${PULSE_AUTH_ERROR_REFRESH_THROTTLE_SECONDS:-300}"
	local pool_file="${PULSE_DISPATCH_OAUTH_POOL_FILE:-${AIDEVOPS_OAUTH_POOL_FILE:-$HOME/.aidevops/oauth-pool.json}}"
	# An unexpired backoff is not an attempt: do not consume the throttle
	# window before the pool's refresh eligibility can recover.
	jq -e --arg provider "$provider" --argjson now "$(($(date +%s) * 1000))" \
		'([.[$provider][]? | select(.status == "auth-error" and ((.cooldownUntil // 0 | tonumber? // 0) <= $now))] | length) > 0' \
		"$pool_file" >/dev/null 2>&1 || return 1
	state_dir=$(_pulse_capacity_auth_error_state_dir)
	stamp="${state_dir}/${provider}.last-refresh"
	lock="${state_dir}/${provider}.refresh-lock"
	[[ "$throttle" =~ ^[0-9]+$ ]] || throttle=300
	mkdir -p "$state_dir" 2>/dev/null || return 1
	# Claim atomically across overlapping pulse invocations. A crashed claimant
	# leaves a lock; fail closed instead of repeatedly contacting the endpoint.
	mkdir "$lock" 2>/dev/null || return 1
	now=$(date +%s)
	if [[ -f "$stamp" ]]; then
		IFS= read -r last <"$stamp" || true
	fi
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	if ((now - last < throttle)); then
		rmdir "$lock" 2>/dev/null || true
		return 1
	fi
	if ! printf '%s\n' "$now" >"$stamp"; then
		rmdir "$lock" 2>/dev/null || true
		return 1
	fi
	rmdir "$lock" 2>/dev/null || true
	local helper="${BASH_SOURCE[0]%/*}/oauth-pool-helper.sh"
	# Refresh is serialized by the pool's own lock. Never let a token endpoint
	# stall the dispatch cycle; the pool helper owns credential transitions.
	if ! AIDEVOPS_OAUTH_POOL_FILE="$pool_file" timeout_sec 20 "$helper" refresh "$provider" >>"${LOGFILE:-/dev/null}" 2>&1; then
		printf '[pulse-wrapper] auth-error refresh failed or timed out: provider=%s\n' "$provider" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	fi
	return 0
}

_pulse_capacity_auth_error_cycles() {
	local provider="$1" total="$2" available="$3" auth_errors="$4"
	local state_dir stamp cycles=0 previous_cycle="" cycle_id="${_PULSE_CYCLE_ID:-}"
	[[ "$provider" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf '0\n'; return 0; }
	state_dir=$(_pulse_capacity_auth_error_state_dir)
	stamp="${state_dir}/${provider}.cycles"
	if ! _pulse_capacity_auth_error_only "$total" "$available" "$auth_errors"; then
		rm -f "$stamp"
		printf '0\n'
		return 0
	fi
	mkdir -p "$state_dir" 2>/dev/null || { printf '0\n'; return 0; }
	if [[ -f "$stamp" ]]; then
		read -r cycles previous_cycle <"$stamp" || true
	fi
	[[ "$cycles" =~ ^[0-9]+$ ]] || cycles=0
	if [[ -z "$cycle_id" || "$previous_cycle" != "$cycle_id" ]]; then
		cycles=$((cycles + 1))
	fi
	printf '%s %s\n' "$cycles" "$cycle_id" >"$stamp" || true
	printf '%s\n' "$cycles"
	return 0
}

_pulse_capacity_account_multiplier() {
	local multiplier="${PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-}" source="env:PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER"
	if [[ -z "$multiplier" ]] && declare -F config_get >/dev/null 2>&1; then
		multiplier=$(config_get "orchestration.provider_account_slot_multiplier" "24")
		source="config:orchestration.provider_account_slot_multiplier"
	elif [[ -z "$multiplier" ]]; then
		source="default:24"
	fi
	[[ "$multiplier" =~ ^[0-9]+$ ]] || multiplier=24
	((multiplier < 1)) && multiplier=1
	printf '%s %s\n' "$multiplier" "$source"
	return 0
}

_pulse_capacity_emit_gauges() {
	local available="$1" failures="$2" final_max="$3"
	if declare -F _dispatch_stats_gauge >/dev/null 2>&1; then
		_dispatch_stats_gauge "dispatch_capacity_provider_accounts_available" "$((available < 0 ? 0 : available))"
		_dispatch_stats_gauge "dispatch_capacity_recent_failures" "$failures"
		_dispatch_stats_gauge "dispatch_capacity_recent_worker_terminal_failures" "$failures"
		_dispatch_stats_gauge "dispatch_capacity_final_max_workers" "$final_max"
	fi
	return 0
}

#######################################
# Read one-minute load and logical cores; unavailable telemetry leaves RAM and
# provider limits in force rather than permanently starving dispatch.
#######################################
_pulse_cpu_load_average() {
	if [[ "$(uname)" == "Darwin" ]]; then
		sysctl -n vm.loadavg 2>/dev/null | LC_ALL=C awk '{print $2}'
	else
		LC_ALL=C awk '{print $1; exit}' /proc/loadavg 2>/dev/null
	fi
	return 0
}

_pulse_cpu_core_count() {
	if [[ "$(uname)" == "Darwin" ]]; then
		sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true
	else
		nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true
	fi
	return 0
}

# Count distinct live runner UIDs, not workers. Include this Pulse's user even
# when ps cannot see its wrapper. Numeric UIDs avoid truncated user names on BSD
# ps; exact argument tokens avoid matching scripts merely mentioned in commands.
# One process-table snapshot, no shared writable registry or per-worker probing.
_pulse_colocated_runner_count() {
	local current_uid="" count=""
	current_uid=$(id -u) || current_uid="self"
	count=$(LC_ALL=C ps -axo uid=,stat=,args= 2>/dev/null | LC_ALL=C awk -v self="$current_uid" '
		BEGIN { users[self] = 1; uid_column = 1; stat_column = 2 }
		$(stat_column) !~ /^Z/ {
			for (i = 3; i <= NF; i++) {
				if ($i ~ /(^|\/)(pulse-wrapper|headless-runtime-helper)[.]sh$/) {
					users[$(uid_column)] = 1
					break
				}
			}
		}
		END { for (user in users) count++; print count }
	') || count=1
	[[ "$count" =~ ^[1-9][0-9]*$ ]] || count=1
	printf '%s\n' "$count"
	return 0
}

# Divide only the automatic core/RAM-derived ceiling. Explicit caps already
# represent the operator's per-runner budget. A shared host always gets >=1 slot.
# Arguments: $1 detected runner count. Stdout: per-runner ceiling, or 0 if unset.
_pulse_shared_host_worker_cap() {
	local runners="$1" cap="${MAX_WORKERS_CAP:-0}"
	[[ "$runners" =~ ^[1-9][0-9]*$ ]] || runners=1
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=0
	if [[ "${MAX_WORKERS_CAP_AUTO:-0}" == "1" ]] && ((cap > 0 && runners > 1)); then
		cap=$((cap / runners))
		((cap < 1)) && cap=1
	fi
	printf '%s\n' "$cap"
	return 0
}

# Read one Linux aggregate CPU sample as "<total-jiffies> <idle-jiffies>".
_pulse_cpu_proc_stat_sample() {
	LC_ALL=C awk '/^cpu / {total = 0; for (i = 2; i <= NF; i++) total += $i; print total, $5; exit}' /proc/stat 2>/dev/null
	return 0
}

#######################################
# Measure current whole-host CPU idle percent (GH#33754). Load average also
# counts threads blocked on I/O or locks (notably on macOS), so it can exceed
# the gate while cores sit idle. Costs ~1s wall and negligible CPU; callers
# sample only when load would otherwise close admission. Linux counts idle
# only, not iowait, so I/O-bound hosts stay closed.
# Stdout: integer 0-100. Returns 1 when telemetry is unavailable.
#######################################
_pulse_cpu_idle_percent() {
	local idle=""
	if [[ "$(uname)" == "Darwin" ]]; then
		# Columns with -n 0: "us sy id 1m 5m 15m"; the last row is the 1s interval.
		idle=$(iostat -n 0 -c 2 -w 1 2>/dev/null |
			LC_ALL=C awk 'NF >= 3 && $1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {value = $3} END {print value}') || idle=""
	else
		local first="" second=""
		first=$(_pulse_cpu_proc_stat_sample) || first=""
		sleep 1
		second=$(_pulse_cpu_proc_stat_sample) || second=""
		idle=$(LC_ALL=C awk -v first="$first" -v second="$second" 'BEGIN {
			if (split(first, a, " ") != 2 || split(second, b, " ") != 2) exit 1
			elapsed = b[1] - a[1]
			if (elapsed <= 0) exit 1
			printf "%d\n", (b[2] - a[2]) * 100 / elapsed
		}') || idle=""
	fi
	[[ "$idle" =~ ^[0-9]+$ ]] || return 1
	((idle > 100)) && idle=100
	printf '%s\n' "$idle"
	return 0
}

# Minimum idle percent that keeps admission open above the load threshold.
# 0 disables the override (load alone decides). Invalid values fall back to 25.
_pulse_cpu_idle_admit_percent() {
	local value="${CPU_IDLE_ADMIT_PERCENT:-25}"
	if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value > 100)); then
		value=25
	fi
	printf '%s\n' "$value"
	return 0
}

# Stdout: "<one-minute-load> <cores> <open|open_idle|closed|unknown> <threshold> <idle-percent|na>".
_pulse_cpu_pressure() {
	# Default 4.0: load/core 1.0 is 100% busy, so full CPU use stays admitted;
	# only severe run-queue thrash closes the gate, and only while CPU idle is
	# below orchestration.cpu_idle_admit_percent (GH#33754).
	local load="" cores="" gate="unknown" threshold="${MAX_LOAD_PER_CORE:-4.0}"
	local idle="na" idle_admit=""
	load=$(_pulse_cpu_load_average) || load=""
	cores=$(_pulse_cpu_core_count) || cores=""
	if ! [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
		! LC_ALL=C awk -v value="$threshold" 'BEGIN {exit !(value > 0)}'; then
		threshold=4.0
	fi
	if [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ && "$cores" =~ ^[1-9][0-9]*$ ]]; then
		gate="open"
		if LC_ALL=C awk -v one_minute="$load" -v cores="$cores" -v threshold="$threshold" 'BEGIN {exit !(one_minute / cores > threshold)}'; then
			gate="closed"
			idle_admit=$(_pulse_cpu_idle_admit_percent)
			if ((idle_admit > 0)); then
				idle=$(_pulse_cpu_idle_percent) || idle="na"
				if [[ "$idle" =~ ^[0-9]+$ ]] && ((idle >= idle_admit)); then
					gate="open_idle"
				fi
			fi
		fi
	else
		load="unknown"
		cores="unknown"
	fi
	printf '%s %s %s %s %s\n' "$load" "$cores" "$gate" "$threshold" "$idle"
	return 0
}

#######################################
# Cap an open_idle pass to the headroom idle cores can absorb (>=1 new worker);
# the next pass re-samples idle, so admission tracks real headroom (GH#33754).
# Arguments: $1 final max, $2 active workers, $3 cores, $4 idle %, $5 load, $6 threshold
# Outputs: capped final max
#######################################
_pulse_cap_idle_headroom() {
	local final_max="$1"
	local active_workers="$2"
	local cpu_cores="$3"
	local cpu_idle="$4"
	local cpu_load="$5"
	local cpu_threshold="$6"
	if [[ ! "$cpu_cores" =~ ^[0-9]+$ || ! "$cpu_idle" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$final_max"
		return 0
	fi
	local idle_slots=$((cpu_cores * cpu_idle / 100))
	((idle_slots < 1)) && idle_slots=1
	if ((final_max > active_workers + idle_slots)); then
		final_max=$((active_workers + idle_slots))
	fi
	printf '[pulse-wrapper] Dispatch_capacity: load=%s/%s max_load_per_core=%s cpu_gate=open_idle cpu_idle_pct=%s idle_slots=%s active_workers=%s admission=idle_headroom\n' \
		"$cpu_load" "$cpu_cores" "$cpu_threshold" "$cpu_idle" "$idle_slots" "$active_workers" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	printf '%s\n' "$final_max"
	return 0
}

#######################################
# Apply CPU admission and provider/account/terminal-health caps to the raw target.
# Arguments:
#   $1 - raw max workers
#   $2 - active workers
#   $3 - minimum worker floor
# Stdout: "<final_max_workers> <floor_active>".
#######################################
pulse_apply_provider_load_capacity_cap() {
	local raw_max_workers="$1"
	local active_workers="$2"
	local min_worker_floor="$3"
	[[ "$raw_max_workers" =~ ^[0-9]+$ ]] || raw_max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$min_worker_floor" =~ ^[0-9]+$ ]] || min_worker_floor=6

	# Re-sample on refill: preflight's capacity file may be stale. The floor
	# must not reopen a closed gate. This limits launches, not running workers.
	local cpu_load="" cpu_cores="" cpu_gate="" cpu_threshold="" cpu_idle=""
	read -r cpu_load cpu_cores cpu_gate cpu_threshold cpu_idle <<<"$(_pulse_cpu_pressure)"
	local colocated_runners="" host_worker_cap=""
	colocated_runners=$(_pulse_colocated_runner_count)
	host_worker_cap=$(_pulse_shared_host_worker_cap "$colocated_runners")
	if [[ "$cpu_gate" == "closed" ]] || ((raw_max_workers == 0)); then
		printf '[pulse-wrapper] Dispatch_capacity: load=%s/%s max_load_per_core=%s cpu_gate=%s cpu_idle_pct=%s active_workers=%s admission=closed colocated_runners=%s\n' \
			"$cpu_load" "$cpu_cores" "$cpu_threshold" "$cpu_gate" "${cpu_idle:-na}" "$active_workers" "$colocated_runners" >>"${LOGFILE:-/dev/null}"
		printf '0 0\n'
		return 0
	fi

	local provider="" account_total="" account_available="" account_limited="" account_auth_errors=""
	provider=$(_pulse_capacity_selected_provider)
	read -r account_total account_available account_limited account_auth_errors <<<"$(_pulse_capacity_provider_account_counts "$provider")"
	[[ "$account_total" =~ ^[0-9]+$ ]] || account_total=0
	[[ "$account_available" =~ ^-?[0-9]+$ ]] || account_available=-1
	[[ "$account_limited" =~ ^[0-9]+$ ]] || account_limited=0
	[[ "$account_auth_errors" =~ ^[0-9]+$ ]] || account_auth_errors=0
	if _pulse_capacity_auth_error_recovery "$provider" "$account_total" "$account_available" "$account_auth_errors"; then
		read -r account_total account_available account_limited account_auth_errors <<<"$(_pulse_capacity_provider_account_counts "$provider")"
	fi
	local auth_error_only_cycles
	auth_error_only_cycles=$(_pulse_capacity_auth_error_cycles "$provider" "$account_total" "$account_available" "$account_auth_errors")

	local failures="" rate_limits="" service_interruptions="" provider_5xx="" progress_heartbeats=""
	read -r failures rate_limits service_interruptions provider_5xx progress_heartbeats <<<"$(_pulse_capacity_recent_health_counts)"
	[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
	[[ "$rate_limits" =~ ^[0-9]+$ ]] || rate_limits=0
	[[ "$service_interruptions" =~ ^[0-9]+$ ]] || service_interruptions=0
	[[ "$provider_5xx" =~ ^[0-9]+$ ]] || provider_5xx=0
	[[ "$progress_heartbeats" =~ ^[0-9]+$ ]] || progress_heartbeats=0

	local account_multiplier="" account_multiplier_source=""
	read -r account_multiplier account_multiplier_source <<<"$(_pulse_capacity_account_multiplier)"
	local account_cap=-1
	if ((account_available >= 0)); then
		account_cap=$((account_available * account_multiplier))
	fi

	local floor_allowed=1 final_max="$raw_max_workers" floor_active=0
	if ((rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
		floor_allowed=0
	fi
	if ((account_cap >= 0 && min_worker_floor > 0 && account_cap < min_worker_floor)); then
		floor_allowed=0
	fi

	if ((floor_allowed == 1 && min_worker_floor > 0 && active_workers < min_worker_floor)); then
		floor_active=1
		if ((final_max < min_worker_floor)); then
			final_max="$min_worker_floor"
		fi
	fi

	if ((account_cap >= 0 && final_max > account_cap)); then
		final_max="$account_cap"
	fi
	# Re-sample sharing on refill and bind the floor too. Do not divide the cached
	# preflight target a second time or terminate already-running workers.
	if [[ "${MAX_WORKERS_CAP_AUTO:-0}" == "1" ]] && ((colocated_runners > 1 && host_worker_cap > 0 && final_max > host_worker_cap)); then
		final_max="$host_worker_cap"
	fi
	if ((rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
		if ((final_max > 1)); then
			final_max=$(((final_max + 1) / 2))
		fi
	fi
	if ((active_workers > 0 && progress_heartbeats > 0)); then
		if ((rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
			if ((final_max > active_workers)); then
				final_max="$active_workers"
			fi
		fi
	fi
	if [[ "$cpu_gate" == "open_idle" ]]; then
		final_max=$(_pulse_cap_idle_headroom "$final_max" "$active_workers" "$cpu_cores" "$cpu_idle" "$cpu_load" "$cpu_threshold")
	fi
	if ((final_max < 0)); then
		final_max=0
	fi
	if ((floor_active == 1 && final_max < min_worker_floor)); then
		floor_active=0
	fi

	_pulse_capacity_emit_gauges "$account_available" "$failures" "$final_max"
	local health_window_seconds="${PULSE_DISPATCH_CAPACITY_HEALTH_WINDOW_SECONDS:-900}"
	[[ "$health_window_seconds" =~ ^[0-9]+$ ]] || health_window_seconds=900
	printf '[pulse-wrapper] Dispatch_capacity: colocated_runners=%s shared_host_worker_cap=%s worker_cap_auto=%s\n' \
		"$colocated_runners" "$host_worker_cap" "${MAX_WORKERS_CAP_AUTO:-0}" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	printf '[pulse-wrapper] Dispatch_capacity: capacity_unit=simultaneous_workers simultaneous_target_raw=%s simultaneous_target_final=%s active_workers=%s provider=%s provider_accounts_total=%s provider_accounts_available=%s account_cap=%s provider_account_slot_multiplier=%s provider_account_slot_multiplier_source=%s override_hint="lower orchestration.provider_account_slot_multiplier or PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER if provider plan cannot sustain this concurrency" rate_limited_accounts=%s auth_error_accounts=%s worker_terminal_failures=%s rate_limits=%s service_interruptions=%s provider_5xx=%s worker_progress_heartbeats=%s failure_observation_window_seconds=%s task_duration_limit=none min_floor=%s floor_allowed=%s floor_active=%s auth_error_only_cycles=%s\n' \
		"$raw_max_workers" "$final_max" "$active_workers" "${provider:-unknown}" "$account_total" "$account_available" "$account_cap" "$account_multiplier" "$account_multiplier_source" "$account_limited" "$account_auth_errors" "$failures" "$rate_limits" "$service_interruptions" "$provider_5xx" "$progress_heartbeats" "$health_window_seconds" "$min_worker_floor" "$floor_allowed" "$floor_active" "$auth_error_only_cycles" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	printf '%s %s\n' "$final_max" "$floor_active"
	return 0
}

#######################################
# Count runnable backlog candidates across pulse scope
# Heuristic for t1453 utilization loop:
# - open issues passing default-open candidate filter
#   (non-needs-* and non-management labels)
# - open PRs with failing checks or changes requested
# Returns: count via stdout
#######################################
count_runnable_candidates() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local total=0
	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		local issue_count
		issue_count=$(list_dispatchable_issue_candidates "$slug" "$PULSE_RUNNABLE_ISSUE_LIMIT" | wc -l | tr -d ' ') || issue_count=0
		[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

		# GH#21799: drop heavy GraphQL statusCheckRollup; fetch headRefOid
		# instead and resolve PASS/FAIL/PENDING via REST check-suites
		# (separate budget pool, ~15x smaller payload).
		local pr_json pr_rc_err
		pr_rc_err=$(mktemp)
		pr_json=$(pulse_pr_list_get --repo "$slug" --state open --json number,headRefOid --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_rc_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_rc_err_msg
			_pr_rc_err_msg=$(cat "$pr_rc_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_runnable_candidates: gh_pr_list FAILED for ${slug}: ${_pr_rc_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_rc_err"
		if declare -F _pmp_enrich_prs_with_review_decisions >/dev/null 2>&1; then
			pr_json=$(_pmp_enrich_prs_with_review_decisions "$slug" "$pr_json")
		fi

		# Enrich with REST check status, then count "runnable" PRs:
		# CHANGES_REQUESTED OR aggregate check status == FAIL.
		local pr_checks_json=""
		pr_checks_json=$(gh_pr_check_status_rest_batch "$slug" "$pr_json" 2>/dev/null) || pr_checks_json="[]"
		[[ -n "$pr_checks_json" && "$pr_checks_json" != "null" ]] || pr_checks_json="[]"

		local pr_count
		pr_count=$(jq -n --argjson prs "$pr_json" --argjson checks "$pr_checks_json" '
			($checks | map({(.number | tostring): .status}) | add // {}) as $check_map |
			[$prs[] | (.number | tostring) as $n | select(.reviewDecision == "CHANGES_REQUESTED" or ($check_map[$n] // "none") == "FAIL")] | length
		' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		pulse_count_debug_log "count_runnable_candidates repo=${slug} issues=${issue_count} prs=${pr_count} total=$((issue_count + pr_count))"

		total=$((total + issue_count + pr_count))
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Count queued issues that do not have an active worker process
# This is a launch-validation signal: queued labels imply dispatch,
# but no matching worker indicates startup failure or immediate exit.
# Returns: count via stdout
#######################################
count_queued_without_worker() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

	local total=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local queued_json queued_err
		queued_err=$(mktemp)
		queued_json=$(gh_issue_list --repo "$slug" --state open --label "status:queued" --json number,assignees --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$queued_err") || queued_json="[]"
		if [[ -z "$queued_json" || "$queued_json" == "null" ]]; then
			local _queued_err_msg
			_queued_err_msg=$(cat "$queued_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_queued_without_worker: gh_issue_list FAILED for ${slug}: ${_queued_err_msg}" >>"$LOGFILE"
			queued_json="[]"
		fi
		rm -f "$queued_err"

		local queued_count
		queued_count=$(echo "$queued_json" | jq 'length' 2>/dev/null) || queued_count=0
		[[ "$queued_count" =~ ^[0-9]+$ ]] || queued_count=0
		pulse_count_debug_log "count_queued_without_worker repo=${slug} queued=${queued_count}"
		if [[ "$queued_count" -eq 0 ]]; then
			continue
		fi

		while IFS='|' read -r issue_num assigned_to_other; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Cross-runner safety: queued issues assigned to another login are not
			# counted as "without worker" because the worker may be running on that
			# runner's machine and invisible to local process inspection.
			if [[ "$assigned_to_other" == "true" ]]; then
				continue
			fi

			if ! has_worker_for_repo_issue "$issue_num" "$slug"; then
				total=$((total + 1))
				pulse_count_debug_log "count_queued_without_worker repo=${slug} issue=${issue_num} missing_worker=true"
			fi
		done < <(echo "$queued_json" | jq -r --arg self "$self_login" '.[] | .number as $n | ((.assignees | length) > 0 and (([.assignees[].login] | index($self)) == null)) as $assigned_other | "\($n)|\($assigned_other)"' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Emit debug logs for pulse count helpers without polluting stdout.
#
# Debug logs are opt-in via PULSE_DEBUG and always go to stderr so helpers that
# are consumed numerically keep a strict stdout contract.
#
# Arguments:
#   $1 - message to log
# Returns: 0 always
#######################################
pulse_count_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		printf '[pulse-wrapper] DEBUG: %s\n' "$message" >&2
		;;
	esac
	return 0
}

#######################################
# Normalize noisy helper stdout to a numeric count.
#
# Some count helpers may emit diagnostic lines before their final numeric
# result. Accept the last line that is purely an integer; otherwise fail closed
# to 0.
#
# Arguments:
#   $1 - raw helper stdout
# Returns: normalized integer via stdout
#######################################
normalize_count_output() {
	local raw_output="$1"
	local normalized
	normalized=$(printf '%s\n' "$raw_output" | awk '
		/^[[:space:]]*[0-9]+[[:space:]]*$/ {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
			last = $0
		}
		END {
			if (last != "") {
				print last
			}
		}
	')

	if [[ "$normalized" =~ ^[0-9]+$ ]]; then
		echo "$normalized"
		return 0
	fi

	echo "0"
	return 0
}
