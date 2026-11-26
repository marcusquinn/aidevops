#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for monthly archive segment sealing (GH#40419 phase 2).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../opencode-db-archive-seal-lib.sh"
HELPER="${SCRIPT_DIR}/../opencode-db-archive.sh"

if ! command -v sqlite3 >/dev/null 2>&1; then
	printf 'SKIP: sqlite3 not available\n'
	exit 0
fi

PASS=0
FAIL=0
_pass() {
	PASS=$((PASS + 1))
	printf '  PASS %s\n' "$1"
	return 0
}
_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	return 0
}

SANDBOX=$(mktemp -d)
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

LEGACY="${SANDBOX}/opencode-archive.db"
for month in 2026-09 2026-10 2026-11; do
	sqlite3 "${SANDBOX}/opencode-archive-${month}.db" "CREATE TABLE session (id text PRIMARY KEY); INSERT INTO session VALUES ('s-${month}');"
done

# shellcheck source=../opencode-db-archive-seal-lib.sh
source "$LIB"

# 2026-11-26: Sep and Oct are complete past the grace; Nov is current.
export OPENCODE_ARCHIVE_NOW_EPOCH_OVERRIDE
OPENCODE_ARCHIVE_NOW_EPOCH_OVERRIDE=$(date -u -j -f '%Y-%m-%d' 2026-11-26 +%s 2>/dev/null || date -u -d 2026-11-26 +%s)

sealed_out=$(opencode_archive_seal_due "$LEGACY" 7)
if [[ "$sealed_out" == *"opencode-archive-2026-09.db"* && "$sealed_out" == *"opencode-archive-2026-10.db"* && "$sealed_out" != *"2026-11"* ]]; then
	_pass "only completed months are sealed"
else
	_fail "unexpected seal output: ${sealed_out}"
fi

mode=$(ls -l "${SANDBOX}/opencode-archive-2026-09.db" | cut -c1-10)
if [[ "$mode" == "-r--r--r--" ]]; then
	_pass "sealed segment is 0444"
else
	_fail "sealed segment mode is ${mode}"
fi

manifest=$(opencode_archive_manifest_path "$LEGACY")
recorded=$(awk -F'\t' '$1 == "opencode-archive-2026-09.db" {print $4}' "$manifest")
actual=$(_opencode_archive_sha256 "${SANDBOX}/opencode-archive-2026-09.db")
if [[ -n "$recorded" && "$recorded" == "$actual" ]]; then
	_pass "manifest sha256 matches sealed file"
else
	_fail "manifest sha256 ${recorded} != ${actual}"
fi

before=$(_opencode_archive_sha256 "${SANDBOX}/opencode-archive-2026-10.db")
second_out=$(opencode_archive_seal_due "$LEGACY" 7)
after=$(_opencode_archive_sha256 "${SANDBOX}/opencode-archive-2026-10.db")
if [[ -z "$second_out" && "$before" == "$after" ]] && [[ "$(wc -l <"$manifest" | tr -d ' ')" == "2" ]]; then
	_pass "second seal pass is a no-op"
else
	_fail "second seal pass changed state"
fi

if opencode_archive_is_sealed "${SANDBOX}/opencode-archive-2026-09.db" "$LEGACY" && ! opencode_archive_is_sealed "${SANDBOX}/opencode-archive-2026-11.db" "$LEGACY"; then
	_pass "is_sealed distinguishes sealed and current segments"
else
	_fail "is_sealed gave wrong answer"
fi

# The archive entry point exposes the same pass as `seal`.
sqlite3 "${SANDBOX}/opencode-archive-2026-08.db" "CREATE TABLE session (id text PRIMARY KEY);"
cli_out=$(OPENCODE_DB_PATH="${SANDBOX}/opencode.db" OPENCODE_ARCHIVE_DB="$LEGACY" bash "$HELPER" seal 2>&1 || true)
if [[ -f "${SANDBOX}/opencode-archive-2026-08.db" ]] && opencode_archive_is_sealed "${SANDBOX}/opencode-archive-2026-08.db" "$LEGACY"; then
	_pass "seal command seals due segments"
else
	_fail "seal command did not seal: ${cli_out}"
fi

if [[ "$(opencode_archive_manifest_path archive.db)" == ./opencode-archive-manifest.tsv && "$(opencode_archive_segment_path archive.db 2026-11)" == ./opencode-archive-2026-11.db ]]; then
	_pass "bare archive filenames use the current directory"
else
	_fail "bare archive filenames produce invalid paths"
fi

# Simulate UTC November while the local calendar is still October.
if (
	date() {
		if [[ "$*" == '-u +%Y-%m' ]]; then
			printf '2026-11\n'
		else
			printf '2026-10\n'
		fi
		return 0
	}
	unset OPENCODE_ARCHIVE_MONTH_OVERRIDE
	[[ "$(opencode_archive_current_segment archive.db)" == ./opencode-archive-2026-11.db ]]
); then
	_pass "writer month uses UTC at the month boundary"
else
	_fail "writer month disagrees with UTC sealing boundary"
fi

failure_segment="${SANDBOX}/opencode-archive-2026-07.db"
sqlite3 "$failure_segment" 'CREATE TABLE session (id text PRIMARY KEY);'
if (
	sha256sum() { return 1; }
	! opencode_archive_seal_segment "$failure_segment" "$LEGACY" &&
		! opencode_archive_is_sealed "$failure_segment" "$LEGACY" && [[ -w "$failure_segment" ]]
); then
	_pass "checksum command failure leaves no completion row"
else
	_fail "checksum command failure was ignored"
fi
if (
	sha256sum() { printf 'not-a-digest\n'; return 0; }
	! opencode_archive_seal_segment "$failure_segment" "$LEGACY" &&
		! opencode_archive_is_sealed "$failure_segment" "$LEGACY"
); then
	_pass "malformed checksum output is rejected"
else
	_fail "malformed checksum was published"
fi
if (
	chmod() {
		local mode="$1"
		[[ "$mode" != 0444 ]] || return 1
		command chmod "$@"
		return 0
	}
	! opencode_archive_seal_segment "$failure_segment" "$LEGACY" &&
		! opencode_archive_is_sealed "$failure_segment" "$LEGACY" && [[ -w "$failure_segment" ]]
); then
	_pass "chmod failure leaves no completion row"
else
	_fail "chmod failure published completion"
fi
if (
	mv() { return 1; }
	! opencode_archive_seal_segment "$failure_segment" "$LEGACY" &&
		! opencode_archive_is_sealed "$failure_segment" "$LEGACY" && [[ -w "$failure_segment" ]]
); then
	_pass "manifest publication failure restores a writable retryable segment"
else
	_fail "manifest publication failure left untracked sealed state"
fi

opencode_archive_seal_segment "$failure_segment" "$LEGACY" &
first_pid=$!
opencode_archive_seal_segment "$failure_segment" "$LEGACY" &
second_pid=$!
if wait "$first_pid" && wait "$second_pid" &&
	[[ "$(awk -F'\t' '$1 == "opencode-archive-2026-07.db" { n++ } END { print n }' "$manifest")" == 1 ]] &&
	[[ "$(awk -F'\t' '$1 == "opencode-archive-2026-07.db" { print $4 }' "$manifest")" == "$(_opencode_archive_sha256 "$failure_segment")" ]]; then
	_pass "concurrent seals publish one matching digest after failed attempts"
else
	_fail "concurrent seals corrupted or duplicated completion"
fi

# A split family with stale legacy copies and a duplicate child. Use the real
# restore CLI, with segmented writing disabled, to exercise read precedence.
restore_dir="${SANDBOX}/restore"
mkdir "$restore_dir"
active="${restore_dir}/active.db"
legacy="${restore_dir}/archive.db"
september="${restore_dir}/opencode-archive-2026-09.db"
october="${restore_dir}/opencode-archive-2026-10.db"
for db in "$active" "$legacy" "$september" "$october"; do
	sqlite3 "$db" 'CREATE TABLE project (id text PRIMARY KEY);
CREATE TABLE session (id text PRIMARY KEY, parent_id text, project_id text, title text);
CREATE TABLE message (id text PRIMARY KEY, session_id text, data text);'
done
sqlite3 "$legacy" "INSERT INTO project VALUES ('p'); INSERT INTO session VALUES ('parent',NULL,'p','stale'),('child','parent','p','stale'); INSERT INTO message VALUES ('mc','child','stale');"
sqlite3 "$september" "INSERT INTO project VALUES ('p'); INSERT INTO session VALUES ('parent',NULL,'p','new-parent'),('child','parent','p','older-child'); INSERT INTO message VALUES ('mp','parent','parent-data'),('mc','child','older-data');"
sqlite3 "$october" "INSERT INTO project VALUES ('p'); INSERT INTO session VALUES ('child','parent','p','new-child'); INSERT INTO message VALUES ('mc','child','new-data');"
opencode_archive_seal_segment "$september" "$legacy"
opencode_archive_seal_segment "$october" "$legacy"
before=$(_opencode_archive_sha256 "$september")
cli_out=$(OPENCODE_DB_PATH="$active" OPENCODE_ARCHIVE_DB="$legacy" OPENCODE_ARCHIVE_SEGMENTED=0 bash "$HELPER" restore --session parent --dry-run)
if [[ "$(sqlite3 "$active" 'SELECT COUNT(*) FROM session;')" == 0 ]]; then
	_pass "split-family dry run does not modify the active DB"
else
	_fail "split-family dry run modified the active DB"
fi
cli_out=$(OPENCODE_DB_PATH="$active" OPENCODE_ARCHIVE_DB="$legacy" OPENCODE_ARCHIVE_SEGMENTED=0 bash "$HELPER" restore --session parent)
if [[ "$(sqlite3 "$active" 'SELECT group_concat(title) FROM (SELECT title FROM session ORDER BY id);')" == new-child,new-parent &&
	"$(sqlite3 "$active" "SELECT data FROM message WHERE id='mc';")" == new-data &&
	"$before" == "$(_opencode_archive_sha256 "$september")" ]]; then
	_pass "split-family restore selects newest copy per ID and preserves sealed files"
else
	_fail "split-family restore mismatch: ${cli_out}"
fi
# Retry with an already-active parent must still recover archived children.
sqlite3 "$active" "DELETE FROM message WHERE session_id='child'; DELETE FROM session WHERE id='child';"
cli_out=$(OPENCODE_DB_PATH="$active" OPENCODE_ARCHIVE_DB="$legacy" bash "$HELPER" restore --session parent)
if [[ "$(sqlite3 "$active" "SELECT title FROM session WHERE id='child';")" == new-child ]]; then
	_pass "restore retries finish children when the parent is already active"
else
	_fail "restore retry skipped archived children: ${cli_out}"
fi

# Migration: split a legacy archive across 3 months (GH#40419 phase 3).
mig="${SANDBOX}/mig"
mkdir -p "$mig" "${mig}/trash"
sqlite3 "${mig}/opencode-archive.db" "CREATE TABLE project (id text PRIMARY KEY); CREATE TABLE session (id text PRIMARY KEY, project_id text, time_updated integer, time_created integer); CREATE TABLE message (id text PRIMARY KEY, session_id text); INSERT INTO project VALUES ('p'); INSERT INTO session VALUES ('a','p',1788220800000,1),('b','p',1790812800000,1),('c','p',1793491200000,1); INSERT INTO message VALUES ('m1','a'),('m2','b'),('m3','b'),('m4','c');"
# shellcheck source=../opencode-db-archive-migrate-lib.sh
source "${SCRIPT_DIR}/../opencode-db-archive-migrate-lib.sh"
dry=$(opencode_archive_migrate "${mig}/opencode-archive.db")
if [[ -f "${mig}/opencode-archive.db" && "$(grep -c '^would create' <<<"$dry")" == 3 ]]; then
	_pass "migrate dry run reports 3 segments and changes nothing"
else
	_fail "migrate dry run unexpected: ${dry}"
fi
mig_out=$(OPENCODE_ARCHIVE_TRASH_DIR="${mig}/trash" opencode_archive_migrate "${mig}/opencode-archive.db" --apply 2>&1) || true
total=0
for f in "${mig}"/opencode-archive-20??-??.db; do
	[[ "$(sqlite3 "$f" 'PRAGMA quick_check;')" == ok ]] || _fail "quick_check failed for ${f##*/}"
	total=$((total + $(sqlite3 "$f" 'SELECT COUNT(*) FROM message;')))
done
if [[ "$total" == 4 && ! -e "${mig}/opencode-archive.db" ]] && [[ -n "$(ls "${mig}/trash")" ]]; then
	_pass "migrate preserves row counts and moves the original to trash"
else
	_fail "migrate result unexpected (total=${total}): ${mig_out}"
fi

# Index: restored marks live in the index, never in a sealed segment.
# shellcheck source=../opencode-db-archive-segments-lib.sh
source "${SCRIPT_DIR}/../opencode-db-archive-segments-lib.sh"
# shellcheck source=../opencode-db-archive-index-lib.sh
source "${SCRIPT_DIR}/../opencode-db-archive-index-lib.sh"
idx="${SANDBOX}/idx"
mkdir -p "$idx"
sqlite3 "${idx}/opencode-archive-2026-09.db" "CREATE TABLE session (id text PRIMARY KEY); INSERT INTO session VALUES ('x1');"
sqlite3 "${idx}/opencode-archive-2026-11.db" "CREATE TABLE session (id text PRIMARY KEY); INSERT INTO session VALUES ('x1');"
sealed_sha_before=$(_opencode_archive_sha256 "${idx}/opencode-archive-2026-09.db")
opencode_archive_index_record "${idx}/opencode-archive.db" "${idx}/opencode-archive-2026-09.db"
[[ "$(opencode_archive_index_lookup "${idx}/opencode-archive.db" x1)" == opencode-archive-2026-09.db ]] && _pass "index lookup resolves the segment" || _fail "index lookup failed"
opencode_archive_index_mark_restored "${idx}/opencode-archive.db" x1
if ! opencode_archive_index_lookup "${idx}/opencode-archive.db" x1 >/dev/null && [[ "$(_opencode_archive_sha256 "${idx}/opencode-archive-2026-09.db")" == "$sealed_sha_before" ]]; then
	_pass "restored mark is in the index and the segment is unchanged"
else
	_fail "restored mark leaked or lookup still resolves"
fi
opencode_archive_index_record "${idx}/opencode-archive.db" "${idx}/opencode-archive-2026-11.db"
[[ "$(opencode_archive_index_lookup "${idx}/opencode-archive.db" x1)" == opencode-archive-2026-11.db ]] && _pass "re-archive points the index at the newest segment" || _fail "re-archive did not update the index"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
