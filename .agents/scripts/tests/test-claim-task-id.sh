#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id.sh — GH#21770 regression guard.
#
# Tests the issue-number extraction logic used in claim-task-id.sh after the
# fix for the "phantom number from captured stderr" bug (t3039 regression).
#
# Root cause: gh_create_issue is called with 2>&1 so stderr log lines (e.g.
# "[INFO] auto-dispatch label present — skipping self-assignment per t2157")
# are merged into $issue_url. The old extractor `grep -oE '[0-9]+$'` matched
# the trailing digits of the log line ("2157") before reaching the real URL.
#
# Fix: extract via the canonical GitHub URL shape `/issues/NNN` — log messages
# never contain that path prefix, so they cannot produce phantom numbers.
#
# Test strategy: run the extraction pipeline directly against controlled
# multi-line inputs, assert the extracted number is correct.
#
# Usage: bash .agents/scripts/tests/test-claim-task-id.sh

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
CLAIM_SCRIPT="${REPO_ROOT}/.agents/scripts/claim-task-id.sh"

if [[ ! -f "$CLAIM_SCRIPT" ]]; then
	printf 'claim-task-id.sh not found: %s\n' "$CLAIM_SCRIPT" >&2
	exit 1
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s — got: %s\n' "$TEST_RED" "$TEST_NC" "$1" "${2:-<empty>}"
	return 0
}

# Extraction command extracted from claim-task-id.sh (GH#21770 fix).
# Kept as a local function so the test targets the exact extraction in use.
extract_issue_num() {
	local input="$1"
	printf '%s\n' "$input" | awk 'match($0, /\/issues\/[0-9]+/) { num=substr($0, RSTART + 8, RLENGTH - 8) } END { print num }'
	return 0
}

# -----------------------------------------------------------------------------
# Case 1: canonical bug input — log line before the URL
# [INFO] auto-dispatch label present — skipping self-assignment per t2157
# https://github.com/example/repo/issues/2150
# Old regex captured "2157"; new pipeline must capture "2150".
# -----------------------------------------------------------------------------
printf 'Case 1: log-line-before-URL (canonical phantom-number repro)\n'
mock_output=$(printf '[INFO] auto-dispatch label present — skipping self-assignment per t2157\nhttps://github.com/example/repo/issues/2150')
result=$(extract_issue_num "$mock_output")
if [[ "$result" == "2150" ]]; then
	pass "extracted 2150 (not phantom 2157)"
else
	fail "expected 2150" "$result"
fi

# -----------------------------------------------------------------------------
# Case 2: clean URL — no log noise at all
# -----------------------------------------------------------------------------
printf 'Case 2: clean URL only\n'
mock_output="https://github.com/example/repo/issues/9999"
result=$(extract_issue_num "$mock_output")
if [[ "$result" == "9999" ]]; then
	pass "extracted 9999 from clean URL"
else
	fail "expected 9999" "$result"
fi

# -----------------------------------------------------------------------------
# Case 3: multiple log lines before URL
# -----------------------------------------------------------------------------
printf 'Case 3: multiple log lines before URL\n'
mock_output=$(printf '[INFO] some message per t1234\n[WARN] another message t5678\nhttps://github.com/example/repo/issues/3000')
result=$(extract_issue_num "$mock_output")
if [[ "$result" == "3000" ]]; then
	pass "extracted 3000 ignoring t1234 and t5678"
else
	fail "expected 3000" "$result"
fi

# -----------------------------------------------------------------------------
# Case 4: log line AFTER URL (tail -1 must pick the URL number if there's
# only one /issues/ match; extra log after URL has no /issues/ shape)
# -----------------------------------------------------------------------------
printf 'Case 4: log line after URL\n'
mock_output=$(printf 'https://github.com/example/repo/issues/4200\n[INFO] some trailing log per t9999')
result=$(extract_issue_num "$mock_output")
if [[ "$result" == "4200" ]]; then
	pass "extracted 4200 with trailing log line"
else
	fail "expected 4200" "$result"
fi

# -----------------------------------------------------------------------------
# Case 5: stderr only — no URL — must return empty (not a phantom number)
# -----------------------------------------------------------------------------
printf 'Case 5: stderr only (no URL)\n'
mock_output="[INFO] auto-dispatch label present — skipping self-assignment per t2157"
result=$(extract_issue_num "$mock_output")
if [[ -z "$result" ]]; then
	pass "empty result when no URL present (correct — caller handles empty)"
else
	fail "expected empty result" "$result"
fi

# -----------------------------------------------------------------------------
# Case 6: document the old-regex failure mode (regression documentation)
# grep -oE '[0-9]+$' on canonical bug input yields "2157" (the phantom), NOT 2150
# -----------------------------------------------------------------------------
printf 'Case 6: old-regex failure documentation (must produce phantom 2157)\n'
mock_output=$(printf '[INFO] auto-dispatch label present — skipping self-assignment per t2157\nhttps://github.com/example/repo/issues/2150')
old_result=$(printf '%s\n' "$mock_output" | grep -oE '[0-9]+$' | head -1)
if [[ "$old_result" == "2157" ]]; then
	pass "confirmed old regex produces phantom 2157 (documents the bug)"
else
	fail "unexpected old-regex result — bug may have changed" "$old_result"
fi

# =============================================================================
# Cases 7-9: _pc_filter_relevant_issues — issue dedup filter (GH#21831)
# =============================================================================
# Reference implementation matching claim-task-id.sh::_pc_filter_relevant_issues.
# Kept inline so the test can run without sourcing the full script (which adds
# set -e and would break Cases 1-6 above).  If the production function changes,
# update this reference implementation to match.
_pc_filter_relevant_issues_test() {
	local raw_json="$1"
	local keywords_nl="$2"
	local dedup_days="${3:-14}"
	local now_epoch cutoff_epoch
	now_epoch=$(date +%s 2>/dev/null || printf '0')
	cutoff_epoch=$((now_epoch - dedup_days * 86400))
	local issue_num issue_title issue_created_at
	while IFS='|' read -r issue_num issue_title issue_created_at; do
		[[ -z "$issue_num" ]] && continue
		if [[ -n "$issue_created_at" ]]; then
			local created_epoch=0
			created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created_at" +%s 2>/dev/null) \
				|| created_epoch=$(date --date="$issue_created_at" +%s 2>/dev/null) \
				|| true
			[[ "$created_epoch" -gt 0 && "$created_epoch" -lt "$cutoff_epoch" ]] && continue
		fi
		local issue_lower overlap=0 kw
		issue_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r kw; do
			[[ -z "$kw" ]] && continue
			[[ "$issue_lower" == *"$kw"* ]] && overlap=$((overlap + 1))
		done <<<"$keywords_nl"
		[[ $overlap -lt 2 ]] && continue
		printf '#%s [ISSUE] %s  (%s)\n' "$issue_num" "$issue_title" "${issue_created_at:-open}"
	done < <(printf '%s' "$raw_json" | jq -r '.[] | "\(.number)|\(.title)|\(.createdAt // "")"')
	return 0
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP Cases 7-9: jq not available\n'
else
	# -------------------------------------------------------------------------
	# Case 7: recent open issue with matching keywords surfaces in output
	# -------------------------------------------------------------------------
	printf 'Case 7: recent issue with matching keywords surfaces in filter output\n'
	mock_json='[{"number":21760,"title":"claim-task-id phantom number from stderr","state":"OPEN","createdAt":"2026-04-29T00:00:00Z"}]'
	mock_keywords=$(printf 'claim\nphantom')
	result=$(_pc_filter_relevant_issues_test "$mock_json" "$mock_keywords" 14)
	if printf '%s' "$result" | grep -q '#21760 \[ISSUE\]'; then
		pass "Case 7: issue #21760 surfaced with matching keywords"
	else
		fail "Case 7: expected #21760 [ISSUE] in output" "$result"
	fi

	# -------------------------------------------------------------------------
	# Case 8: issue older than dedup window is filtered out by recency gate
	# -------------------------------------------------------------------------
	printf 'Case 8: old issue (2020) filtered by recency gate\n'
	mock_json='[{"number":100,"title":"claim-task-id phantom number fix","state":"OPEN","createdAt":"2020-01-01T00:00:00Z"}]'
	mock_keywords=$(printf 'claim\nphantom')
	result=$(_pc_filter_relevant_issues_test "$mock_json" "$mock_keywords" 14)
	if [[ -z "$result" ]]; then
		pass "Case 8: old issue filtered out (empty output)"
	else
		fail "Case 8: expected empty output for old issue" "$result"
	fi

	# -------------------------------------------------------------------------
	# Case 9: issue with fewer than 2 keyword overlaps is filtered out
	# -------------------------------------------------------------------------
	printf 'Case 9: issue with <2 keyword overlaps is filtered\n'
	mock_json='[{"number":200,"title":"claim-task-id ssh key rotation","state":"OPEN","createdAt":"2026-04-29T00:00:00Z"}]'
	mock_keywords=$(printf 'phantom\nnumber')
	result=$(_pc_filter_relevant_issues_test "$mock_json" "$mock_keywords" 14)
	if [[ -z "$result" ]]; then
		pass "Case 9: insufficient keyword overlap filtered (empty output)"
	else
		fail "Case 9: expected empty output for low keyword overlap" "$result"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
