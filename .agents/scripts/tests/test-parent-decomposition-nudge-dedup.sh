#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-parent-decomposition-nudge-dedup.sh — regression test for t2572 (GH#20240)
#
# The parent-decomposition nudge dedup check was silently broken since
# introduction: `gh api --paginate ... --slurp --jq "..."` is REJECTED by
# `gh api` with "the --slurp option is not supported with --jq or --template".
# The error was swallowed by `2>/dev/null`, `existing=""` never matched the
# `^[1-9]` regex, and the "post only once" guarantee was voided — every pulse
# cycle re-posted a fresh nudge comment.
#
# Observed impact: 22 identical nudge comments on a single parent-task issue
# across ~30h from two pulse runners (aidevops#20001). 4 identical comments
# on awardsapp#2546 from two runners within minutes.
#
# Fix: replace `--slurp --jq` with streaming `--paginate | --jq | wc -l`
# pattern. --paginate alone concatenates per-page responses; --jq applies
# per page. Emit one .id per matching comment across all pages and count.
#
# Test coverage:
#   1. No `--slurp` combined with `--jq`/`--template` remains in .agents/
#      (acceptance criterion from the issue body)
#   2. _post_parent_decomposition_nudge uses streaming + wc -l pattern
#   3. _post_parent_decomposition_nudge has no --slurp flag
#   4. _compute_parent_nudge_age_hours uses streaming + head -n1 pattern
#   5. _compute_parent_nudge_age_hours has no --slurp flag
#   6. _post_parent_decomposition_escalation uses streaming + wc -l pattern
#   7. _post_parent_decomposition_escalation has no --slurp flag
#   8. _post_parent_task_no_markers_warning (issue-sync-lib.sh) uses streaming
#   9. _post_parent_task_no_markers_warning has no --slurp flag
#  10. Idempotency regex unchanged (`^[1-9][0-9]*$`) — 0 and empty fall through
#  11. t2572 provenance comment present in at least one fixed site
#
# Structural grep-based tests; functional end-to-end with a stubbed gh api
# requires sourcing all pulse-wrapper dependencies which is out of scope for
# a regression test. The broken-state detection (no --slurp+--jq remains)
# is the canonical regression signal — if the anti-pattern reappears, this
# test catches it.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_no_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  unexpected pattern found: $pattern"
		echo "  in file:                  $file"
		grep -nE "$pattern" "$file" 2>/dev/null | head -5 | sed 's/^/    /'
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECONCILE="$SCRIPT_DIR/pulse-issue-reconcile.sh"
SYNC_LIB="$SCRIPT_DIR/issue-sync-lib.sh"

for f in "$RECONCILE" "$SYNC_LIB"; do
	if [[ ! -f "$f" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $f not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2572: gh api --slurp+--jq anti-pattern regression tests ===${TEST_NC}"
echo ""

# --- Acceptance criterion 1: no --slurp+--jq/--template anywhere in .agents/ ---
# This catches reintroduction of the anti-pattern in any new or modified file.
# We filter:
#   - comment lines (prose reference to the bug is fine)
#   - jq's own --slurpfile flag (unrelated)
#   - this test file itself (it cites the anti-pattern in prose + regex)
# and check that no line containing `--slurp` as a bash flag remains.
TESTS_RUN=$((TESTS_RUN + 1))
anti_pattern_hits=$(grep -rn -- '--slurp' "$AGENTS_DIR" 2>/dev/null \
	| grep -vE -- '--slurpfile' \
	| grep -vE -- '/tests/test-parent-decomposition-nudge-dedup\.sh:' \
	| grep -vE ':\s*#' \
	|| true)
if [[ -z "$anti_pattern_hits" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1: no non-comment gh api --slurp usage in .agents/"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1: found non-comment --slurp usage:"
	echo "$anti_pattern_hits" | sed 's/^/    /'
fi

# --- _post_parent_decomposition_nudge (pulse-issue-reconcile.sh:~1127) ---

assert_grep_fixed \
	"2: nudge helper uses streaming --jq + .id select" \
	'--jq ".[] | select(.body | contains(\"${marker}\")) | .id"' \
	"$RECONCILE"

assert_grep_fixed \
	"3: nudge helper pipes to wc -l | tr -d" \
	'2>/dev/null | wc -l | tr -d' \
	"$RECONCILE"

# --- _compute_parent_nudge_age_hours (~1204) ---

assert_grep_fixed \
	"4: nudge-age helper uses streaming + head -n1" \
	'| head -n1) || nudge_created_at=""' \
	"$RECONCILE"

assert_grep_fixed \
	"5: nudge-age helper selects .created_at without slurp" \
	"--jq '.[] | select(.body | contains(\"<!-- parent-needs-decomposition -->\")) | .created_at'" \
	"$RECONCILE"

# --- _post_parent_decomposition_escalation (~1271) ---
# Counts occurrences of the streaming pattern — expect 2 (nudge + escalation)
# in pulse-issue-reconcile.sh.
TESTS_RUN=$((TESTS_RUN + 1))
streaming_count=$(grep -cF -- '2>/dev/null | wc -l | tr -d' "$RECONCILE" 2>/dev/null || echo 0)
if [[ "$streaming_count" -ge 2 ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 6: pulse-issue-reconcile.sh has 2+ streaming-pattern sites (got: $streaming_count)"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 6: expected 2+ streaming-pattern sites, got: $streaming_count"
fi

# --- _post_parent_task_no_markers_warning (issue-sync-lib.sh:~759) ---

assert_grep_fixed \
	"7: no-markers warning uses streaming --jq + .id select" \
	'--jq ".[] | select(.body | contains(\"${marker}\")) | .id"' \
	"$SYNC_LIB"

# Test 8: verify no non-comment --slurp in sync lib.
TESTS_RUN=$((TESTS_RUN + 1))
sync_slurp=$(grep -n -- '--slurp' "$SYNC_LIB" 2>/dev/null \
	| grep -vE ':\s*#' \
	| grep -vE -- '--slurpfile' \
	|| true)
if [[ -z "$sync_slurp" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 8: no-markers warning has no non-comment --slurp flag"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 8: found non-comment --slurp in issue-sync-lib.sh:"
	echo "$sync_slurp" | sed 's/^/    /'
fi

# --- Idempotency regex semantics ---
# Nudge + escalation sites use fail-closed `^[0-9]+$` (GH#20219): on API
# failure, skip the cycle rather than post. The no-markers-warning in
# issue-sync-lib.sh still uses the original `^[1-9][0-9]*$` (fail-open on
# empty — a one-shot warning is low-cost to duplicate).

assert_grep_fixed \
	"9: nudge site uses fail-closed regex (GH#20219)" \
	'[[ ! "$existing" =~ ^[0-9]+$ ]]' \
	"$RECONCILE"

assert_grep_fixed \
	"10: no-markers-warning retains original ^[1-9] regex (fail-open)" \
	'[[ "$existing" =~ ^[1-9][0-9]*$ ]]' \
	"$SYNC_LIB"

# --- Provenance ---

assert_grep_fixed \
	"11: t2572 provenance comment present in pulse-issue-reconcile.sh" \
	't2572:' \
	"$RECONCILE"

assert_grep_fixed \
	"12: t2572 provenance comment present in issue-sync-lib.sh" \
	't2572:' \
	"$SYNC_LIB"

# --- Summary ---

echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
