#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/.agents/scripts"

source "${REPO_ROOT}/.agents/scripts/issue-sync-lib.sh"
source "${REPO_ROOT}/.agents/scripts/issue-sync-helper-close.sh"
source "${REPO_ROOT}/.agents/scripts/issue-sync-helper-commands.sh"

log_verbose() {
	return 0
}

fail() {
	local message="$1"
	printf '[FAIL] %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf '[PASS] %s\n' "$message"
	return 0
}

test_dedupe_preserves_canonical_brief_line() {
	local tmpdir todo_file count line
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	cat >"$todo_file" <<'EOF'
- [ ] t18002 vault: add GUI Vault sidebar #architecture blocked-by:t17999 tier:thinking ref:GH#25539 logged:2026-06-26 -> [todo/tasks/t18002-brief.md]

- [ ] t18002 vault: add GUI Vault sidebar #architecture #enhancement ref:GH#25539
EOF
	_dedupe_todo_task_lines "t18002" "$todo_file" >/dev/null
	count=$(grep -Ec '^[[:space:]]*- \[.\] t18002 ' "$todo_file" || true)
	[[ "$count" == "1" ]] || fail "expected one t18002 line after dedupe, got $count"
	line=$(grep -E '^[[:space:]]*- \[.\] t18002 ' "$todo_file")
	[[ "$line" == *'-> [todo/tasks/t18002-brief.md]'* ]] || fail "expected canonical brief link to survive"
	rm -rf "$tmpdir"
	pass "dedupe preserves canonical brief line"
	return 0
}

test_mark_done_dedupes_and_adds_verified_proof() {
	local tmpdir todo_file count line
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	cat >"$todo_file" <<'EOF'
- [ ] t18002 vault: add GUI Vault sidebar #architecture blocked-by:t17999 tier:thinking ref:GH#25539 logged:2026-06-26 -> [todo/tasks/t18002-brief.md]

- [ ] t18002 vault: add GUI Vault sidebar #architecture #enhancement ref:GH#25539
EOF
	_mark_todo_done "t18002" "$todo_file" "verified:2026-06-26"
	count=$(grep -Ec '^[[:space:]]*- \[.\] t18002 ' "$todo_file" || true)
	[[ "$count" == "1" ]] || fail "expected one t18002 line after mark done, got $count"
	line=$(grep -E '^[[:space:]]*- \[x\] t18002 ' "$todo_file")
	[[ "$line" == *'verified:2026-06-26'* ]] || fail "expected verified proof on completed line"
	[[ "$line" == *'completed:'* ]] || fail "expected completed metadata on completed line"
	[[ "$line" == *'-> [todo/tasks/t18002-brief.md]'* ]] || fail "expected canonical metadata after mark done"
	rm -rf "$tmpdir"
	pass "mark done dedupes and adds verified proof"
	return 0
}

test_mark_done_completes_in_progress_entry() {
	local tmpdir todo_file line
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	printf '%s\n' '- [>] t18002 active task ref:GH#25539 started:2026-06-26' >"$todo_file"
	_mark_todo_done "t18002" "$todo_file" "pr:#25540"
	line=$(grep -E '^[[:space:]]*- \[x\] t18002 ' "$todo_file")
	[[ "$line" == *'pr:#25540'* ]] || fail "expected proof on completed in-progress line"
	[[ "$line" == *'completed:'* ]] || fail "expected completion date on in-progress line"
	rm -rf "$tmpdir"
	pass "mark done completes in-progress entry"
	return 0
}

test_dedupe_ignores_markdown_fences() {
	local tmpdir todo_file count fenced_count canonical_count
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	cat >"$todo_file" <<'EOF'
```markdown
- [ ] t18002 vault: example task inside docs ref:GH#25539
```

- [ ] t18002 vault: add GUI Vault sidebar #architecture ref:GH#25539
EOF
	_dedupe_todo_task_lines "t18002" "$todo_file" >/dev/null || true
	count=$(grep -Ec '^[[:space:]]*- \[.\] t18002 ' "$todo_file" || true)
	fenced_count=$(grep -Ec 'example task inside docs' "$todo_file" || true)
	canonical_count=$(grep -Ec 'add GUI Vault sidebar' "$todo_file" || true)
	[[ "$count" == "2" ]] || fail "expected fenced and canonical t18002 lines to remain, got $count"
	[[ "$fenced_count" == "1" ]] || fail "expected fenced example line to remain"
	[[ "$canonical_count" == "1" ]] || fail "expected canonical task line to remain"
	rm -rf "$tmpdir"
	pass "dedupe ignores markdown fences"
	return 0
}

test_dedupe_scores_metadata_individually() {
	local tmpdir todo_file line
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	cat >"$todo_file" <<'EOF'
- [ ] t18002 vault: add GUI Vault sidebar #architecture ref:GH#25539 pr:#1
- [ ] t18002 vault: add GUI Vault sidebar #architecture ref:GH#25539 verified:2026-06-26 completed:2026-06-27
EOF
	_dedupe_todo_task_lines "t18002" "$todo_file" >/dev/null
	line=$(grep -E '^[[:space:]]*- \[.\] t18002 ' "$todo_file")
	[[ "$line" == *'verified:2026-06-26'* ]] || fail "expected verified metadata to win cumulative score"
	[[ "$line" == *'completed:2026-06-27'* ]] || fail "expected completed metadata to win cumulative score"
	rm -rf "$tmpdir"
	pass "dedupe scores metadata individually"
	return 0
}

test_status_counts_duplicate_task_rows_once() {
	local tmpdir todo_file output reverse_count
	tmpdir=$(mktemp -d)
	todo_file="${tmpdir}/TODO.md"
	cat >"$todo_file" <<'EOF'
- [ ] t18002 canonical task ref:GH#25539 -> [todo/tasks/t18002-brief.md]
- [ ] t18002 stale duplicate ref:GH#25539
- [ ] t18003 another task ref:GH#25540
EOF
	TEST_TODO_FILE="$todo_file"
	_init_cmd() {
		_CMD_REPO="owner/repo"
		_CMD_TODO="$TEST_TODO_FILE"
		return 0
	}
	gh_list_issues() {
		local repo="$1"
		local state="$2"
		: "$repo" "$state"
		printf '[]\n'
		return 0
	}
	output=$(cmd_status 2>&1)
	[[ "$output" == *'TODO open: 2 (2 ref, 0 no ref)'* ]] || fail "expected duplicate open rows to count once"
	[[ "$output" == *'reverse-drift: 2'* ]] || fail "expected duplicate reverse drift to count once"
	reverse_count=$(printf '%s\n' "$output" | grep -c 'REVERSE-DRIFT: t18002' || true)
	[[ "$reverse_count" == "1" ]] || fail "expected one reverse-drift warning for duplicate t18002, got $reverse_count"
	rm -rf "$tmpdir"
	pass "status counts duplicate task rows once"
	return 0
}

main() {
	test_dedupe_preserves_canonical_brief_line
	test_mark_done_dedupes_and_adds_verified_proof
	test_mark_done_completes_in_progress_entry
	test_dedupe_ignores_markdown_fences
	test_dedupe_scores_metadata_individually
	test_status_counts_duplicate_task_rows_once
	return 0
}

main "$@"
