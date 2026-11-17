#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for GH#38769: memory maintenance must not prune while the
# Vault is locked, must keep accessed rows with --keep-accessed, and must cap
# bulk deletes unless --force.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AIDEVOPS_MEMORY_DIR="$TMP/mem"
export AIDEVOPS_VAULT_DIR="$TMP/vault"
mkdir -p "$TMP/mem" "$TMP/vault"
DB="$TMP/mem/memory.db"
fail=0

check() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
		fail=1
	fi
	return 0
}

count() {
	sqlite3 "$DB" "SELECT COUNT(*) FROM learnings;"
	return 0
}

for i in 1 2 3 4 5 6 7 8; do
	"$SCRIPT_DIR/memory-helper.sh" store --content "gate test entry number $i unique-$i" >/dev/null 2>&1
done
sqlite3 "$DB" "UPDATE learnings SET created_at = datetime('now','-200 days');"
first_id="$(sqlite3 "$DB" "SELECT id FROM learnings LIMIT 1;")"
sqlite3 "$DB" "INSERT OR REPLACE INTO learning_access(id, last_accessed_at, access_count) VALUES('$first_id', datetime('now'), 1);" 2>/dev/null ||
	sqlite3 "$DB" "INSERT OR REPLACE INTO learning_access(id) VALUES('$first_id');"
check "seeded" 8 "$(count)"

# Locked vault: pulse and prune skip
printf '{}\n' >"$TMP/vault/vault.json"
export AIDEVOPS_VAULT_HELPER="$TMP/fake-vault-helper"
printf '#!/usr/bin/env bash\necho locked\nexit 1\n' >"$AIDEVOPS_VAULT_HELPER"
chmod +x "$AIDEVOPS_VAULT_HELPER"
"$SCRIPT_DIR/memory-audit-pulse.sh" run --force >/dev/null 2>&1
check "locked pulse keeps rows" 8 "$(count)"
"$SCRIPT_DIR/memory-helper.sh" prune --older-than-days 90 >/dev/null 2>&1
check "locked prune keeps rows" 8 "$(count)"

# Unlocked: cap refuses without --force when total >= min entries
rm -f "$TMP/vault/vault.json"
AIDEVOPS_MEMORY_PRUNE_CAP_MIN_ENTRIES=5 "$SCRIPT_DIR/memory-helper.sh" prune --older-than-days 90 >/dev/null 2>&1
check "cap refuses bulk delete" 8 "$(count)"

# --keep-accessed preserves the accessed row (forced past the cap)
sqlite3 "$DB" "DELETE FROM learning_access WHERE id != '$first_id';"
accessed_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM learnings WHERE id = '$first_id';")"
"$SCRIPT_DIR/memory-helper.sh" prune --older-than-days 90 --keep-accessed --force >/dev/null 2>&1
check "keep-accessed survivor" "$accessed_count" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM learnings WHERE id = '$first_id';")"
check "unaccessed stale rows pruned" 0 "$(sqlite3 "$DB" "SELECT COUNT(*) FROM learnings WHERE created_at < datetime('now','-90 days') AND id != '$first_id';")"

# Auto-prune must refuse a large delete and mark the attempt, even on store.
for i in 1 2 3 4 5 6 7 8; do
	"$SCRIPT_DIR/memory-helper.sh" store --content "auto prune stale unique entry $i" >/dev/null 2>&1
done
sqlite3 "$DB" "UPDATE learnings SET created_at = datetime('now','-200 days') WHERE id != '$first_id';"
sqlite3 "$DB" "DELETE FROM learning_access WHERE id != '$first_id';"
before_cap="$(count)"
rm -f "$TMP/mem/.last_auto_prune"
AIDEVOPS_MEMORY_PRUNE_CAP_MIN_ENTRIES=5 "$SCRIPT_DIR/memory-helper.sh" store --content 'auto prune cap trigger unique' >"$TMP/cap.log" 2>&1
check "auto-prune cap keeps stale rows" "$((before_cap + 1))" "$(count)"
check "auto-prune cap writes marker" yes "$(if [[ -f "$TMP/mem/.last_auto_prune" ]]; then printf yes; else printf no; fi)"
check "auto-prune cap warns about force" yes "$(if grep -q 'memory-helper.sh prune --force' "$TMP/cap.log"; then printf yes; else printf no; fi)"

# Raising the allowed share makes the same candidates eligible and creates a backup.
before_allowed="$(count)"
sqlite3 "$DB" "DELETE FROM learning_access WHERE id != '$first_id';"
rm -f "$TMP/mem/.last_auto_prune"
AIDEVOPS_MEMORY_PRUNE_CAP_MIN_ENTRIES=5 AIDEVOPS_MEMORY_PRUNE_MAX_SHARE_PCT=90 "$SCRIPT_DIR/memory-helper.sh" store --content 'auto prune allowed trigger unique' >/dev/null 2>&1
check "auto-prune removes eligible rows" 0 "$(sqlite3 "$DB" "SELECT COUNT(*) FROM learnings WHERE created_at < datetime('now','-90 days') AND id != '$first_id';")"
backups=("$TMP"/mem/memory-backup-*-pre-auto-prune.db)
check "auto-prune backup exists" yes "$(if [[ -f "${backups[0]}" ]]; then printf yes; else printf no; fi)"
if [[ -f "${backups[0]}" ]]; then
	check "backup preserves pre-prune rows" "$before_allowed" "$(sqlite3 "${backups[0]}" 'SELECT COUNT(*) FROM learnings;')"
fi

exit "$fail"
