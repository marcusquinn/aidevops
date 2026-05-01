#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export AIDEVOPS_MEMORY_DIR="$TEST_DIR/memory"
mkdir -p "$AIDEVOPS_MEMORY_DIR"

MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
AUDIT_PULSE="$REPO_ROOT/.agents/scripts/memory-audit-pulse.sh"

seed_duplicate_memories() {
	"$MEMORY_HELPER" stats >/dev/null
	local test_db="$AIDEVOPS_MEMORY_DIR/memory.db"
	local i
	for i in 1 2; do
		local content="duplicate dry-run regression memory group ${i}"
		sqlite3 "$test_db" \
			"INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source) VALUES ('mem_2026050112000${i}_dryrun_a', 'test-session', '$content', 'WORKING_SOLUTION', 'test', 'high', '2026-05-01T12:00:0${i}Z', '2026-05-01T12:00:0${i}Z', '', 'test');"
		sqlite3 "$test_db" \
			"INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source) VALUES ('mem_2026050112010${i}_dryrun_b', 'test-session', '$content', 'WORKING_SOLUTION', 'test', 'high', '2026-05-01T12:01:0${i}Z', '2026-05-01T12:01:0${i}Z', '', 'test');"
	done
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

seed_duplicate_memories

validate_output="$($MEMORY_HELPER validate 2>&1)" || fail "memory-helper validate exited non-zero"

if [[ ! "$validate_output" =~ Found[[:space:]]+2[[:space:]]+groups[[:space:]]+of[[:space:]]+exact[[:space:]]+duplicate[[:space:]]+entries ]]; then
	fail "validate did not report 2 duplicate groups: $validate_output"
fi

dedup_output="$($MEMORY_HELPER dedup --dry-run 2>&1)" || fail "memory-helper dedup --dry-run exited non-zero"

if [[ ! "$dedup_output" =~ Would[[:space:]]+remove[[:space:]]+2[[:space:]]+duplicates ]]; then
	fail "dedup dry-run did not report 2 duplicates: $dedup_output"
fi

if [[ "$dedup_output" =~ syntax[[:space:]]+error ]]; then
	fail "dedup dry-run emitted arithmetic syntax error: $dedup_output"
fi

audit_output="$($AUDIT_PULSE run --force --dry-run 2>&1)" || fail "memory-audit-pulse dry-run exited non-zero"

if [[ ! "$audit_output" =~ Dedup:[[:space:]]+2[[:space:]]+duplicates[[:space:]]+would[[:space:]]+be[[:space:]]+removed ]]; then
	fail "audit pulse did not report matching dedup count: $audit_output"
fi

printf 'PASS: memory dedup dry-run count channel\n'
exit 0
