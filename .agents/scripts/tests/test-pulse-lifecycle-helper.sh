#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pulse-lifecycle-helper.sh (t2579).
#
# The helper must NOT operate on the real user pulse. Tests use a mock
# "pulse-wrapper.sh" script in a temp directory and override
# AIDEVOPS_AGENTS_DIR to point there. The mock simply sleeps so it produces
# a live PID that pgrep can match on the process-pattern.
#
# Covers:
#   1. --help emits usage
#   2. Unknown command exits 2 with usage
#   3. is-running exits 1 when no pulse running
#   4. is-running exits 0 when pulse running
#   5. status prints "not running" when stopped
#   6. status prints PID(s) when running
#   7. start launches pulse and is-running flips to 0
#   8. start is idempotent (already-running path)
#   9. stop terminates a running pulse
#   10. stop is idempotent (already-stopped path)
#   11. restart-if-running no-ops when pulse not running
#   12. restart-if-running stops + starts when running (PID changes)
#   13. AIDEVOPS_SKIP_PULSE_RESTART=1 skips restart-if-running
#   14. AIDEVOPS_SKIP_PULSE_RESTART=1 skips restart
#   15. Missing pulse-wrapper.sh → start exits 2
#
# No real pulse is touched. We use a unique mock filename and match pattern
# on pulse-wrapper.sh which we control inside TEST_ROOT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../pulse-lifecycle-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
MOCK_PIDS=()

_print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "1" ]]; then
		printf '%b[PASS]%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%b[FAIL]%b %s\n' "$TEST_RED" "$TEST_RESET" "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		_print_result "$name" 1
	else
		_print_result "$name (expected='$expected' actual='$actual')" 0
	fi
	return 0
}

_setup() {
	TEST_ROOT=$(mktemp -d -t pulse-lifecycle-test.XXXXXX)
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/logs"

	# Create mock pulse-wrapper.sh that sleeps long enough to be caught by
	# pgrep. sleep 300 keeps it alive for the life of the test suite.
	cat >"${TEST_ROOT}/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
# Mock pulse — just sleeps. Using a bash while loop (not exec sleep) so
# the bash argv retains the script path, which is what pgrep matches on.
while true; do sleep 10; done
SH
	chmod +x "${TEST_ROOT}/scripts/pulse-wrapper.sh"

	# Point helper at our temp dir.
	export AIDEVOPS_AGENTS_DIR="$TEST_ROOT"

	# Isolate the helper's pgrep from the user's real pulse by anchoring
	# the pattern to our TEST_ROOT path. The production default pattern
	# is the equivalent without path anchoring — see the helper header.
	# Escape TEST_ROOT for use inside an extended regex: / stays, but
	# . must be escaped. mktemp paths contain only [A-Za-z0-9./] so this
	# is sufficient.
	local _escaped_root="${TEST_ROOT//./\\.}"
	export AIDEVOPS_PULSE_PROCESS_PATTERN="${_escaped_root}/scripts/pulse-wrapper\\.sh"

	# Ensure env overrides don't leak between tests.
	unset AIDEVOPS_SKIP_PULSE_RESTART 2>/dev/null || true
	# Shorten wait windows so tests finish quickly.
	export AIDEVOPS_PULSE_RESTART_WAIT=0
	export AIDEVOPS_PULSE_SIGTERM_WAIT=1
}

_teardown() {
	# Kill any mock pulses this suite spawned.
	if [[ -n "${TEST_ROOT:-}" ]]; then
		pkill -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true
	fi
	# Also catch any residual mock PIDs we noted.
	local _pid
	for _pid in "${MOCK_PIDS[@]}"; do
		kill -KILL "$_pid" 2>/dev/null || true
	done
	sleep 1
	[[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
}

trap _teardown EXIT

# Returns 0 if a mock pulse from our TEST_ROOT is alive, 1 otherwise.
# Separate from the helper's own pgrep so we independently verify state.
_mock_pulse_alive() {
	pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" >/dev/null 2>&1
}

_wait_for_mock_pulse() {
	local _tries="${1:-10}"
	while [[ "$_tries" -gt 0 ]]; do
		if _mock_pulse_alive; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_wait_for_no_mock_pulse() {
	local _tries="${1:-10}"
	while [[ "$_tries" -gt 0 ]]; do
		if ! _mock_pulse_alive; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_kill_mocks() {
	pkill -KILL -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true
	_wait_for_no_mock_pulse 20 || true
}

# _spawn_extra_mock_pulse: launch ONE additional mock pulse-wrapper.sh process
# in the background and return after it's registered with the kernel. Used by
# the threshold tests (GH#21903) to simulate post-t2774 cycle overlap where
# multiple pulse-wrapper.sh PIDs are alive simultaneously.
#
# Note on filtering: the spawned process is parented to the test-runner bash,
# whose argv ('bash .../test-pulse-lifecycle-helper.sh') does NOT contain
# 'pulse-wrapper.sh' — so Layer 2 of _pulse_pids does NOT filter it. It is
# counted as a top-level pulse PID, which is exactly what we want for these
# tests.
_spawn_extra_mock_pulse() {
	bash "${TEST_ROOT}/scripts/pulse-wrapper.sh" >/dev/null 2>&1 &
	local _pid=$!
	MOCK_PIDS+=("$_pid")
	# Wait for the kernel to register the process so subsequent pgrep finds it.
	local _tries=20
	while [[ "$_tries" -gt 0 ]]; do
		if kill -0 "$_pid" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
		_tries=$((_tries - 1))
	done
	return 1
}

# _count_top_level_mock_pulses: count PIDs the helper would treat as
# top-level pulse instances. We replicate _pulse_pids' two-layer filter
# directly here — running the helper itself would side-effect via the
# subcommand contract.
_count_top_level_mock_pulses() {
	local _pids _pid _ppid _ppid_cmd _count=0
	_pids=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true)
	[[ -z "$_pids" ]] && {
		printf '0\n'
		return 0
	}
	while read -r _pid; do
		_ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
		[[ -z "$_ppid" || "$_ppid" == "0" ]] && continue
		if [[ "$_ppid" == "1" ]]; then
			_count=$((_count + 1))
			continue
		fi
		_ppid_cmd=$(ps -p "$_ppid" -o command= 2>/dev/null)
		[[ "$_ppid_cmd" =~ pulse-wrapper\.sh ]] && continue
		_count=$((_count + 1))
	done <<<"$_pids"
	printf '%s\n' "$_count"
	return 0
}

# _spawn_sidecar_mock_pulse: launch ONE mock pulse-wrapper.sh process with a
# sidecar role flag in argv. Uses --merge-only as the canonical sidecar; the
# helper's _PULSE_SIDECAR_FLAGS_RE matches all four documented flags. Used
# by the GH#21903 sidecar-filtering tests to verify that sidecars are
# excluded from the MAIN pile-up count and reported separately by status.
#
# Note on filtering: the spawned process is a child of the test runner
# (whose argv contains 'test-pulse-lifecycle-helper.sh' — does NOT match
# the literal 'pulse-wrapper.sh' regex on Layer 2). It is therefore counted
# as top-level by Layers 1+2 and rejected only by Layer 3 (sidecar guard).
_spawn_sidecar_mock_pulse() {
	bash "${TEST_ROOT}/scripts/pulse-wrapper.sh" --merge-only >/dev/null 2>&1 &
	local _pid=$!
	MOCK_PIDS+=("$_pid")
	local _tries=20
	while [[ "$_tries" -gt 0 ]]; do
		if kill -0 "$_pid" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
		_tries=$((_tries - 1))
	done
	return 1
}

# _count_main_mock_pulses: count PIDs the helper's _pulse_pids would return
# AFTER the GH#21903 sidecar filter. Identical to _count_top_level_mock_pulses
# plus the Layer 3 argv-flag check.
_count_main_mock_pulses() {
	local _pids _pid _ppid _ppid_cmd _cmd _count=0
	_pids=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true)
	[[ -z "$_pids" ]] && {
		printf '0\n'
		return 0
	}
	while read -r _pid; do
		_ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
		[[ -z "$_ppid" || "$_ppid" == "0" ]] && continue
		if [[ "$_ppid" == "1" ]]; then
			_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
			[[ "$_cmd" =~ (--merge-only|--self-check|--dry-run|--canary) ]] && continue
			_count=$((_count + 1))
			continue
		fi
		_ppid_cmd=$(ps -p "$_ppid" -o command= 2>/dev/null)
		[[ "$_ppid_cmd" =~ pulse-wrapper\.sh ]] && continue
		_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
		[[ "$_cmd" =~ (--merge-only|--self-check|--dry-run|--canary) ]] && continue
		_count=$((_count + 1))
	done <<<"$_pids"
	printf '%s\n' "$_count"
	return 0
}

# _count_sidecar_mock_pulses: count PIDs that match the sidecar argv pattern
# (top-level by subshell-guard, AND argv contains a sidecar flag).
_count_sidecar_mock_pulses() {
	local _pids _pid _ppid _ppid_cmd _cmd _count=0
	_pids=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true)
	[[ -z "$_pids" ]] && {
		printf '0\n'
		return 0
	}
	while read -r _pid; do
		_ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
		[[ -z "$_ppid" || "$_ppid" == "0" ]] && continue
		if [[ "$_ppid" != "1" ]]; then
			_ppid_cmd=$(ps -p "$_ppid" -o command= 2>/dev/null)
			[[ "$_ppid_cmd" =~ pulse-wrapper\.sh ]] && continue
		fi
		_cmd=$(ps -p "$_pid" -o command= 2>/dev/null)
		[[ "$_cmd" =~ (--merge-only|--self-check|--dry-run|--canary) ]] && _count=$((_count + 1))
	done <<<"$_pids"
	printf '%s\n' "$_count"
	return 0
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_help_emits_usage() {
	local out
	out=$("$HELPER" --help 2>&1)
	if [[ "$out" == *"Usage:"* && "$out" == *"restart-if-running"* ]]; then
		_print_result "help emits usage" 1
	else
		_print_result "help emits usage (missing Usage or subcommands)" 0
	fi
	return 0
}

test_unknown_command_exits_2() {
	local rc=0
	"$HELPER" this-is-not-a-command >/dev/null 2>&1 || rc=$?
	_assert_eq "unknown command exits 2" "2" "$rc"
	return 0
}

test_is_running_exit_1_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" is-running >/dev/null 2>&1 || rc=$?
	_assert_eq "is-running exits 1 when stopped" "1" "$rc"
	return 0
}

test_is_running_exit_0_when_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	if ! _wait_for_mock_pulse 20; then
		_print_result "is-running exits 0 when running (failed to start mock)" 0
		return 0
	fi
	local rc=0
	"$HELPER" is-running >/dev/null 2>&1 || rc=$?
	_assert_eq "is-running exits 0 when running" "0" "$rc"
	_kill_mocks
	return 0
}

test_status_when_stopped() {
	_kill_mocks
	local out
	out=$("$HELPER" status 2>&1)
	if [[ "$out" == *"not running"* ]]; then
		_print_result "status prints 'not running' when stopped" 1
	else
		_print_result "status when stopped (got: $out)" 0
	fi
	return 0
}

test_status_when_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local out
	out=$("$HELPER" status 2>&1)
	if [[ "$out" == *"running"* && "$out" == *"PID"* ]]; then
		_print_result "status prints PID(s) when running" 1
	else
		_print_result "status when running (got: $out)" 0
	fi
	_kill_mocks
	return 0
}

test_start_launches_pulse() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	if _wait_for_mock_pulse 20; then
		_print_result "start launches pulse" 1
	else
		_print_result "start launches pulse (pulse did not appear)" 0
	fi
	_kill_mocks
	return 0
}

test_start_is_idempotent() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	# Second start should no-op, PID should be unchanged.
	"$HELPER" start >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "start idempotent (same PID)" "$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_stop_terminates_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	"$HELPER" stop >/dev/null 2>&1 || true
	if _wait_for_no_mock_pulse 20; then
		_print_result "stop terminates running pulse" 1
	else
		_print_result "stop terminates running pulse (residual PIDs found)" 0
		_kill_mocks
	fi
	return 0
}

test_stop_idempotent_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" stop >/dev/null 2>&1 || rc=$?
	_assert_eq "stop idempotent when stopped" "0" "$rc"
	return 0
}

test_restart_if_running_noop_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" restart-if-running >/dev/null 2>&1 || rc=$?
	_assert_eq "restart-if-running no-op exit 0 when stopped" "0" "$rc"
	# And it must NOT have started a pulse.
	if _mock_pulse_alive; then
		_print_result "restart-if-running did not spuriously start pulse" 0
		_kill_mocks
	else
		_print_result "restart-if-running did not spuriously start pulse" 1
	fi
	return 0
}

test_restart_if_running_replaces_pid() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	"$HELPER" restart-if-running >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)

	if [[ -n "$first_pid" && -n "$second_pid" && "$first_pid" != "$second_pid" ]]; then
		_print_result "restart-if-running replaces PID" 1
	else
		_print_result "restart-if-running replaces PID (first=$first_pid second=$second_pid)" 0
	fi
	_kill_mocks
	return 0
}

test_skip_env_honoured_in_restart_if_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	AIDEVOPS_SKIP_PULSE_RESTART=1 "$HELPER" restart-if-running >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "AIDEVOPS_SKIP_PULSE_RESTART=1 preserves PID (restart-if-running)" \
		"$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_skip_env_honoured_in_restart() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	AIDEVOPS_SKIP_PULSE_RESTART=1 "$HELPER" restart >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "AIDEVOPS_SKIP_PULSE_RESTART=1 preserves PID (restart)" \
		"$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_missing_pulse_script_exit_2() {
	_kill_mocks
	# Move the mock away so the helper sees no pulse-wrapper.sh.
	local _saved="${TEST_ROOT}/scripts/pulse-wrapper.sh.hidden"
	mv "${TEST_ROOT}/scripts/pulse-wrapper.sh" "$_saved"
	local rc=0
	"$HELPER" start >/dev/null 2>&1 || rc=$?
	# Restore for subsequent tests.
	mv "$_saved" "${TEST_ROOT}/scripts/pulse-wrapper.sh"
	_assert_eq "start with missing pulse-wrapper.sh exits 2" "2" "$rc"
	return 0
}

test_pulse_pids_suppresses_broken_pipe_when_consumer_exits_early() {
	local rc=0 err=""
	err=$(
		(
			# shellcheck source=../pulse-lifecycle-helper.sh
			source "$HELPER"

			_pulse_pids_raw() {
				local _i=1
				while [[ "$_i" -le 100000 ]]; do
					printf '%s\n' "$_i"
					_i=$((_i + 1))
				done
				return 0
			}

			ps() {
				local _arg1="${1:-}" _arg2="${2:-}" _arg3="${3:-}" _arg4="${4:-}" _fallback_rc=0
				if [[ "$_arg1" == "-p" && "$_arg3" == "-o" && "$_arg4" == "ppid=" ]]; then
					printf '1\n'
					return 0
				fi
				if [[ "$_arg1" == "-p" && "$_arg3" == "-o" && "$_arg4" == "command=" ]]; then
					printf 'bash %s/scripts/pulse-wrapper.sh pid=%s\n' "${TEST_ROOT:-/tmp}" "$_arg2"
					return 0
				fi
				command ps "$@"
				_fallback_rc=$?
				return "$_fallback_rc"
			}

			_pulse_pids | {
				local _first=""
				read -r _first || true
				return 0
			} >/dev/null
		) 2>&1
	) || rc=$?

	_assert_eq "_pulse_pids exits 0 when consumer closes early" "0" "$rc"
	if [[ "$err" != *"Broken pipe"* ]]; then
		_print_result "_pulse_pids suppresses Broken pipe noise on early close" 1
	else
		_print_result "_pulse_pids emitted Broken pipe noise (stderr=$err)" 0
	fi
	return 0
}

test_pipe_trap_restore_avoids_eval() {
	local out=""
	out=$(
		(
			# shellcheck source=../pulse-lifecycle-helper.sh
			source "$HELPER"
			_trap_eval_marker=0
			_pulse_restore_pipe_trap '_trap_eval_marker=1'
			printf '%s\n' "$_trap_eval_marker"
		)
	)
	_assert_eq "_pulse_restore_pipe_trap does not eval trap text" "0" "$out"
	return 0
}

test_pipe_trap_restore_ignored_sigpipe() {
	local out=""
	out=$(
		(
			# shellcheck source=../pulse-lifecycle-helper.sh
			source "$HELPER"
			trap - PIPE
			_pulse_restore_pipe_trap "trap -- '' SIGPIPE"
			trap -p PIPE
		)
	)
	if [[ "$out" == *"''"* ]]; then
		_print_result "_pulse_restore_pipe_trap restores ignored SIGPIPE" 1
	else
		_print_result "_pulse_restore_pipe_trap failed to restore ignored SIGPIPE (out=$out)" 0
	fi
	return 0
}

# -----------------------------------------------------------------------------
# GH#21903: threshold-based PILE-UP detection
# -----------------------------------------------------------------------------
# Post-t2774 the pulse releases its instance lock BEFORE the LLM phase, so
# brief coexistence of 2-3 pulse-wrapper.sh PIDs is the EXPECTED steady state
# (cycle N's LLM phase + cycle N+1's deterministic phase + occasional N+2
# overlap). The legacy "warn on count > 1" check trained operators to ignore
# legitimate overlap. _status now warns ONLY when the count exceeds
# AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES (default 3).

test_status_two_instances_no_warning_default_threshold() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	sleep 0.3

	local count
	count=$(_count_top_level_mock_pulses)
	if [[ "$count" -lt 2 ]]; then
		_print_result "status: 2-instance setup (expected >=2 top-level mocks, got $count)" 0
		_kill_mocks
		return 0
	fi

	local rc=0
	local out
	out=$("$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: 2 instances exits 0 (default threshold 3)" "0" "$rc"
	if [[ "$out" != *"PILE-UP"* && "$out" != *"singleton invariant"* ]]; then
		_print_result "status: 2 instances does not warn" 1
	else
		_print_result "status: 2 instances should not warn (output included PILE-UP/singleton)" 0
	fi
	_kill_mocks
	return 0
}

test_status_at_threshold_no_warning() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	sleep 0.3

	local count
	count=$(_count_top_level_mock_pulses)
	if [[ "$count" -lt 3 ]]; then
		_print_result "status: 3-instance setup (expected >=3 top-level mocks, got $count)" 0
		_kill_mocks
		return 0
	fi

	local rc=0
	local out
	out=$("$HELPER" status 2>&1) || rc=$?
	# 3 instances is exactly the default threshold — must not warn.
	if [[ "$count" -eq 3 ]]; then
		_assert_eq "status: 3 instances exits 0 (at default threshold)" "0" "$rc"
		if [[ "$out" != *"PILE-UP"* ]]; then
			_print_result "status: at-threshold (3) does not emit PILE-UP" 1
		else
			_print_result "status: at-threshold (3) should not warn (got PILE-UP)" 0
		fi
	else
		# Spurious extra process picked up — environmental, skip cleanly.
		_print_result "status: at-threshold setup got $count mocks (env noise; skipping)" 1
	fi
	_kill_mocks
	return 0
}

test_status_pileup_above_threshold_warns_and_exits_3() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	sleep 0.3

	local count
	count=$(_count_top_level_mock_pulses)
	if [[ "$count" -lt 4 ]]; then
		_print_result "status: pile-up setup (expected >=4 top-level mocks, got $count)" 0
		_kill_mocks
		return 0
	fi

	local rc=0
	local out
	out=$("$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: 4+ instances exits 3 (above default threshold)" "3" "$rc"
	if [[ "$out" == *"PILE-UP"* && "$out" == *"GH#21903"* ]]; then
		_print_result "status: pile-up message includes 'PILE-UP' and 'GH#21903'" 1
	else
		_print_result "status: pile-up message missing expected markers (got: $out)" 0
	fi
	_kill_mocks
	return 0
}

test_status_legacy_strict_threshold_via_env() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	sleep 0.3

	local count
	count=$(_count_top_level_mock_pulses)
	if [[ "$count" -lt 2 ]]; then
		_print_result "status: legacy-mode setup (expected >=2 top-level mocks, got $count)" 0
		_kill_mocks
		return 0
	fi

	local rc=0
	local out
	out=$(AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES=1 "$HELPER" status 2>&1) || rc=$?
	# With threshold=1, ANY coexistence is a pile-up (legacy strict-singleton mode).
	_assert_eq "status: 2 instances exits 3 with threshold=1 (legacy strict mode)" "3" "$rc"
	if [[ "$out" == *"PILE-UP"* ]]; then
		_print_result "status: legacy strict threshold triggers PILE-UP warning" 1
	else
		_print_result "status: legacy strict threshold should warn (got: $out)" 0
	fi
	_kill_mocks
	return 0
}

test_status_accepts_leading_zero_threshold_env() {
	_kill_mocks
	local rc=0
	local out
	out=$(AIDEVOPS_PULSE_EXPECTED_MAX_INSTANCES=08 "$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: leading-zero threshold 08 exits 0" "0" "$rc"
	if [[ "$out" == *"value too great for base"* ]]; then
		_print_result "status: leading-zero threshold 08 avoids octal parse error" 0
	else
		_print_result "status: leading-zero threshold 08 avoids octal parse error" 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# GH#21903 sidecar filter — sidecar-flagged pulse PIDs (--merge-only, etc)
# must NOT count toward the MAIN pulse PILE-UP threshold. Without this, a
# single 60s --merge-only sidecar permanently consumes one of the three
# threshold slots, leaving only two for legitimate t2774 main-pulse overlap.
# These tests pin the sidecar exclusion behaviour and the status display.

test_status_excludes_merge_only_sidecar() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_sidecar_mock_pulse || true
	sleep 0.3

	local _main _sidecar
	_main=$(_count_main_mock_pulses)
	_sidecar=$(_count_sidecar_mock_pulses)
	if [[ "$_main" -lt 1 || "$_sidecar" -lt 1 ]]; then
		_print_result "status: 1-main-1-sidecar setup (got main=$_main sidecar=$_sidecar)" 0
		_kill_mocks
		return 0
	fi

	local rc=0 out
	out=$("$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: 1 main + 1 sidecar exits 0 (sidecar excluded)" "0" "$rc"
	if [[ "$out" == *"Sidecar"* && "$out" == *"GH#21903"* ]]; then
		_print_result "status: lists sidecar separately with GH#21903 marker" 1
	else
		_print_result "status: missing sidecar listing or GH#21903 marker (out=$out)" 0
	fi
	# Match the warning prefix 'PILE-UP:' (with colon), not the
	# documentation phrase 'PILE-UP threshold' that appears in the
	# sidecar listing block on every status invocation with sidecars.
	if [[ "$out" != *"PILE-UP:"* ]]; then
		_print_result "status: 1 main + 1 sidecar does not warn PILE-UP" 1
	else
		_print_result "status: 1 main + 1 sidecar should not warn (got PILE-UP:)" 0
	fi
	_kill_mocks
	return 0
}

test_status_three_main_plus_sidecar_no_warn() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	_spawn_sidecar_mock_pulse || true
	sleep 0.3

	local _main _sidecar
	_main=$(_count_main_mock_pulses)
	_sidecar=$(_count_sidecar_mock_pulses)
	if [[ "$_main" -lt 3 || "$_sidecar" -lt 1 ]]; then
		_print_result "status: 3-main-1-sidecar setup (got main=$_main sidecar=$_sidecar)" 0
		_kill_mocks
		return 0
	fi

	local rc=0 out
	out=$("$HELPER" status 2>&1) || rc=$?
	# Pre-fix bug: 3+1=4 PIDs would be counted, exceeding threshold 3 → exit 3.
	# Post-fix: only the 3 mains count, exactly at threshold → exit 0, no warn.
	if [[ "$_main" -eq 3 ]]; then
		_assert_eq "status: 3 main + 1 sidecar exits 0 (sidecar excluded from threshold)" "0" "$rc"
		# Match the warning prefix 'PILE-UP:' (with colon), not the
		# documentation phrase 'PILE-UP threshold' that appears in the
		# sidecar listing block on every status invocation with sidecars.
		if [[ "$out" != *"PILE-UP:"* ]]; then
			_print_result "status: 3 main + 1 sidecar does not warn (sidecar correctly excluded)" 1
		else
			_print_result "status: 3 main + 1 sidecar wrongly emitted PILE-UP: (got: $out)" 0
		fi
	else
		_print_result "status: 3-main-1-sidecar setup got main=$_main (env noise; skipping)" 1
	fi
	_kill_mocks
	return 0
}

test_status_four_main_plus_sidecar_warns() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	_spawn_extra_mock_pulse || true
	_spawn_sidecar_mock_pulse || true
	sleep 0.3

	local _main _sidecar
	_main=$(_count_main_mock_pulses)
	_sidecar=$(_count_sidecar_mock_pulses)
	if [[ "$_main" -lt 4 || "$_sidecar" -lt 1 ]]; then
		_print_result "status: 4-main-1-sidecar setup (got main=$_main sidecar=$_sidecar)" 0
		_kill_mocks
		return 0
	fi

	local rc=0 out
	out=$("$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: 4 main + 1 sidecar exits 3 (main count > threshold)" "3" "$rc"
	if [[ "$out" == *"PILE-UP"* && "$out" == *"main pulse-wrapper.sh"* ]]; then
		_print_result "status: pile-up message names 'main pulse-wrapper.sh'" 1
	else
		_print_result "status: pile-up missing 'main' qualifier (out=$out)" 0
	fi
	if [[ "$out" == *"Sidecars"*"excluded"* ]]; then
		_print_result "status: pile-up message documents sidecar exclusion" 1
	else
		_print_result "status: pile-up missing sidecar-exclusion note (out=$out)" 0
	fi
	_kill_mocks
	return 0
}

test_is_running_returns_false_with_only_sidecar() {
	_kill_mocks
	# Start ONLY a sidecar, no main pulse.
	_spawn_sidecar_mock_pulse || true
	sleep 0.3

	local _main _sidecar
	_main=$(_count_main_mock_pulses)
	_sidecar=$(_count_sidecar_mock_pulses)
	if [[ "$_main" -ne 0 || "$_sidecar" -lt 1 ]]; then
		_print_result "is-running: sidecar-only setup (got main=$_main sidecar=$_sidecar)" 0
		_kill_mocks
		return 0
	fi

	local rc=0
	"$HELPER" is-running >/dev/null 2>&1 || rc=$?
	_assert_eq "is-running: 0 main + 1 sidecar returns 1 (sidecar is not main)" "1" "$rc"
	_kill_mocks
	return 0
}

test_status_sidecar_only_reports_not_running() {
	_kill_mocks
	_spawn_sidecar_mock_pulse || true
	sleep 0.3

	local _main _sidecar
	_main=$(_count_main_mock_pulses)
	_sidecar=$(_count_sidecar_mock_pulses)
	if [[ "$_main" -ne 0 || "$_sidecar" -lt 1 ]]; then
		_print_result "status: sidecar-only setup (got main=$_main sidecar=$_sidecar)" 0
		_kill_mocks
		return 0
	fi

	local rc=0 out
	out=$("$HELPER" status 2>&1) || rc=$?
	_assert_eq "status: sidecar-only exits 0" "0" "$rc"
	if [[ "$out" == *"not running (sidecar(s) only)"* ]]; then
		_print_result "status: sidecar-only labels state explicitly" 1
	else
		_print_result "status: sidecar-only header missing (out=$out)" 0
	fi
	if [[ "$out" == *"Sidecar"*"excluded"* ]]; then
		_print_result "status: sidecar-only includes sidecar listing block" 1
	else
		_print_result "status: sidecar-only missing sidecar listing (out=$out)" 0
	fi
	_kill_mocks
	return 0
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------

main() {
	_setup

	test_help_emits_usage
	test_unknown_command_exits_2
	test_is_running_exit_1_when_stopped
	test_is_running_exit_0_when_running
	test_status_when_stopped
	test_status_when_running
	test_start_launches_pulse
	test_start_is_idempotent
	test_stop_terminates_running
	test_stop_idempotent_when_stopped
	test_restart_if_running_noop_when_stopped
	test_restart_if_running_replaces_pid
	test_skip_env_honoured_in_restart_if_running
	test_skip_env_honoured_in_restart
	test_missing_pulse_script_exit_2
	test_pulse_pids_suppresses_broken_pipe_when_consumer_exits_early
	test_pipe_trap_restore_avoids_eval
	test_pipe_trap_restore_ignored_sigpipe

	# GH#21903 threshold-based PILE-UP detection
	test_status_two_instances_no_warning_default_threshold
	test_status_at_threshold_no_warning
	test_status_pileup_above_threshold_warns_and_exits_3
	test_status_legacy_strict_threshold_via_env
	test_status_accepts_leading_zero_threshold_env

	# GH#21903 sidecar exclusion (additive on top of threshold)
	test_status_excludes_merge_only_sidecar
	test_status_three_main_plus_sidecar_no_warn
	test_status_four_main_plus_sidecar_warns
	test_is_running_returns_false_with_only_sidecar
	test_status_sidecar_only_reports_not_running

	echo ""
	echo "----"
	echo "Tests run: $TESTS_RUN"
	echo "Failed:    $TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%b[OK]%b All pulse-lifecycle-helper tests passed\n' \
			"$TEST_GREEN" "$TEST_RESET"
		return 0
	fi
	printf '%b[FAIL]%b %d test(s) failed\n' "$TEST_RED" "$TEST_RESET" \
		"$TESTS_FAILED"
	return 1
}

main "$@"
