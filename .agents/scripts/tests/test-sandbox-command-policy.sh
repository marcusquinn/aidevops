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
ARGS_LOG="${TEST_ROOT}/args.json"
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
python3 - "\$@" >"${ARGS_LOG}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
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
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","https://github.com/aidevops"]' --worker-id test >/dev/null 2>&1; then
		pass "network check-argv allows Tier 1"
	else
		fail "network check-argv allows Tier 1"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--url","HTTPS://requestbin.com/collect"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks Tier 5"
	else
		pass "network check-argv blocks Tier 5"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--proxy","https://requestbin.com","--url","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks proxy destination"
	else
		pass "network check-argv blocks proxy destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--connect-to","github.com:443:requestbin.com:443","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks connect-to destination"
	else
		pass "network check-argv blocks connect-to destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["curl","--silent"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed without destination"
	else
		pass "network check-argv fails closed without destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["wget","HTTPS://requestbin.com/file"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks wget Tier 5 destination"
	else
		pass "network check-argv blocks wget Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["wget","-e","https_proxy=https://requestbin.com","https://github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks wget proxy override"
	else
		pass "network check-argv blocks wget proxy override"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-p22","user@requestbin.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks ssh Tier 5 destination"
	else
		pass "network check-argv blocks ssh Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["scp","file.txt","user@requestbin.com:/tmp/file.txt"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks scp Tier 5 destination"
	else
		pass "network check-argv blocks scp Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["git","clone","HTTPS://requestbin.com/repo.git"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks git Tier 5 destination"
	else
		pass "network check-argv blocks git Tier 5 destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-V"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on unclassified ssh destination"
	else
		pass "network check-argv fails closed on unclassified ssh destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-F","custom.conf","github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on hidden ssh config"
	else
		pass "network check-argv fails closed on hidden ssh config"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["ssh","-W","requestbin.com:443","github.com"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv blocks ssh forwarding destination"
	else
		pass "network check-argv blocks ssh forwarding destination"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["git","-c","http.proxy=https://requestbin.com","fetch","https://github.com/repo.git"]' --worker-id test >/dev/null 2>&1; then
		fail "network check-argv fails closed on Git proxy override"
	else
		pass "network check-argv fails closed on Git proxy override"
	fi
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-argv '["printf","curl https://requestbin.com"]' --worker-id test >/dev/null 2>&1; then
		pass "network check-argv ignores printf text"
	else
		fail "network check-argv ignores printf text"
	fi
	# Shell-string compatibility must reject dynamic expansion before execution.
	# shellcheck disable=SC2016
	if HOME="$TEST_HOME" "$NETWORK_HELPER" check-command 'dig $(printf data).example.com' --worker-id test >/dev/null 2>&1; then
		fail "network check-command rejects dynamic DNS destination"
	else
		pass "network check-command rejects dynamic DNS destination"
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
	rm -f "$ARGS_LOG"
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run curl "https://github.com/a path" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 0 && -e "$MARKER" && "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])) == ["https://github.com/a path"])' "$ARGS_LOG")" == "True" ]]; then
		pass "sandbox preserves exact argv for allowed network command"
	else
		fail "sandbox preserves exact argv for allowed network command" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
	fi

	status=0
	reset_marker
	HOME="$TEST_HOME" PATH="${TEST_BIN}:$PATH" "$SANDBOX_HELPER" run bash -lc "rm -rf /opt/aidevops-policy-test-nonexistent" >/dev/null 2>&1 || status=$?
	if [[ "$status" -eq 126 && ! -e "$MARKER" ]]; then
		pass "sandbox inspects combined shell flags before execution"
	else
		fail "sandbox inspects combined shell flags before execution" "status=${status} marker=$([[ -e "$MARKER" ]] && printf yes || printf no)"
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
