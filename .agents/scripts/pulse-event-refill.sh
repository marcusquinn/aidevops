#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-event-refill.sh — Coalesced worker-exit signals and lock-safe Pulse refill.

if [[ -n "${_PULSE_EVENT_REFILL_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_PULSE_EVENT_REFILL_LOADED=1

_pulse_event_refill_source_dir="${BASH_SOURCE[0]%/*}"
_PULSE_EVENT_REFILL_SCRIPT_DIR=$(cd "$_pulse_event_refill_source_dir" 2>/dev/null && pwd) || _PULSE_EVENT_REFILL_SCRIPT_DIR="$_pulse_event_refill_source_dir"
unset _pulse_event_refill_source_dir
# GH#36122: the refill gate requires the shared breaker definitions; source
# them here so a missing module fails loudly instead of dispatching open.
# shellcheck source=./pulse-wrapper-dispatch-gates.sh
source "${_PULSE_EVENT_REFILL_SCRIPT_DIR}/pulse-wrapper-dispatch-gates.sh"

pulse_event_refill_is_enabled() {
	local enabled_value="${AIDEVOPS_PULSE_EVENT_REFILL_ENABLED:-1}"
	case "$enabled_value" in
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	esac
	return 1
}

pulse_event_refill_log() {
	local message="$1"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local timestamp=""
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	mkdir -p "${logfile%/*}" 2>/dev/null || true
	printf '[%s] [pulse-event-refill] %s\n' "$timestamp" "$message" >>"$logfile" 2>/dev/null || true
	return 0
}

pulse_event_refill_counter() {
	local counter_name="$1"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

pulse_event_refill_write_trigger() {
	local issue_number="$1"
	local worker_pid="$2"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${AIDEVOPS_PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}}"
	local trigger_dir="${trigger_file%/*}"
	local temporary_file=""
	local timestamp=""

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	mkdir -p "$trigger_dir" 2>/dev/null || return 1
	temporary_file="${trigger_file}.tmp.$$.${RANDOM:-0}"
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	if ! printf 'issue=%s worker_pid=%s ts=%s\n' "$issue_number" "$worker_pid" "$timestamp" >"$temporary_file"; then
		rm -f "$temporary_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$temporary_file" "$trigger_file" 2>/dev/null; then
		rm -f "$temporary_file" 2>/dev/null || true
		return 1
	fi
	pulse_event_refill_log "action=trigger_recorded issue=${issue_number} worker_pid=${worker_pid}"
	return 0
}

_pulse_event_refill_acquire_wake_lock() {
	local wake_lock="$1"
	local self_pid="${BASHPID:-$$}"
	local owner_token="${self_pid}:${RANDOM}"
	local recorded_owner=""
	local owner_pid=""
	local grace_attempt=0

	[[ "$wake_lock" == *.wake.lock ]] || return 1
	if ! mkdir "$wake_lock" 2>/dev/null; then
		while ((grace_attempt < 5)); do
			if [[ -f "${wake_lock}/pid" ]]; then
				read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
			fi
			[[ -n "$recorded_owner" ]] && break
			sleep 0.1 2>/dev/null || sleep 1
			grace_attempt=$((grace_attempt + 1))
		done
		owner_pid="${recorded_owner%%:*}"
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
			return 1
		fi
		rm -rf "$wake_lock" 2>/dev/null || true
		mkdir "$wake_lock" 2>/dev/null || return 1
	fi
	printf '%s\n' "$owner_token" >"${wake_lock}/pid" 2>/dev/null || {
		rm -rf "$wake_lock" 2>/dev/null || true
		return 1
	}
	read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
	[[ "$recorded_owner" == "$owner_token" ]] || return 1
	_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN="$owner_token"
	return 0
}

_pulse_event_refill_release_wake_lock() {
	local wake_lock="$1"
	local recorded_owner=""
	local owner_token="${_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN:-}"
	[[ "$wake_lock" == *.wake.lock ]] || return 1
	if [[ -f "${wake_lock}/pid" ]]; then
		read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
	fi
	if [[ -n "$owner_token" && "$recorded_owner" == "$owner_token" ]]; then
		rm -rf "$wake_lock" 2>/dev/null || true
	fi
	_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN=""
	return 0
}

_pulse_event_refill_wrapper_supports_mode() {
	local wrapper="$1"
	[[ -r "$wrapper" ]] || return 1
	grep -q -- '--refill-only' "$wrapper" 2>/dev/null
	return $?
}

_pulse_event_refill_wrapper_is_active() {
	local wrapper="$1"
	local active_agents_link="${AIDEVOPS_ACTIVE_AGENTS_LINK:-${HOME}/.aidevops/agents}"
	local wrapper_agents_root=""
	local active_agents_root=""

	wrapper_agents_root=$(cd "${wrapper%/*}/.." 2>/dev/null && pwd -P) || return 0
	# Only bundle-backed wrappers can become stale across activation. Leave
	# standalone/test wrappers alone so mixed-version compatibility remains safe.
	[[ -r "${wrapper_agents_root}/.bundle-manifest" ]] || return 0
	active_agents_root=$(cd "$active_agents_link" 2>/dev/null && pwd -P) || return 0
	[[ "$wrapper_agents_root" == "$active_agents_root" ]]
	return $?
}

pulse_event_refill_signal() {
	local issue_number="$1"
	local worker_pid="$2"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${AIDEVOPS_PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}}"
	local wake_lock="${trigger_file}.wake.lock"
	local wrapper="${PULSE_EVENT_REFILL_WRAPPER:-${AIDEVOPS_PULSE_EVENT_REFILL_WRAPPER:-${_PULSE_EVENT_REFILL_SCRIPT_DIR}/pulse-wrapper.sh}}"
	local wake_pass=0
	local max_wake_passes="${PULSE_EVENT_REFILL_WAKE_PASSES:-2}"

	if ! pulse_event_refill_write_trigger "$issue_number" "$worker_pid"; then
		pulse_event_refill_log "action=trigger_failed issue=${issue_number} worker_pid=${worker_pid}"
		return 0
	fi
	if ! pulse_event_refill_is_enabled; then
		pulse_event_refill_log "action=disabled trigger=retained issue=${issue_number}"
		return 0
	fi
	if ! _pulse_event_refill_wrapper_supports_mode "$wrapper"; then
		pulse_event_refill_log "action=wrapper_unsupported trigger=retained wrapper=${wrapper}"
		return 0
	fi
	if ! _pulse_event_refill_wrapper_is_active "$wrapper"; then
		pulse_event_refill_log "action=wake_skipped reason=inactive-bundle trigger=retained wrapper=${wrapper}"
		return 0
	fi
	if ! _pulse_event_refill_acquire_wake_lock "$wake_lock"; then
		pulse_event_refill_log "action=wake_coalesced issue=${issue_number} worker_pid=${worker_pid}"
		return 0
	fi
	[[ "$max_wake_passes" =~ ^[0-9]+$ ]] || max_wake_passes=2
	((max_wake_passes > 0)) || max_wake_passes=1
	while [[ -f "$trigger_file" && "$wake_pass" -lt "$max_wake_passes" ]]; do
		wake_pass=$((wake_pass + 1))
		pulse_event_refill_log "action=wake_started issue=${issue_number} worker_pid=${worker_pid} pass=${wake_pass}"
		AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=1 \
			PULSE_EVENT_REFILL_TRIGGER_FILE="$trigger_file" \
			PULSE_EVENT_REFILL_WRAPPER="$wrapper" \
			bash "$wrapper" --refill-only --refill-source=worker-exit || true
		if [[ -f "$trigger_file" && "$wake_pass" -lt "$max_wake_passes" ]]; then
			sleep 1
		fi
	done
	_pulse_event_refill_release_wake_lock "$wake_lock"
	return 0
}

_pulse_setup_refill_only_mode() {
	local refill_argument=""
	local refill_source="${PULSE_REFILL_SOURCE:-event}"
	for refill_argument in "$@"; do
		case "$refill_argument" in
		--refill-only) export PULSE_REFILL_ONLY=1 ;;
		--refill-source=*) refill_source="${refill_argument#*=}" ;;
		esac
	done
	case "$refill_source" in
	*[!A-Za-z0-9:_-]*) refill_source="unknown" ;;
	esac
	export PULSE_REFILL_SOURCE="$refill_source"
	return 0
}

_pulse_event_refill_cleanup() {
	if declare -F release_instance_lock >/dev/null 2>&1; then
		release_instance_lock || true
	fi
	if declare -F aidevops_runtime_bundle_lease_release >/dev/null 2>&1; then
		aidevops_runtime_bundle_lease_release || true
	fi
	return 0
}

_pulse_event_refill_wait_for_instance_lock() {
	local wait_seconds="${PULSE_EVENT_REFILL_WAIT_SECONDS:-20}"
	local poll_seconds="${PULSE_EVENT_REFILL_POLL_SECONDS:-1}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local started_epoch=""
	local now_epoch=""

	[[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=20
	[[ "$poll_seconds" =~ ^[0-9]+$ ]] || poll_seconds=1
	((poll_seconds > 0)) || poll_seconds=1
	started_epoch=$(date +%s)
	while [[ -f "$trigger_file" ]]; do
		if acquire_instance_lock; then
			return 0
		fi
		now_epoch=$(date +%s)
		if ((now_epoch - started_epoch >= wait_seconds)); then
			return 1
		fi
		sleep "$poll_seconds"
	done
	return 1
}

pulse_event_refill_recover_processing() {
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local processing_file=""
	for processing_file in "${trigger_file}.processing."*; do
		[[ -f "$processing_file" ]] || continue
		if [[ -f "$trigger_file" ]]; then
			rm -f "$processing_file" 2>/dev/null || true
		else
			mv -f "$processing_file" "$trigger_file" 2>/dev/null || true
		fi
	done
	return 0
}

pulse_event_refill_github_available() {
	command -v gh >/dev/null 2>&1 || return 1
	gh api user --jq '.login' >/dev/null 2>&1
	return $?
}

_pulse_event_refill_dispatch_gate() {
	if [[ -f "${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}" ]]; then
		pulse_event_refill_log "action=blocked reason=stop_flag trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_stop"
		return 1
	fi
	if ! pulse_event_refill_github_available; then
		pulse_event_refill_log "action=blocked reason=github_unavailable trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_github"
		return 1
	fi
	if declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		local graphql_budget_rc=0
		is_graphql_budget_sufficient || graphql_budget_rc=$?
		if [[ "$graphql_budget_rc" -eq 1 ]]; then
			pulse_event_refill_log "action=blocked reason=graphql_circuit trigger=retained"
			pulse_event_refill_counter "pulse_event_refill_blocked_graphql"
			return 1
		fi
	fi
	# GH#36122: shared runner-local breaker gate (no_work, permission-block,
	# runner-health); apply_dispatch_max re-checks it for every other caller.
	local breakers_rc=0
	pulse_dispatch_breakers_allow "event_refill" || breakers_rc=$?
	if [[ "$breakers_rc" -eq 0 ]]; then
		return 0
	fi
	case "$PULSE_DISPATCH_BREAKER_TRIPPED" in
	no_work)
		pulse_event_refill_log "action=blocked reason=no_work_circuit trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_no_work"
		;;
	permission_block)
		pulse_event_refill_log "action=blocked reason=permission_block_circuit trigger=retained"
		;;
	*)
		pulse_event_refill_log "action=blocked reason=runner_health trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_runner_health"
		;;
	esac
	return 1
}

_pulse_event_refill_restore_processing() {
	local processing_file="$1"
	local trigger_file="$2"
	if [[ -f "$trigger_file" ]]; then
		rm -f "$processing_file" 2>/dev/null || true
	else
		mv -f "$processing_file" "$trigger_file" 2>/dev/null || true
	fi
	return 0
}

# Outcome of the latest pulse_event_refill_drain call in this process:
# completed, failed, budget_exhausted, or empty when no dispatch pass ran.
_PULSE_EVENT_REFILL_LAST_OUTCOME=""
# Epoch after which a refill-only run admits no new dispatch pass (GH#35349).
_PULSE_EVENT_REFILL_ADMIT_DEADLINE=""

#######################################
# Bound how long a refill-only run may hold the Pulse instance lock (GH#35349).
#
# Dispatch admission reads the existing cycle-budget variables through
# _pulse_cycle_remaining_seconds (start + min(stale, lock_max) - now - reserve).
# A round needs floor + enumeration seconds before enumeration, and every
# stage timeout is clamped to the same remaining budget. A budget of
# max + enumeration + floor + reserve therefore admits rounds only during the
# first PULSE_EVENT_REFILL_MAX_SECONDS. Candidates start only while a full
# floor remains and their stages are clamped to the remaining budget, so the
# lock is released within that window plus one enumeration, one candidate
# stage timeout and the finalise reserve (about 21.5 minutes by default).
# Never raises the budget above the full-cycle ceiling.
#
# Env: PULSE_EVENT_REFILL_MAX_SECONDS (default 300) sets the admission window;
# PULSE_EVENT_REFILL_FAILED_COOLDOWN_SECONDS (default 600, 0 disables) sets the
# failed-drain cooldown read by _pulse_event_refill_cooldown_remaining.
#######################################
_pulse_event_refill_apply_budget() {
	local max_seconds="${PULSE_EVENT_REFILL_MAX_SECONDS:-300}"
	local floor_seconds="${DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR:-600}"
	local reserve_seconds="${AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S:-90}"
	local lock_max="${PULSE_LOCK_MAX_AGE_S:-1800}"
	local ceiling="${PULSE_STALE_THRESHOLD:-3600}"
	local enumeration_seconds=300
	local budget_seconds=0
	local now_epoch=""
	[[ "$max_seconds" =~ ^[1-9][0-9]*$ ]] || max_seconds=300
	[[ "$floor_seconds" =~ ^[1-9][0-9]*$ ]] || floor_seconds=600
	[[ "$reserve_seconds" =~ ^[0-9]+$ ]] || reserve_seconds=90
	[[ "$lock_max" =~ ^[1-9][0-9]*$ ]] || lock_max=1800
	[[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || ceiling=3600
	((lock_max >= ceiling)) || ceiling="$lock_max"
	if declare -F _dispatch_enumeration_expected_seconds >/dev/null 2>&1; then
		enumeration_seconds=$(_dispatch_enumeration_expected_seconds 2>/dev/null) || enumeration_seconds=300
	fi
	[[ "$enumeration_seconds" =~ ^[0-9]+$ ]] || enumeration_seconds=300
	now_epoch=$(date +%s 2>/dev/null) || return 0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 0
	budget_seconds=$((max_seconds + enumeration_seconds + floor_seconds + reserve_seconds))
	((budget_seconds <= ceiling)) || budget_seconds="$ceiling"
	PULSE_START_EPOCH="$now_epoch"
	PULSE_STALE_THRESHOLD="$budget_seconds"
	_PULSE_EVENT_REFILL_ADMIT_DEADLINE=$((now_epoch + max_seconds))
	pulse_event_refill_log "action=budget_set max_seconds=${max_seconds} cycle_budget=${budget_seconds}s enumeration=${enumeration_seconds}s floor=${floor_seconds}s"
	return 0
}

# Return 0 once a refill-only run's admission window has elapsed.
_pulse_event_refill_budget_spent() {
	local deadline="${_PULSE_EVENT_REFILL_ADMIT_DEADLINE:-}"
	local now_epoch=""
	[[ "$deadline" =~ ^[0-9]+$ ]] || return 1
	now_epoch=$(date +%s 2>/dev/null) || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	((now_epoch >= deadline))
	return $?
}

_pulse_event_refill_cooldown_file() {
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	printf '%s\n' "${trigger_file}.failed-cooldown"
	return 0
}

#######################################
# Record a failed-drain cooldown beside the trigger (GH#35349). A refill-only
# drain that failed or spent its budget leaves the trigger for the next full
# cycle's cycle-final drain; the cooldown stops the next worker-exit wake from
# taking the instance lock straight back and starving that cycle.
#######################################
_pulse_event_refill_record_cooldown() {
	local reason="$1"
	local cooldown_file=""
	local temporary_file=""
	local now_epoch=""
	cooldown_file=$(_pulse_event_refill_cooldown_file)
	now_epoch=$(date +%s 2>/dev/null) || return 0
	mkdir -p "${cooldown_file%/*}" 2>/dev/null || return 0
	temporary_file="${cooldown_file}.tmp.$$"
	if ! printf '%s %s\n' "$now_epoch" "$reason" >"$temporary_file" 2>/dev/null; then
		rm -f "$temporary_file" 2>/dev/null || true
		return 0
	fi
	mv -f "$temporary_file" "$cooldown_file" 2>/dev/null || rm -f "$temporary_file" 2>/dev/null || true
	return 0
}

_pulse_event_refill_clear_cooldown() {
	local cooldown_file=""
	cooldown_file=$(_pulse_event_refill_cooldown_file)
	rm -f "$cooldown_file" 2>/dev/null || true
	return 0
}

#######################################
# Print the remaining failed-drain cooldown seconds and return 0 while it is
# active. Invalid, expired or future-dated markers are treated as inactive.
#######################################
_pulse_event_refill_cooldown_remaining() {
	local cooldown_seconds="${PULSE_EVENT_REFILL_FAILED_COOLDOWN_SECONDS:-600}"
	local cooldown_file=""
	local recorded_epoch=""
	local recorded_reason=""
	local now_epoch=""
	local remaining=0
	[[ "$cooldown_seconds" =~ ^[0-9]+$ ]] || cooldown_seconds=600
	((cooldown_seconds > 0)) || return 1
	cooldown_file=$(_pulse_event_refill_cooldown_file)
	[[ -f "$cooldown_file" ]] || return 1
	read -r recorded_epoch recorded_reason <"$cooldown_file" 2>/dev/null || true
	: "$recorded_reason"
	[[ "$recorded_epoch" =~ ^[0-9]+$ ]] || return 1
	now_epoch=$(date +%s 2>/dev/null) || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	remaining=$((recorded_epoch + cooldown_seconds - now_epoch))
	((remaining > 0 && remaining <= cooldown_seconds)) || return 1
	printf '%s\n' "$remaining"
	return 0
}

#######################################
# Evaluate due routines before waiting when another live process holds the
# Pulse instance lock (GH#35349). The wrapper owns the routines-only pass;
# standalone sourcing without it is a no-op.
#######################################
_pulse_event_refill_run_routines_if_busy() {
	local source_name="$1"
	local lock_pid=""
	declare -F _pulse_run_routines_while_busy >/dev/null 2>&1 || return 0
	[[ -n "${LOCKDIR:-}" && -f "${LOCKDIR}/pid" ]] || return 0
	read -r lock_pid <"${LOCKDIR}/pid" 2>/dev/null || lock_pid=""
	[[ "$lock_pid" =~ ^[0-9]+$ && "$lock_pid" != "$$" ]] || return 0
	kill -0 "$lock_pid" 2>/dev/null || return 0
	_pulse_run_routines_while_busy "refill-only:${source_name}"
	return 0
}

pulse_event_refill_drain() {
	local source_name="${1:-cycle}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local processing_file=""
	local pass=0
	local max_passes="${PULSE_EVENT_REFILL_MAX_PASSES:-2}"
	case "$source_name" in
	*[!A-Za-z0-9:_-]*) source_name="unknown" ;;
	esac
	if ! pulse_event_refill_is_enabled; then
		[[ -f "$trigger_file" ]] && pulse_event_refill_log "action=disabled trigger=retained source=${source_name}"
		return 0
	fi
	[[ "$max_passes" =~ ^[0-9]+$ ]] || max_passes=2
	((max_passes > 0)) || max_passes=1
	pulse_event_refill_recover_processing
	# The normal cycle runs preflight and its own dispatch rounds. Running the
	# full, potentially multi-candidate apply_dispatch_max here can consume the
	# entire cycle before preflight. Leave the signal for cycle-final (or an
	# independent worker-exit refill); never claim that dispatch ran at entry.
	if [[ "$source_name" == "cycle-entry" ]]; then
		if [[ -f "$trigger_file" ]]; then
			pulse_event_refill_log "action=drain_completed source=cycle-entry pass=0 dispatch=deferred trigger=retained"
		fi
		return 0
	fi
	if ! declare -F apply_dispatch_max >/dev/null 2>&1; then
		pulse_event_refill_log "action=blocked reason=dispatch_unavailable trigger=retained source=${source_name}"
		return 0
	fi
	while [[ -f "$trigger_file" && "$pass" -lt "$max_passes" ]]; do
		# GH#35349: a spent refill-only budget admits no further pass; the
		# retained trigger belongs to the next full cycle's cycle-final drain.
		if _pulse_event_refill_budget_spent; then
			pulse_event_refill_log "action=drain_budget_exhausted source=${source_name} pass=${pass} trigger=retained"
			pulse_event_refill_counter "pulse_event_refill_budget_exhausted"
			_PULSE_EVENT_REFILL_LAST_OUTCOME="budget_exhausted"
			return 0
		fi
		if ! _pulse_event_refill_dispatch_gate; then
			return 0
		fi
		processing_file="${trigger_file}.processing.$$"
		if ! mv -f "$trigger_file" "$processing_file" 2>/dev/null; then
			return 0
		fi
		if ! _pulse_event_refill_dispatch_gate; then
			_pulse_event_refill_restore_processing "$processing_file" "$trigger_file"
			return 0
		fi
		pass=$((pass + 1))
		pulse_event_refill_log "action=drain_started source=${source_name} pass=${pass}"
		if ! apply_dispatch_max; then
			_pulse_event_refill_restore_processing "$processing_file" "$trigger_file"
			# apply_dispatch_max fails only on a cycle-budget deferral; after the
			# refill admission window that is the expected budget stop.
			if _pulse_event_refill_budget_spent; then
				pulse_event_refill_log "action=drain_budget_exhausted source=${source_name} pass=${pass} trigger=retained"
				pulse_event_refill_counter "pulse_event_refill_budget_exhausted"
				_PULSE_EVENT_REFILL_LAST_OUTCOME="budget_exhausted"
			else
				pulse_event_refill_log "action=drain_failed source=${source_name} pass=${pass} trigger=retained"
				pulse_event_refill_counter "pulse_event_refill_failed"
				_PULSE_EVENT_REFILL_LAST_OUTCOME="failed"
			fi
			return 0
		fi
		rm -f "$processing_file" 2>/dev/null || true
		pulse_event_refill_log "action=drain_completed source=${source_name} pass=${pass}"
		pulse_event_refill_counter "pulse_event_refill_completed"
		_PULSE_EVENT_REFILL_LAST_OUTCOME="completed"
		_pulse_event_refill_clear_cooldown
	done
	if [[ -f "$trigger_file" ]]; then
		pulse_event_refill_log "action=pass_limit trigger=retained source=${source_name} passes=${pass}"
	fi
	return 0
}

_pulse_run_refill_only() {
	local source_name="${PULSE_REFILL_SOURCE:-event}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	[[ -f "$trigger_file" ]] || return 0
	if ! pulse_event_refill_is_enabled; then
		pulse_event_refill_log "action=disabled trigger=retained source=${source_name}"
		return 0
	fi
	# GH#35349: after a failed or budget-exhausted drain, leave the lock to the
	# next full cycle, whose cycle-final drain consumes the retained trigger.
	local cooldown_remaining=""
	if cooldown_remaining=$(_pulse_event_refill_cooldown_remaining); then
		pulse_event_refill_log "action=deferred reason=failed_drain_cooldown trigger=retained source=${source_name} remaining=${cooldown_remaining}s"
		pulse_event_refill_counter "pulse_event_refill_deferred_cooldown"
		return 0
	fi
	_pulse_event_refill_run_routines_if_busy "$source_name"
	if ! _pulse_event_refill_wait_for_instance_lock; then
		[[ -f "$trigger_file" ]] && pulse_event_refill_log "action=lock_busy trigger=retained source=${source_name}"
		pulse_event_refill_counter "pulse_event_refill_lock_busy"
		return 0
	fi
	trap '_pulse_event_refill_cleanup' EXIT
	if ! check_session_gate; then
		pulse_event_refill_log "action=blocked reason=session_gate trigger=retained source=${source_name}"
		release_instance_lock
		return 0
	fi
	if [[ "${AIDEVOPS_PULSE_REST_FIRST_READS:-1}" == "1" ]]; then
		export AIDEVOPS_GH_REST_FIRST_READS=1
	fi
	if declare -F _pulse_set_graphql_budget_priority >/dev/null 2>&1; then
		_pulse_set_graphql_budget_priority
	fi
	if declare -F _dispatch_invalidate_candidate_snapshot >/dev/null 2>&1; then
		_dispatch_invalidate_candidate_snapshot "event_refill" || true
	fi
	_pulse_event_refill_apply_budget
	_PULSE_EVENT_REFILL_LAST_OUTCOME=""
	pulse_event_refill_drain "$source_name"
	case "$_PULSE_EVENT_REFILL_LAST_OUTCOME" in
	failed | budget_exhausted)
		_pulse_event_refill_record_cooldown "$_PULSE_EVENT_REFILL_LAST_OUTCOME"
		;;
	esac
	release_instance_lock
	return 0
}

_pulse_event_refill_main() {
	local command_name="${1:-}"
	case "$command_name" in
	signal)
		shift
		local issue_number="${1:-}"
		local worker_pid="${2:-}"
		pulse_event_refill_signal "$issue_number" "$worker_pid"
		return $?
		;;
	*)
		printf 'Usage: %s signal <issue-number> <worker-pid>\n' "$0" >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	_pulse_event_refill_main "$@"
	exit $?
fi
