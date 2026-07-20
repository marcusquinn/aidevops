#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

_TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TEST_REPO_ROOT="$(cd "${_TEST_SCRIPT_DIR}/../../.." && pwd)"
_TEST_TARGET="${_TEST_REPO_ROOT}/.agents/scripts/pulse-session-helper.sh"
_TEST_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pulse-session-last-run.XXXXXX")
export HOME="${_TEST_TMP_DIR}/home"
mkdir -p "${HOME}/.aidevops/logs"

_cleanup() {
	rm -rf "$_TEST_TMP_DIR"
	return 0
}
trap _cleanup EXIT

# Load functions without invoking the CLI. The helper derives all readonly
# paths from the isolated HOME above.
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$_TEST_TARGET")

_TESTS_RUN=0
_TESTS_FAILED=0

_assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf 'ok %d - %s\n' "$_TESTS_RUN" "$name"
		return 0
	fi
	_TESTS_FAILED=$((_TESTS_FAILED + 1))
	printf 'not ok %d - %s (expected %q, got %q)\n' "$_TESTS_RUN" "$name" "$expected" "$actual"
	return 0
}

_reset_sources() {
	rm -f "$WRAPPER_LAST_RUN_FILE" "$WRAPPER_LOGFILE" "$LOGFILE"
	return 0
}

_test_marker_precedes_optional_cycle_log() {
	_reset_sources
	printf '%s\n' "1704067200" >"$WRAPPER_LAST_RUN_FILE"
	printf '%s\n' '[pulse] Starting pulse at 2023-01-01T00:00:00Z' >"$WRAPPER_LOGFILE"
	_assert_equal "2024-01-01T00:00:00Z" "$(get_last_pulse_time)" \
		"deterministic wrapper marker wins over optional LLM-cycle log"
	return 0
}

_test_log_fallbacks() {
	_reset_sources
	printf '%s\n' "invalid" >"$WRAPPER_LAST_RUN_FILE"
	printf '%s\n' '[pulse] Starting pulse at 2025-02-03T04:05:06Z' >"$WRAPPER_LOGFILE"
	_assert_equal "2025-02-03T04:05:06Z" "$(get_last_pulse_time)" \
		"malformed marker falls back to wrapper log"

	_reset_sources
	printf '%s\n' '[pulse] Starting pulse at 2025-03-04T05:06:07Z' >"$LOGFILE"
	_assert_equal "2025-03-04T05:06:07Z" "$(get_last_pulse_time)" \
		"legacy pulse log remains a final fallback"

	_reset_sources
	_assert_equal "never" "$(get_last_pulse_time)" "missing marker and logs report never"
	return 0
}

_test_portable_date_fallback() {
	date() {
		local first="${1:-}"
		local second="${2:-}"
		if [[ "$first" == "-u" && "$second" == "-d" ]]; then
			return 1
		fi
		if [[ "$first" == "-u" && "$second" == "-r" ]]; then
			printf '%s\n' "2024-01-01T00:00:00Z"
			return 0
		fi
		return 1
	}
	_assert_equal "2024-01-01T00:00:00Z" "$(_pulse_epoch_to_iso 1704067200)" \
		"BSD date fallback converts the wrapper epoch"
	unset -f date
	return 0
}

_test_status_summary_uses_marker() {
	_reset_sources
	printf '%s\n' "1704067200" >"$WRAPPER_LAST_RUN_FILE"
	get_pulse_repo_count() {
		printf '%s\n' "0"
		return 0
	}
	local output
	output=$(_status_print_workers_summary 0)
	if [[ "$output" == *"Last pulse:  2024-01-01T00:00:00Z"* ]]; then
		_assert_equal "present" "present" "status displays deterministic wrapper timestamp"
	else
		_assert_equal "present" "missing" "status displays deterministic wrapper timestamp"
	fi
	return 0
}

main() {
	_test_marker_precedes_optional_cycle_log
	_test_log_fallbacks
	_test_portable_date_fallback
	_test_status_summary_uses_marker
	printf '1..%d\n' "$_TESTS_RUN"
	[[ "$_TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
