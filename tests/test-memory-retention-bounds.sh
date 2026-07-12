#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

memory() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" AIDEVOPS_VAULT_DIR="$TEST_DIR/no-vault" "$MEMORY_HELPER" "$@"
	return $?
}

for number in 1 2 3 4; do
	memory store --content "Retention fixture $number with enough bytes to exercise hard storage budgets" --type CONTEXT >/dev/null
done
db="$TEST_DIR/memory.db"
old_id=$(sqlite3 "$db" "SELECT id FROM learnings WHERE rowid=(SELECT MIN(rowid) FROM learnings);")
sqlite3 "$db" "UPDATE learnings SET created_at='2020-01-01T00:00:00Z' WHERE id='$old_id'; INSERT INTO learning_access(id,last_accessed_at,access_count) VALUES ('$old_id',datetime('now'),99) ON CONFLICT(id) DO UPDATE SET access_count=99;"

memory prune --older-than-days 1 --max-count 2 --max-bytes 100000 >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM learnings;')" -le 2 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM learnings WHERE id='$old_id';")" == "0" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM observations;')" == "4" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM observation_sources;')" == "4" ]]

memory prune --older-than-days 99999 --max-count 100 --max-bytes 300 >/dev/null
projection_bytes=$(sqlite3 "$db" "SELECT COALESCE(SUM(length(CAST(COALESCE(id,'') AS BLOB))+length(CAST(COALESCE(session_id,'') AS BLOB))+length(CAST(COALESCE(content,'') AS BLOB))+length(CAST(COALESCE(type,'') AS BLOB))+length(CAST(COALESCE(tags,'') AS BLOB))+length(CAST(COALESCE(confidence,'') AS BLOB))+length(CAST(COALESCE(created_at,'') AS BLOB))+length(CAST(COALESCE(event_date,'') AS BLOB))+length(CAST(COALESCE(project_path,'') AS BLOB))+length(CAST(COALESCE(source,'') AS BLOB))),0) FROM learnings;")
[[ "$projection_bytes" -le 300 ]]
memory prune --older-than-days 99999 --max-count 100 --max-bytes 1 >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM learnings;')" == "0" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM observations;')" == "4" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM observation_sources;')" == "4" ]]

# AI-judged mode must execute the relevance pass after enforcing the hard age bound.
prune_source="$REPO_ROOT/.agents/scripts/memory/maintenance-prune.sh"
flat_line=$(grep -n "_prune_flat_threshold \"\$older_than_days\" \"\$dry_run\"" "$prune_source" | sed -n '1s/:.*//p')
ai_line=$(grep -n "_prune_ai_judged \"\$older_than_days\" \"\$dry_run\" \"\$keep_accessed\"" "$prune_source" | sed -n '1s/:.*//p')
[[ -n "$flat_line" && -n "$ai_line" && "$flat_line" -lt "$ai_line" ]]

printf 'PASS: age, AI relevance, count, and byte retention bounds preserve canonical audit evidence\n'
