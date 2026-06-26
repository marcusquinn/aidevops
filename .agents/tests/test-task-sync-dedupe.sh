#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/.agents/scripts"

source "${REPO_ROOT}/.agents/scripts/issue-sync-lib.sh"
source "${REPO_ROOT}/.agents/scripts/issue-sync-helper-close.sh"

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

main() {
	test_dedupe_preserves_canonical_brief_line
	test_mark_done_dedupes_and_adds_verified_proof
	return 0
}

main "$@"
