#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SANDBOX_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"

# shellcheck source=../sandbox-exec-helper.sh
source "$SANDBOX_HELPER"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

resolve_timeout() {
	local requested="$1"
	local timeout_secs="$SANDBOX_DEFAULT_TIMEOUT"
	local block_network=false
	local network_tiering=true
	local allow_secret_io=false
	local worker_id="timeout-test"
	local extra_passthrough=""
	local stream_stdout=false
	local private_output=false
	local egress_mode="off"
	local -a cmd_args=()

	_sandbox_run_parse_args --timeout "$requested" -- true 2>/dev/null
	printf '%s' "$timeout_secs"
	return 0
}

test_timeout_constants() {
	if [[ "$SANDBOX_DEFAULT_TIMEOUT" == "120" && "$SANDBOX_MAX_TIMEOUT" == "21600" ]]; then
		pass "direct sandbox default stays short while the safety ceiling is six hours"
		return 0
	fi

	fail "direct sandbox default stays short while the safety ceiling is six hours" \
		"default=$SANDBOX_DEFAULT_TIMEOUT max=$SANDBOX_MAX_TIMEOUT"
	return 0
}

test_timeout_parser_preserves_checkpoint_safe_override() {
	local resolved=""
	resolved="$(resolve_timeout 10800)"
	if [[ "$resolved" == "10800" ]]; then
		pass "sandbox preserves explicit timeout above the former one-hour ceiling"
		return 0
	fi

	fail "sandbox preserves explicit timeout above the former one-hour ceiling" "resolved=$resolved"
	return 0
}

test_timeout_parser_caps_at_six_hours() {
	local resolved=""
	resolved="$(resolve_timeout 86400)"
	if [[ "$resolved" == "21600" ]]; then
		pass "sandbox caps explicit timeout at six hours"
		return 0
	fi

	fail "sandbox caps explicit timeout at six hours" "resolved=$resolved"
	return 0
}

test_timeout_help_and_config_match_constants() {
	local config_output=""
	local help_output=""
	config_output="$(sandbox_config)"
	help_output="$(sandbox_help)"
	if [[ "$config_output" == *"Timeout:      120s (max 21600s)"* &&
		"$help_output" == *"Timeout in seconds (default: 120s, max: 21600s)"* ]]; then
		pass "sandbox config and help report the active timeout budget"
		return 0
	fi

	fail "sandbox config and help report the active timeout budget" \
		"config/help output did not contain default=120s max=21600s"
	return 0
}

main() {
	test_timeout_constants
	test_timeout_parser_preserves_checkpoint_safe_override
	test_timeout_parser_caps_at_six_hours
	test_timeout_help_and_config_match_constants

	printf '\nTests: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if ((TESTS_FAILED > 0)); then
		return 1
	fi
	return 0
}

main "$@"
