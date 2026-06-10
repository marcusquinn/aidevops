#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for aidevops status headless runtime configuration warnings.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
STATUS_LIB="${SCRIPT_DIR}/../aidevops-cli/aidevops-status-lib.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

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

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		printf '%bPASS%b %s\n' "$GREEN" "$NC" "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%bFAIL%b %s — %s\n' "$RED" "$NC" "$name" "$detail"
	fi
	return 0
}

run_status_check() {
	local credentials_file="$1"
	AIDEVOPS_CREDENTIALS_FILE="$credentials_file" _status_headless_runtime_config
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$STATUS_LIB"

TMP_DIR=$(mktemp -d -t aidevops-status-env.XXXXXX) || exit 1
trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"' EXIT

missing_credentials="${TMP_DIR}/missing-credentials.sh"
configured_credentials="${TMP_DIR}/credentials.sh"
config_dir="${TMP_DIR}/config"
mkdir -p "$config_dir"
printf '%s\n' 'export AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="anthropic"' >"$configured_credentials"
printf '%s\n' 'export AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"' >"${config_dir}/credentials.sh"

AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="anthropic" output=$(run_status_check "$missing_credentials" 2>&1)
if printf '%s' "$output" | grep -q 'only set in this shell' && printf '%s' "$output" | grep -q 'credentials.sh'; then
	print_result "warns when allowlist is shell-only" 0
else
	print_result "warns when allowlist is shell-only" 1 "$output"
fi

AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="anthropic" output=$(run_status_check "$configured_credentials" 2>&1)
if printf '%s' "$output" | grep -q 'configured in credentials.sh' && ! printf '%s' "$output" | grep -q 'only set in this shell'; then
	print_result "accepts daemon-visible allowlist with shell env" 0
else
	print_result "accepts daemon-visible allowlist with shell env" 1 "$output"
fi

unset AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST
output=$(run_status_check "$configured_credentials" 2>&1)
if printf '%s' "$output" | grep -q 'configured in credentials.sh'; then
	print_result "accepts daemon-visible allowlist without shell env" 0
else
	print_result "accepts daemon-visible allowlist without shell env" 1 "$output"
fi

unset AIDEVOPS_CREDENTIALS_FILE
CONFIG_DIR="$config_dir" output=$(_status_headless_runtime_config 2>&1)
if printf '%s' "$output" | grep -q 'configured in credentials.sh'; then
	print_result "uses CONFIG_DIR credentials fallback" 0
else
	print_result "uses CONFIG_DIR credentials fallback" 1 "$output"
fi

output=$(run_status_check "$missing_credentials" 2>&1)
if printf '%s' "$output" | grep -q 'No headless provider allowlist configured'; then
	print_result "reports no allowlist when neither source is set" 0
else
	print_result "reports no allowlist when neither source is set" 1 "$output"
fi

printf '\nTests: %d run, %d passed, %d failed\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
