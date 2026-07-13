#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TMP=$(mktemp -d -t pulse-cycle-gates.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

export SCRIPT_DIR="${TMP}/scripts"
export WRAPPER_LOGFILE="${TMP}/wrapper.log"
export PULSE_SCOPE_REPOS="owner/repo"
mkdir -p "$SCRIPT_DIR"
: >"$WRAPPER_LOGFILE"

GH_QUERY_FILE="${TMP}/query.txt"
export GH_QUERY_FILE
gh() {
	printf '%s\n' "$*" >"$GH_QUERY_FILE"
	printf '0\n'
	return 0
}

SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-wrapper-cycle-gates.sh"
# shellcheck disable=SC1090
source "$SOURCE_SCRIPT"

if _pulse_available_auto_dispatch_work_exists; then
	fail "zero eligible issues does not bypass idle backoff"
else
	pass "zero eligible issues does not bypass idle backoff"
fi

if grep -q -- '-label:needs-maintainer-review' "$GH_QUERY_FILE"; then
	pass "idle-work query excludes NMR-held issues"
else
	fail "idle-work query excludes NMR-held issues" "query=$(cat "$GH_QUERY_FILE")"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
