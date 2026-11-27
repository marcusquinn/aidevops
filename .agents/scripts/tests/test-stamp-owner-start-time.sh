#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stamp-owner-start-time.sh — GH#40572 regression.
# A claim stamp whose PID now belongs to a process started AFTER claimed_at
# must be classified dead (PID reuse), and a matching start token stays alive.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || exit 1
_isc_warn() { return 0; }
_isc_info() { return 0; }
_isc_err() { return 0; }
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/interactive-session-helper-stamp.sh" 2>/dev/null || exit 1

FAILED=0
check() {
	local name="$1" want="$2" got="$3"
	if [[ "$want" == "$got" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (want=%s got=%s)\n' "$name" "$want" "$got"
		FAILED=$((FAILED + 1))
	fi
	return 0
}

sleep 30 &
child=$!
trap 'kill "$child" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT
sleep 2

old_claim="2000-01-01T00:00:00Z"
rc=0
_isc_stamp_owner_alive "$child" "" "" "" "$old_claim" || rc=$?
check "process started after claimed_at is dead (no token)" 1 "$rc"

future_claim=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)
rc=0
_isc_stamp_owner_alive "$child" "" "" "" "$future_claim" || rc=$?
check "process started before claimed_at is alive (no token)" 0 "$rc"

token=$(_process_start_token "$child")
rc=0
_isc_stamp_owner_alive "$child" "" "" "$token" "$old_claim" || rc=$?
check "matching start token is alive" 0 "$rc"

rc=0
_isc_stamp_owner_alive "$child" "" "" "bogus-token" "$future_claim" || rc=$?
check "mismatched start token is dead" 1 "$rc"

[[ "$FAILED" -eq 0 ]]
