#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1090
#
# Regression test: GH#18702 — init-routines-helper.sh must not fail with
# `readonly variable` when sourced from a shell where shared-constants.sh
# has already been sourced (which declares RED/GREEN/YELLOW/BLUE/NC as
# readonly). Before the fix, setup.sh was being killed by this collision,
# blocking auto-update deploys since 2026-04-09 and causing the 18693/18702
# stale-recovery cascade.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_SCRIPTS="${SCRIPT_DIR}/.."
SHARED_CONSTANTS="${REPO_SCRIPTS}/shared-constants.sh"
INIT_ROUTINES="${REPO_SCRIPTS}/init-routines-helper.sh"
COMMON_HELPER="${REPO_SCRIPTS}/setup/_common.sh"
ROUTINES_MODULE="${REPO_SCRIPTS}/setup/_routines.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# The original bug: setup.sh sources shared-constants.sh (readonly colors),
# then sources _routines.sh which sources init-routines-helper.sh. The helper
# previously did unconditional `GREEN='\033[0;32m'` which failed under
# `set -Eeuo pipefail` and killed the whole setup.sh run.
test_init_routines_sources_after_shared_constants() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${SHARED_CONSTANTS}'
			source '${INIT_ROUTINES}'
			echo 'INIT_OK'
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && "$output" == *"INIT_OK"* ]]; then
		print_result "init-routines-helper.sh sources cleanly after shared-constants.sh (GH#18702)" 0
		return 0
	fi

	print_result "init-routines-helper.sh sources cleanly after shared-constants.sh (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

# Belt-and-braces: _common.sh should also tolerate pre-existing readonly colors,
# so reordering the setup.sh sourcing sequence can't regress the bug.
test_common_tolerates_readonly_colors() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${SHARED_CONSTANTS}'
			source '${COMMON_HELPER}'
			echo 'COMMON_OK'
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && "$output" == *"COMMON_OK"* ]]; then
		print_result "setup/_common.sh tolerates pre-existing readonly colors (GH#18702)" 0
		return 0
	fi

	print_result "setup/_common.sh tolerates pre-existing readonly colors (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

# End-to-end defensive check: _routines.sh's _load_init_routines_helper must
# isolate errors so any future helper-level failure cannot propagate and
# kill setup.sh. This is the second line of defense from GH#18702.
test_routines_loader_isolates_errors() {
	local output=""
	local exit_code=0

	output=$(
		bash -c "
			set -Eeuo pipefail
			source '${COMMON_HELPER}'
			source '${SHARED_CONSTANTS}'
			source '${ROUTINES_MODULE}'
			if _load_init_routines_helper; then
				echo 'LOADER_OK'
			else
				echo 'LOADER_FAILED_BUT_DID_NOT_KILL_SETUP'
			fi
		" 2>&1
	) || exit_code=$?

	if [[ "$exit_code" -eq 0 && ("$output" == *"LOADER_OK"* || "$output" == *"LOADER_FAILED_BUT_DID_NOT_KILL_SETUP"*) ]]; then
		print_result "_load_init_routines_helper isolates source errors (GH#18702)" 0
		return 0
	fi

	print_result "_load_init_routines_helper isolates source errors (GH#18702)" 1 \
		"exit=${exit_code} output=${output}"
	return 0
}

main() {
	test_init_routines_sources_after_shared_constants
	test_common_tolerates_readonly_colors
	test_routines_loader_isolates_errors

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
