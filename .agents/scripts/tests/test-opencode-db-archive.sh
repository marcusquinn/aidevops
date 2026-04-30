#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for opencode-db-archive.sh schema drift handling.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../opencode-db-archive.sh"

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
	local msg="$1"
	PASS=$((PASS + 1))
	printf '  \033[0;32mPASS\033[0m %s\n' "$msg"
	return 0
}

_fail() {
	local msg="$1"
	FAIL=$((FAIL + 1))
	printf '  \033[0;31mFAIL\033[0m %s\n' "$msg"
	return 0
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ACTIVE_DB="${SANDBOX}/opencode.db"
ARCHIVE_DB="${SANDBOX}/opencode-archive.db"

_make_active_db_with_session_path() {
	sqlite3 "$ACTIVE_DB" <<'SQL'
PRAGMA journal_mode = WAL;
CREATE TABLE project (
  id text PRIMARY KEY,
  worktree text NOT NULL,
  vcs text,
  name text,
  icon_url text,
  icon_color text,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_initialized integer,
  sandboxes text NOT NULL,
  commands text,
  icon_url_override text
);
CREATE TABLE session (
  id text PRIMARY KEY,
  project_id text NOT NULL,
  parent_id text,
  slug text NOT NULL,
  directory text NOT NULL,
  title text NOT NULL,
  version text NOT NULL,
  share_url text,
  summary_additions integer,
  summary_deletions integer,
  summary_files integer,
  summary_diffs text,
  revert text,
  permission text,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_compacting integer,
  time_archived integer,
  workspace_id text,
  path text
);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE todo (session_id text NOT NULL, content text NOT NULL, status text NOT NULL, priority text NOT NULL, position integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, PRIMARY KEY(session_id, position));
CREATE TABLE session_share (session_id text PRIMARY KEY, id text NOT NULL, secret text NOT NULL, url text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
INSERT INTO project VALUES ('proj1', '/tmp/worktree', 'git', 'project', NULL, NULL, 1, 1, NULL, '{}', NULL, NULL);
INSERT INTO session VALUES ('ses1', 'proj1', NULL, 'slug', '/tmp/dir', 'title', '1.0.0', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 1, NULL, NULL, 'workspace1', '/tmp/session-path');
INSERT INTO message VALUES ('msg1', 'ses1', 1, 1, '{}');
SQL
	return 0
}

_make_legacy_archive_db_without_session_path() {
	sqlite3 "$ARCHIVE_DB" <<'SQL'
CREATE TABLE project (
  id text PRIMARY KEY,
  worktree text NOT NULL,
  vcs text,
  name text,
  icon_url text,
  icon_color text,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_initialized integer,
  sandboxes text NOT NULL,
  commands text,
  icon_url_override text
);
CREATE TABLE session (
  id text PRIMARY KEY,
  project_id text NOT NULL,
  parent_id text,
  slug text NOT NULL,
  directory text NOT NULL,
  title text NOT NULL,
  version text NOT NULL,
  share_url text,
  summary_additions integer,
  summary_deletions integer,
  summary_files integer,
  summary_diffs text,
  revert text,
  permission text,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_compacting integer,
  time_archived integer,
  workspace_id text
);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE todo (session_id text NOT NULL, content text NOT NULL, status text NOT NULL, priority text NOT NULL, position integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, PRIMARY KEY(session_id, position));
CREATE TABLE session_share (session_id text PRIMARY KEY, id text NOT NULL, secret text NOT NULL, url text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
SQL
	return 0
}

_make_active_db_with_session_path
_make_legacy_archive_db_without_session_path

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive succeeds with active session.path and legacy archive schema"
else
	_fail "archive failed with rc=$rc — output: $out"
fi

path_col_count=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM pragma_table_info('session') WHERE name='path';")
if [[ "$path_col_count" == "1" ]]; then
	_pass "legacy archive.session schema migrated with path column"
else
	_fail "archive.session path column missing after migration"
fi

archived_path=$(sqlite3 "$ARCHIVE_DB" "SELECT path FROM session WHERE id='ses1';")
if [[ "$archived_path" == "/tmp/session-path" ]]; then
	_pass "session.path value preserved in archive"
else
	_fail "session.path not preserved (got '${archived_path}')"
fi

active_sessions=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE id='ses1';")
if [[ "$active_sessions" == "0" ]]; then
	_pass "archived session removed from active DB"
else
	_fail "archived session still present in active DB"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
