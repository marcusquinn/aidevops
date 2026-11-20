#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#38682: a not-open non-closing reference gets exactly one marker comment and
# label across repeated merge passes; other permanent blocks stay silent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TARGET="${SCRIPT_DIR}/pulse-merge-process-worker-briefed.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/not-open-ref.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
export PULSE_T2449_BLOCK_STATE_DIR="${TEST_ROOT}/state"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
COMMENTS=0
LABELS=0

eval "$(awk '
	/^_worker_briefed_permanent_block_file\(\) \{/,/^\}$/ { print }
	/^_worker_briefed_flag_not_open_reference\(\) \{/,/^\}$/ { print }
	/^_worker_briefed_retire_stale_non_closing_pr\(\) \{/,/^\}$/ { print }
	/^_worker_briefed_sync_permanent_block_marker\(\) \{/,/^\}$/ { print }
' "$TARGET")"

# Stub gh: comment listing reflects what gh_pr_comment posted.
gh() {
	case "$1 $2" in
	"api --paginate")
		if [[ "$COMMENTS" -gt 0 ]]; then
			printf '[[{"id":1,"body":"<!-- aidevops:non-closing-ref-not-open:v1 -->"}]]\n'
		else
			printf '[[]]\n'
		fi
		;;
	"api repos/test/repo/issues/12") printf 'completed\n' ;;
	"label create") : ;;
	*) return 1 ;;
	esac
	return 0
}
gh_pr_comment() { COMMENTS=$((COMMENTS + 1)); return 0; }
gh_pr_edit_safe() { LABELS=$((LABELS + 1)); return 0; }

fail() { printf 'FAIL %s\n' "$1"; exit 1; }

_WORKER_BRIEFED_NOT_OPEN_ISSUE=12
_worker_briefed_sync_permanent_block_marker 7 test/repo 1 non_closing_reference_not_open "$HEAD_SHA"
_worker_briefed_sync_permanent_block_marker 7 test/repo 1 non_closing_reference_not_open "$HEAD_SHA"
_worker_briefed_sync_permanent_block_marker 7 test/repo 1 non_closing_reference_not_open "$HEAD_SHA"
[[ "$COMMENTS" -eq 1 && "$LABELS" -eq 1 ]] || fail "expected one comment/label, got ${COMMENTS}/${LABELS}"
printf 'PASS not-open reference flagged exactly once across repeated passes\n'

# A cleared marker (e.g. head change) must still dedupe against the live comment.
rm -rf "$PULSE_T2449_BLOCK_STATE_DIR"
_worker_briefed_sync_permanent_block_marker 7 test/repo 1 non_closing_reference_not_open "$HEAD_SHA"
[[ "$COMMENTS" -eq 1 ]] || fail "live marker comment must dedupe"
printf 'PASS live marker comment dedupes after local marker loss\n'

_worker_briefed_sync_permanent_block_marker 8 test/repo 1 untrusted_issue_author_no_crypto_approval "$HEAD_SHA"
[[ "$COMMENTS" -eq 1 && "$LABELS" -eq 1 ]] || fail "other permanent blocks must stay silent"
printf 'PASS other permanent blocks do not comment\n'

# GH#39213: retire empty-diff / stale-planning PRs; fail closed otherwise.
_PM_PLANNING_CHECKPOINT_MAX_FILES=50
H1="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
H2="cccccccccccccccccccccccccccccccccccccccc"
ISSUE_TSV=$'closed\tcompleted\t2026-11-19T01:00:00Z\tt100: thing'
FILES_JSON='[]'
HEAD_SEQ=("$H1" "$H1" "$H1")
rm -f "${TEST_ROOT}/head-idx"
CLOSES=0
gh() {
	case "$1 $2" in
	"api repos/test/repo/issues/12") printf '%s\n' "$ISSUE_TSV" ;;
	"api repos/test/repo/pulls/9")
		# Command substitution is a subshell: persist the read index in a file.
		HEAD_IDX=$(cat "${TEST_ROOT}/head-idx" 2>/dev/null || printf '0')
		printf '%s\n' "${HEAD_SEQ[$HEAD_IDX]}"
		printf '%s' $((HEAD_IDX + 1)) >"${TEST_ROOT}/head-idx"
		;;
	"api repos/test/repo/pulls/9/files?per_page=100") printf '%s\n' "$FILES_JSON" ;;
	"pr close") CLOSES=$((CLOSES + 1)) ;;
	*) return 1 ;;
	esac
	return 0
}

rm -f "${TEST_ROOT}/head-idx"
CLOSES=0
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 || fail "empty diff must close"
[[ "$CLOSES" -eq 1 ]] || fail "empty diff close count ${CLOSES}"
printf 'PASS empty diff closed\n'

rm -f "${TEST_ROOT}/head-idx"
CLOSES=0
FILES_JSON='[{"filename":"TODO.md","status":"modified","deletions":0,"patch":"@@\n+- [ ] t100 thing #auto-dispatch ref:GH#12"}]'
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 || fail "stale planning row must close"
[[ "$CLOSES" -eq 1 ]] || fail "planning close count"
printf 'PASS stale planning row closed\n'

rm -f "${TEST_ROOT}/head-idx"
CLOSES=0
FILES_JSON='[{"filename":"TODO.md","status":"modified","deletions":0,"patch":"@@\n+- [ ] t100 x"},{"filename":"src/a.sh","status":"modified","deletions":0,"patch":"@@\n+x"}]'
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 && fail "non-planning path must not close"
[[ "$CLOSES" -eq 0 ]] || fail "non-planning closed"
printf 'PASS non-planning diff kept open\n'

rm -f "${TEST_ROOT}/head-idx"
FILES_JSON='[{"filename":"TODO.md","status":"modified","deletions":0,"patch":"@@\n+- [ ] t999 other task"}]'
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 && fail "other task row must not close"
printf 'PASS unrelated planning row kept open\n'

rm -f "${TEST_ROOT}/head-idx"
CLOSES=0
FILES_JSON='[]'
HEAD_SEQ=("$H1" "$H1" "$H2")
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 && fail "moved head must not close"
[[ "$CLOSES" -eq 0 ]] || fail "moved head closed"
printf 'PASS head change fails closed\n'

rm -f "${TEST_ROOT}/head-idx"
HEAD_SEQ=("$H1" "$H1" "$H1")
ISSUE_TSV=$'closed\tnot_planned\t2026-11-19T01:00:00Z\tt100: thing'
_worker_briefed_retire_stale_non_closing_pr 9 test/repo 12 && fail "not_planned must not close"
printf 'PASS not_planned issue kept open\n'
