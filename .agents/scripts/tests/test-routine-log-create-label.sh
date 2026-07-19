#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#28213: routine-log-helper.sh owns the
# routine-tracking label invariant instead of relying on its callers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROUTINE_LOG_HELPER="${SCRIPT_DIR}/../routine-log-helper.sh"
TEST_ROOT="$(mktemp -d)"
CREATE_LOG="${TEST_ROOT}/create.log"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# Load the helper functions without creating an issue.
# shellcheck source=/dev/null
source "$ROUTINE_LOG_HELPER" help >/dev/null

gh_create_issue() {
	printf '%s\n' "$*" >"$CREATE_LOG"
	printf '%s\n' "https://github.com/example/routines/issues/4242"
	return 0
}

issue_number=$(_create_github_issue "example/routines" "r999: Test" "body")
create_args=$(<"$CREATE_LOG")

if [[ "$issue_number" != "4242" ]]; then
	printf 'FAIL routine issue number extraction: expected 4242, got %s\n' "$issue_number" >&2
	exit 1
fi

if [[ "$create_args" != *"--label routines"* ]]; then
	printf 'FAIL routine issue creation omitted routines label: %s\n' "$create_args" >&2
	exit 1
fi

if [[ "$create_args" != *"--label routine-tracking"* ]]; then
	printf 'FAIL routine issue creation omitted routine-tracking label: %s\n' "$create_args" >&2
	exit 1
fi

printf 'PASS routine issue creation includes routines and routine-tracking labels\n'
