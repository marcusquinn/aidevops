#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#23516: issue-sync must not treat a merged PR whose
# title merely starts with a task ID as completion evidence. Completion requires
# explicit proof in TODO.md (`pr:#NNN`, `verified:YYYY-MM-DD`, cancellation state)
# and unresolved `blocked-by:*` markers veto close/proof-log automation.
set -euo pipefail

PASS=0
FAIL=0

pass() {
	local msg="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$msg"
	return 0
}

fail() {
	local msg="$1"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$msg"
	return 0
}

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../issue-sync-helper-close.sh"

print_warning() { return 0; }
print_info() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
gh_find_merged_pr() {
	local repo="$1" task_id="$2"
	: "$task_id"
	printf '%s\n' "42|https://github.com/${repo}/pull/42"
	return 0
}
export -f print_warning print_info print_error print_success log_verbose gh_find_merged_pr

# shellcheck source=../issue-sync-helper-close.sh
source "$HELPER_PATH"

metadata_only_task='- [ ] t9001 keep closeout open tier:standard'
if _has_evidence "$metadata_only_task" "t9001" "owner/repo"; then
	fail "title-only merged PR lookup is not accepted as evidence"
else
	pass "title-only merged PR lookup is not accepted as evidence"
fi

if _find_closing_pr "$metadata_only_task" "t9001" "owner/repo" >/dev/null; then
	fail "title-only merged PR lookup is not returned as closing PR"
else
	pass "title-only merged PR lookup is not returned as closing PR"
fi

explicit_task='- [ ] t9002 fixed implementation pr:#77 tier:standard'
if _has_evidence "$explicit_task" "t9002" "owner/repo"; then
	pass "explicit pr proof remains valid evidence"
else
	fail "explicit pr proof should remain valid evidence"
fi

blocked_task='- [ ] t9003 blocked implementation pr:#78 tier:standard blocked-by:t9002'
if _has_evidence "$blocked_task" "t9003" "owner/repo"; then
	fail "blocked-by marker vetoes otherwise explicit PR evidence"
else
	pass "blocked-by marker vetoes otherwise explicit PR evidence"
fi

historical_note_task='- [ ] t9004 fixed implementation pr:#79 tier:standard
  - Historical note: earlier attempt was blocked-by:t9003 before the dependency landed.'
if _has_evidence "$historical_note_task" "t9004" "owner/repo"; then
	pass "blocked-by mention in task notes does not veto current task line"
else
	fail "blocked-by mention in task notes should not veto current task line"
fi

historical_cancelled_note_task='- [ ] t9005 incomplete implementation tier:standard
  - Historical note: earlier scope was cancelled:2026-01-01 before being reopened.'
if _has_evidence "$historical_cancelled_note_task" "t9005" "owner/repo"; then
	fail "cancelled marker in task notes is not accepted as completion evidence"
else
	pass "cancelled marker in task notes is not accepted as completion evidence"
fi

unexpected_marker_cancelled_note_task='- [~] t9006 incomplete implementation tier:standard
  - Historical note: earlier scope was cancelled:2026-01-01 before being reopened.'
if _has_evidence "$unexpected_marker_cancelled_note_task" "t9006" "owner/repo"; then
	fail "unexpected task marker still ignores cancelled marker in task notes"
else
	pass "unexpected task marker still ignores cancelled marker in task notes"
fi

unexpected_marker_proof_task='- [~] t9007 fixed implementation pr:#80 tier:standard
  - Historical note: earlier attempt was blocked-by:t9006 before the dependency landed.'
if _has_evidence "$unexpected_marker_proof_task" "t9007" "owner/repo"; then
	pass "unexpected task marker accepts proof on the task line"
else
	fail "unexpected task marker should accept proof on the task line"
fi

precomputed_clean_task_line='- [ ] t9008 fixed implementation pr:#81 tier:standard'
precomputed_note_block='- [ ] t9008 fixed implementation pr:#81 tier:standard
  - Historical note: earlier attempt was blocked-by:t9007 before the dependency landed.'
if _has_unresolved_blocker "$precomputed_note_block" "t9008" "$precomputed_clean_task_line"; then
	fail "precomputed clean task line skips blocker mentions in notes"
else
	pass "precomputed clean task line skips blocker mentions in notes"
fi

precomputed_blocked_task_line='- [ ] t9009 fixed implementation pr:#82 tier:standard blocked-by:t9008'
if _has_unresolved_blocker "- [ ] t9009 fixed implementation pr:#82 tier:standard" "t9009" "$precomputed_blocked_task_line"; then
	pass "precomputed blocked task line still vetoes completion"
else
	fail "precomputed blocked task line should veto completion"
fi

if [[ "$FAIL" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$PASS"
	exit 0
fi

exit 1
