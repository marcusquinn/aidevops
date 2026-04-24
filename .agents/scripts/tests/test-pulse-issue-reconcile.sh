#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-issue-reconcile.sh — Unit tests for pulse-issue-reconcile.sh helpers.
#
# Tests the t2773 cache-reader helper (_read_cache_issues_for_slug) and
# verifies that no bare 'gh issue list'/'gh pr list' calls remain outside
# the fallback path in pulse-issue-reconcile.sh.
#
# Usage: bash .agents/scripts/tests/test-pulse-issue-reconcile.sh

# Note: no set -e — test functions must handle their own failures explicitly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE_SH="${SCRIPT_DIR}/../pulse-issue-reconcile.sh"

pass=0
fail=0

_pass() { echo "PASS: $1"; pass=$((pass + 1)); return 0; }
_fail() { echo "FAIL: $1"; fail=$((fail + 1)); return 0; }

# ---------------------------------------------------------------------------
# Test 1: _read_cache_issues_for_slug — cache miss (file absent)
# ---------------------------------------------------------------------------
test_cache_miss_no_file() {
	local tmp_cache
	tmp_cache=$(mktemp)
	rm -f "$tmp_cache"  # ensure absent

	# Source only the helper by injecting it in a subshell
	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-miss: absent cache file returns 1"
	else
		_fail "cache-miss: absent cache file — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: _read_cache_issues_for_slug — cache miss (no entry for slug)
# ---------------------------------------------------------------------------
test_cache_miss_no_slug() {
	local tmp_cache
	tmp_cache=$(mktemp)
	# Write a cache with a different slug
	printf '{"other/repo":{"last_prefetch":"%s","issues":[]}}' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-miss: no entry for slug returns 1"
	else
		_fail "cache-miss: no entry for slug — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: _read_cache_issues_for_slug — stale cache (> 10 min old)
# ---------------------------------------------------------------------------
test_cache_stale() {
	local tmp_cache
	tmp_cache=$(mktemp)
	# Write a cache entry with a last_prefetch 11 minutes ago
	local old_ts
	old_ts=$(date -u -v -11M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
	         date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
	         echo "2000-01-01T00:00:00Z")
	printf '{"owner/repo":{"last_prefetch":"%s","issues":[{"number":1,"title":"t"}]}}' \
		"$old_ts" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		_read_cache_issues_for_slug 'owner/repo' && echo HIT || echo MISS
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if [[ "$result" == "MISS" ]]; then
		_pass "cache-stale: 11-minute-old cache returns 1"
	else
		_fail "cache-stale: 11-minute-old cache — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: _read_cache_issues_for_slug — fresh cache hit
# ---------------------------------------------------------------------------
test_cache_hit_fresh() {
	local tmp_cache
	tmp_cache=$(mktemp)
	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"owner/repo":{"last_prefetch":"%s","issues":[{"number":42,"title":"Test issue","labels":[],"body":"test body"}]}}' \
		"$now_ts" >"$tmp_cache"

	local result
	result=$(bash -c "
		PULSE_PREFETCH_CACHE_FILE='${tmp_cache}'
		$(grep -A 40 '^_read_cache_issues_for_slug()' "${RECONCILE_SH}" | head -50)
		output=\$(_read_cache_issues_for_slug 'owner/repo') && echo \"\$output\"
	" 2>/dev/null)
	rm -f "$tmp_cache"
	if printf '%s' "$result" | jq -e '.[0].number == 42' >/dev/null 2>&1; then
		_pass "cache-hit: fresh cache returns issues JSON"
	else
		_fail "cache-hit: fresh cache — got '${result}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: No raw 'gh issue list' calls outside fallback paths
# ---------------------------------------------------------------------------
test_no_raw_gh_issue_list_outside_fallback() {
	# Count non-comment lines containing 'gh issue list' or 'gh pr list' that are
	# NOT inside _gh_pr_list_merged (the allowed fallback wrapper).
	# grep -n output format: "LINE_NUM:CONTENT" — filter out lines where CONTENT starts
	# with optional whitespace + '#' (comment lines in the shell script).
	# Use awk END{NR} to count matching lines safely (avoids grep -c exit-1 on no-match
	# and the grep|wc -l SC2126 nit — awk always exits 0 and prints 0 on empty input).
	local raw_count
	raw_count=$(grep -n 'gh issue list\|gh pr list' "${RECONCILE_SH}" 2>/dev/null | \
		grep -v ':[[:space:]]*#' | \
		grep -v 'gh_issue_list\|_gh_pr_list_merged' | \
		grep -v 'gh pr list "$@"' | \
		awk 'END{print NR}')

	if [[ "$raw_count" -eq 0 ]]; then
		_pass "no-raw-calls: zero raw gh issue/pr list calls outside fallback wrappers"
	else
		_fail "no-raw-calls: ${raw_count} raw gh issue/pr list call(s) found outside fallback wrappers"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Cache reads present in all 5 sub-stages
# ---------------------------------------------------------------------------
test_cache_reads_in_all_stages() {
	# safe_grep_count inline pattern (t2763): grep -c exits 1 on no-match, producing "0\n0"
	# with || echo 0. Use the guard form instead.
	local cache_read_count
	cache_read_count=$(grep -c '_read_cache_issues_for_slug' "${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$cache_read_count" =~ ^[0-9]+$ ]] || cache_read_count=0

	# Expect: 1 definition + 5 call sites = 6+ matches
	if [[ "$cache_read_count" -ge 6 ]]; then
		_pass "cache-reads: _read_cache_issues_for_slug found ${cache_read_count} times (definition + 5 sub-stages)"
	else
		_fail "cache-reads: expected ≥6 matches, got ${cache_read_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: body field present in prefetch fetch
# ---------------------------------------------------------------------------
test_body_in_prefetch_fetch() {
	local prefetch_sh="${SCRIPT_DIR}/../pulse-prefetch.sh"
	local prefetch_fetch_sh="${SCRIPT_DIR}/../pulse-prefetch-fetch.sh"

	# safe_grep_count inline pattern (t2763): use guard form, not || echo 0.
	local full_has_body delta_has_body
	full_has_body=$(grep -c 'number,title,labels,updatedAt,assignees,body' "${prefetch_sh}" 2>/dev/null || true)
	[[ "$full_has_body" =~ ^[0-9]+$ ]] || full_has_body=0
	delta_has_body=$(grep -c 'number,title,labels,updatedAt,assignees,body' "${prefetch_fetch_sh}" 2>/dev/null || true)
	[[ "$delta_has_body" =~ ^[0-9]+$ ]] || delta_has_body=0

	if [[ "$full_has_body" -ge 1 ]] && [[ "$delta_has_body" -ge 1 ]]; then
		_pass "body-in-prefetch: body field present in both full and delta fetches"
	else
		_fail "body-in-prefetch: full=${full_has_body} delta=${delta_has_body} (expected ≥1 each)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_cache_miss_no_file
test_cache_miss_no_slug
test_cache_stale
test_cache_hit_fresh
test_no_raw_gh_issue_list_outside_fallback
test_cache_reads_in_all_stages
test_body_in_prefetch_fetch

echo ""
echo "Results: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
	exit 1
fi
exit 0
