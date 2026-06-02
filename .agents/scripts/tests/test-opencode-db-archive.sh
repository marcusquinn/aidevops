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

_reset_dbs() {
	rm -f "$ACTIVE_DB" "$ARCHIVE_DB" "${ACTIVE_DB}-wal" "${ACTIVE_DB}-shm" "${ARCHIVE_DB}-wal" "${ARCHIVE_DB}-shm"
	return 0
}

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

_make_active_db_with_sessions() {
	local sessions_csv="$1"

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
SQL

	local session_id created_ms updated_ms
	while IFS=',' read -r session_id created_ms updated_ms; do
		[[ -n "$session_id" ]] || continue
		updated_ms="${updated_ms:-$created_ms}"
		sqlite3 "$ACTIVE_DB" \
			"INSERT INTO session VALUES ('${session_id}', 'proj1', NULL, '${session_id}', '/tmp/dir', '${session_id}', '1.0.0', NULL, NULL, NULL, NULL, NULL, NULL, NULL, ${created_ms}, ${updated_ms}, NULL, NULL, 'workspace1', '/tmp/${session_id}');"
		sqlite3 "$ACTIVE_DB" \
			"INSERT INTO message VALUES ('msg-${session_id}', '${session_id}', ${created_ms}, ${updated_ms}, '{}');"
	done <<<"$sessions_csv"
	return 0
}

_reset_dbs
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

_reset_dbs
_make_active_db_with_sessions $'s1,1000,5000\ns2,2000,1000\ns3,3000,4000\ns4,4000,2000\ns5,5000,3000'

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" archive --keep-sessions 2 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive succeeds with count-based retention"
else
	_fail "count-based archive failed with rc=$rc — output: $out"
fi

active_kept=$(sqlite3 "$ACTIVE_DB" "SELECT GROUP_CONCAT(id, ',') FROM (SELECT id FROM session ORDER BY id);")
if [[ "$active_kept" == "s1,s3" ]]; then
	_pass "count-based retention preserves most recently updated sessions"
else
	_fail "count-based retention kept unexpected active sessions: ${active_kept}"
fi

archived_count_sessions=$(sqlite3 "$ARCHIVE_DB" "SELECT GROUP_CONCAT(id, ',') FROM (SELECT id FROM session ORDER BY time_updated, id);")
if [[ "$archived_count_sessions" == "s2,s4,s5" ]]; then
	_pass "count-based retention archives sessions outside update-time keep target"
else
	_fail "count-based retention archived unexpected sessions: ${archived_count_sessions}"
fi

_reset_dbs
now_seconds=$(date +%s)
old_created_ms=$(((now_seconds - 30 * 86400) * 1000))
recent_updated_ms=$(((now_seconds - 1 * 86400) * 1000))
stale_updated_ms=$old_created_ms
_make_active_db_with_sessions "resumed,${old_created_ms},${recent_updated_ms}
stale,${old_created_ms},${stale_updated_ms}"

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" archive --retention-days 14 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive succeeds with old-created recently updated regression"
else
	_fail "old-created recently updated archive failed with rc=$rc — output: $out"
fi

recent_active=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE id='resumed';")
stale_archived=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE id='stale';")
if [[ "$recent_active" == "1" && "$stale_archived" == "1" ]]; then
	_pass "age retention preserves recently updated sessions despite old creation time"
else
	_fail "age retention regression mismatch: resumed_active=${recent_active}, stale_archived=${stale_archived}"
fi

_reset_dbs
now_seconds=$(date +%s)
old1_ms=$(((now_seconds - 10 * 86400) * 1000))
old2_created_ms=$(((now_seconds - 9 * 86400) * 1000))
old2_updated_ms=$(((now_seconds - 8 * 86400) * 1000))
mid_ms=$(((now_seconds - 3 * 86400) * 1000))
new_created_ms=$(((now_seconds - 20 * 86400) * 1000))
new_updated_ms=$(((now_seconds - 1 * 86400) * 1000))
_make_active_db_with_sessions "old1,${old1_ms}
old2,${old2_created_ms},${old2_updated_ms}
mid,${mid_ms}
new,${new_created_ms},${new_updated_ms}"

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" archive --retention-days 7 --keep-sessions 3 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive succeeds with combined retention targets"
else
	_fail "combined archive failed with rc=$rc — output: $out"
fi

combined_active=$(sqlite3 "$ACTIVE_DB" "SELECT GROUP_CONCAT(id, ',') FROM (SELECT id FROM session ORDER BY time_updated);")
if [[ "$combined_active" == "old2,mid,new" ]]; then
	_pass "combined retention uses conservative update-time intersection"
else
	_fail "combined retention kept unexpected active sessions: ${combined_active}"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
