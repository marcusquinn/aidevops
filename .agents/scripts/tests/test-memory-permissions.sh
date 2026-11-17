#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#38806: memory dir/DB/backups must be owner-only (700/600).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AIDEVOPS_MEMORY_DIR="$TMP/mem"
# Isolate from any real Vault so the store gate cannot return VAULT_LOCKED
export AIDEVOPS_VAULT_DIR="$TMP/vault"
unset AIDEVOPS_VAULT_REQUIRE
fail=0

mode_of() {
	local path="$1"
	stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path"
	return 0
}

check() {
	local label="$1" want="$2" got="$3"
	if [[ "$want" == "$got" ]]; then
		echo "PASS: $label ($got)"
	else
		echo "FAIL: $label (want $want, got $got)"
		fail=1
	fi
	return 0
}

bash "$SCRIPTS/memory-helper.sh" store --content "permission test" >/dev/null 2>&1
check "fresh dir" 700 "$(mode_of "$AIDEVOPS_MEMORY_DIR")"
check "fresh db" 600 "$(mode_of "$AIDEVOPS_MEMORY_DIR/memory.db")"

chmod 755 "$AIDEVOPS_MEMORY_DIR"
chmod 644 "$AIDEVOPS_MEMORY_DIR/memory.db"
bash "$SCRIPTS/memory-helper.sh" stats >/dev/null 2>&1
check "repaired dir" 700 "$(mode_of "$AIDEVOPS_MEMORY_DIR")"
check "repaired db" 600 "$(mode_of "$AIDEVOPS_MEMORY_DIR/memory.db")"

# shellcheck source=../shared-sqlite-backup.sh
source "$SCRIPTS/shared-sqlite-backup.sh"
backup="$(backup_sqlite_db "$AIDEVOPS_MEMORY_DIR/memory.db" t)"
check "backup" 600 "$(mode_of "$backup")"

exit "$fail"
