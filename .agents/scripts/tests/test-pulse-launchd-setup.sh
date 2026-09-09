#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#31668: source-backed Pulse installer/launchd regression tests. No live jobs.
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../../.." && pwd)"
TESTS_RUN=0
TESTS_FAILED=0

setup_fixture() {
	HOME=$(mktemp -d)
	export HOME
	trap 'rm -rf "$HOME"' EXIT
	mkdir -p "$HOME/.aidevops/agents/scripts" "$HOME/.aidevops/logs" "$HOME/Library/LaunchAgents"
	touch "$HOME/.aidevops/agents/scripts/pulse-wrapper.sh"
	# shellcheck source=../setup/_scheduler_runtime.sh
	source "$TEST_REPO_ROOT/.agents/scripts/setup/_scheduler_runtime.sh"
	# shellcheck source=../setup/modules/schedulers-pulse.sh
	source "$TEST_REPO_ROOT/.agents/scripts/setup/modules/schedulers-pulse.sh"
	# shellcheck source=../pulse-lifecycle-helper.sh
	source "$TEST_REPO_ROOT/.agents/scripts/pulse-lifecycle-helper.sh"
	NON_INTERACTIVE=true
	AIDEVOPS_PULSE_OS_NAME=Darwin
	TEST_LABEL=com.aidevops.aidevops-supervisor-pulse
	TEST_CONSENT=true
	TEST_DISABLED=true
	TEST_LOADED=false
	TEST_FAIL_ENABLE=false
	TEST_FAIL_BOOTSTRAP=false
	TEST_BOOTSTRAP_NOOP=false
	TEST_LOAD_NOOP=false
	TEST_EVENTS="$HOME/events"
	: >"$TEST_EVENTS"
	TEST_PLIST="$HOME/Library/LaunchAgents/$TEST_LABEL.plist"
	printf 'fixture plist\n' >"$TEST_PLIST"
	print_info() {
		printf '%s\n' "$*"
		return 0
	}
	print_warning() {
		printf '%s\n' "$*"
		return 0
	}
	print_error() {
		printf '%s\n' "$*"
		return 0
	}
	_resolve_pulse_consent() {
		printf '%s' "$TEST_CONSENT"
		return 0
	}
	_schedulers_record_template_hash() { return 0; }
	_resolve_pulse_runtime_binary() { return 0; }
	_pulse_runtime_pin_preserves_scheduler() { return 1; }
	_is_pulse_installed() { [[ "$TEST_LOADED" == true ]]; }
	_generate_pulse_plist_content() {
		printf 'fixture plist'
		return 0
	}
	_read_pulse_interval_seconds() {
		printf '120'
		return 0
	}
	_log_plist_env_overrides() { return 0; }
	_uninstall_pulse() {
		printf 'uninstall\n' >>"$TEST_EVENTS"
		return 0
	}
	return 0
}

launchctl() {
	printf '%s\n' "$1" >>"$TEST_EVENTS"
	case "$1" in
	enable)
		[[ "$TEST_FAIL_ENABLE" == false ]] || return 1
		TEST_DISABLED=false
		;;
	list)
		[[ "$TEST_LOADED" == false ]] || printf '%s\n' "$TEST_LABEL"
		;;
	print)
		[[ "$TEST_LOADED" == true ]] || return 1
		printf 'state = waiting\n'
		;;
	print-disabled) printf '"%s" => %s\n' "$TEST_LABEL" "$TEST_DISABLED" ;;
	load)
		# Legacy load may succeed without registering a disabled service.
		if [[ "$TEST_DISABLED" == false && "$TEST_LOAD_NOOP" == false ]]; then
			TEST_LOADED=true
		fi
		;;
	bootstrap)
		[[ "$TEST_DISABLED" == false && "$TEST_FAIL_BOOTSTRAP" == false ]] || return 1
		[[ "$TEST_BOOTSTRAP_NOOP" == true ]] || TEST_LOADED=true
		;;
	unload | bootout) TEST_LOADED=false ;;
	*) return 1 ;;
	esac
	return 0
}

test_disabled_converges() {
	setup_supervisor_pulse Darwin || return 1
	[[ "$TEST_DISABLED" == false && "$TEST_LOADED" == true && "$PULSE_ENABLED" == true ]] || return 1
	local first_mutation
	first_mutation=$(awk '/^(enable|load|bootstrap)$/ {print; exit}' "$TEST_EVENTS")
	[[ "$first_mutation" == enable ]]
}

test_disabled_loaded_preserves_timing() {
	TEST_LOADED=true
	setup_supervisor_pulse Darwin || return 1
	[[ "$TEST_DISABLED" == false && "$PULSE_ENABLED" == true ]] || return 1
	! grep -Eq '^(unload|bootout|bootstrap|load|kickstart)$' "$TEST_EVENTS"
}

test_repeat_preserves_timing() {
	test_disabled_converges || return 1
	: >"$TEST_EVENTS"
	setup_supervisor_pulse Darwin || return 1
	! grep -Eq '^(unload|bootout|bootstrap|load|kickstart)$' "$TEST_EVENTS"
}

test_load_noop_bootstraps() {
	TEST_LOAD_NOOP=true
	test_disabled_converges || return 1
	grep -q '^bootstrap$' "$TEST_EVENTS"
}

test_enable_failure() {
	TEST_FAIL_ENABLE=true
	PULSE_ENABLED=true
	if setup_supervisor_pulse Darwin; then return 1; fi
	[[ "$PULSE_ENABLED" == false && "$TEST_DISABLED" == true ]] || return 1
	! grep -Eq '^(load|bootstrap)$' "$TEST_EVENTS"
}

test_bootstrap_failure_retry() {
	TEST_LOAD_NOOP=true
	TEST_FAIL_BOOTSTRAP=true
	if setup_supervisor_pulse Darwin; then return 1; fi
	[[ "$PULSE_ENABLED" == false && "$TEST_LOADED" == false ]] || return 1
	TEST_FAIL_BOOTSTRAP=false
	test_disabled_converges
}

test_bootstrap_noop_fails() {
	TEST_LOAD_NOOP=true
	TEST_BOOTSTRAP_NOOP=true
	if setup_supervisor_pulse Darwin; then return 1; fi
	[[ "$PULSE_ENABLED" == false && "$TEST_LOADED" == false ]]
}

test_consent_false() {
	TEST_CONSENT=false
	setup_supervisor_pulse Darwin || return 1
	[[ "$PULSE_ENABLED" == false && "$TEST_DISABLED" == true ]] || return 1
	! grep -Eq '^(enable|load|bootstrap)$' "$TEST_EVENTS"
}

test_consent_false_cleanup() {
	TEST_LOADED=true
	test_consent_false || return 1
	grep -q '^uninstall$' "$TEST_EVENTS"
}

test_stop_wins() {
	touch "$HOME/.aidevops/logs/pulse-session.stop"
	setup_supervisor_pulse Darwin || return 1
	[[ "$PULSE_ENABLED" == false && "$TEST_DISABLED" == true ]] || return 1
	[[ -f "$HOME/.aidevops/logs/pulse-session.stop" ]] || return 1
	! grep -Eq '^(enable|load|bootstrap)$' "$TEST_EVENTS"
}

test_disabled_parser() {
	local state
	for state in true disabled; do
		TEST_DISABLED="$state"
		_pulse_launchd_supervisor_disabled || return 1
	done
	for state in false enabled; do
		TEST_DISABLED="$state"
		if _pulse_launchd_supervisor_disabled; then return 1; fi
	done
	TEST_DISABLED=disabled
	TEST_LABEL=com.aidevops.aidevops-supervisor-pulse-watchdog
	if _pulse_launchd_supervisor_disabled; then return 1; fi
	return 0
}

test_failure_does_not_report_enabled() {
	TEST_LOAD_NOOP=true
	TEST_FAIL_BOOTSTRAP=true
	if setup_supervisor_pulse Darwin >"$HOME/setup-output" 2>&1; then return 1; fi
	grep -q 'retry aidevops setup --scope pulse' "$HOME/setup-output" || return 1
	! grep -Eq 'Supervisor pulse (enabled|updated)' "$HOME/setup-output"
}

test_reconcile_respects_stop() {
	touch "$HOME/.aidevops/logs/pulse-session.stop"
	_PULSE_AGENTS_DIR="$TEST_REPO_ROOT/.agents"
	AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR="$HOME/runtime-lock"
	AIDEVOPS_PULSE_MANAGED_ENABLED=true
	TEST_DISABLED=false
	_pulse_refresh_active_runtime() { return 0; }
	_stop_reconciliation_processes() {
		printf 'stop\n' >>"$TEST_EVENTS"
		return 0
	}
	_pulse_reconciliation_pids_raw() { return 0; }
	_pulse_start_managed() {
		printf 'start\n' >>"$TEST_EVENTS"
		return 1
	}
	_reconcile_managed || return 1
	grep -q '^stop$' "$TEST_EVENTS" || return 1
	[[ ! -d "$AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR" ]] || return 1
	! grep -q '^start$' "$TEST_EVENTS"
}

main() {
	local test_name output
	for test_name in test_disabled_converges test_disabled_loaded_preserves_timing \
		test_repeat_preserves_timing test_load_noop_bootstraps test_enable_failure \
		test_bootstrap_failure_retry test_bootstrap_noop_fails test_consent_false \
		test_consent_false_cleanup test_stop_wins test_disabled_parser \
		test_failure_does_not_report_enabled test_reconcile_respects_stop; do
		TESTS_RUN=$((TESTS_RUN + 1))
		if output=$(setup_fixture && "$test_name"); then
			printf 'PASS %s\n' "$test_name"
		else
			TESTS_FAILED=$((TESTS_FAILED + 1))
			printf 'FAIL %s\n%s\n' "$test_name" "$output"
		fi
	done
	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
