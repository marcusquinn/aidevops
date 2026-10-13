#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#34574: sourced SQLite verifiers must not inherit table delimiters from IFS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shared-sqlite-backup.sh
source "${SCRIPT_DIR}/shared-sqlite-backup.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

command -v sqlite3 >/dev/null || fail "sqlite3 is required"
temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$temp_root"
workspace=$(mktemp -d "${temp_root}/sqlite-backup-ifs.XXXXXX")
trap 'rm -rf "$workspace"' EXIT
db_path="$workspace/current.db"
backup_path="$workspace/backup.db"
sqlite3 "$backup_path" 'CREATE TABLE first_table (id INTEGER); INSERT INTO first_table VALUES (1); CREATE TABLE second_table (id INTEGER); INSERT INTO second_table VALUES (1), (2);'

for caller_ifs in $' \t\n' $'\n\t'; do
	IFS="$caller_ifs"
	cp "$backup_path" "$db_path"
	for verifier in verify_sqlite_backup verify_migration_rowcounts; do
		"$verifier" "$db_path" "$backup_path" 'first_table second_table' ||
			fail "$verifier rejected matching tables under caller IFS"
		[[ "$IFS" == "$caller_ifs" ]] || fail "$verifier changed caller IFS"
	done

	# Keep the first table intact: loss in the second proves both names are read.
	sqlite3 "$db_path" 'DELETE FROM second_table WHERE id = 2;'
	for verifier in verify_sqlite_backup verify_migration_rowcounts; do
		if "$verifier" "$db_path" "$backup_path" 'first_table second_table'; then
			fail "$verifier accepted row loss in the second table"
		fi
		[[ "$IFS" == "$caller_ifs" ]] || fail "$verifier changed caller IFS on failure"
	done
done

printf 'PASS: both SQLite verifiers split table lists and preserve default/strict caller IFS\n'
