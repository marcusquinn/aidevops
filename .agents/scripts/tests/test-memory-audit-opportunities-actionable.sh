#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export AIDEVOPS_MEMORY_DIR="$TEST_DIR/memory"
export AIDEVOPS_MEMORY_AUDIT_LOG_DIR="$TEST_DIR/audit"
mkdir -p "$AIDEVOPS_MEMORY_DIR" "$AIDEVOPS_MEMORY_AUDIT_LOG_DIR"

MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
AUDIT_PULSE="$REPO_ROOT/.agents/scripts/memory-audit-pulse.sh"
MOCK_TASK_CMD="$TEST_DIR/mock-claim-task-id.sh"
MOCK_LOG="$TEST_DIR/mock-claims.log"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

seed_repeated_failures() {
	"$MEMORY_HELPER" stats >/dev/null
	local test_db="$AIDEVOPS_MEMORY_DIR/memory.db"
	local i
	for i in 1 2 3; do
		sqlite3 "$test_db" \
			"INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source) VALUES ('mem_20260502_action_${i}', 'test-session', 'actionable failure pattern ${i}', 'FAILED_APPROACH', 'memory-audit,test', 'medium', datetime('now'), datetime('now'), '', 'test');"
	done
	return 0
}

write_mock_task_cmd() {
	cat >"$MOCK_TASK_CMD" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

title=""
description=""
labels=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--title)
		title="$2"
		shift 2
		;;
	--description)
		description="$2"
		shift 2
		;;
	--labels)
		labels="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

{
	printf 'title=%s\n' "$title"
	printf 'labels=%s\n' "$labels"
	printf 'description_has_files=%s\n' "$([[ "$description" == *"## Files to modify"* ]] && printf yes || printf no)"
} >>"${MOCK_LOG:?}"
printf 'Created issue GH#999 for %s\n' "$title"
MOCK
	chmod +x "$MOCK_TASK_CMD"
	return 0
}

seed_repeated_failures
write_mock_task_cmd
export AIDEVOPS_MEMORY_AUDIT_TASK_CMD="$MOCK_TASK_CMD"
export MOCK_LOG

dry_output="$($AUDIT_PULSE run --force --dry-run 2>&1)" || fail "dry-run audit exited non-zero: $dry_output"

if [[ ! "$dry_output" =~ Found[[:space:]]+1[[:space:]]+improvement[[:space:]]+opportunities ]]; then
	fail "dry-run did not detect repeated failure opportunity: $dry_output"
fi

if [[ -f "$MOCK_LOG" ]]; then
	fail "dry-run invoked task creation command"
fi

if ! grep -Fq 'would-file' "$AIDEVOPS_MEMORY_AUDIT_LOG_DIR/last-opportunity-actions.txt"; then
	fail "dry-run did not record would-file action"
fi

live_output="$($AUDIT_PULSE run --force 2>&1)" || fail "live audit exited non-zero: $live_output"

if [[ ! -f "$MOCK_LOG" ]]; then
	fail "live audit did not invoke task creation command"
fi

claim_count=$(grep -c '^title=' "$MOCK_LOG" 2>/dev/null || true)
[[ "$claim_count" =~ ^[0-9]+$ ]] || claim_count=0
if [[ "$claim_count" -ne 1 ]]; then
	fail "expected one live task creation, got $claim_count"
fi

if ! grep -Fq 'description_has_files=yes' "$MOCK_LOG"; then
	fail "mock task body was not worker-ready"
fi

second_output="$($AUDIT_PULSE run --force 2>&1)" || fail "second live audit exited non-zero: $second_output"
claim_count=$(grep -c '^title=' "$MOCK_LOG" 2>/dev/null || true)
[[ "$claim_count" =~ ^[0-9]+$ ]] || claim_count=0
if [[ "$claim_count" -ne 1 ]]; then
	fail "duplicate suppression failed; task creations: $claim_count"
fi

if ! grep -Fq 'skipped-duplicate' "$AIDEVOPS_MEMORY_AUDIT_LOG_DIR/last-opportunity-actions.txt"; then
	fail "second live audit did not record duplicate suppression: $second_output"
fi

if ! grep -Fq 'Opportunity filing actions:' "$AIDEVOPS_MEMORY_AUDIT_LOG_DIR"/audit-*.txt; then
	fail "saved audit report did not include filing actions"
fi

printf 'PASS: memory audit opportunities are actionable and deduplicated\n'
exit 0
