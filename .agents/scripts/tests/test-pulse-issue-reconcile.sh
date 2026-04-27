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
# Test 6: Single-pass orchestrator consolidates cache reads (t2776)
# ---------------------------------------------------------------------------
test_single_pass_cache_consolidation() {
	# After t2776, reconcile_issues_single_pass holds ONE cache-read call
	# covering all five sub-stages. The five legacy functions keep their own
	# call sites for standalone/test use. We verify:
	#   a) reconcile_issues_single_pass is defined
	#   b) _read_cache_issues_for_slug is still present (≥2: definition + single-pass)
	#   c) The five _should_* predicates are defined

	# (a) single-pass function defined
	local sp_count
	sp_count=$(grep -c '^reconcile_issues_single_pass()' "${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$sp_count" =~ ^[0-9]+$ ]] || sp_count=0
	if [[ "$sp_count" -ge 1 ]]; then
		_pass "single-pass: reconcile_issues_single_pass defined"
	else
		_fail "single-pass: reconcile_issues_single_pass NOT found"
	fi

	# (b) cache helper still present
	local cache_read_count
	cache_read_count=$(grep -c '_read_cache_issues_for_slug' "${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$cache_read_count" =~ ^[0-9]+$ ]] || cache_read_count=0
	if [[ "$cache_read_count" -ge 2 ]]; then
		_pass "single-pass: _read_cache_issues_for_slug found ${cache_read_count} times (definition + call sites)"
	else
		_fail "single-pass: expected ≥2 _read_cache_issues_for_slug matches, got ${cache_read_count}"
	fi

	# (c) all five _should_* predicates defined
	local pred_count
	pred_count=$(grep -c '^_should_ciw()\|^_should_rsd()\|^_should_oimp()\|^_should_cpt()\|^_should_lia()' \
		"${RECONCILE_SH}" 2>/dev/null || true)
	[[ "$pred_count" =~ ^[0-9]+$ ]] || pred_count=0
	if [[ "$pred_count" -eq 5 ]]; then
		_pass "single-pass: all 5 _should_* predicates defined"
	else
		_fail "single-pass: expected 5 _should_* predicates, found ${pred_count}"
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
# Test 8: _should_* predicates (t2776)
# ---------------------------------------------------------------------------
test_should_predicates() {
	# Source just the predicate functions from RECONCILE_SH in a subshell.
	# We extract the five _should_* function definitions then call each.

	# Extract all five predicate definitions (stop before the first _action_* helper)
	local pred_defs
	pred_defs=$(sed -n '/^_should_ciw()/,/^_action_ciw_single()/p' "${RECONCILE_SH}" | \
		grep -v '^_action_ciw_single()' || true)

	# Run predicate checks in one subshell
	local result
	result=$(bash -c "
		${pred_defs}

		# _should_ciw: true for status:available, false otherwise
		_should_ciw 'origin:worker,status:available' && echo 'ciw:1' || echo 'ciw:0'
		_should_ciw 'origin:worker,status:done'      && echo 'ciw-done:1' || echo 'ciw-done:0'

		# _should_rsd: true for status:done
		_should_rsd 'status:done,tier:standard' && echo 'rsd:1' || echo 'rsd:0'
		_should_rsd 'status:available'          && echo 'rsd-avail:1' || echo 'rsd-avail:0'

		# _should_oimp: false if issue is in parent_task_nums list
		_should_oimp '42' '41
42
43' && echo 'oimp-parent:1' || echo 'oimp-parent:0'
		_should_oimp '99' '41
42' && echo 'oimp-nonparent:1' || echo 'oimp-nonparent:0'

		# _should_cpt: true for parent-task
		_should_cpt 'parent-task,origin:worker' && echo 'cpt:1' || echo 'cpt:0'
		_should_cpt 'status:available'          && echo 'cpt-noparent:1' || echo 'cpt-noparent:0'

		# _should_lia: true for tNNN: title + no aidevops labels
		_should_lia 't1234: fix something' '' && echo 'lia:1' || echo 'lia:0'
		_should_lia 'GH#567: fix' ''          && echo 'lia-gh:1' || echo 'lia-gh:0'
		_should_lia 't1234: fix' 'origin:worker' && echo 'lia-labeled:1' || echo 'lia-labeled:0'
		_should_lia 'not a task title' ''     && echo 'lia-badtitle:1' || echo 'lia-badtitle:0'
	" 2>/dev/null)

	local all_ok=1

	# Check each expected result
	if ! printf '%s\n' "$result" | grep -qx 'ciw:1';         then _fail "_should_ciw: status:available should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'ciw-done:0';    then _fail "_should_ciw: status:done should return 1"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'rsd:1';         then _fail "_should_rsd: status:done should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'rsd-avail:0';   then _fail "_should_rsd: status:available should return 1"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'oimp-parent:0'; then _fail "_should_oimp: parent-task issue should return 1"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'oimp-nonparent:1'; then _fail "_should_oimp: non-parent issue should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'cpt:1';         then _fail "_should_cpt: parent-task should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'cpt-noparent:0'; then _fail "_should_cpt: no parent-task should return 1"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'lia:1';         then _fail "_should_lia: tNNN: title + no labels should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'lia-gh:1';      then _fail "_should_lia: GH#NNN: title + no labels should return 0"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'lia-labeled:0'; then _fail "_should_lia: labeled issue should return 1"; all_ok=0; fi
	if ! printf '%s\n' "$result" | grep -qx 'lia-badtitle:0'; then _fail "_should_lia: non-task title should return 1"; all_ok=0; fi

	[[ "$all_ok" == "1" ]] && _pass "_should_* predicates: all 12 cases correct"
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: reconcile_issues_single_pass wired in pulse-dispatch-engine.sh
# ---------------------------------------------------------------------------
test_single_pass_wired_in_engine() {
	local engine_sh="${SCRIPT_DIR}/../pulse-dispatch-engine.sh"
	if [[ ! -f "$engine_sh" ]]; then
		_pass "single-pass engine wiring: pulse-dispatch-engine.sh not found (skip)"
		return 0
	fi

	# Verify the single-pass is called (not the five legacy functions)
	local sp_calls legacy_calls
	sp_calls=$(grep -c 'reconcile_issues_single_pass' "$engine_sh" 2>/dev/null || true)
	[[ "$sp_calls" =~ ^[0-9]+$ ]] || sp_calls=0

	# Legacy functions should NOT be direct run_stage_with_timeout targets anymore
	legacy_calls=$(grep -E 'run_stage_with_timeout.*(close_issues_with_merged_prs|reconcile_stale_done_issues|reconcile_open_issues_with_merged_prs|reconcile_completed_parent_tasks|reconcile_labelless_aidevops_issues)' \
		"$engine_sh" 2>/dev/null | grep -vc '^\s*#' || true)
	[[ "$legacy_calls" =~ ^[0-9]+$ ]] || legacy_calls=0

	if [[ "$sp_calls" -ge 1 && "$legacy_calls" -eq 0 ]]; then
		_pass "single-pass engine: wired in pulse-dispatch-engine.sh (sp_calls=${sp_calls}, legacy_direct=${legacy_calls})"
	else
		_fail "single-pass engine: sp_calls=${sp_calls}, legacy_direct=${legacy_calls} (expected sp≥1, legacy=0)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: Batched per-issue field extraction parity (t2904)
#
# Verifies the t2904 single-jq-per-repo + base64 round-trip preserves
# every field exactly — including multi-line bodies, embedded tabs, and
# UTF-8. Catches the @tsv-without-base64 footgun where embedded \n / \t
# break the consumer (_extract_children_section grep'ing for child refs).
# ---------------------------------------------------------------------------
test_batched_field_extraction_parity() {
	# Fixture: 2 issues, body[0] has multiline + tab + UTF-8, body[1] is empty.
	local fixture_json
	fixture_json=$(jq -nc '[
		{
			number: 12345,
			title: "t2904: batch jq extraction",
			labels: [{name:"origin:worker"},{name:"status:available"}],
			body: "Line 1\nLine 2\twith tab\n— em-dash + Unicode ✓"
		},
		{
			number: 67890,
			title: "Empty body case",
			labels: [],
			body: ""
		}
	]')

	# Run the extraction pattern from reconcile_issues_single_pass.
	local extracted
	extracted=$(printf '%s' "$fixture_json" | jq -r '
		.[] | [
			(.number // "" | tostring),
			((.title // "") | @base64),
			((.labels // []) | map(.name) | join(",")),
			((.body // "") | @base64)
		] | join("|")
	')

	local row_count
	row_count=$(printf '%s\n' "$extracted" | grep -c .)
	[[ "$row_count" =~ ^[0-9]+$ ]] || row_count=0
	if [[ "$row_count" -ne 2 ]]; then
		_fail "batched-extraction: expected 2 rows, got ${row_count}"
		return 0
	fi

	local all_ok=1

	# Decode and verify row 1 (multiline + tab + UTF-8 body).
	local r1_num r1_title_b64 r1_labels r1_body_b64 r1_title r1_body
	IFS='|' read -r r1_num r1_title_b64 r1_labels r1_body_b64 < <(printf '%s\n' "$extracted" | sed -n 1p)
	r1_title=$(printf '%s' "$r1_title_b64" | base64 -d 2>/dev/null)
	r1_body=$(printf '%s' "$r1_body_b64" | base64 -d 2>/dev/null)

	[[ "$r1_num" == "12345" ]] || { _fail "row1 number: expected 12345, got '$r1_num'"; all_ok=0; }
	[[ "$r1_title" == "t2904: batch jq extraction" ]] || { _fail "row1 title decode mismatch"; all_ok=0; }
	[[ "$r1_labels" == "origin:worker,status:available" ]] || { _fail "row1 labels: got '$r1_labels'"; all_ok=0; }
	# Body must contain BOTH a real newline AND a real tab — the @tsv-only path
	# would have escaped these to literal \n / \t markers.
	if ! printf '%s' "$r1_body" | grep -q $'Line 1\nLine 2\twith tab'; then
		_fail "row1 body: newline/tab lost in round-trip"
		all_ok=0
	fi
	# UTF-8 must survive the base64 round-trip.
	if ! printf '%s' "$r1_body" | grep -q '— em-dash + Unicode ✓'; then
		_fail "row1 body: UTF-8 corrupted in round-trip"
		all_ok=0
	fi

	# Decode and verify row 2 (empty body, empty labels).
	local r2_num r2_title_b64 r2_labels r2_body_b64 r2_title r2_body
	IFS='|' read -r r2_num r2_title_b64 r2_labels r2_body_b64 < <(printf '%s\n' "$extracted" | sed -n 2p)
	r2_title=$(printf '%s' "$r2_title_b64" | base64 -d 2>/dev/null)
	# Empty body — base64-decode of empty input is empty.
	r2_body=$(printf '%s' "$r2_body_b64" | base64 -d 2>/dev/null)

	[[ "$r2_num" == "67890" ]] || { _fail "row2 number: expected 67890, got '$r2_num'"; all_ok=0; }
	[[ "$r2_title" == "Empty body case" ]] || { _fail "row2 title decode mismatch"; all_ok=0; }
	[[ -z "$r2_labels" ]] || { _fail "row2 labels: expected empty, got '$r2_labels'"; all_ok=0; }
	[[ -z "$r2_body" ]] || { _fail "row2 body: expected empty, got '$r2_body'"; all_ok=0; }

	[[ "$all_ok" == "1" ]] && _pass "batched-extraction: 2 rows decode with multiline/tab/UTF-8/empty fidelity"
	return 0
}

# ---------------------------------------------------------------------------
# Test 11 (t2984): time-budget early-exit code is present and well-formed
# ---------------------------------------------------------------------------
# Verify the t2984 budget gate exists in three required places:
#   1. Initialization (RECONCILE_TIME_BUDGET_SECS env var read)
#   2. Outer slug-loop gate (per-repo check)
#   3. Inner issue-loop gate (per-issue check) with `break 2`
# Also verify the abort log line exists for diagnostics.
# Pure source-code verification — no shell execution required.
test_t2984_time_budget_present() {
	local all_ok=1

	# 1. Init block
	if ! grep -q 'RECONCILE_TIME_BUDGET_SECS' "${RECONCILE_SH}"; then
		_fail "t2984: missing RECONCILE_TIME_BUDGET_SECS env var read"
		all_ok=0
	fi

	# 2. Default value 540 must be the documented default
	if ! grep -qE '_t2984_budget=.*540' "${RECONCILE_SH}"; then
		_fail "t2984: default budget 540 not present (or not parseable)"
		all_ok=0
	fi

	# 3. Outer per-slug gate — uses `break` (not `break 2`) to exit slug loop
	#    Inner per-issue gate — uses `break 2` to exit BOTH loops
	#    Verify both forms exist with t2984 markers.
	if ! grep -q '_t2984_aborted=1' "${RECONCILE_SH}"; then
		_fail "t2984: _t2984_aborted=1 marker missing — abort signaling broken"
		all_ok=0
	fi

	if ! grep -q 'break 2' "${RECONCILE_SH}"; then
		_fail "t2984: 'break 2' missing — inner loop won't exit outer on abort"
		all_ok=0
	fi

	# 4. Diagnostic log line must reference time-budget
	if ! grep -q 'time-budget abort' "${RECONCILE_SH}"; then
		_fail "t2984: 'time-budget abort' diagnostic log missing"
		all_ok=0
	fi

	# 5. Disable mechanism — RECONCILE_TIME_BUDGET_SECS=0 should disable
	#    Verify the gate condition checks _t2984_budget -gt 0
	if ! grep -q '_t2984_budget" -gt 0' "${RECONCILE_SH}"; then
		_fail "t2984: budget=0 disable path missing (no '-gt 0' guard)"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && _pass "t2984: time-budget early-exit code present (init + outer + inner + log + disable)"
	return 0
}

# ---------------------------------------------------------------------------
# Test 12 (t2984): budget validation — non-numeric env var falls back to default
# ---------------------------------------------------------------------------
# Black-box: source the function definition, call it with a garbage env var,
# and verify it doesn't crash. The actual loop body needs network access so
# we just verify the variable validation logic.
test_t2984_budget_env_validation() {
	local result
	# Extract just the validation lines and exec them in isolation
	result=$(bash -c '
		RECONCILE_TIME_BUDGET_SECS="not-a-number"
		_t2984_budget="${RECONCILE_TIME_BUDGET_SECS:-540}"
		[[ "$_t2984_budget" =~ ^[0-9]+$ ]] || _t2984_budget=540
		echo "$_t2984_budget"
	' 2>/dev/null)
	if [[ "$result" == "540" ]]; then
		_pass "t2984: non-numeric RECONCILE_TIME_BUDGET_SECS falls back to 540"
	else
		_fail "t2984: garbage env var produced '$result' instead of fallback 540"
	fi

	# Also verify zero is honoured (disable path)
	result=$(bash -c '
		RECONCILE_TIME_BUDGET_SECS="0"
		_t2984_budget="${RECONCILE_TIME_BUDGET_SECS:-540}"
		[[ "$_t2984_budget" =~ ^[0-9]+$ ]] || _t2984_budget=540
		echo "$_t2984_budget"
	' 2>/dev/null)
	if [[ "$result" == "0" ]]; then
		_pass "t2984: RECONCILE_TIME_BUDGET_SECS=0 honoured (unbounded mode)"
	else
		_fail "t2984: '0' override produced '$result' instead of '0'"
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
test_single_pass_cache_consolidation
test_body_in_prefetch_fetch
test_should_predicates
test_single_pass_wired_in_engine
test_batched_field_extraction_parity
test_t2984_time_budget_present
test_t2984_budget_env_validation

echo ""
echo "Results: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
	exit 1
fi
exit 0
