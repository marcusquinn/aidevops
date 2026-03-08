#!/usr/bin/env bash
# shellcheck disable=SC2034

# =============================================================================
# Test Script for matterbridge-helper.sh
# =============================================================================
# Tests helper script functions without requiring Docker or Matterbridge binary.
# Focuses on: argument parsing, file discovery, init logic, help output.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../matterbridge-helper.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp dir for test isolation
TEST_DIR=""

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

#######################################
# Setup test environment
# Returns:
#   0 on success
#######################################
setup() {
	TEST_DIR="$(mktemp -d)"
	export HOME="$TEST_DIR"
	export MATTERBRIDGE_CONFIG="$TEST_DIR/matterbridge.toml"
	export SIMPLEX_COMPOSE_FILE=""
	export AGENTS_DIR="$SCRIPT_DIR/../.."
	mkdir -p "$TEST_DIR/.aidevops/.agent-workspace/matterbridge"
	return 0
}

#######################################
# Teardown test environment
# Returns:
#   0 on success
#######################################
teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_help_output() {
	local output
	output="$(bash "$HELPER" help 2>&1)" || true

	if echo "$output" | grep -q "matterbridge-helper.sh"; then
		print_result "help: shows usage header" 0
	else
		print_result "help: shows usage header" 1 "Expected 'matterbridge-helper.sh' in output"
	fi

	if echo "$output" | grep -q "simplex-bridge"; then
		print_result "help: lists simplex-bridge command" 0
	else
		print_result "help: lists simplex-bridge command" 1 "Expected 'simplex-bridge' in help output"
	fi

	return 0
}

test_simplex_bridge_help() {
	local output
	output="$(bash "$HELPER" simplex-bridge help 2>&1)" || true

	if echo "$output" | grep -q "simplex-bridge"; then
		print_result "simplex-bridge help: shows subcommand help" 0
	else
		print_result "simplex-bridge help: shows subcommand help" 1 "Expected 'simplex-bridge' in output"
	fi

	if echo "$output" | grep -q "SIMPLEX_CHAT_ID"; then
		print_result "simplex-bridge help: documents env vars" 0
	else
		print_result "simplex-bridge help: documents env vars" 1 "Expected 'SIMPLEX_CHAT_ID' in output"
	fi

	return 0
}

test_simplex_bridge_init() {
	setup

	local output
	output="$(bash "$HELPER" simplex-bridge init 2>&1)" || true

	# Check compose file was copied
	local compose_path="$TEST_DIR/.aidevops/.agent-workspace/matterbridge/simplex-bridge/docker-compose.yml"
	if [[ -f "$compose_path" ]]; then
		print_result "simplex-bridge init: creates compose file" 0
	else
		print_result "simplex-bridge init: creates compose file" 1 "Expected $compose_path to exist"
	fi

	# Check config template was copied
	local config_path="$TEST_DIR/.aidevops/.agent-workspace/matterbridge/simplex-bridge/matterbridge.toml"
	if [[ -f "$config_path" ]]; then
		print_result "simplex-bridge init: creates config template" 0
	else
		print_result "simplex-bridge init: creates config template" 1 "Expected $config_path to exist"
	fi

	# Check config permissions
	if [[ -f "$config_path" ]]; then
		local perms
		# stat -c '%a' is Linux; stat -f '%Lp' is macOS
		perms="$(stat -c '%a' "$config_path" 2>/dev/null || stat -f '%Lp' "$config_path" 2>/dev/null || echo "unknown")"
		if [[ "$perms" == "600" ]]; then
			print_result "simplex-bridge init: config has 600 permissions" 0
		else
			print_result "simplex-bridge init: config has 600 permissions" 1 "Got permissions: $perms"
		fi
	fi

	# Check data directory was created
	local data_dir="$TEST_DIR/.aidevops/.agent-workspace/matterbridge/simplex-bridge/data/simplex"
	if [[ -d "$data_dir" ]]; then
		print_result "simplex-bridge init: creates data/simplex directory" 0
	else
		print_result "simplex-bridge init: creates data/simplex directory" 1 "Expected $data_dir to exist"
	fi

	# Check output includes next steps
	if echo "$output" | grep -q "Next steps"; then
		print_result "simplex-bridge init: shows next steps" 0
	else
		print_result "simplex-bridge init: shows next steps" 1 "Expected 'Next steps' in output"
	fi

	teardown
	return 0
}

test_simplex_bridge_status_no_docker() {
	setup

	# Status should work even without Docker (graceful degradation)
	local output
	output="$(bash "$HELPER" simplex-bridge status 2>&1)" || true

	if echo "$output" | grep -q "matterbridge"; then
		print_result "simplex-bridge status: runs without Docker" 0
	else
		print_result "simplex-bridge status: runs without Docker" 1 "Expected some output"
	fi

	teardown
	return 0
}

test_unknown_command() {
	local output exit_code
	output="$(bash "$HELPER" nonexistent 2>&1)" && exit_code=0 || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "unknown command: returns non-zero exit" 0
	else
		print_result "unknown command: returns non-zero exit" 1 "Expected non-zero exit code"
	fi

	return 0
}

test_unknown_simplex_bridge_action() {
	local output exit_code
	output="$(bash "$HELPER" simplex-bridge nonexistent 2>&1)" && exit_code=0 || exit_code=$?

	if [[ "$exit_code" -ne 0 ]]; then
		print_result "unknown simplex-bridge action: returns non-zero exit" 0
	else
		print_result "unknown simplex-bridge action: returns non-zero exit" 1 "Expected non-zero exit code"
	fi

	return 0
}

test_compose_template_valid_yaml() {
	local compose_file="$SCRIPT_DIR/../../configs/matterbridge-simplex-compose.yml"

	if [[ ! -f "$compose_file" ]]; then
		print_result "compose template: file exists" 1 "Not found: $compose_file"
		return 0
	fi

	print_result "compose template: file exists" 0

	# Check for required services
	if grep -q 'simplex:' "$compose_file"; then
		print_result "compose template: has simplex service" 0
	else
		print_result "compose template: has simplex service" 1
	fi

	if grep -q 'matterbridge:' "$compose_file"; then
		print_result "compose template: has matterbridge service" 0
	else
		print_result "compose template: has matterbridge service" 1
	fi

	if grep -q 'node-app:' "$compose_file"; then
		print_result "compose template: has node-app service" 0
	else
		print_result "compose template: has node-app service" 1
	fi

	# Check for SIMPLEX_CHAT_ID variable
	if grep -q 'SIMPLEX_CHAT_ID' "$compose_file"; then
		print_result "compose template: uses SIMPLEX_CHAT_ID env var" 0
	else
		print_result "compose template: uses SIMPLEX_CHAT_ID env var" 1
	fi

	return 0
}

test_config_template_valid() {
	local config_file="$SCRIPT_DIR/../../configs/matterbridge-simplex.toml.example"

	if [[ ! -f "$config_file" ]]; then
		print_result "config template: file exists" 1 "Not found: $config_file"
		return 0
	fi

	print_result "config template: file exists" 0

	# Check for API section (required for matterbridge-simplex)
	if grep -q '\[api\]' "$config_file"; then
		print_result "config template: has [api] section" 0
	else
		print_result "config template: has [api] section" 1
	fi

	# Check for gateway section
	if grep -q '\[\[gateway\]\]' "$config_file"; then
		print_result "config template: has [[gateway]] section" 0
	else
		print_result "config template: has [[gateway]] section" 1
	fi

	# Check for BindAddress on localhost (security)
	if grep -q '127.0.0.1' "$config_file"; then
		print_result "config template: API binds to localhost" 0
	else
		print_result "config template: API binds to localhost" 1 "API should bind to 127.0.0.1 for security"
	fi

	return 0
}

test_script_shellcheck() {
	if ! command -v shellcheck >/dev/null 2>&1; then
		print_result "shellcheck: installed" 1 "shellcheck not found"
		return 0
	fi

	print_result "shellcheck: installed" 0

	local output exit_code
	output="$(shellcheck "$HELPER" 2>&1)" && exit_code=0 || exit_code=$?

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "shellcheck: matterbridge-helper.sh passes" 0
	else
		print_result "shellcheck: matterbridge-helper.sh passes" 1 "$output"
	fi

	return 0
}

# =============================================================================
# Runner
# =============================================================================

main() {
	echo "=== matterbridge-helper.sh tests ==="
	echo ""

	test_help_output
	test_simplex_bridge_help
	test_simplex_bridge_init
	test_simplex_bridge_status_no_docker
	test_unknown_command
	test_unknown_simplex_bridge_action
	test_compose_template_valid_yaml
	test_config_template_valid
	test_script_shellcheck

	echo ""
	echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
