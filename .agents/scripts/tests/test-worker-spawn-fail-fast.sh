#!/usr/bin/env bash
# shellcheck disable=SC2218  # Functions defined via dynamic source
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-spawn-fail-fast.sh — GH#36390 regression guard.
#
# A worker spawn that never submits must fail the launch immediately instead
# of returning an empty PID that launch validation later records as
# no_worker_process (supervisor breaker trip GH#36389). The real
# _dlw_spawn_worker_or_fail runs; only the backend (_dlw_exec_detached) and
# circuit-breaker-helper.sh are stubbed.
#
# Asserts:
#   1. backend fails before any unit is submitted: rc 1, lifecycle line,
#      supervisor breaker records worker_spawn_failed
#   2. backend returns 0 without a numeric PID: rc 1 and breaker record
#   3. unit submitted but readiness unconfirmed: rc 0, empty PID, no record
#      (launch validation keeps deciding; avoids duplicate workers)
#   4. a stale sidecar from an earlier attempt does not mask a new failure
#   5. success prints the PID

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[[ -z "${2:-}" ]] || printf '       %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t gh36390.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export AIDEVOPS_TEMP_DIR="${TMP}/agent-tmp"
mkdir -p "$AIDEVOPS_TEMP_DIR"
export LOGFILE="${TMP}/pulse.log"
export SCRIPT_DIR="$TMP"
CB_CALLS="${TMP}/cb-calls.txt"

set +e
unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"
SCRIPT_DIR="$TMP"

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$CB_CALLS" >"${TMP}/circuit-breaker-helper.sh"
chmod +x "${TMP}/circuit-breaker-helper.sh"

# --- Backend stub (defined after sourcing so it replaces the real spawn) ---
STUB_MODE=""
_dlw_exec_detached() {
	local worker_log="$1"
	case "$STUB_MODE" in
	presubmit_fail) return 1 ;;
	empty_success) return 0 ;;
	submitted_unconfirmed)
		printf 'LaunchState=submitting\n' >"${worker_log}.systemd-launch"
		return 1
		;;
	ok)
		printf '4242\n'
		return 0
		;;
	esac
	return 1
}

# Args: stub mode, stale sidecar (0|1). Sets RUN_RC, RUN_OUT, RUN_CB, RUN_LOG.
run_spawn() {
	local mode="$1" stale="$2"
	STUB_MODE="$mode"
	RUN_LOG="${TMP}/${mode}-${stale}.log"
	: >"$RUN_LOG"
	rm -f "$CB_CALLS" "${RUN_LOG}.systemd-launch"
	[[ "$stale" -eq 0 ]] || printf 'stale\n' >"${RUN_LOG}.systemd-launch"
	RUN_RC=0
	RUN_OUT=$(_dlw_spawn_worker_or_fail 36390 owner/repo "$RUN_LOG" attempt-test env true) || RUN_RC=$?
	RUN_CB=""
	[[ ! -f "$CB_CALLS" ]] || RUN_CB=$(<"$CB_CALLS")
	return 0
}

printf '\n%s\n' "=== GH#36390: worker spawn fail-fast ==="

run_spawn presubmit_fail 0
if [[ "$RUN_RC" -eq 1 && -z "$RUN_OUT" && "$RUN_CB" == "record-failure owner/repo#36390 worker_spawn_failed" ]] &&
	grep -q 'worker_spawn_failed backend_rc=1 unit_submitted=no' "$RUN_LOG"; then
	pass "pre-submit spawn failure fails fast and records worker_spawn_failed"
else
	fail "pre-submit spawn failure fails fast and records worker_spawn_failed" \
		"rc=$RUN_RC out='$RUN_OUT' cb='$RUN_CB'"
fi

run_spawn empty_success 0
if [[ "$RUN_RC" -eq 1 && -z "$RUN_OUT" && -n "$RUN_CB" ]]; then
	pass "rc 0 without a numeric PID is a spawn failure"
else
	fail "rc 0 without a numeric PID is a spawn failure" "rc=$RUN_RC out='$RUN_OUT' cb='$RUN_CB'"
fi

run_spawn submitted_unconfirmed 0
if [[ "$RUN_RC" -eq 0 && -z "$RUN_OUT" && -z "$RUN_CB" ]]; then
	pass "submitted unit with unconfirmed readiness defers to launch validation"
else
	fail "submitted unit with unconfirmed readiness defers to launch validation" \
		"rc=$RUN_RC out='$RUN_OUT' cb='$RUN_CB'"
fi

run_spawn presubmit_fail 1
if [[ "$RUN_RC" -eq 1 && -n "$RUN_CB" ]]; then
	pass "stale sidecar from an earlier attempt does not mask a new failure"
else
	fail "stale sidecar from an earlier attempt does not mask a new failure" "rc=$RUN_RC cb='$RUN_CB'"
fi

run_spawn ok 1
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" == "4242" && -z "$RUN_CB" ]]; then
	pass "successful spawn prints the worker PID"
else
	fail "successful spawn prints the worker PID" "rc=$RUN_RC out='$RUN_OUT' cb='$RUN_CB'"
fi

printf '\n%s\n' "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ---"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
