#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for `opencode-db-maintenance-helper.sh sessions` (GH#24411).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../opencode-db-maintenance-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'FAIL: helper not executable at %s\n' "$HELPER"
	exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
	printf 'SKIP: sqlite3 not available\n'
	exit 0
fi

PASS=0
FAIL=0

_pass() {
	local message="$1"
	PASS=$((PASS + 1))
	printf '  \033[0;32mPASS\033[0m %s\n' "$message"
	return 0
}

_fail() {
	local message="$1"
	FAIL=$((FAIL + 1))
	printf '  \033[0;31mFAIL\033[0m %s\n' "$message"
	return 0
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ACTIVE_DB="${SANDBOX}/opencode.db"
ARCHIVE_DB="${SANDBOX}/opencode-archive.db"

_run_helper() {
	if HOME="${SANDBOX}/home" OPENCODE_DB_PATH="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" sessions "$@"; then
		return 0
	fi
	return 1
}

_make_db() {
	local db="$1"
	sqlite3 "$db" <<'SQL'
CREATE TABLE session (
  id text PRIMARY KEY,
  directory text,
  title text,
  project_id text,
  parent_id text,
  time_created integer,
  time_updated integer
);
SQL
	return 0
}

_make_db "$ACTIVE_DB"
_make_db "$ARCHIVE_DB"

sqlite3 "$ACTIVE_DB" <<'SQL'
INSERT INTO session VALUES ('ses_parent', '/repo/demo', 'Issue 24411 parent', 'proj-new', '', 10, 20);
INSERT INTO session VALUES ('ses_child', '/repo/demo', 'Issue 24411 child', 'proj-new', 'ses_parent', 11, 21);
INSERT INTO session VALUES ('ses_old_project', '/repo/demo', 'Old project id session', 'proj-old', '', 5, 6);
SQL

sqlite3 "$ARCHIVE_DB" <<'SQL'
INSERT INTO session VALUES ('ses_archived', '/repo/demo', 'Archived issue 24411', 'proj-old', '', 1, 2);
SQL

out=$(_run_helper --query "24411" --include-archive 2>&1)
if grep -q 'active-top-level' <<<"$out" && grep -q 'active-child' <<<"$out" && grep -q 'archived' <<<"$out"; then
	_pass "table lookup includes active top-level, active child, and archived sessions"
else
	_fail "table lookup missed expected statuses: $out"
fi

if grep -q 'ses_parent (Issue 24411 pare' <<<"$out"; then
	_pass "child session output includes parent title"
else
	_fail "child session output missing parent title: $out"
fi

out=$(_run_helper --directory "/repo/demo" 2>&1)
if grep -q 'possible-project-id-mismatch' <<<"$out"; then
	_pass "directory lookup reports possible project-id mismatch"
else
	_fail "directory lookup missing project-id mismatch guidance: $out"
fi

rm -f "$ARCHIVE_DB"
set +e
out=$(_run_helper --query "24411" --include-archive 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'archive DB not found' <<<"$out" && grep -q 'active-child' <<<"$out"; then
	_pass "missing archive DB falls back to active lookup"
else
	_fail "missing archive DB should not fail active lookup (rc=$rc): $out"
fi

json=$(_run_helper --id "ses_child" --json 2>&1)
if python3 -c 'import json,sys; data=json.load(sys.stdin); assert data[0]["status"] == "active-child"; assert data[0]["parent_title"] == "Issue 24411 parent"' <<<"$json"; then
	_pass "JSON output is valid and includes expected fields"
else
	_fail "JSON output invalid or missing expected fields: $json"
fi

printf '\nOpenCode session lookup tests: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
