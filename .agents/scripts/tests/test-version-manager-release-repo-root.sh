#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for unset REPO_ROOT handling in hotfix tag creation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
RELEASE_HELPER="${SCRIPT_DIR}/../version-manager-release.sh"

print_error() {
	local message="$1"
	printf '%s\n' "$message"
	return 0
}

# shellcheck source=../version-manager-release.sh
source "$RELEASE_HELPER"
unset REPO_ROOT

output="$(_create_hotfix_tag "1.2.3" 2>&1)"
status=$?

if [[ "$status" -ne 1 ]]; then
	printf 'FAIL: expected status 1 with unset REPO_ROOT, got %s\n' "$status"
	exit 1
fi

if [[ "$output" != *"REPO_ROOT is not set"* ]]; then
	printf 'FAIL: expected missing REPO_ROOT diagnostic, got: %s\n' "$output"
	exit 1
fi

printf 'PASS: unset REPO_ROOT returns a controlled error under set -u\n'
exit 0
