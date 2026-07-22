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

main() {
	# shellcheck source=../routines/core-routines.sh
	source "$CORE_ROUTINES"
	local entries=""
	entries=$(get_core_routine_entries)
	assert_contains "$entries" 'r916|x|Cloudron packages — check upstream releases|repeat:daily(@07:10)|~2m|scripts/cloudron-package-monitor-helper.sh upstream --apply|script' "daily upstream routine registered"
	assert_contains "$entries" 'r917|x|Cloudron packages — audit compatibility|repeat:weekly(sun@07:40)|~5m|scripts/cloudron-package-monitor-helper.sh compatibility --apply|script' "weekly compatibility routine registered"
	declare -F describe_r916 >/dev/null 2>&1 && assert_contains "$(describe_r916 linux)" 'cloudron-package-monitor-helper.sh upstream --apply' "r916 description exposes exact command"
	declare -F describe_r917 >/dev/null 2>&1 && assert_contains "$(describe_r917 linux)" 'cloudron-package-monitor-helper.sh compatibility --apply' "r917 description exposes exact command"
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
