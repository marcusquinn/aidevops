#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-nostr-vpn-helper.sh - Nostr VPN/FIPS helper smoke coverage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../nostr-vpn-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '  %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d)"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

write_stub_command() {
	local name="$1"
	local body="$2"
	local path="${TEST_ROOT}/${name}"

	cat >"$path" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
${body}
EOF_STUB
	chmod +x "$path"
	return 0
}

run_helper_with_path() {
	PATH="${TEST_ROOT}:$PATH" bash "$HELPER_SCRIPT" "$@"
	return $?
}

test_check_reports_available_required_tools() {
	local output=""
	write_stub_command fips 'printf "fips stub\\n"'
	# shellcheck disable=SC2016 # Intentionally expands inside the generated stub.
	write_stub_command fipsctl 'printf "fipsctl %s\\n" "${1:-}"'

	output="$(run_helper_with_path check 2>&1)"
	if [[ "$output" == *"OK: fips found"* && "$output" == *"OK: fipsctl found"* ]]; then
		print_result "check reports available required tools" 0
		return 0
	fi

	print_result "check reports available required tools" 1 "$output"
	return 0
}

test_status_delegates_to_fipsctl() {
	local output=""
	# shellcheck disable=SC2016 # Intentionally expands inside the generated stub.
	write_stub_command fipsctl 'printf "stub-status:%s:%s\\n" "${1:-}" "${2:-}"'

	output="$(run_helper_with_path status 2>&1)"
	if [[ "$output" == "stub-status:show:status" ]]; then
		print_result "status delegates to fipsctl show status" 0
		return 0
	fi

	print_result "status delegates to fipsctl show status" 1 "$output"
	return 0
}

test_status_propagates_fipsctl_failure() {
	local output=""
	local exit_code=0
	write_stub_command fipsctl 'printf "stub-status-failed\n" >&2; exit 42'

	output="$(run_helper_with_path status 2>&1)" || exit_code=$?
	if [[ "$exit_code" -eq 1 && "$output" == *"stub-status-failed"* && "$output" == *"No FIPS status available"* ]]; then
		print_result "status propagates fipsctl failure" 0
		return 0
	fi

	print_result "status propagates fipsctl failure" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_peers_delegates_to_fipsctl() {
	local output=""
	# shellcheck disable=SC2016 # Intentionally expands inside the generated stub.
	write_stub_command fipsctl 'printf "stub-peers:%s:%s\\n" "${1:-}" "${2:-}"'

	output="$(run_helper_with_path peers 2>&1)"
	if [[ "$output" == "stub-peers:show:peers" ]]; then
		print_result "peers delegates to fipsctl show peers" 0
		return 0
	fi

	print_result "peers delegates to fipsctl show peers" 1 "$output"
	return 0
}

test_secret_guidance_mentions_aidevops_secret() {
	local output=""
	output="$(bash "$HELPER_SCRIPT" secrets-help 2>&1)"

	if [[ "$output" == *"aidevops secret set FIPS_NSEC"* && "$output" == *"aidevops secret set OPENCODE_SERVER_TOKEN"* ]]; then
		print_result "secret guidance uses aidevops secret" 0
		return 0
	fi

	print_result "secret guidance uses aidevops secret" 1 "$output"
	return 0
}

test_firewall_status_suppresses_systemctl_stderr() {
	local output=""
	write_stub_command systemctl 'printf "systemctl transient failure\n" >&2; exit 1'

	output="$(run_helper_with_path firewall-status 2>&1)"
	if [[ "$output" == *"Security baseline"* && "$output" != *"systemctl transient failure"* ]]; then
		print_result "firewall status suppresses systemctl stderr" 0
		return 0
	fi

	print_result "firewall status suppresses systemctl stderr" 1 "$output"
	return 0
}

test_macos_source_mentions_rc1_package_validation() {
	local output=""
	output="$(bash "$HELPER_SCRIPT" macos-source 2>&1)"

	if [[ "$output" == *"v0.4.0-rc1"* && "$output" == *"xar -tf"* && "$output" == *"pkgutil --payload-files"* ]]; then
		print_result "macos source guide mentions rc1 package validation" 0
		return 0
	fi

	print_result "macos source guide mentions rc1 package validation" 1 "$output"
	return 0
}

test_safe_posture_mentions_disable_and_default_open() {
	local output=""
	output="$(bash "$HELPER_SCRIPT" safe-posture 2>&1)"

	if [[ "$output" == *"default-open"* && "$output" == *"launchctl disable"* && "$output" == *"0.0.0.0:8443"* ]]; then
		print_result "safe posture mentions disable and default open" 0
		return 0
	fi

	print_result "safe posture mentions disable and default open" 1 "$output"
	return 0
}

test_opencode_guide_mentions_aidevops_services() {
	local output=""
	output="$(bash "$HELPER_SCRIPT" opencode-guide 2>&1)"

	if [[ "$output" == *"MCP services"* && "$output" == *"Git operations"* && "$output" == *"loopback/FIPS"* ]]; then
		print_result "opencode guide mentions aidevops services" 0
		return 0
	fi

	print_result "opencode guide mentions aidevops services" 1 "$output"
	return 0
}

test_privacy_guide_mentions_limits_and_companions() {
	local output=""
	output="$(bash "$HELPER_SCRIPT" privacy-guide 2>&1)"

	if [[ "$output" == *"not as an anonymity network"* && "$output" == *"SimpleX or Signal"* && "$output" == *"self-hosted or trusted private Nostr relays"* ]]; then
		print_result "privacy guide mentions limits and companions" 0
		return 0
	fi

	print_result "privacy guide mentions limits and companions" 1 "$output"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_check_reports_available_required_tools
	test_status_delegates_to_fipsctl
	test_status_propagates_fipsctl_failure
	test_peers_delegates_to_fipsctl
	test_secret_guidance_mentions_aidevops_secret
	test_firewall_status_suppresses_systemctl_stderr
	test_macos_source_mentions_rc1_package_validation
	test_safe_posture_mentions_disable_and_default_open
	test_opencode_guide_mentions_aidevops_services
	test_privacy_guide_mentions_limits_and_companions

	printf '\nTests run: %d\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %d\n' "$TESTS_FAILED"
		return 1
	fi

	printf 'All tests passed\n'
	return 0
}

main "$@"
