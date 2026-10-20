#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
LOGFILE="$(mktemp -t pulse-stale-open-pr.XXXXXX)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -f "$LOGFILE"
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local passed="$2"
	local details="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -z "$details" ]] || printf '     %s\n' "$details"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# shellcheck source=../pulse-issue-reconcile-stale.sh
source "${SCRIPT_DIR}/pulse-issue-reconcile-stale.sh"

pgrep() {
	return 1
}

aidevops_pulse_worker_log_path() {
	printf '%s\n' "/nonexistent/worker.log"
	return 0
}

test_open_pr_skips_stale_reset() {
	_normalize_stale_find_open_pr() {
		printf '%s\n' '321|ready'
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf 'unexpected-dispatch-read\n' >>"$LOGFILE"
		return 1
	}
	if _normalize_stale_should_skip_reset 42 owner/repo 2000 600 runner-bot &&
		grep -q 'open PR #321' "$LOGFILE" &&
		! grep -q 'unexpected-dispatch-read' "$LOGFILE"; then
		print_result "authoritative open PR blocks stale reset before dispatch inspection" 0
	else
		print_result "authoritative open PR blocks stale reset before dispatch inspection" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_open_pr_lookup_failure_is_fail_closed() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		return 1
	}
	_normalize_stale_get_dispatch_info() {
		printf 'unexpected-dispatch-read\n' >>"$LOGFILE"
		return 1
	}
	if _normalize_stale_should_skip_reset 43 owner/repo 2000 600 runner-bot &&
		grep -q 'open-PR lookup fail-closed' "$LOGFILE" &&
		! grep -q 'unexpected-dispatch-read' "$LOGFILE"; then
		print_result "indeterminate open PR evidence fails closed" 0
	else
		print_result "indeterminate open PR evidence fails closed" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_confirmed_absence_allows_stale_evaluation() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '\n\n\n'
		return 0
	}
	if _normalize_stale_should_skip_reset 44 owner/repo 2000 600 runner-bot; then
		print_result "confirmed open PR absence continues stale evaluation" 1 "unexpected skip"
	else
		print_result "confirmed open PR absence continues stale evaluation" 0
	fi
	return 0
}

# GH#35218: one runner login on several devices. A recent dispatch from
# another device must not be judged by this device's PID table or logs.
test_same_login_other_device_is_cross_runner() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '%s\n%s\n%s\n%s\n' 4242 1970-01-01T00:16:40Z runner-bot device-remote
		return 0
	}
	ps() { return 1; }
	if AIDEVOPS_DEVICE_ID=device-local _normalize_stale_should_skip_reset 45 owner/repo 2000 10800 runner-bot &&
		grep -q 'cross-runner guard' "$LOGFILE"; then
		print_result "same-login dispatch on another device keeps its claim" 0
	else
		print_result "same-login dispatch on another device keeps its claim" 1 "$(<"$LOGFILE")"
	fi
	unset -f ps
	return 0
}

test_same_login_same_device_dead_pid_resets() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '%s\n%s\n%s\n%s\n' 4242 1970-01-01T00:16:40Z runner-bot device-local
		return 0
	}
	ps() { return 1; }
	if AIDEVOPS_DEVICE_ID=device-local _normalize_stale_should_skip_reset 46 owner/repo 2000 10800 runner-bot; then
		print_result "same-device dispatch with a dead PID still resets" 1 "$(<"$LOGFILE")"
	else
		print_result "same-device dispatch with a dead PID still resets" 0
	fi
	unset -f ps
	return 0
}

test_open_pr_skips_stale_reset
test_open_pr_lookup_failure_is_fail_closed
test_confirmed_absence_allows_stale_evaluation
test_same_login_other_device_is_cross_runner
test_same_login_same_device_dead_pid_resets

printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
