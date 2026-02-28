#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for ai-threshold-judge.sh and ai-research-helper.sh (t1363.6)
# Tests the fallback heuristics (no API key needed) and script structure.
# AI-judged paths are tested only when ANTHROPIC_API_KEY is available.
#
# Usage: bash tests/test-ai-threshold-judge.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
THRESHOLD_JUDGE="${REPO_DIR}/.agents/scripts/ai-threshold-judge.sh"
AI_RESEARCH="${REPO_DIR}/.agents/scripts/ai-research-helper.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

assert_eq() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" == "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected '$expected', got '$actual')"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"

	if echo "$haystack" | grep -qF -- "$needle"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description ('$needle' not found in output)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_numeric() {
	local value="$1"
	local description="$2"

	if [[ "$value" =~ ^[0-9]+$ ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected numeric, got '$value')"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

skip_test() {
	local description="$1"
	echo -e "  ${YELLOW}SKIP${NC}: $description"
	SKIP=$((SKIP + 1))
	return 0
}

# ============================================================
# ai-research-helper.sh tests
# ============================================================

test_ai_research_help() {
	echo ""
	echo "=== ai-research-helper.sh ==="

	local output
	output=$("$AI_RESEARCH" --help 2>&1)
	assert_contains "$output" "Lightweight Anthropic API wrapper" "help text shows description"
	assert_contains "$output" "--prompt" "help text shows --prompt flag"
	assert_contains "$output" "--model" "help text shows --model flag"
	return 0
}

test_ai_research_no_prompt() {
	local output
	output=$("$AI_RESEARCH" 2>&1 || true)
	assert_contains "$output" "No prompt provided" "error on missing prompt"
	return 0
}

# ============================================================
# ai-threshold-judge.sh tests
# ============================================================

test_threshold_help() {
	echo ""
	echo "=== ai-threshold-judge.sh help ==="

	local output
	output=$("$THRESHOLD_JUDGE" help 2>&1)
	assert_contains "$output" "AI-judged threshold decisions" "help text shows description"
	assert_contains "$output" "judge-prune-relevance" "help lists prune command"
	assert_contains "$output" "judge-dedup-similarity" "help lists dedup command"
	assert_contains "$output" "judge-prompt-length" "help lists prompt-length command"
	return 0
}

test_threshold_unknown_command() {
	local output
	output=$("$THRESHOLD_JUDGE" nonexistent 2>&1 || true)
	assert_contains "$output" "Unknown command" "error on unknown command"
	return 0
}

# ============================================================
# Prune relevance tests (heuristic fallback — no API needed)
# ============================================================

test_prune_high_confidence_accessed() {
	echo ""
	echo "=== Prune relevance: heuristic fallback ==="

	# High confidence + accessed = always keep
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "CORS fix with nginx reverse proxy" \
		--age-days 200 \
		--type "WORKING_SOLUTION" \
		--accessed "true" \
		--confidence "high" 2>/dev/null)
	assert_eq "keep" "$result" "high confidence + accessed = keep"
	return 0
}

test_prune_very_old_low_confidence() {
	# Very old + never accessed + low confidence = always prune
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Temporary debug note" \
		--age-days 200 \
		--type "CONTEXT" \
		--accessed "false" \
		--confidence "low" 2>/dev/null)
	assert_eq "prune" "$result" "very old + never accessed + low confidence = prune"
	return 0
}

test_prune_working_solution_type() {
	# WORKING_SOLUTION: long-lived, 180 day threshold
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Use nginx for CORS headers" \
		--age-days 100 \
		--type "WORKING_SOLUTION" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "keep" "$result" "WORKING_SOLUTION at 100 days = keep (threshold 180)"

	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Use nginx for CORS headers" \
		--age-days 190 \
		--type "WORKING_SOLUTION" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "prune" "$result" "WORKING_SOLUTION at 190 days = prune (threshold 180)"
	return 0
}

test_prune_error_fix_type() {
	# ERROR_FIX: medium-lived, 120 day threshold
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Fix: add missing semicolon in config" \
		--age-days 100 \
		--type "ERROR_FIX" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "keep" "$result" "ERROR_FIX at 100 days = keep (threshold 120)"

	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Fix: add missing semicolon in config" \
		--age-days 130 \
		--type "ERROR_FIX" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "prune" "$result" "ERROR_FIX at 130 days = prune (threshold 120)"
	return 0
}

test_prune_context_type() {
	# CONTEXT: short-lived, 60 day threshold
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Working on feature branch for auth" \
		--age-days 50 \
		--type "CONTEXT" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "keep" "$result" "CONTEXT at 50 days = keep (threshold 60)"

	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "Working on feature branch for auth" \
		--age-days 70 \
		--type "CONTEXT" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "prune" "$result" "CONTEXT at 70 days = prune (threshold 60)"
	return 0
}

test_prune_user_preference_type() {
	# USER_PREFERENCE: very long-lived, 365 day threshold
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "User prefers concise responses" \
		--age-days 300 \
		--type "USER_PREFERENCE" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "keep" "$result" "USER_PREFERENCE at 300 days = keep (threshold 365)"

	result=$("$THRESHOLD_JUDGE" judge-prune-relevance \
		--content "User prefers concise responses" \
		--age-days 400 \
		--type "USER_PREFERENCE" \
		--accessed "false" \
		--confidence "medium" 2>/dev/null)
	assert_eq "prune" "$result" "USER_PREFERENCE at 400 days = prune (threshold 365)"
	return 0
}

test_prune_missing_args() {
	# Missing required args = keep (safe default)
	local result
	result=$("$THRESHOLD_JUDGE" judge-prune-relevance --content "test" 2>/dev/null)
	assert_eq "keep" "$result" "missing --age-days = keep (safe default)"
	return 0
}

# ============================================================
# Dedup similarity tests (heuristic fallback — no API needed)
# ============================================================

test_dedup_exact_match() {
	echo ""
	echo "=== Dedup similarity: heuristic fallback ==="

	local result
	result=$("$THRESHOLD_JUDGE" judge-dedup-similarity \
		--content-a "Use nginx for CORS headers" \
		--content-b "Use nginx for CORS headers" 2>/dev/null)
	assert_eq "duplicate" "$result" "exact match = duplicate"
	return 0
}

test_dedup_normalized_match() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-dedup-similarity \
		--content-a "Use nginx for CORS headers." \
		--content-b "Use nginx for CORS headers" 2>/dev/null)
	assert_eq "duplicate" "$result" "normalized match (punctuation) = duplicate"
	return 0
}

test_dedup_very_different_lengths() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-dedup-similarity \
		--content-a "Short" \
		--content-b "This is a much longer piece of content that discusses many different topics and has a very different length from the first entry which makes it clearly distinct" 2>/dev/null)
	assert_eq "distinct" "$result" "very different lengths = distinct"
	return 0
}

test_dedup_clearly_different() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-dedup-similarity \
		--content-a "Use nginx for CORS headers" \
		--content-b "Deploy with Docker Compose on production" 2>/dev/null)
	assert_eq "distinct" "$result" "clearly different content = distinct"
	return 0
}

test_dedup_missing_args() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-dedup-similarity --content-a "test" 2>/dev/null)
	assert_eq "distinct" "$result" "missing --content-b = distinct (safe default)"
	return 0
}

# ============================================================
# Prompt length tests (heuristic fallback — no API needed)
# ============================================================

test_prompt_length_matrix() {
	echo ""
	echo "=== Prompt length: channel defaults ==="

	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length --channel matrix 2>/dev/null)
	assert_eq "3000" "$result" "matrix channel = 3000"
	return 0
}

test_prompt_length_email() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length --channel email 2>/dev/null)
	assert_eq "6000" "$result" "email channel = 6000"
	return 0
}

test_prompt_length_cli() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length --channel cli 2>/dev/null)
	assert_eq "4000" "$result" "cli channel = 4000"
	return 0
}

test_prompt_length_simplex() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length --channel simplex 2>/dev/null)
	assert_eq "3000" "$result" "simplex channel = 3000"
	return 0
}

test_prompt_length_default() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length 2>/dev/null)
	assert_eq "4000" "$result" "no channel = 4000 default"
	return 0
}

test_prompt_length_numeric() {
	local result
	result=$("$THRESHOLD_JUDGE" judge-prompt-length --channel matrix 2>/dev/null)
	assert_numeric "$result" "prompt length is numeric"
	return 0
}

# ============================================================
# Main
# ============================================================

main() {
	echo "============================================"
	echo "  ai-threshold-judge.sh + ai-research-helper.sh tests"
	echo "============================================"

	# Verify scripts exist
	if [[ ! -x "$THRESHOLD_JUDGE" ]]; then
		echo -e "${RED}ERROR${NC}: ai-threshold-judge.sh not found or not executable"
		exit 1
	fi
	if [[ ! -x "$AI_RESEARCH" ]]; then
		echo -e "${RED}ERROR${NC}: ai-research-helper.sh not found or not executable"
		exit 1
	fi

	# ai-research-helper tests
	test_ai_research_help
	test_ai_research_no_prompt

	# ai-threshold-judge tests
	test_threshold_help
	test_threshold_unknown_command

	# Prune relevance (heuristic fallback)
	test_prune_high_confidence_accessed
	test_prune_very_old_low_confidence
	test_prune_working_solution_type
	test_prune_error_fix_type
	test_prune_context_type
	test_prune_user_preference_type
	test_prune_missing_args

	# Dedup similarity (heuristic fallback)
	test_dedup_exact_match
	test_dedup_normalized_match
	test_dedup_very_different_lengths
	test_dedup_clearly_different
	test_dedup_missing_args

	# Prompt length (channel defaults)
	test_prompt_length_matrix
	test_prompt_length_email
	test_prompt_length_cli
	test_prompt_length_simplex
	test_prompt_length_default
	test_prompt_length_numeric

	# Summary
	echo ""
	echo "============================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
