#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_LIB="$SCRIPT_DIR/../aidevops-cli/aidevops-status-lib.sh"
TEST_ROOT="$(mktemp -d -t aidevops-status-runtime-parity.XXXXXX)"
AGENTS_DIR="$TEST_ROOT/agents"
GENERATOR="$AGENTS_DIR/scripts/generate-runtime-config.sh"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_header() {
	local text="$1"
	printf 'HEADER: %s\n' "$text"
	return 0
}
print_success() {
	local text="$1"
	printf 'SUCCESS: %s\n' "$text"
	return 0
}
print_warning() {
	local text="$1"
	printf 'WARNING: %s\n' "$text"
	return 0
}
print_info() {
	local text="$1"
	printf 'INFO: %s\n' "$text"
	return 0
}
check_cmd() {
	local command_name="$1"
	if [[ "$command_name" == "opencode" ]]; then
		return 0
	fi
	return 1
}

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$STATUS_LIB"
mkdir -p "$(dirname "$GENERATOR")"

printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$GENERATOR"
chmod +x "$GENERATOR"
output=$(_status_runtime_config_parity)
if [[ "$output" != *"OpenCode runtime configuration is stale or incomplete"* ]] ||
	[[ "$output" != *"aidevops setup --scope runtime-config"* ]]; then
	printf 'FAIL: stale runtime status was not actionable: %s\n' "$output" >&2
	exit 1
fi

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$GENERATOR"
output=$(_status_runtime_config_parity)
if [[ "$output" != *"OpenCode runtime configuration matches installed aidevops sources"* ]]; then
	printf 'FAIL: synchronized runtime status was not reported: %s\n' "$output" >&2
	exit 1
fi

printf '%s\n' 'PASS: status reports runtime command drift and remediation'
exit 0
