#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2939 regression tests — pulse defense-in-depth restart reliability.
# Covers:
#   (1) Pulse plist KeepAlive is dict form with SuccessfulExit=false
#   (2) Pulse plist ThrottleInterval is set
#   (3) Watchdog plist generation produces valid XML
#   (4) Watchdog plist StartInterval=60s
#   (5) pulse-watchdog-tick.sh: alive → exit 0 silently
#   (6) pulse-watchdog-tick.sh: dead within grace → exit 0 silently
#   (7) pulse-watchdog-tick.sh: dead past grace → revives via lifecycle helper
#   (8) pulse-watchdog-tick.sh: missing last-run timestamp → revives immediately
#   (9) pulse-watchdog-tick.sh: AIDEVOPS_PULSE_WATCHDOG_DISABLE=1 → no-op exit 0
#
# Usage: bash .agents/scripts/tests/test-pulse-defense-restart.sh
# Platform: macOS-specific tests (plist generation) skip on Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SCHEDULERS_SH="$REPO_ROOT/setup-modules/schedulers.sh"
TICK_SH="$REPO_ROOT/.agents/scripts/pulse-watchdog-tick.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

# Generate plists in a subshell with stubs for _xml_escape, _resolve_modern_bash,
# _read_pulse_interval_seconds, _build_pulse_headless_env_xml,
# _build_plist_env_overrides_xml.
_render_pulse_plist() {
	local out_file="$1"
	bash -c '
		set -uo pipefail
		export PULSE_STALE_THRESHOLD_SECONDS=1800
		_xml_escape() {
			local val="$1"
			val="${val//&/&amp;}"
			val="${val//</&lt;}"
			val="${val//>/&gt;}"
			val="${val//\"/&quot;}"
			val="${val//\x27/&apos;}"
			printf "%s" "$val"
		}
		_resolve_modern_bash() { echo "/opt/homebrew/bin/bash"; }
		_read_pulse_interval_seconds() { echo "600"; }
		_build_pulse_headless_env_xml() { return 0; }
		_build_plist_env_overrides_xml() { return 0; }
		print_info() { :; }
		print_warning() { :; }
		source "'"$SCHEDULERS_SH"'" 2>/dev/null || true
		# Re-define after source in case schedulers.sh defined real ones.
		_resolve_modern_bash() { echo "/opt/homebrew/bin/bash"; }
		_read_pulse_interval_seconds() { echo "600"; }
		_build_pulse_headless_env_xml() { return 0; }
		_build_plist_env_overrides_xml() { return 0; }
		_generate_pulse_plist_content "com.test.pulse" "/path/to/pulse.sh" "/opt/homebrew/bin/opencode"
	' >"$out_file"
}

_render_watchdog_plist() {
	local out_file="$1"
	bash -c '
		set -uo pipefail
		_xml_escape() {
			local val="$1"
			val="${val//&/&amp;}"
			val="${val//</&lt;}"
			val="${val//>/&gt;}"
			val="${val//\"/&quot;}"
			val="${val//\x27/&apos;}"
			printf "%s" "$val"
		}
		print_info() { :; }
		print_warning() { :; }
		source "'"$SCHEDULERS_SH"'" 2>/dev/null || true
		_generate_pulse_watchdog_plist_content "sh.aidevops.pulse-watchdog" "/path/to/tick.sh" "/opt/homebrew/bin/bash"
	' >"$out_file"
}

# ---------------------------------------------------------------------------
# Tests for plist generation (macOS only — plutil/grep-based)
# ---------------------------------------------------------------------------

test_pulse_plist_keepalive_dict() {
	local plist="$TEST_DIR/pulse.plist"
	_render_pulse_plist "$plist"

	# Inline grep-based check (avoids plutil dependency for cross-platform CI).
	local rc=0
	if ! grep -A 3 "<key>KeepAlive</key>" "$plist" | grep -q "<key>SuccessfulExit</key>"; then
		rc=1
	fi
	print_result "test_pulse_plist_keepalive_dict" "$rc" \
		"KeepAlive must be a dict containing SuccessfulExit (t2939 layer 1)"
	return 0
}

test_pulse_plist_throttle_interval() {
	local plist="$TEST_DIR/pulse.plist"
	_render_pulse_plist "$plist"
	local rc=0
	if ! grep -q "<key>ThrottleInterval</key>" "$plist"; then
		rc=1
	fi
	print_result "test_pulse_plist_throttle_interval" "$rc" \
		"ThrottleInterval prevents rapid-restart loops (t2939 layer 1)"
	return 0
}

test_watchdog_plist_label() {
	local plist="$TEST_DIR/watchdog.plist"
	_render_watchdog_plist "$plist"
	local rc=0
	if ! grep -q "<string>sh.aidevops.pulse-watchdog</string>" "$plist"; then
		rc=1
	fi
	print_result "test_watchdog_plist_label" "$rc" \
		"Watchdog label must be sh.aidevops.pulse-watchdog (t2939 layer 2)"
	return 0
}

test_watchdog_plist_start_interval() {
	local plist="$TEST_DIR/watchdog.plist"
	_render_watchdog_plist "$plist"
	local rc=0
	# StartInterval should be 60 seconds.
	if ! grep -B 1 "<integer>60</integer>" "$plist" | grep -q "StartInterval"; then
		rc=1
	fi
	print_result "test_watchdog_plist_start_interval" "$rc" \
		"Watchdog must run every 60s (t2939 layer 2)"
	return 0
}

test_watchdog_plist_valid_xml() {
	local plist="$TEST_DIR/watchdog.plist"
	_render_watchdog_plist "$plist"
	local rc=0
	if command -v plutil >/dev/null 2>&1; then
		plutil -lint "$plist" >/dev/null 2>&1 || rc=1
	else
		# Fall back to xmllint or basic structural check on Linux.
		grep -q '<plist version="1.0">' "$plist" && grep -q '</plist>' "$plist" || rc=1
	fi
	print_result "test_watchdog_plist_valid_xml" "$rc" \
		"Watchdog plist must be valid XML (t2939 layer 2)"
	return 0
}

# ---------------------------------------------------------------------------
# Tests for pulse-watchdog-tick.sh logic
# ---------------------------------------------------------------------------

# Returns the watchdog log path from a stubbed HOME.
_setup_tick_env() {
	local stub_home="$1"
	local helper_state="$2" # "alive" or "dead"
	mkdir -p "$stub_home/.aidevops/logs" "$stub_home/.config/aidevops" \
		"$stub_home/.aidevops/agents/scripts"
	echo '{"supervisor":{"pulse_interval_seconds":600}}' >"$stub_home/.config/aidevops/settings.json"

	# Stub lifecycle helper. Records every invocation.
	cat >"$stub_home/.aidevops/agents/scripts/pulse-lifecycle-helper.sh" <<STUB
#!/usr/bin/env bash
echo "stub:\$*" >>"$stub_home/.aidevops/logs/stub-helper-invocations.log"
case "\$1" in
  is-running) [[ "$helper_state" == "alive" ]] && exit 0 || exit 1 ;;
  start) echo "stub start invoked"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
	chmod +x "$stub_home/.aidevops/agents/scripts/pulse-lifecycle-helper.sh"
	return 0
}

test_tick_alive_fast_exit() {
	local stub_home="$TEST_DIR/alive"
	_setup_tick_env "$stub_home" "alive"
	local rc=0
	HOME="$stub_home" AIDEVOPS_AGENTS_DIR="$stub_home/.aidevops/agents" \
		bash "$TICK_SH" || rc=$?
	# Must exit 0 with no revival attempt.
	local invocations=""
	if [[ -f "$stub_home/.aidevops/logs/stub-helper-invocations.log" ]]; then
		invocations=$(cat "$stub_home/.aidevops/logs/stub-helper-invocations.log")
	fi
	if [[ "$rc" -eq 0 ]] && [[ "$invocations" == "stub:is-running" ]]; then
		print_result "test_tick_alive_fast_exit" 0
	else
		print_result "test_tick_alive_fast_exit" 1 \
			"expected exit=0 + only is-running call; got exit=$rc invocations=$invocations"
	fi
	return 0
}

test_tick_dead_within_grace_no_revive() {
	local stub_home="$TEST_DIR/within-grace"
	_setup_tick_env "$stub_home" "dead"
	# Recent timestamp (NOW) — within (600 + 120) grace window.
	date +%s >"$stub_home/.aidevops/logs/pulse-wrapper-last-run.ts"
	local rc=0
	HOME="$stub_home" AIDEVOPS_AGENTS_DIR="$stub_home/.aidevops/agents" \
		bash "$TICK_SH" || rc=$?
	local invocations
	invocations=$(cat "$stub_home/.aidevops/logs/stub-helper-invocations.log" 2>/dev/null || echo "")
	# Should call is-running but NOT start.
	if [[ "$rc" -eq 0 ]] && [[ "$invocations" == "stub:is-running" ]]; then
		print_result "test_tick_dead_within_grace_no_revive" 0
	else
		print_result "test_tick_dead_within_grace_no_revive" 1 \
			"expected exit=0 + no start call within grace; got exit=$rc invocations='$invocations'"
	fi
	return 0
}

test_tick_dead_past_grace_revives() {
	local stub_home="$TEST_DIR/past-grace"
	_setup_tick_env "$stub_home" "dead"
	# Timestamp 1000s ago > (600 interval + 120 grace) = 720s threshold.
	echo "$(($(date +%s) - 1000))" >"$stub_home/.aidevops/logs/pulse-wrapper-last-run.ts"
	local rc=0
	HOME="$stub_home" AIDEVOPS_AGENTS_DIR="$stub_home/.aidevops/agents" \
		bash "$TICK_SH" || rc=$?
	local invocations
	invocations=$(cat "$stub_home/.aidevops/logs/stub-helper-invocations.log" 2>/dev/null || echo "")
	# Should call is-running AND start.
	if [[ "$rc" -eq 0 ]] && [[ "$invocations" == *"stub:is-running"* ]] && [[ "$invocations" == *"stub:start"* ]]; then
		print_result "test_tick_dead_past_grace_revives" 0
	else
		print_result "test_tick_dead_past_grace_revives" 1 \
			"expected exit=0 + is-running + start; got exit=$rc invocations='$invocations'"
	fi
	return 0
}

test_tick_no_last_run_revives() {
	local stub_home="$TEST_DIR/no-last-run"
	_setup_tick_env "$stub_home" "dead"
	# Intentionally no last-run.ts file.
	local rc=0
	HOME="$stub_home" AIDEVOPS_AGENTS_DIR="$stub_home/.aidevops/agents" \
		bash "$TICK_SH" || rc=$?
	local invocations
	invocations=$(cat "$stub_home/.aidevops/logs/stub-helper-invocations.log" 2>/dev/null || echo "")
	if [[ "$rc" -eq 0 ]] && [[ "$invocations" == *"stub:start"* ]]; then
		print_result "test_tick_no_last_run_revives" 0
	else
		print_result "test_tick_no_last_run_revives" 1 \
			"expected exit=0 + start call when last-run missing; got exit=$rc invocations='$invocations'"
	fi
	return 0
}

test_tick_disable_flag() {
	local stub_home="$TEST_DIR/disabled"
	_setup_tick_env "$stub_home" "dead"
	echo "0" >"$stub_home/.aidevops/logs/pulse-wrapper-last-run.ts"
	local rc=0
	HOME="$stub_home" AIDEVOPS_AGENTS_DIR="$stub_home/.aidevops/agents" \
		AIDEVOPS_PULSE_WATCHDOG_DISABLE=1 \
		bash "$TICK_SH" || rc=$?
	local invocations
	invocations=$(cat "$stub_home/.aidevops/logs/stub-helper-invocations.log" 2>/dev/null || echo "")
	# Should exit 0 with no helper invocations.
	if [[ "$rc" -eq 0 ]] && [[ -z "$invocations" ]]; then
		print_result "test_tick_disable_flag" 0
	else
		print_result "test_tick_disable_flag" 1 \
			"expected exit=0 + zero invocations when DISABLE=1; got exit=$rc invocations='$invocations'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	echo "Running pulse defense-in-depth regression tests (t2939)..."
	echo

	setup

	# Plist generation tests (macOS-only path — generation works on Linux too,
	# we only skip the plutil-lint validation).
	test_pulse_plist_keepalive_dict
	test_pulse_plist_throttle_interval
	test_watchdog_plist_label
	test_watchdog_plist_start_interval
	test_watchdog_plist_valid_xml

	# Tick logic tests (cross-platform).
	test_tick_alive_fast_exit
	test_tick_dead_within_grace_no_revive
	test_tick_dead_past_grace_revives
	test_tick_no_last_run_revives
	test_tick_disable_flag

	echo
	echo "Tests run:    $TESTS_RUN"
	echo "Tests passed: $TESTS_PASSED"
	echo "Tests failed: $TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
