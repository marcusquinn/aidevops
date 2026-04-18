#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for opencode-db-maintenance-helper.sh (t2174).
#
# Strategy: build a synthetic opencode-shaped SQLite DB in a tmp dir,
# point the helper at it via XDG_DATA_HOME, and assert each subcommand
# behaves correctly. No real opencode install is touched.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../opencode-db-maintenance-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FAIL: helper not executable at $HELPER"
	exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo "SKIP: sqlite3 not available"
	exit 0
fi

PASS=0
FAIL=0

_pass() {
	PASS=$((PASS + 1))
	printf '  \033[0;32mPASS\033[0m %s\n' "$1"
}
_fail() {
	FAIL=$((FAIL + 1))
	printf '  \033[0;31mFAIL\033[0m %s\n' "$1"
}

# -----------------------------------------------------------------------------
# Sandbox setup
# -----------------------------------------------------------------------------

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export XDG_DATA_HOME="$SANDBOX/data"

OPENCODE_DIR="$XDG_DATA_HOME/opencode"
mkdir -p "$OPENCODE_DIR"

# Route state to sandbox so tests don't touch real state
AIDEVOPS_WS="$SANDBOX/aidevops-ws"
mkdir -p "$AIDEVOPS_WS"

# The helper resolves STATE_DIR from $HOME — redirect HOME for the duration
# of each invocation.
_run_helper() {
	HOME="$SANDBOX/fakehome" "$HELPER" "$@"
}

_make_opencode_db() {
	# Build an opencode-shaped DB with a few thousand rows for fragmentation
	sqlite3 "$OPENCODE_DIR/opencode.db" <<'SQL'
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE TABLE session (
  id text PRIMARY KEY,
  directory text,
  title text,
  time_created integer
);
CREATE TABLE message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
CREATE INDEX message_session_idx ON message(session_id, time_created, id);
INSERT INTO session VALUES ('ses1', '/tmp', 'test', 0);
SQL

	# Insert+delete rows to create freelist pages (fragmentation)
	local i
	for i in $(seq 1 500); do
		sqlite3 "$OPENCODE_DIR/opencode.db" \
			"INSERT INTO message VALUES ('msg$i', 'ses1', $i, $i, '$(head -c 1024 /dev/urandom | base64 | tr -d '\n' | head -c 1024)');" 2>/dev/null
	done
	sqlite3 "$OPENCODE_DIR/opencode.db" "DELETE FROM message WHERE CAST(substr(id, 4) AS INTEGER) % 2 = 0;" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Test 1: help returns 0 and shows subcommand list
# -----------------------------------------------------------------------------

out=$(_run_helper help 2>&1)
if grep -q "check" <<<"$out" && grep -q "maintain" <<<"$out" && grep -q "auto" <<<"$out"; then
	_pass "help lists all subcommands"
else
	_fail "help output missing subcommands"
fi

# -----------------------------------------------------------------------------
# Test 2: check returns 0 when opencode not installed (no-op path)
# -----------------------------------------------------------------------------

# No DB yet → should report no-op cleanly
set +e
_run_helper check >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "check returns 0 when opencode not installed"
else
	_fail "check returned $rc (expected 0) when opencode not installed"
fi

# -----------------------------------------------------------------------------
# Test 3: auto returns 0 silently when opencode not installed
# -----------------------------------------------------------------------------

set +e
out=$(_run_helper auto 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "auto returns 0 when opencode not installed"
else
	_fail "auto returned $rc (expected 0) with no DB — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 4: Create the synthetic DB, then report shows stats
# -----------------------------------------------------------------------------

_make_opencode_db

set +e
out=$(_run_helper report 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "OpenCode DB Report" <<<"$out" && grep -q "DB size:" <<<"$out"; then
	_pass "report shows DB stats for synthetic DB"
else
	_fail "report failed or output missing stats (rc=$rc)"
fi

# -----------------------------------------------------------------------------
# Test 5: maintain succeeds on synthetic DB
# -----------------------------------------------------------------------------
# Note: --force is used because the test host may have real opencode
# processes running. The sandbox DB is separate (XDG_DATA_HOME), so
# --force here only waives the *process count* check, not any real risk.

# Lower thresholds so VACUUM is exercised even on tiny synthetic DB
set +e
out=$(VACUUM_FREELIST_THRESHOLD=0.01 FORCE_VACUUM_SIZE_MB=0 _run_helper maintain --force 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "Maintenance complete" <<<"$out"; then
	_pass "maintain succeeds on synthetic DB"
else
	_fail "maintain failed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 6: state file is written after maintain
# -----------------------------------------------------------------------------

if [[ -f "$SANDBOX/fakehome/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json" ]]; then
	_pass "state file written after maintain"
	if grep -q '"outcome":' "$SANDBOX/fakehome/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json"; then
		_pass "state file contains outcome field"
	else
		_fail "state file missing outcome field"
	fi
else
	_fail "state file not written"
fi

# -----------------------------------------------------------------------------
# Test 7: auto throttles when last run is recent
# -----------------------------------------------------------------------------

# Immediately re-run auto — should be throttled (last-run.json just written).
# Throttle check runs BEFORE the process-count check, so real opencode
# processes don't block the throttle path.
set +e
out=$(_run_helper auto 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qiE "throttl|skipping" <<<"$out"; then
	_pass "auto throttles when last run is recent"
else
	_fail "auto did not throttle (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 8: unknown subcommand returns 1 with help
# -----------------------------------------------------------------------------

set +e
out=$(_run_helper bogus-subcmd 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && grep -q "Unknown subcommand" <<<"$out"; then
	_pass "unknown subcommand returns 1 with error"
else
	_fail "unknown subcommand behaviour wrong (rc=$rc)"
fi

# -----------------------------------------------------------------------------
# Test 9: r913 is registered in core-routines.sh
# -----------------------------------------------------------------------------

CORE_ROUTINES="${SCRIPT_DIR}/../routines/core-routines.sh"
if [[ -f "$CORE_ROUTINES" ]]; then
	# shellcheck disable=SC1090
	if (source "$CORE_ROUTINES" && get_core_routine_entries | grep -q "^r913|"); then
		_pass "r913 registered in core-routines.sh get_core_routine_entries"
	else
		_fail "r913 not in get_core_routine_entries output"
	fi

	# shellcheck disable=SC1090
	if (source "$CORE_ROUTINES" && declare -f describe_r913 >/dev/null); then
		_pass "describe_r913 function defined"
	else
		_fail "describe_r913 function not defined"
	fi
else
	_fail "core-routines.sh not found at $CORE_ROUTINES"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
