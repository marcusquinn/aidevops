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
