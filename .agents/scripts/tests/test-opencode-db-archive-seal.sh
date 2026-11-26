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

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
