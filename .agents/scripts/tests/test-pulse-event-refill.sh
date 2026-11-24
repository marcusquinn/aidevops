#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for coalesced, lock-safe Pulse event refill (GH#29448).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
APPLY_CALLS=0
APPLY_SLOT_TARGET=0
APPLY_RC=0
WRITE_TRIGGER_DURING_APPLY=0
GITHUB_AVAILABLE=1
GRAPHQL_AVAILABLE=1
NO_WORK_ACCEPTABLE=1

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local test_name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$test_name"
	return 0
}

fail() {
	local test_name="$1"
	local message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n  %s\n' "$test_name" "$message"
	return 0
}

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected=${expected}, actual=${actual}"
	fi
	return 0
}

assert_file_exists() {
	local test_name="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected file to exist: ${file}"
	fi
	return 0
}

assert_file_absent() {
	local test_name="$1"
	local file="$2"
	if [[ ! -e "$file" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected file to be absent: ${file}"
	fi
	return 0
}

reset_state() {
	rm -rf "${TEST_ROOT:?}/home"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
	PULSE_EVENT_REFILL_TRIGGER_FILE="${HOME}/.aidevops/cache/pulse-event-refill.trigger"
	PULSE_EVENT_REFILL_MAX_PASSES=2
	PULSE_EVENT_REFILL_WAKE_PASSES=2
	PULSE_EVENT_REFILL_WAIT_SECONDS=0
	PULSE_EVENT_REFILL_POLL_SECONDS=1
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=1
	APPLY_CALLS=0
	APPLY_SLOT_TARGET=0
	APPLY_RC=0
	WRITE_TRIGGER_DURING_APPLY=0
	GITHUB_AVAILABLE=1
	GRAPHQL_AVAILABLE=1
	NO_WORK_ACCEPTABLE=1
	DISPATCH_LOCK_STILL_OWNED=1
	return 0
}

# shellcheck source=../pulse-event-refill.sh
source "${SCRIPTS_DIR}/pulse-event-refill.sh"

pulse_event_refill_github_available() {
	[[ "$GITHUB_AVAILABLE" -eq 1 ]]
	return $?
}

is_graphql_budget_sufficient() {
	[[ "$GRAPHQL_AVAILABLE" -eq 1 ]]
	return $?
}

is_no_work_rate_acceptable() {
	[[ "$NO_WORK_ACCEPTABLE" -eq 1 ]]
	return $?
}

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"${HOME}/.aidevops/logs/counters.log"
	return 0
}

pulse_dispatch_lock_still_owned() {
	if [[ "$DISPATCH_LOCK_STILL_OWNED" -eq 1 ]]; then
		return 0
	fi
	return 1
}

apply_dispatch_max() {
	APPLY_CALLS=$((APPLY_CALLS + 1))
	printf 'call=%s slots=%s epoch=%s\n' "$APPLY_CALLS" "$APPLY_SLOT_TARGET" "${PULSE_START_EPOCH:-unset}" >>"${HOME}/.aidevops/logs/apply.log"
	if [[ "$WRITE_TRIGGER_DURING_APPLY" -eq 1 && "$APPLY_CALLS" -eq 1 ]]; then
		pulse_event_refill_write_trigger 202 2202
	fi
	return "$APPLY_RC"
}

test_mode_parser() {
	reset_state
	unset PULSE_REFILL_ONLY PULSE_REFILL_SOURCE 2>/dev/null || true
	_pulse_setup_refill_only_mode --unrelated --refill-only --refill-source=worker-exit
	assert_eq "refill-only parser enables lightweight mode" "1" "${PULSE_REFILL_ONLY:-0}"
	assert_eq "refill-only parser records a safe source" "worker-exit" "${PULSE_REFILL_SOURCE:-}"
	return 0
}

test_coalesced_trigger_fills_full_target() {
	reset_state
	APPLY_SLOT_TARGET=7
	pulse_event_refill_write_trigger 101 1101
	pulse_event_refill_write_trigger 102 1102
	pulse_event_refill_drain "test"
	assert_eq "coalesced exits invoke one full-capacity dispatch pass" "1" "$APPLY_CALLS"
	assert_file_absent "successful refill consumes the presence trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'slots=7' "${HOME}/.aidevops/logs/apply.log"; then
		pass "event refill delegates the complete slot target to apply_dispatch_max"
	else
		fail "event refill delegates the complete slot target to apply_dispatch_max" "slot target was not observed"
	fi
	return 0
}

test_event_during_drain_gets_second_pass() {
	reset_state
	WRITE_TRIGGER_DURING_APPLY=1
	pulse_event_refill_write_trigger 201 2201
	pulse_event_refill_drain "test-race"
	assert_eq "an exit arriving during refill gets a bounded second pass" "2" "$APPLY_CALLS"
	assert_file_absent "second-pass refill leaves no consumed trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_stop_and_circuits_retain_trigger() {
	reset_state
	pulse_event_refill_write_trigger 301 3301
	: >"$STOP_FLAG"
	pulse_event_refill_drain "test-stop"
	assert_eq "stop flag prevents event dispatch" "0" "$APPLY_CALLS"
	assert_file_exists "stop flag retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	GITHUB_AVAILABLE=0
	pulse_event_refill_write_trigger 302 3302
	pulse_event_refill_drain "test-github"
	assert_file_exists "GitHub outage retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	GRAPHQL_AVAILABLE=0
	pulse_event_refill_write_trigger 303 3303
	pulse_event_refill_drain "test-graphql"
	assert_file_exists "GraphQL circuit breaker retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	NO_WORK_ACCEPTABLE=0
	pulse_event_refill_write_trigger 304 3304
	pulse_event_refill_drain "test-no-work"
	assert_file_exists "no-work circuit breaker retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_disabled_and_missing_dispatch_retain_trigger() {
	reset_state
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0
	pulse_event_refill_write_trigger 401 4401
	pulse_event_refill_drain "test-disabled"
	assert_eq "disabled event refill does not dispatch" "0" "$APPLY_CALLS"
	assert_file_exists "disabled event refill retains its trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	pulse_event_refill_write_trigger 402 4402
	(
		unset -f apply_dispatch_max
		pulse_event_refill_drain "test-missing-dispatch"
	)
	assert_file_exists "missing dispatch function retains its trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_processing_recovery_and_busy_lock() {
	reset_state
	local processing_file="${PULSE_EVENT_REFILL_TRIGGER_FILE}.processing.99999"
	printf 'stale\n' >"$processing_file"
	pulse_event_refill_recover_processing
	assert_file_exists "stale processing state is restored to the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "stale processing file is consumed during recovery" "$processing_file"

	(
		acquire_instance_lock() {
			return 1
		}
		_pulse_run_refill_only
	)
	assert_file_exists "busy instance lock retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_wrapper_refill_only_cli_short_circuit() {
	reset_state
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0
	pulse_event_refill_write_trigger 450 4450
	local cli_log="${TEST_ROOT}/refill-cli.log"
	local cli_rc=0
	HOME="$HOME" \
		AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0 \
		AIDEVOPS_PULSE_RUNTIME_PIN_FILE="${TEST_ROOT}/missing-runtime-pin.conf" \
		PULSE_EVENT_REFILL_TRIGGER_FILE="$PULSE_EVENT_REFILL_TRIGGER_FILE" \
		PULSE_JITTER_MAX=30 \
		PULSE_MODEL="test/model" \
		bash "${SCRIPTS_DIR}/pulse-wrapper.sh" --refill-only --refill-source=integration \
		>"$cli_log" 2>&1 || cli_rc=$?
	assert_eq "wrapper accepts refill-only without entering the full cycle" "0" "$cli_rc"
	assert_file_exists "disabled refill-only CLI retains the pending trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "refill-only disabled path does not acquire the Pulse lock" "${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	return 0
}

test_signal_wake_coalesces_parallel_exits() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/fake-pulse-wrapper.sh"
	local wake_log="${TEST_ROOT}/wake.log"
	cat >"$fake_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
sleep 1
rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
	chmod +x "$fake_wrapper"
	export PULSE_EVENT_TEST_WAKE_LOG="$wake_log"
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	(pulse_event_refill_signal 501 5501) &
	local first_signal_pid=$!
	sleep 0.2
	(pulse_event_refill_signal 502 5502) &
	local second_signal_pid=$!
	wait "$first_signal_pid"
	wait "$second_signal_pid"
	local wake_count=0
	wake_count=$(wc -l <"$wake_log" 2>/dev/null | tr -d ' ') || wake_count=0
	assert_eq "parallel worker exits coalesce to one wrapper wake" "1" "$wake_count"
	assert_file_absent "coalesced wake consumes the shared trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

# Fake wrapper: runs 1..N re-record a fresh trigger; later runs consume it.
# PULSE_EVENT_TEST_FRESH_RUNS=0 leaves the original trigger untouched.
write_fresh_trigger_wrapper() {
	local fake_wrapper="$1"
	cat >"$fake_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
runs=$(wc -l <"$PULSE_EVENT_TEST_WAKE_LOG" | tr -d ' ')
if [[ "$PULSE_EVENT_TEST_FRESH_RUNS" -eq 0 ]]; then
	exit 0
fi
if [[ "$runs" -le "$PULSE_EVENT_TEST_FRESH_RUNS" ]]; then
	printf 'issue=9 worker_pid=%s ts=%s\n' "$runs" "$runs" >"$PULSE_EVENT_REFILL_TRIGGER_FILE"
else
	rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
fi
WRAPPER
	chmod +x "$fake_wrapper"
	return 0
}

test_signal_wake_continues_on_fresh_trigger() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/fresh-wrapper.sh"
	export PULSE_EVENT_TEST_WAKE_LOG="${TEST_ROOT}/fresh-wake.log"
	rm -f "$PULSE_EVENT_TEST_WAKE_LOG"
	write_fresh_trigger_wrapper "$fake_wrapper"
	export PULSE_EVENT_TEST_FRESH_RUNS=2
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	pulse_event_refill_signal 601 6601
	local wake_count=0
	wake_count=$(wc -l <"$PULSE_EVENT_TEST_WAKE_LOG" | tr -d ' ')
	assert_eq "fresh trigger keeps the waker running" "3" "$wake_count"
	assert_file_absent "continued waker leaves no trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'action=wake_continued pass=2 reason=fresh_trigger' "$LOGFILE"; then
		pass "continuation is logged"
	else
		fail "continuation is logged" "wake_continued was not logged"
	fi
	return 0
}

test_signal_wake_stops_on_stale_trigger() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/stale-wrapper.sh"
	export PULSE_EVENT_TEST_WAKE_LOG="${TEST_ROOT}/unchanged-trigger-wake.log"
	rm -f "$PULSE_EVENT_TEST_WAKE_LOG"
	write_fresh_trigger_wrapper "$fake_wrapper"
	export PULSE_EVENT_TEST_FRESH_RUNS=0
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	pulse_event_refill_signal 602 6602
	local wake_count=0
	wake_count=$(wc -l <"$PULSE_EVENT_TEST_WAKE_LOG" | tr -d ' ')
	assert_eq "stale trigger stops after max wake passes" "1" "$wake_count"
	assert_file_exists "stale trigger is retained" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_signal_wake_continuations_disabled() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/nocont-wrapper.sh"
	export PULSE_EVENT_TEST_WAKE_LOG="${TEST_ROOT}/nocont-wake.log"
	rm -f "$PULSE_EVENT_TEST_WAKE_LOG"
	write_fresh_trigger_wrapper "$fake_wrapper"
	export PULSE_EVENT_TEST_FRESH_RUNS=2
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	PULSE_EVENT_REFILL_WAKE_MAX_CONTINUATIONS=0 pulse_event_refill_signal 603 6603
	local wake_count=0
	wake_count=$(wc -l <"$PULSE_EVENT_TEST_WAKE_LOG" | tr -d ' ')
	assert_eq "zero continuations restores bounded passes" "1" "$wake_count"
	assert_file_exists "bounded stop retains the fresh trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_signal_from_inactive_bundle_retains_trigger() {
	reset_state
	local active_agents="${TEST_ROOT}/active-bundle/agents"
	local stale_agents="${TEST_ROOT}/stale-bundle/agents"
	local stale_wrapper="${stale_agents}/scripts/pulse-wrapper.sh"
	local wake_log="${TEST_ROOT}/inactive-bundle-wake.log"
	mkdir -p "${active_agents}/scripts" "${stale_agents}/scripts"
	: >"${active_agents}/.bundle-manifest"
	: >"${stale_agents}/.bundle-manifest"
	cat >"$stale_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
	chmod +x "$stale_wrapper"
	ln -s "$active_agents" "${HOME}/.aidevops/agents"
	export PULSE_EVENT_TEST_WAKE_LOG="$wake_log"
	PULSE_EVENT_REFILL_WRAPPER="$stale_wrapper"
	pulse_event_refill_signal 551 5551
	assert_file_exists "inactive bundle signal retains its trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "inactive bundle signal does not invoke its wrapper" "$wake_log"
	if grep -q 'action=wake_skipped reason=inactive-bundle' "$LOGFILE"; then
		pass "inactive bundle signal records the skipped wake"
	else
		fail "inactive bundle signal records the skipped wake" "inactive-bundle skip was not logged"
	fi
	return 0
}

# GH#38627: stale and active bundles, each with a wake-recording wrapper.
setup_rebase_bundles() {
	local bundle_name=""
	local bundle_agents=""
	for bundle_name in active stale; do
		bundle_agents="${TEST_ROOT}/rebase-${bundle_name}/agents"
		rm -rf "${TEST_ROOT:?}/rebase-${bundle_name}"
		mkdir -p "${bundle_agents}/scripts"
		: >"${bundle_agents}/.bundle-manifest"
		cat >"${bundle_agents}/scripts/pulse-wrapper.sh" <<WRAPPER
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '${bundle_name} %s\n' "\$*" >>"\$PULSE_EVENT_TEST_WAKE_LOG"
rm -f "\$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
		chmod +x "${bundle_agents}/scripts/pulse-wrapper.sh"
	done
	ln -s "${TEST_ROOT}/rebase-active/agents" "${HOME}/.aidevops/agents"
	export PULSE_EVENT_TEST_WAKE_LOG="${TEST_ROOT}/rebase-wake.log"
	rm -f "$PULSE_EVENT_TEST_WAKE_LOG"
	PULSE_EVENT_REFILL_WRAPPER="${TEST_ROOT}/rebase-stale/agents/scripts/pulse-wrapper.sh"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	return 0
}

test_signal_from_inactive_bundle_wakes_active_wrapper() {
	reset_state
	unset AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR
	setup_rebase_bundles
	pulse_event_refill_signal 561 5561
	local wake_lines=""
	wake_lines=$(cat "$PULSE_EVENT_TEST_WAKE_LOG" 2>/dev/null) || wake_lines=""
	assert_eq "inactive bundle exit wakes the active bundle wrapper" "active --refill-only --refill-source=worker-exit" "$wake_lines"
	assert_file_absent "rebased wake consumes the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'action=wake_rebased' "$LOGFILE"; then
		pass "rebased wake is logged"
	else
		fail "rebased wake is logged" "wake_rebased was not logged"
	fi
	return 0
}

test_signal_during_runtime_transition_retains_trigger() {
	reset_state
	setup_rebase_bundles
	export AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR="${TEST_ROOT}/runtime-transition.lock.d"
	mkdir -p "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	printf '%s\n' "$$" >"${AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR}/pid"
	pulse_event_refill_signal 571 5571
	assert_file_exists "runtime transition retains the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "runtime transition invokes no wrapper" "$PULSE_EVENT_TEST_WAKE_LOG"
	if grep -q 'action=wake_skipped reason=runtime-transition' "$LOGFILE"; then
		pass "runtime transition skip is logged"
	else
		fail "runtime transition skip is logged" "runtime-transition skip was not logged"
	fi
	# A dead owner no longer marks a transition.
	printf '99999999\n' >"${AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR}/pid"
	pulse_event_refill_signal 572 5572
	assert_file_absent "dead transition owner does not block the rebased wake" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	rm -rf "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	unset AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR
	return 0
}

test_refill_only_defers_during_runtime_transition() {
	reset_state
	pulse_event_refill_write_trigger 581 5581
	export AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR="${TEST_ROOT}/runtime-transition.lock.d"
	mkdir -p "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	printf '%s\n' "$$" >"${AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR}/pid"
	local lock_calls_file="${TEST_ROOT}/refill-lock-calls.log"
	rm -f "$lock_calls_file"
	(
		acquire_instance_lock() {
			printf 'acquire\n' >>"$lock_calls_file"
			return 0
		}
		_pulse_run_refill_only
	)
	assert_file_absent "transition-deferred refill never takes the instance lock" "$lock_calls_file"
	assert_file_exists "transition-deferred refill retains the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_eq "transition-deferred refill dispatches nothing" "0" "$APPLY_CALLS"
	rm -rf "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	unset AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR
	return 0
}

# t19337 (GH#40162): a split-lock refill-only pass 2 gets a fresh clock; a
# cycle-owned drain keeps its clock; a lost dispatch lock or a runtime
# transition stops pass 2.
test_split_refill_second_pass_gets_fresh_clock() {
	reset_state
	local PULSE_REFILL_ONLY=1 _LOCK_OWNED=false _DISPATCH_LOCK_OWNED=true PULSE_START_EPOCH=1
	local apply_log="${HOME}/.aidevops/logs/apply.log" pass2_epoch=""
	WRITE_TRIGGER_DURING_APPLY=1
	pulse_event_refill_write_trigger 611 6611
	pulse_event_refill_drain "worker-exit"
	assert_eq "split refill-only runs the second pass" "2" "$APPLY_CALLS"
	pass2_epoch=$(sed -n 's/^call=2 .* epoch=\([0-9]*\)$/\1/p' "$apply_log")
	if grep -q '^call=1 .* epoch=1$' "$apply_log" && [[ "$pass2_epoch" =~ ^[0-9]+$ ]] && ((pass2_epoch > 1)) &&
		grep -q 'action=pass_clock_refreshed source=worker-exit' "$LOGFILE"; then
		pass "split refill-only pass 1 keeps its clock and pass 2 dispatches on a fresh one"
	else
		fail "split refill-only pass 1 keeps its clock and pass 2 dispatches on a fresh one" "apply_log=$(tr '\n' ';' <"$apply_log")"
	fi

	reset_state
	PULSE_START_EPOCH=1
	DISPATCH_LOCK_STILL_OWNED=0
	WRITE_TRIGGER_DURING_APPLY=1
	pulse_event_refill_write_trigger 614 6614
	pulse_event_refill_drain "worker-exit"
	assert_eq "reclaimed dispatch lock stops the second pass" "1" "$APPLY_CALLS"
	assert_eq "reclaimed dispatch lock leaves the clock unchanged" "1" "$PULSE_START_EPOCH"
	if grep -q 'action=pass_deferred reason=dispatch_lock_lost trigger=retained' "$LOGFILE" &&
		[[ -f "$PULSE_EVENT_REFILL_TRIGGER_FILE" ]]; then
		pass "reclaimed dispatch lock defers with the trigger retained"
	else
		fail "reclaimed dispatch lock defers with the trigger retained" "dispatch_lock_lost deferral not observed"
	fi

	reset_state
	_LOCK_OWNED=true PULSE_START_EPOCH=1
	WRITE_TRIGGER_DURING_APPLY=1
	pulse_event_refill_write_trigger 612 6612
	pulse_event_refill_drain "cycle-final"
	assert_eq "cycle-owned drain keeps its own clock" "1" "$PULSE_START_EPOCH"

	reset_state
	_LOCK_OWNED=false PULSE_START_EPOCH=1
	WRITE_TRIGGER_DURING_APPLY=1
	export AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR="${TEST_ROOT}/runtime-transition.lock.d"
	mkdir -p "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	printf '%s\n' "$$" >"${AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR}/pid"
	pulse_event_refill_write_trigger 613 6613
	pulse_event_refill_drain "worker-exit"
	assert_eq "runtime transition stops the second pass" "1" "$APPLY_CALLS"
	assert_file_exists "deferred second pass retains the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'action=pass_deferred reason=runtime_transition' "$LOGFILE"; then
		pass "deferred second pass is logged"
	else
		fail "deferred second pass is logged" "pass_deferred was not logged"
	fi
	rm -rf "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR"
	unset AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR
	return 0
}

# t19350 (GH#40224): cycle entry never dispatches in-process. Split-lock mode
# wakes a detached refill with the cycle-entry source; shared-lock mode, or an
# unavailable wake, keeps the deferral. The trigger stays for the refill.
run_cycle_entry_drain() {
	local split_rc="$1"
	local wake_rc="$2"
	local wake_args="$3"
	(
		pulse_dispatch_lock_split_enabled() { return "$split_rc"; }
		pulse_event_refill_wake_underfilled() {
			printf '%s\n' "$*" >>"$wake_args"
			return "$wake_rc"
		}
		pulse_event_refill_drain "cycle-entry"
	)
	return 0
}

test_cycle_entry_wakes_detached_refill_in_split_mode() {
	reset_state
	local wake_args="${TEST_ROOT}/cycle-entry-wake.args"
	local apply_log="${HOME}/.aidevops/logs/apply.log"
	rm -f "$wake_args"
	pulse_event_refill_write_trigger 621 6621
	run_cycle_entry_drain 0 0 "$wake_args"
	assert_eq "split cycle entry wakes one refill with its source" "cycle-entry" "$(cat "$wake_args" 2>/dev/null || true)"
	assert_file_absent "split cycle entry never dispatches in-process" "$apply_log"
	assert_file_exists "woken cycle entry retains the trigger for the refill" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'action=drain_completed source=cycle-entry pass=0 dispatch=woken trigger=retained' "$LOGFILE"; then
		pass "woken cycle entry is logged"
	else
		fail "woken cycle entry is logged" "dispatch=woken was not logged"
	fi

	local case_spec="" split_rc="" wake_rc=""
	for case_spec in "1:0:shared-lock" "0:1:unavailable-wake"; do
		reset_state
		rm -f "$wake_args"
		split_rc="${case_spec%%:*}"
		wake_rc="${case_spec#*:}"
		wake_rc="${wake_rc%%:*}"
		pulse_event_refill_write_trigger 622 6622
		run_cycle_entry_drain "$split_rc" "$wake_rc" "$wake_args"
		assert_file_absent "${case_spec##*:} cycle entry never dispatches in-process" "$apply_log"
		if grep -q 'source=cycle-entry pass=0 dispatch=deferred trigger=retained' "$LOGFILE" &&
			[[ -f "$PULSE_EVENT_REFILL_TRIGGER_FILE" ]]; then
			pass "${case_spec##*:} cycle entry defers with the trigger retained"
		else
			fail "${case_spec##*:} cycle entry defers with the trigger retained" "deferral not observed"
		fi
		[[ "$split_rc" == "0" ]] || assert_file_absent "shared-lock cycle entry starts no wake" "$wake_args"
	done
	return 0
}

test_underfill_wake_forwards_refill_source() {
	reset_state
	local fake_helper="${TEST_ROOT}/fake-refill-helper.sh"
	local fake_wrapper="${TEST_ROOT}/fake-source-wrapper.sh"
	local helper_log="${TEST_ROOT}/fake-refill-helper.log"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$helper_log" >"$fake_helper"
	printf '#!/usr/bin/env bash\n# Supports --refill-only for the mixed-version compatibility probe.\n' >"$fake_wrapper"
	chmod +x "$fake_helper" "$fake_wrapper"
	local source_arg="" expected="" attempt=0
	for source_arg in "cycle-entry" "" "bad source"; do
		rm -f "$helper_log"
		expected="signal 0 $$ ${source_arg:-active-pulse}"
		[[ "$source_arg" != "bad source" ]] || expected="signal 0 $$ active-pulse"
		PULSE_EVENT_REFILL_HELPER="$fake_helper" PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper" \
			pulse_event_refill_wake_underfilled "$source_arg"
		attempt=0
		while [[ ! -s "$helper_log" && "$attempt" -lt 50 ]]; do
			sleep 0.1
			attempt=$((attempt + 1))
		done
		assert_eq "underfill wake forwards source '${source_arg}'" "$expected" "$(cat "$helper_log" 2>/dev/null || true)"
	done
	return 0
}

test_stale_wake_lock_is_reclaimed() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/fake-stale-wake-wrapper.sh"
	local wake_log="${TEST_ROOT}/stale-wake.log"
	local wake_lock="${PULSE_EVENT_REFILL_TRIGGER_FILE}.wake.lock"
	cat >"$fake_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
	chmod +x "$fake_wrapper"
	export PULSE_EVENT_TEST_WAKE_LOG="$wake_log"
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	mkdir "$wake_lock"
	printf '99999999:stale\n' >"${wake_lock}/pid"
	pulse_event_refill_write_trigger 601 6601
	pulse_event_refill_signal 602 6602
	local wake_count=0
	wake_count=$(wc -l <"$wake_log" 2>/dev/null | tr -d ' ') || wake_count=0
	assert_eq "stale wake ownership does not suppress the next refill" "1" "$wake_count"
	assert_file_absent "stale wake lock is reclaimed and released" "$wake_lock"
	assert_file_absent "reclaimed wake consumes the pending trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

main() {
	test_mode_parser
	test_coalesced_trigger_fills_full_target
	test_event_during_drain_gets_second_pass
	test_stop_and_circuits_retain_trigger
	test_disabled_and_missing_dispatch_retain_trigger
	test_processing_recovery_and_busy_lock
	test_wrapper_refill_only_cli_short_circuit
	test_signal_wake_coalesces_parallel_exits
	test_signal_wake_continues_on_fresh_trigger
	test_signal_wake_stops_on_stale_trigger
	test_signal_wake_continuations_disabled
	test_signal_from_inactive_bundle_retains_trigger
	test_signal_from_inactive_bundle_wakes_active_wrapper
	test_signal_during_runtime_transition_retains_trigger
	test_refill_only_defers_during_runtime_transition
	test_split_refill_second_pass_gets_fresh_clock
	test_cycle_entry_wakes_detached_refill_in_split_mode
	test_underfill_wake_forwards_refill_source
	test_stale_wake_lock_is_reclaimed
	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
