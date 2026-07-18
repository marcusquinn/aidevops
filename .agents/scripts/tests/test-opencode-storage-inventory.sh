#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../storage-inventory-helper.sh"
SAFETY_LIB="$SCRIPT_DIR/../opencode-db-safety-lib.sh"
SHARED_CONSTANTS="$SCRIPT_DIR/../shared-constants.sh"
TEST_ROOT="$(mktemp -d -t aidevops-opencode-storage.XXXXXX)"
HOME="$TEST_ROOT/home"
export HOME

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required"

data_root="$HOME/.local/share/opencode"
active_db="$data_root/opencode.db"
archive_db="$data_root/opencode-archive.db"
mkdir -p "$data_root/storage" "$data_root/tool" "$data_root/future-format-v2"

sqlite3 "$active_db" <<'SQL'
CREATE TABLE project (id text PRIMARY KEY);
CREATE TABLE session (id text PRIMARY KEY, title text);
CREATE TABLE message (id text PRIMARY KEY, session_id text);
CREATE TABLE part (id text PRIMARY KEY, session_id text);
INSERT INTO session VALUES ('ses-private', 'PRIVATE_SENTINEL_TITLE');
SQL
sqlite3 "$archive_db" <<'SQL'
CREATE TABLE project (id text PRIMARY KEY);
CREATE TABLE session (id text PRIMARY KEY, title text);
CREATE TABLE message (id text PRIMARY KEY, session_id text);
CREATE TABLE part (id text PRIMARY KEY, session_id text);
INSERT INTO session VALUES ('ses-archived', 'ARCHIVE_PRIVATE_SENTINEL');
SQL
printf 'legacy-format\n' >"$data_root/storage/session.json"
printf 'tool-output\n' >"$data_root/tool/output.bin"
printf 'future-format\n' >"$data_root/future-format-v2/blob.bin"

fixture_checksum() {
	cksum "$active_db" "$archive_db" \
		"$data_root/storage/session.json" \
		"$data_root/tool/output.bin" \
		"$data_root/future-format-v2/blob.bin"
	return 0
}

idle_holder="$TEST_ROOT/idle-holder"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$idle_holder"
chmod +x "$idle_holder"

before_checksum=$(fixture_checksum)
report=$(AIDEVOPS_OPENCODE_DATA_DIR="$data_root" \
	AIDEVOPS_STORAGE_LSOF_COMMAND="$idle_holder" \
	AIDEVOPS_STORAGE_WAL_SAMPLE_DELAY_SECONDS=0 \
	bash "$HELPER" json)
after_checksum=$(fixture_checksum)

[[ "$before_checksum" == "$after_checksum" ]] || fail "inventory changed OpenCode fixture bytes"
[[ "$report" != *"PRIVATE_SENTINEL_TITLE"* && "$report" != *"ARCHIVE_PRIVATE_SENTINEL"* ]] || fail "inventory exposed private session content"
[[ "$(printf '%s' "$report" | jq -r '.schema_version')" == "2" ]] || fail "OpenCode inventory schema version missing"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-active-db") | [.owner,.safety_class,(.protected_bytes > 0),.unknown_bytes] | @tsv')" == $'joint\tactive\ttrue\t0' ]] || fail "active DB was not jointly owned and protected"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-active-wal") | [.owner,.safety_class,.reclaimable_bytes] | @tsv')" == $'joint\tactive\t0' ]] || fail "active WAL lifecycle was not protected"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-archive") | [.owner,.safety_class,(.protected_bytes > 0)] | @tsv')" == $'joint\tarchive\ttrue' ]] || fail "archive bytes were not jointly owned and protected"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-legacy") | [.owner,.safety_class,(.unknown_bytes > 0)] | @tsv')" == $'unknown\tunknown\ttrue' ]] || fail "legacy format was not fail-closed unknown"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-tool-output") | [.owner,.safety_class,(.unknown_bytes > 0)] | @tsv')" == $'unknown\tunknown\ttrue' ]] || fail "tool output was not fail-closed unknown"
[[ "$(printf '%s' "$report" | jq -r '.stores[] | select(.store_id == "opencode-unclassified") | [.owner,.safety_class,(.unknown_bytes > 0)] | @tsv')" == $'unknown\tunknown\ttrue' ]] || fail "future format was not reported as unclassified"
[[ "$(printf '%s' "$report" | jq '[.stores[] | select(.store_id | startswith("opencode-")) | .reclaimable_bytes] | add')" == "0" ]] || fail "OpenCode storage exposed generic cleanup candidates"

active_holder="$TEST_ROOT/active-holder"
printf '%s\n' '#!/usr/bin/env bash' 'printf "999\n"' 'exit 0' >"$active_holder"
chmod +x "$active_holder"
holder_report=$(AIDEVOPS_OPENCODE_DATA_DIR="$data_root" \
	AIDEVOPS_STORAGE_LSOF_COMMAND="$active_holder" \
	AIDEVOPS_STORAGE_WAL_SAMPLE_DELAY_SECONDS=0 \
	bash "$HELPER" json)
[[ "$(printf '%s' "$holder_report" | jq -r '.stores[] | select(.store_id == "opencode-active-wal") | .protection_reasons[0]')" == *"holder detected"* ]] || fail "active holder was not surfaced as a hard protection reason"

bad_root="$TEST_ROOT/bad-opencode"
mkdir -p "$bad_root"
printf 'unavailable-schema\n' >"$bad_root/opencode.db"
bad_report=$(AIDEVOPS_OPENCODE_DATA_DIR="$bad_root" \
	AIDEVOPS_STORAGE_LSOF_COMMAND="$idle_holder" \
	AIDEVOPS_STORAGE_WAL_SAMPLE_DELAY_SECONDS=0 \
	bash "$HELPER" json)
[[ "$(printf '%s' "$bad_report" | jq -r '.stores[] | select(.store_id == "opencode-active-db") | [.safety_class,(.unknown_bytes > 0),.reclaimable_bytes] | @tsv')" == $'unknown\ttrue\t0' ]] || fail "unavailable active schema did not remain unknown"

# Exercise the shared changing-WAL probe directly with an isolated fixture.
# shellcheck source=../shared-constants.sh
source "$SHARED_CONSTANTS"
# shellcheck source=../opencode-db-safety-lib.sh
source "$SAFETY_LIB"
changing_wal="$TEST_ROOT/changing.wal"
printf 'before\n' >"$changing_wal"
(
	sleep 1
	printf 'after\n' >>"$changing_wal"
) &
writer_pid=$!
wal_state=$(opencode_db_wal_state "$TEST_ROOT/unused.db" 2 "$changing_wal")
wait "$writer_pid"
[[ "$wal_state" == "changing" ]] || fail "changing WAL fixture was not detected"

printf 'PASS: OpenCode storage is ownership-aware, content-private, and fail-closed\n'
exit 0
