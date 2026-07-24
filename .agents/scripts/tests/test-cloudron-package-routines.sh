#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CORE_ROUTINES="${SCRIPT_DIR}/../routines/core-routines.sh"
PASSED=0
FAILED=0

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (missing=%s)\n' "$description" "$needle" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (unexpected=%s)\n' "$description" "$needle" >&2
	FAILED=$((FAILED + 1))
	return 0
}

main() {
	# shellcheck source=../routines/core-routines.sh
	source "$CORE_ROUTINES"
	local entries=""
	entries=$(get_core_routine_entries)
	assert_contains "$entries" 'r916|x|Cloudron packages — check upstream releases|repeat:daily(@07:10)|~2m|scripts/cloudron-package-monitor-helper.sh upstream --apply|script' "daily upstream routine registered"
	assert_contains "$entries" 'r917|x|Cloudron packages — audit compatibility|repeat:weekly(sun@07:40)|~5m|scripts/cloudron-package-monitor-helper.sh compatibility --apply|script' "weekly compatibility routine registered"
	local r916_description=""
	local r917_description=""
	r916_description=$(describe_r916 linux)
	r917_description=$(describe_r917 linux)
	assert_contains "$r916_description" 'cloudron-package-monitor-helper.sh upstream --apply' "r916 description exposes exact command"
	assert_contains "$r917_description" 'cloudron-package-monitor-helper.sh compatibility --apply' "r917 description exposes exact command"
	# shellcheck disable=SC2016  # Markdown backticks are literal expected output.
	assert_contains "$r916_description" 'Supervisor Pulse evaluates version-controlled `repeat:daily(@07:10)`' "r916 names Pulse as scheduler"
	# shellcheck disable=SC2016  # Markdown backticks are literal expected output.
	assert_contains "$r917_description" 'Supervisor Pulse evaluates version-controlled `repeat:weekly(sun@07:40)`' "r917 names Pulse as scheduler"
	assert_contains "$r916_description" 'systemctl --user status sh.aidevops.pulse' "r916 exposes shared Pulse diagnostics"
	assert_not_contains "$r916_description" 'sh.aidevops.cloudron-package-upstream' "r916 omits fictional dedicated service"
	assert_not_contains "$r917_description" 'sh.aidevops.cloudron-package-compatibility' "r917 omits fictional dedicated service"
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
