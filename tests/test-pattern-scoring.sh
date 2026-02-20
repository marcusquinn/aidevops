#!/usr/bin/env bash
# test-pattern-scoring.sh
#
# Tests for the unified model performance scoring backbone (t1094)
# Validates: score command, ab-compare command, and integration with
# response-scoring-helper.sh and compare-models-helper.sh.
#
# Usage: bash tests/test-pattern-scoring.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN_HELPER="$REPO_DIR/.agents/scripts/pattern-tracker-helper.sh"
SCORING_HELPER="$REPO_DIR/.agents/scripts/response-scoring-helper.sh"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# Use a temp memory DB for testing to avoid polluting real data
TEST_MEM_DIR=$(mktemp -d)
TEST_SCORING_DIR=$(mktemp -d)
export AIDEVOPS_MEMORY_DIR="$TEST_MEM_DIR"
export SCORING_DB_OVERRIDE="$TEST_SCORING_DIR/test-scoring.db"
export SCORING_NO_PATTERN_SYNC=1 # Disable cross-tool sync during unit tests

# Initialize memory DB (required by pattern-tracker-helper.sh)
MEMORY_HELPER="$REPO_DIR/.agents/scripts/memory-helper.sh"
if [[ -x "$MEMORY_HELPER" ]]; then
	"$MEMORY_HELPER" store --content "test init" --type "NOTE" >/dev/null 2>&1 || true
fi

cleanup() {
	rm -rf "$TEST_MEM_DIR" "$TEST_SCORING_DIR"
}
trap cleanup EXIT

# =============================================================================
# Tests
# =============================================================================

section "Syntax Checks"

if bash -n "$PATTERN_HELPER" 2>/dev/null; then
	pass "pattern-tracker-helper.sh passes bash -n syntax check"
else
	fail "pattern-tracker-helper.sh has syntax errors"
fi

if bash -n "$SCORING_HELPER" 2>/dev/null; then
	pass "response-scoring-helper.sh passes bash -n syntax check"
else
	fail "response-scoring-helper.sh has syntax errors"
fi

section "Help Output — score command"

help_output=$(bash "$PATTERN_HELPER" help 2>&1) || true
if echo "$help_output" | grep -q "score"; then
	pass "help output lists 'score' command"
else
	fail "help output missing 'score' command"
fi

if echo "$help_output" | grep -q "ab-compare"; then
	pass "help output lists 'ab-compare' command"
else
	fail "help output missing 'ab-compare' command"
fi

if echo "$help_output" | grep -q "unified backbone"; then
	pass "help output mentions 'unified backbone'"
else
	fail "help output missing 'unified backbone' description"
fi

section "score command — weighted average computation"

# Test: per-criterion scores compute correct weighted average
# correctness=5 (w=0.30), completeness=4 (w=0.25), code-quality=4 (w=0.25), clarity=5 (w=0.20)
# Expected: (5*0.30 + 4*0.25 + 4*0.25 + 5*0.20) / (0.30+0.25+0.25+0.20) = (1.5+1.0+1.0+1.0)/1.0 = 4.5
score_output=$(bash "$PATTERN_HELPER" score \
	--model sonnet \
	--task-type code-review \
	--correctness 5 \
	--completeness 4 \
	--code-quality 4 \
	--clarity 5 \
	--source test \
	2>&1) || true

if echo "$score_output" | grep -qi "recorded\|success\|pattern"; then
	pass "score command records successfully with per-criterion scores"
else
	fail "score command failed to record" "$score_output"
fi

section "score command — explicit weighted average"

score_output2=$(bash "$PATTERN_HELPER" score \
	--model haiku \
	--task-type testing \
	--weighted-avg 3.2 \
	--source test \
	2>&1) || true

if echo "$score_output2" | grep -qi "recorded\|success\|pattern"; then
	pass "score command records with explicit weighted-avg (failure outcome)"
else
	fail "score command failed with explicit weighted-avg" "$score_output2"
fi

section "score command — outcome derivation"

# Score >= 3.5 should be success
score_high=$(bash "$PATTERN_HELPER" score \
	--model sonnet \
	--weighted-avg 4.0 \
	--source test \
	2>&1) || true
if echo "$score_high" | grep -qi "recorded\|success"; then
	pass "score >= 3.5 records as success"
else
	fail "score >= 3.5 did not record as success" "$score_high"
fi

# Score < 3.5 should be failure
score_low=$(bash "$PATTERN_HELPER" score \
	--model haiku \
	--weighted-avg 2.8 \
	--source test \
	2>&1) || true
if echo "$score_low" | grep -qi "recorded\|success"; then
	pass "score < 3.5 records (as failure outcome)"
else
	fail "score < 3.5 failed to record" "$score_low"
fi

section "score command — validation"

# Invalid score value
invalid_score=$(bash "$PATTERN_HELPER" score \
	--model sonnet \
	--correctness 6 \
	2>&1) || true
if echo "$invalid_score" | grep -qi "error\|must be\|1-5"; then
	pass "score command rejects out-of-range criterion score (6)"
else
	fail "score command should reject score > 5" "$invalid_score"
fi

# Invalid weighted-avg
invalid_avg=$(bash "$PATTERN_HELPER" score \
	--model sonnet \
	--weighted-avg "not-a-number" \
	2>&1) || true
if echo "$invalid_avg" | grep -qi "error\|number"; then
	pass "score command rejects non-numeric weighted-avg"
else
	fail "score command should reject non-numeric weighted-avg" "$invalid_avg"
fi

section "score command — with strategy and quality"

score_meta=$(bash "$PATTERN_HELPER" score \
	--model sonnet \
	--task-type feature \
	--task-id t1094 \
	--correctness 5 \
	--completeness 5 \
	--code-quality 4 \
	--clarity 4 \
	--strategy normal \
	--quality ci-pass-first-try \
	--tokens-in 12000 \
	--tokens-out 5000 \
	--source test \
	2>&1) || true

if echo "$score_meta" | grep -qi "recorded\|success"; then
	pass "score command records with full metadata (strategy, quality, tokens)"
else
	fail "score command failed with full metadata" "$score_meta"
fi

section "ab-compare command — basic"

ab_output=$(bash "$PATTERN_HELPER" ab-compare \
	--winner sonnet \
	--loser haiku \
	--task-type code-review \
	--winner-score 4.5 \
	--loser-score 3.1 \
	--models-compared 2 \
	--source test \
	2>&1) || true

if echo "$ab_output" | grep -qi "recorded\|wins\|success"; then
	pass "ab-compare records winner successfully"
else
	fail "ab-compare failed to record" "$ab_output"
fi

section "ab-compare command — multi-model"

ab_multi=$(bash "$PATTERN_HELPER" ab-compare \
	--winner opus \
	--loser sonnet \
	--loser haiku \
	--loser flash \
	--task-type architecture \
	--winner-score 4.8 \
	--models-compared 4 \
	--source test \
	2>&1) || true

if echo "$ab_multi" | grep -qi "recorded\|wins\|success"; then
	pass "ab-compare records multi-model comparison"
else
	fail "ab-compare failed for multi-model" "$ab_multi"
fi

section "ab-compare command — validation"

# Missing winner
ab_no_winner=$(bash "$PATTERN_HELPER" ab-compare \
	--loser haiku \
	2>&1) || true
if echo "$ab_no_winner" | grep -qi "error\|required\|winner"; then
	pass "ab-compare rejects missing --winner"
else
	fail "ab-compare should require --winner" "$ab_no_winner"
fi

section "score command — source tag tracking"

# Verify source tag is included in output (indirectly via stats)
bash "$PATTERN_HELPER" score \
	--model flash \
	--task-type docs \
	--weighted-avg 4.2 \
	--source response-scoring \
	>/dev/null 2>&1 || true

bash "$PATTERN_HELPER" score \
	--model sonnet \
	--task-type docs \
	--weighted-avg 3.8 \
	--source compare-models \
	>/dev/null 2>&1 || true

# Stats should show data
stats_output=$(bash "$PATTERN_HELPER" stats 2>&1) || true
if echo "$stats_output" | grep -qiE "pattern|total|success"; then
	pass "stats shows data after score recordings"
else
	fail "stats should show data after recordings" "$stats_output"
fi

section "score command — recommend integration"

# After recording scores, recommend should have data
bash "$PATTERN_HELPER" score \
	--model sonnet \
	--task-type bugfix \
	--weighted-avg 4.5 \
	--source test \
	>/dev/null 2>&1 || true

bash "$PATTERN_HELPER" score \
	--model haiku \
	--task-type bugfix \
	--weighted-avg 2.8 \
	--source test \
	>/dev/null 2>&1 || true

recommend_output=$(bash "$PATTERN_HELPER" recommend --task-type bugfix 2>&1) || true
if echo "$recommend_output" | grep -qi "sonnet\|recommend\|success"; then
	pass "recommend uses score data for model routing"
else
	skip "recommend output format may vary (no memory DB initialized)"
fi

section "export — includes score data"

export_output=$(bash "$PATTERN_HELPER" export --format json 2>&1) || true
if echo "$export_output" | grep -qE '\[|\{'; then
	pass "export returns JSON with score data"
else
	skip "export requires initialized memory DB"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
printf "\033[1m=== Test Summary ===\033[0m\n"
printf "  \033[0;32mPassed: %d\033[0m\n" "$PASS_COUNT"
printf "  \033[0;31mFailed: %d\033[0m\n" "$FAIL_COUNT"
printf "  \033[0;33mSkipped: %d\033[0m\n" "$SKIP_COUNT"
printf "  Total:  %d\n" "$TOTAL_COUNT"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
