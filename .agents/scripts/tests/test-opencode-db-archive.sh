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
CREATE TABLE event (id text PRIMARY KEY, aggregate_id text NOT NULL, seq integer NOT NULL, type text NOT NULL, data text NOT NULL);
CREATE UNIQUE INDEX event_aggregate_seq_idx ON event (aggregate_id, seq);
CREATE INDEX event_aggregate_type_seq_idx ON event (aggregate_id, type, seq);
INSERT INTO project VALUES ('proj1', '/tmp/worktree', 'git', 'project', NULL, NULL, 1, 1, NULL, '{}', NULL, NULL);
INSERT INTO session VALUES ('ses1', 'proj1', NULL, 'slug', '/tmp/dir', 'title', '1.0.0', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 1, NULL, NULL, 'workspace1', '/tmp/session-path');
INSERT INTO message VALUES ('msg1', 'ses1', 1, 1, '{}');
INSERT INTO event VALUES ('evt1', 'ses1', 1, 'session.updated.1', '{"ok":true}');
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

_make_active_db_1_18_3() {
	sqlite3 "$ACTIVE_DB" <<'SQL'
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
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
  path text,
  agent text,
  model text,
  cost real DEFAULT 0 NOT NULL,
  tokens_input integer DEFAULT 0 NOT NULL,
  tokens_output integer DEFAULT 0 NOT NULL,
  tokens_reasoning integer DEFAULT 0 NOT NULL,
  tokens_cache_read integer DEFAULT 0 NOT NULL,
  tokens_cache_write integer DEFAULT 0 NOT NULL,
  metadata text,
  FOREIGN KEY (project_id) REFERENCES project(id) ON DELETE CASCADE
);
CREATE INDEX session_project_idx ON session (project_id);
CREATE INDEX session_parent_idx ON session (parent_id);
CREATE INDEX session_workspace_idx ON session (workspace_id);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL, FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL, FOREIGN KEY (message_id) REFERENCES message(id) ON DELETE CASCADE);
CREATE INDEX part_session_idx ON part (session_id);
CREATE INDEX part_message_id_id_idx ON part (message_id, id);
CREATE TABLE todo (session_id text NOT NULL, content text NOT NULL, status text NOT NULL, priority text NOT NULL, position integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, PRIMARY KEY(session_id, position), FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE INDEX todo_session_idx ON todo (session_id);
CREATE TABLE session_share (session_id text PRIMARY KEY, id text NOT NULL, secret text NOT NULL, url text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL, seq integer NOT NULL, FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
CREATE INDEX session_message_session_time_created_id_idx ON session_message (session_id, time_created, id);
CREATE INDEX session_message_session_type_seq_idx ON session_message (session_id, type, seq);
CREATE INDEX session_message_time_created_idx ON session_message (time_created);
CREATE TABLE session_input (id text PRIMARY KEY, session_id text NOT NULL, prompt text NOT NULL, delivery text NOT NULL, admitted_seq integer NOT NULL, promoted_seq integer, time_created integer NOT NULL, FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE UNIQUE INDEX session_input_session_admitted_seq_idx ON session_input (session_id, admitted_seq);
CREATE INDEX session_input_session_pending_delivery_seq_idx ON session_input (session_id, promoted_seq, delivery, admitted_seq);
CREATE UNIQUE INDEX session_input_session_promoted_seq_idx ON session_input (session_id, promoted_seq);
CREATE TABLE session_context_epoch (session_id text PRIMARY KEY, baseline text NOT NULL, snapshot text NOT NULL, baseline_seq integer NOT NULL, FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE);
CREATE TABLE event_sequence (aggregate_id text PRIMARY KEY, seq integer NOT NULL, owner_id text);
CREATE TABLE event (id text PRIMARY KEY, aggregate_id text NOT NULL, seq integer NOT NULL, type text NOT NULL, data text NOT NULL, FOREIGN KEY (aggregate_id) REFERENCES event_sequence(aggregate_id) ON DELETE CASCADE);
CREATE UNIQUE INDEX event_aggregate_seq_idx ON event (aggregate_id, seq);
CREATE INDEX event_aggregate_type_seq_idx ON event (aggregate_id, type, seq);

INSERT INTO project VALUES ('proj-1183', '/fixture/worktree', 'git', 'fixture', NULL, '#abcdef', 10, 20, 15, '{"sandboxes":[]}', '{"build":"run"}', 'fixture-icon');
INSERT INTO session VALUES ('ses-1183', 'proj-1183', NULL, 'slug-1183', '/fixture/directory', 'Fixture title', '1.18.3', NULL, 3, 4, 5, '{"files":["a"]}', '{"snapshot":"r"}', '{"allow":"all"}', 100, 200, 150, NULL, 'workspace-1183', '/fixture/session', 'fixture-agent', 'fixture/model', 12.75, 101, 202, 303, 404, 505, '{"meta":"value"}');
INSERT INTO message VALUES ('msg-1183', 'ses-1183', 101, 201, '{"role":"assistant"}');
INSERT INTO part VALUES ('part-1183', 'msg-1183', 'ses-1183', 102, 202, '{"text":"payload"}');
INSERT INTO todo VALUES ('ses-1183', 'archive fixture', 'pending', 'high', 0, 103, 203);
INSERT INTO session_share VALUES ('ses-1183', 'share-1183', 'fixture-secret', 'fixture-url', 104, 204);
INSERT INTO session_message VALUES ('session-msg-1183', 'ses-1183', 'assistant', 105, 205, '{"content":"session-message"}', 7);
INSERT INTO session_input VALUES ('input-1183', 'ses-1183', 'fixture prompt', 'promoted', 8, 9, 106);
INSERT INTO session_context_epoch VALUES ('ses-1183', '{"baseline":1}', '{"snapshot":2}', 6);
INSERT INTO event_sequence VALUES ('ses-1183', 11, 'owner-1183');
INSERT INTO event VALUES ('event-1183', 'ses-1183', 11, 'session.updated.1', '{"event":"value"}');
SQL
	return 0
}

_add_second_active_1_18_3_session() {
	sqlite3 "$ACTIVE_DB" <<'SQL'
PRAGMA foreign_keys = ON;
INSERT INTO session VALUES ('ses-1183-b', 'proj-1183', NULL, 'slug-1183-b', '/fixture/directory-b', 'Fixture title B', '1.18.3', NULL, 13, 14, 15, '{"files":["b"]}', '{"snapshot":"s"}', '{"allow":"all"}', 110, 210, 160, NULL, 'workspace-1183-b', '/fixture/session-b', 'fixture-agent', 'fixture/model', 22.5, 111, 212, 313, 414, 515, '{"meta":"value-b"}');
INSERT INTO message VALUES ('msg-1183-b', 'ses-1183-b', 111, 211, '{"role":"user"}');
INSERT INTO part VALUES ('part-1183-b', 'msg-1183-b', 'ses-1183-b', 112, 212, '{"text":"payload-b"}');
INSERT INTO todo VALUES ('ses-1183-b', 'archive fixture b', 'pending', 'medium', 0, 113, 213);
INSERT INTO session_share VALUES ('ses-1183-b', 'share-1183-b', 'fixture-secret-b', 'fixture-url-b', 114, 214);
INSERT INTO session_message VALUES ('session-msg-1183-b', 'ses-1183-b', 'user', 115, 215, '{"content":"session-message-b"}', 17);
INSERT INTO session_input VALUES ('input-1183-b', 'ses-1183-b', 'fixture prompt b', 'pending', 18, NULL, 116);
INSERT INTO session_context_epoch VALUES ('ses-1183-b', '{"baseline":11}', '{"snapshot":12}', 16);
INSERT INTO event_sequence VALUES ('ses-1183-b', 21, 'owner-1183-b');
INSERT INTO event VALUES ('event-1183-b', 'ses-1183-b', 21, 'session.updated.1', '{"event":"value-b"}');
SQL
	return 0
}

_fixture_graph_fingerprint() {
	local db_path="$1"

	sqlite3 "$db_path" <<'SQL'
SELECT row_value FROM (
  SELECT 'project|' || quote(id) || '|' || quote(worktree) || '|' || quote(vcs) || '|' || quote(name) || '|' || quote(icon_url) || '|' || quote(icon_color) || '|' || quote(time_created) || '|' || quote(time_updated) || '|' || quote(time_initialized) || '|' || quote(sandboxes) || '|' || quote(commands) || '|' || quote(icon_url_override) AS row_value FROM project
  UNION ALL
  SELECT 'session|' || quote(id) || '|' || quote(project_id) || '|' || quote(parent_id) || '|' || quote(slug) || '|' || quote(directory) || '|' || quote(title) || '|' || quote(version) || '|' || quote(share_url) || '|' || quote(summary_additions) || '|' || quote(summary_deletions) || '|' || quote(summary_files) || '|' || quote(summary_diffs) || '|' || quote(revert) || '|' || quote(permission) || '|' || quote(time_created) || '|' || quote(time_updated) || '|' || quote(time_compacting) || '|' || quote(time_archived) || '|' || quote(workspace_id) || '|' || quote(path) || '|' || quote(agent) || '|' || quote(model) || '|' || quote(cost) || '|' || quote(tokens_input) || '|' || quote(tokens_output) || '|' || quote(tokens_reasoning) || '|' || quote(tokens_cache_read) || '|' || quote(tokens_cache_write) || '|' || quote(metadata) FROM session
  UNION ALL
  SELECT 'message|' || quote(id) || '|' || quote(session_id) || '|' || quote(time_created) || '|' || quote(time_updated) || '|' || quote(data) FROM message
  UNION ALL
  SELECT 'part|' || quote(id) || '|' || quote(message_id) || '|' || quote(session_id) || '|' || quote(time_created) || '|' || quote(time_updated) || '|' || quote(data) FROM part
  UNION ALL
  SELECT 'todo|' || quote(session_id) || '|' || quote(content) || '|' || quote(status) || '|' || quote(priority) || '|' || quote(position) || '|' || quote(time_created) || '|' || quote(time_updated) FROM todo
  UNION ALL
  SELECT 'session_share|' || quote(session_id) || '|' || quote(id) || '|' || quote(secret) || '|' || quote(url) || '|' || quote(time_created) || '|' || quote(time_updated) FROM session_share
  UNION ALL
  SELECT 'session_message|' || quote(id) || '|' || quote(session_id) || '|' || quote(type) || '|' || quote(time_created) || '|' || quote(time_updated) || '|' || quote(data) || '|' || quote(seq) FROM session_message
  UNION ALL
  SELECT 'session_input|' || quote(id) || '|' || quote(session_id) || '|' || quote(prompt) || '|' || quote(delivery) || '|' || quote(admitted_seq) || '|' || quote(promoted_seq) || '|' || quote(time_created) FROM session_input
  UNION ALL
  SELECT 'session_context_epoch|' || quote(session_id) || '|' || quote(baseline) || '|' || quote(snapshot) || '|' || quote(baseline_seq) FROM session_context_epoch
  UNION ALL
  SELECT 'event_sequence|' || quote(aggregate_id) || '|' || quote(seq) || '|' || quote(owner_id) FROM event_sequence
  UNION ALL
  SELECT 'event|' || quote(id) || '|' || quote(aggregate_id) || '|' || quote(seq) || '|' || quote(type) || '|' || quote(data) FROM event
) ORDER BY row_value;
SQL
	return $?
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
CREATE TABLE event (id text PRIMARY KEY, aggregate_id text NOT NULL, seq integer NOT NULL, type text NOT NULL, data text NOT NULL);
CREATE UNIQUE INDEX event_aggregate_seq_idx ON event (aggregate_id, seq);
CREATE INDEX event_aggregate_type_seq_idx ON event (aggregate_id, type, seq);
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
		sqlite3 "$ACTIVE_DB" \
			"INSERT INTO event VALUES ('evt-${session_id}', '${session_id}', 1, 'session.updated.1', '{\"session\":\"${session_id}\"}');"
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

event_table_count=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM pragma_table_info('event') WHERE name='aggregate_id';")
if [[ "$event_table_count" == "1" ]]; then
	_pass "legacy archive schema gains event table"
else
	_fail "archive.event table missing after migration"
fi

archived_event_count=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM event WHERE aggregate_id='ses1';")
active_event_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM event WHERE aggregate_id='ses1';")
if [[ "$archived_event_count" == "1" && "$active_event_count" == "0" ]]; then
	_pass "session event rows moved from active DB to archive DB"
else
	_fail "event archive mismatch: archived=${archived_event_count}, active=${active_event_count}"
fi

expected_session_columns="id,project_id,parent_id,slug,directory,title,version,share_url,summary_additions,summary_deletions,summary_files,summary_diffs,revert,permission,time_created,time_updated,time_compacting,time_archived,workspace_id,path,agent,model,cost,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write,metadata"
archive_session_columns=$(sqlite3 "$ARCHIVE_DB" "SELECT group_concat(name, ',') FROM pragma_table_info('session');")
archive_current_table_count=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('session_message','session_input','session_context_epoch','event_sequence');")
legacy_default_count=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE id='ses1' AND agent IS NULL AND model IS NULL AND cost=0 AND tokens_input=0 AND tokens_output=0 AND tokens_reasoning=0 AND tokens_cache_read=0 AND tokens_cache_write=0 AND metadata IS NULL;")
if [[ "$archive_session_columns" == "$expected_session_columns" && "$archive_current_table_count" == "4" && "$legacy_default_count" == "1" ]]; then
	_pass "legacy archive migrates losslessly to the complete 1.18.3 contract"
else
	_fail "legacy archive migration mismatch: columns=${archive_session_columns}, tables=${archive_current_table_count}, defaults=${legacy_default_count}"
fi

# Exact OpenCode 1.18.3 fixture: dry-run reporting, schema acceptance, full
# session graph movement, value fidelity, and orphan checks.
_reset_dbs
_make_active_db_1_18_3
source_graph=$(_fixture_graph_fingerprint "$ACTIVE_DB")
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --dry-run --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 && "$out" == *"Session msgs:   1"* && "$out" == *"Session inputs: 1"* && "$out" == *"Context epochs: 1"* && "$out" == *"Event sequences: 1"* && ! -e "$ARCHIVE_DB" ]]; then
	_pass "1.18.3 dry run reports the complete graph without creating an archive"
else
	_fail "1.18.3 dry-run mismatch: rc=${rc}, output=${out}"
fi

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "archive accepts the exact populated OpenCode 1.18.3 schema"
else
	_fail "1.18.3 archive failed with rc=${rc} — output: ${out}"
fi

archive_graph=$(_fixture_graph_fingerprint "$ARCHIVE_DB")
if [[ "$archive_graph" == "$source_graph" ]]; then
	_pass "1.18.3 archive preserves every fixture value byte-for-byte"
else
	_fail "1.18.3 archive graph differs from the source fixture"
fi

active_owned_count=$(sqlite3 "$ACTIVE_DB" "SELECT (SELECT COUNT(*) FROM session) + (SELECT COUNT(*) FROM message) + (SELECT COUNT(*) FROM part) + (SELECT COUNT(*) FROM todo) + (SELECT COUNT(*) FROM session_share) + (SELECT COUNT(*) FROM session_message) + (SELECT COUNT(*) FROM session_input) + (SELECT COUNT(*) FROM session_context_epoch) + (SELECT COUNT(*) FROM event_sequence) + (SELECT COUNT(*) FROM event);")
archive_orphan_count=$(sqlite3 "$ARCHIVE_DB" "SELECT (SELECT COUNT(*) FROM message c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM part c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM part c LEFT JOIN message p ON p.id=c.message_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM todo c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM session_share c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM session_message c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM session_input c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM session_context_epoch c LEFT JOIN session p ON p.id=c.session_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM event_sequence c LEFT JOIN session p ON p.id=c.aggregate_id WHERE p.id IS NULL) + (SELECT COUNT(*) FROM event c LEFT JOIN event_sequence p ON p.aggregate_id=c.aggregate_id WHERE p.aggregate_id IS NULL);")
archive_foreign_key_violations=$(sqlite3 "$ARCHIVE_DB" "PRAGMA foreign_key_check;")
if [[ "$active_owned_count" == "0" && "$archive_orphan_count" == "0" && -z "$archive_foreign_key_violations" ]]; then
	_pass "1.18.3 copy/delete ordering leaves no active rows or archive orphans"
else
	_fail "1.18.3 orphan mismatch: active=${active_owned_count}, archive=${archive_orphan_count}, foreign_keys=${archive_foreign_key_violations}"
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

archived_count_events=$(sqlite3 "$ARCHIVE_DB" "SELECT GROUP_CONCAT(aggregate_id, ',') FROM (SELECT aggregate_id FROM event ORDER BY aggregate_id);")
if [[ "$archived_count_events" == "s2,s4,s5" ]]; then
	_pass "count-based retention archives matching event stream rows"
else
	_fail "count-based retention archived unexpected events: ${archived_count_events}"
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
old_default_ms=$(((now_seconds - 31 * 86400) * 1000))
recent_default_ms=$(((now_seconds - 29 * 86400) * 1000))
_make_active_db_with_sessions "default_old,${old_default_ms}
default_recent,${recent_default_ms}"

set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" "$HELPER" archive --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive succeeds with default 30-day retention"
else
	_fail "default 30-day archive failed with rc=$rc — output: $out"
fi

default_recent_active=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE id='default_recent';")
default_old_archived=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE id='default_old';")
if [[ "$default_recent_active" == "1" && "$default_old_archived" == "1" ]]; then
	_pass "default retention preserves 30-day /sessions history"
else
	_fail "default retention mismatch: recent_active=${default_recent_active}, old_archived=${default_old_archived}"
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

xdg_data_home="${SANDBOX}/xdg-data"
mkdir -p "${xdg_data_home}/opencode"
saved_active_db="$ACTIVE_DB"
saved_archive_db="$ARCHIVE_DB"
ACTIVE_DB="${xdg_data_home}/opencode/opencode.db"
ARCHIVE_DB="${xdg_data_home}/opencode/opencode-archive.db"
_make_active_db_with_session_path
ACTIVE_DB="$saved_active_db"
ARCHIVE_DB="$saved_archive_db"

set +e
out=$(XDG_DATA_HOME="$xdg_data_home" "$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive honors XDG_DATA_HOME default DB path"
else
	_fail "XDG_DATA_HOME archive failed with rc=$rc — output: $out"
fi

xdg_archived_event_count=$(sqlite3 "${xdg_data_home}/opencode/opencode-archive.db" "SELECT COUNT(*) FROM event WHERE aggregate_id='ses1';")
if [[ "$xdg_archived_event_count" == "1" ]]; then
	_pass "XDG_DATA_HOME archive stores events next to isolated DB"
else
	_fail "XDG_DATA_HOME event archive mismatch: ${xdg_archived_event_count}"
fi

path_override_dir="${SANDBOX}/path-override"
mkdir -p "$path_override_dir"
saved_active_db="$ACTIVE_DB"
saved_archive_db="$ARCHIVE_DB"
ACTIVE_DB="${path_override_dir}/custom-opencode.db"
ARCHIVE_DB="${path_override_dir}/opencode-archive.db"
_make_active_db_with_session_path
ACTIVE_DB="$saved_active_db"
ARCHIVE_DB="$saved_archive_db"

set +e
out=$(OPENCODE_DB_PATH="${path_override_dir}/custom-opencode.db" "$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive honors OPENCODE_DB_PATH override"
else
	_fail "OPENCODE_DB_PATH archive failed with rc=$rc — output: $out"
fi

path_override_event_count=$(sqlite3 "${path_override_dir}/opencode-archive.db" "SELECT COUNT(*) FROM event WHERE aggregate_id='ses1';")
if [[ "$path_override_event_count" == "1" ]]; then
	_pass "OPENCODE_DB_PATH archive defaults archive DB next to active DB"
else
	_fail "OPENCODE_DB_PATH event archive mismatch: ${path_override_event_count}"
fi

home_unset_dir="${SANDBOX}/home-unset"
mkdir -p "${home_unset_dir}/opencode"
saved_active_db="$ACTIVE_DB"
saved_archive_db="$ARCHIVE_DB"
ACTIVE_DB="${home_unset_dir}/opencode/opencode.db"
ARCHIVE_DB="${home_unset_dir}/opencode/opencode-archive.db"
_make_active_db_with_session_path
ACTIVE_DB="$saved_active_db"
ARCHIVE_DB="$saved_archive_db"

set +e
out=$(env -u HOME XDG_DATA_HOME="$home_unset_dir" "$HELPER" archive --dry-run --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
	_pass "archive dry run is safe when HOME is unset and XDG_DATA_HOME is set"
else
	_fail "HOME-unset dry run failed with rc=$rc — output: $out"
fi

set +e
out=$(env -u HOME -u XDG_DATA_HOME "$HELPER" stats 2>&1)
rc=$?
set -e

if [[ "$rc" -ne 0 && "$out" == *"Active DB not found: opencode/opencode.db"* ]]; then
	_pass "archive default path avoids root directory when HOME and XDG_DATA_HOME are unset"
else
	_fail "HOME/XDG unset default path mismatch with rc=$rc — output: $out"
fi

# Active database holders are a hard veto before candidate selection or writes.
_reset_dbs
_make_active_db_with_session_path
mock_holder="${SANDBOX}/mock-holder"
printf '%s\n' '#!/usr/bin/env bash' 'printf "4242\n"' 'exit 0' >"$mock_holder"
chmod +x "$mock_holder"
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_HOLDER_COMMAND="$mock_holder" OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 \
	"$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e
active_sessions=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session;")
if [[ "$rc" -eq 2 && "$active_sessions" == "1" && ! -e "$ARCHIVE_DB" && "$out" == *"hold the active DB open"* ]]; then
	_pass "active DB holder veto leaves logical sessions untouched"
else
	_fail "active-holder veto mismatch: rc=${rc}, active=${active_sessions}, output=${out}"
fi

# A changing WAL is a hard veto even when holder inspection reports idle.
_reset_dbs
_make_active_db_with_session_path
mock_idle_holder="${SANDBOX}/mock-idle-holder"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$mock_idle_holder"
chmod +x "$mock_idle_holder"
(
	sleep 1
	: >"${ACTIVE_DB}-wal"
) &
wal_writer_pid=$!
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_HOLDER_COMMAND="$mock_idle_holder" OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=3 \
	"$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e
wait "$wal_writer_pid"
rm -f "${ACTIVE_DB}-wal" "${ACTIVE_DB}-shm"
active_sessions=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session;")
if [[ "$rc" -eq 2 && "$active_sessions" == "1" && ! -e "$ARCHIVE_DB" && "$out" == *"active WAL changed"* ]]; then
	_pass "changing WAL veto leaves logical sessions untouched"
else
	_fail "changing-WAL veto mismatch: rc=${rc}, active=${active_sessions}, output=${out}"
fi

# Unavailable and future schemas remain unknown and are never partially moved.
_reset_dbs
printf 'not-a-sqlite-database\n' >"$ACTIVE_DB"
before_checksum=$(cksum "$ACTIVE_DB")
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --retention-days 0 2>&1)
rc=$?
set -e
after_checksum=$(cksum "$ACTIVE_DB")
if [[ "$rc" -eq 3 && "$before_checksum" == "$after_checksum" && ! -e "$ARCHIVE_DB" && "$out" == *"schema"* ]]; then
	_pass "unavailable schema fails closed without creating an archive"
else
	_fail "unavailable-schema fail-closed mismatch: rc=${rc}, output=${out}"
fi

_reset_dbs
_make_active_db_with_session_path
sqlite3 "$ACTIVE_DB" "ALTER TABLE session ADD COLUMN future_payload text; UPDATE session SET future_payload='preserve-me';"
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --retention-days 0 2>&1)
rc=$?
set -e
future_payload=$(sqlite3 "$ACTIVE_DB" "SELECT future_payload FROM session WHERE id='ses1';")
if [[ "$rc" -eq 3 && "$future_payload" == "preserve-me" && ! -e "$ARCHIVE_DB" && "$out" == *"table=session"* && "$out" == *"actual_columns="* && "$out" == *"supported_columns="* && "$out" == *"reason=column-mismatch"* ]]; then
	_pass "future session columns fail closed with structured mismatch diagnostics"
else
	_fail "future-schema fail-closed mismatch: rc=${rc}, payload=${future_payload}, output=${out}"
fi

_reset_dbs
_make_active_db_1_18_3
sqlite3 "$ACTIVE_DB" "CREATE TABLE future_session_data (session_id text NOT NULL, payload blob NOT NULL); INSERT INTO future_session_data VALUES ('ses-1183', X'00FF10');"
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --retention-days 0 2>&1)
rc=$?
set -e
future_table_payload=$(sqlite3 "$ACTIVE_DB" "SELECT hex(payload) FROM future_session_data WHERE session_id='ses-1183';")
if [[ "$rc" -eq 3 && "$future_table_payload" == "00FF10" && ! -e "$ARCHIVE_DB" && "$out" == *"table=future_session_data"* && "$out" == *"actual_columns=[session_id,payload]"* && "$out" == *"supported_columns=[no-additional-session-id-table]"* && "$out" == *"reason=unknown-session-table"* ]]; then
	_pass "unknown future session tables are named and left untouched"
else
	_fail "future-table fail-closed mismatch: rc=${rc}, payload=${future_table_payload}, output=${out}"
fi

# A signal between committed batches leaves both databases queryable and every
# logical session present in exactly one database.
_reset_dbs
_make_active_db_1_18_3
_add_second_active_1_18_3_session
interrupt_output="${SANDBOX}/interrupt-output.log"
OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 OPENCODE_DB_ARCHIVE_BATCH_SIZE=1 \
	OPENCODE_DB_ARCHIVE_BATCH_DELAY_SECONDS=10 \
	"$HELPER" archive --retention-days 0 --max-duration-seconds 30 >"$interrupt_output" 2>&1 &
archive_pid=$!
archive_progress=0
interrupt_log=""
for _attempt in {1..100}; do
	if [[ -f "$interrupt_output" ]]; then
		interrupt_log=$(<"$interrupt_output")
		if [[ "$interrupt_log" == *"Archived 1/2 sessions"* ]]; then
			archive_progress=1
			break
		fi
	fi
	sleep 0.05
done
kill -TERM "$archive_pid" 2>/dev/null || true
set +e
wait "$archive_pid"
rc=$?
set -e
active_quick_check=$(sqlite3 "$ACTIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
archive_quick_check=$(sqlite3 "$ARCHIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
preserved_sessions=$(sqlite3 "$ACTIVE_DB" "ATTACH DATABASE '$ARCHIVE_DB' AS archive; SELECT COUNT(*) FROM (SELECT id FROM main.session UNION SELECT id FROM archive.session);" 2>/dev/null || printf '0')
preserved_graph_rows=$(sqlite3 "$ACTIVE_DB" "ATTACH DATABASE '$ARCHIVE_DB' AS archive; SELECT (SELECT COUNT(*) FROM main.session) + (SELECT COUNT(*) FROM archive.session) + (SELECT COUNT(*) FROM main.message) + (SELECT COUNT(*) FROM archive.message) + (SELECT COUNT(*) FROM main.part) + (SELECT COUNT(*) FROM archive.part) + (SELECT COUNT(*) FROM main.todo) + (SELECT COUNT(*) FROM archive.todo) + (SELECT COUNT(*) FROM main.session_share) + (SELECT COUNT(*) FROM archive.session_share) + (SELECT COUNT(*) FROM main.session_message) + (SELECT COUNT(*) FROM archive.session_message) + (SELECT COUNT(*) FROM main.session_input) + (SELECT COUNT(*) FROM archive.session_input) + (SELECT COUNT(*) FROM main.session_context_epoch) + (SELECT COUNT(*) FROM archive.session_context_epoch) + (SELECT COUNT(*) FROM main.event_sequence) + (SELECT COUNT(*) FROM archive.event_sequence) + (SELECT COUNT(*) FROM main.event) + (SELECT COUNT(*) FROM archive.event);" 2>/dev/null || printf '0')
if [[ "$archive_progress" -eq 1 && "$rc" -eq 143 && "$active_quick_check" == "ok" && "$archive_quick_check" == "ok" && "$preserved_sessions" == "2" && "$preserved_graph_rows" == "20" ]]; then
	_pass "interrupted archive preserves every 1.18.3 graph row in exactly one database"
else
	_fail "interrupted archive mismatch: progress=${archive_progress}, rc=${rc}, active=${active_quick_check}, archive=${archive_quick_check}, sessions=${preserved_sessions}, graph_rows=${preserved_graph_rows}, output=${interrupt_log}"
fi

# VACUUM is bracketed by idle-only checkpoints and leaves both DBs verified.
_reset_dbs
_make_active_db_with_session_path
sqlite3 "$ACTIVE_DB" "UPDATE message SET data=hex(randomblob(262144));"
set +e
out=$(OPENCODE_DB="$ACTIVE_DB" OPENCODE_ARCHIVE_DB="$ARCHIVE_DB" \
	OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS=0 "$HELPER" archive --retention-days 0 --max-duration-seconds 30 2>&1)
rc=$?
set -e
active_quick_check=$(sqlite3 "$ACTIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
archive_quick_check=$(sqlite3 "$ARCHIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
if [[ "$rc" -eq 0 && "$out" == *"pre-VACUUM wal_checkpoint(TRUNCATE)"* && "$out" == *"post-VACUUM wal_checkpoint(TRUNCATE)"* && "$active_quick_check" == "ok" && "$archive_quick_check" == "ok" ]]; then
	_pass "archive VACUUM uses idle checkpoints and verifies both databases"
else
	_fail "archive VACUUM coordination mismatch: rc=${rc}, active=${active_quick_check}, archive=${archive_quick_check}, output=${out}"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
