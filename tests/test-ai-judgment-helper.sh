#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for ai-judgment-helper.sh and ai-research-helper.sh (t1363.6)
# Tests the intelligent threshold replacement system.
#
# Tests are designed to work WITHOUT an Anthropic API key — they verify
# the fallback behavior (deterministic thresholds) and the script structure.
# AI judgment tests are skipped when ANTHROPIC_API_KEY is not set.
#
# Usage: bash tests/test-ai-judgment-helper.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
AI_JUDGMENT="${REPO_DIR}/.agents/scripts/ai-judgment-helper.sh"
AI_RESEARCH="${REPO_DIR}/.agents/scripts/ai-research-helper.sh"
MEMORY_HELPER="${REPO_DIR}/.agents/scripts/memory-helper.sh"
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"
WORK_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

setup() {
	WORK_DIR=$(mktemp -d)
	export AIDEVOPS_MEMORY_DIR="$WORK_DIR"
	# Initialize memory tables first (creates learnings FTS5 table)
	# then entity tables (adds entity-specific tables to same DB)
	"$MEMORY_HELPER" store --content "init" --type CONTEXT 2>/dev/null || true
	"$MEMORY_HELPER" prune --older-than-days 0 --include-accessed 2>/dev/null || true
	"$ENTITY_HELPER" migrate 2>/dev/null || true
	return 0
}

teardown() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
	return 0
}

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

	if echo "$haystack" | grep -qF "$needle"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description ('$needle' not found in output)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_empty() {
	local value="$1"
	local description="$2"

	if [[ -n "$value" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (value is empty)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit_code() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" -eq "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected exit $expected, got $actual)"
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

has_api_key() {
	[[ -n "${ANTHROPIC_API_KEY:-}" ]]
}

# ============================================================
# Test: ai-research-helper.sh exists and is executable
# ============================================================
test_ai_research_helper_exists() {
	echo "Test: ai-research-helper.sh structure"

	assert_eq "true" "$(test -x "$AI_RESEARCH" && echo true || echo false)" \
		"ai-research-helper.sh is executable"

	# Test help/usage output
	local output
	output=$("$AI_RESEARCH" 2>&1 || true)
	assert_contains "$output" "Usage" "Shows usage on no args"

	return 0
}

# ============================================================
# Test: ai-research-helper.sh argument validation
# ============================================================
test_ai_research_argument_validation() {
	echo "Test: ai-research-helper.sh argument validation"

	# Missing prompt
	local exit_code=0
	"$AI_RESEARCH" 2>/dev/null || exit_code=$?
	assert_eq "3" "$exit_code" "Exits 3 on missing --prompt"

	# Invalid model
	exit_code=0
	"$AI_RESEARCH" --prompt "test" --model invalid 2>/dev/null || exit_code=$?
	assert_eq "3" "$exit_code" "Exits 3 on invalid model tier"

	return 0
}

# ============================================================
# Test: ai-judgment-helper.sh exists and is executable
# ============================================================
test_ai_judgment_helper_exists() {
	echo "Test: ai-judgment-helper.sh structure"

	assert_eq "true" "$(test -x "$AI_JUDGMENT" && echo true || echo false)" \
		"ai-judgment-helper.sh is executable"

	# Test help output
	local output
	output=$("$AI_JUDGMENT" help 2>&1)
	assert_contains "$output" "Intelligent threshold replacement" "Help shows description"
	assert_contains "$output" "is-memory-relevant" "Help lists is-memory-relevant command"
	assert_contains "$output" "optimal-response-length" "Help lists optimal-response-length command"
	assert_contains "$output" "batch-prune-check" "Help lists batch-prune-check command"

	return 0
}

# ============================================================
# Test: is-memory-relevant fallback (no API key)
# ============================================================
test_is_memory_relevant_fallback() {
	echo "Test: is-memory-relevant fallback behavior"
	setup

	# Young memory — should be kept
	local result
	result=$("$AI_JUDGMENT" is-memory-relevant --content "CORS fix: add nginx proxy_pass" --age-days 30 2>/dev/null)
	assert_eq "relevant" "$result" "Young memory (30d) is relevant"

	# Old memory — should be pruned by fallback threshold
	result=$("$AI_JUDGMENT" is-memory-relevant --content "Temporary debug logging" --age-days 120 2>/dev/null)
	assert_eq "prune" "$result" "Old memory (120d) is pruned by fallback"

	# Memory at threshold boundary
	result=$("$AI_JUDGMENT" is-memory-relevant --content "Some learning" --age-days 89 2>/dev/null)
	assert_eq "relevant" "$result" "Memory at 89d is relevant (under 90d threshold)"

	result=$("$AI_JUDGMENT" is-memory-relevant --content "Some learning" --age-days 91 2>/dev/null)
	assert_eq "prune" "$result" "Memory at 91d is pruned (over 90d threshold)"

	teardown
	return 0
}

# ============================================================
# Test: optimal-response-length defaults
# ============================================================
test_optimal_response_length_defaults() {
	echo "Test: optimal-response-length defaults"
	setup

	# No entity — returns default
	local result
	result=$("$AI_JUDGMENT" optimal-response-length 2>/dev/null)
	assert_eq "4000" "$result" "No entity returns default 4000"

	# Custom default
	result=$("$AI_JUDGMENT" optimal-response-length --default 6000 2>/dev/null)
	assert_eq "6000" "$result" "Custom default is respected"

	# Non-existent entity — returns default
	result=$("$AI_JUDGMENT" optimal-response-length --entity "ent_nonexistent" 2>/dev/null)
	assert_eq "4000" "$result" "Non-existent entity returns default"

	teardown
	return 0
}

# ============================================================
# Test: optimal-response-length with entity profile
# ============================================================
test_optimal_response_length_with_profile() {
	echo "Test: optimal-response-length with entity profile"
	setup

	# Create an entity
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Test User" --type person 2>/dev/null)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -oP 'ent_[a-f0-9_]+' | head -1)

	if [[ -z "$entity_id" ]]; then
		skip_test "Could not create test entity"
		teardown
		return 0
	fi

	# Set detail preference to concise
	"$ENTITY_HELPER" profile-update "$entity_id" --key "detail_preference" --value "concise" 2>/dev/null || true

	local result
	result=$("$AI_JUDGMENT" optimal-response-length --entity "$entity_id" 2>/dev/null)
	assert_eq "2000" "$result" "Concise preference returns 2000"

	# Update to verbose
	"$ENTITY_HELPER" profile-update "$entity_id" --key "detail_preference" --value "detailed" 2>/dev/null || true

	result=$("$AI_JUDGMENT" optimal-response-length --entity "$entity_id" 2>/dev/null)
	assert_eq "8000" "$result" "Detailed preference returns 8000"

	teardown
	return 0
}

# ============================================================
# Test: should-prune with memory data
# ============================================================
test_should_prune() {
	echo "Test: should-prune with memory data"
	setup

	# Store a memory
	local store_output
	store_output=$("$MEMORY_HELPER" store --content "Test memory for pruning" --type WORKING_SOLUTION 2>/dev/null)
	local mem_id
	mem_id=$(echo "$store_output" | grep -oP 'mem_[a-f0-9_]+' | head -1)

	if [[ -z "$mem_id" ]]; then
		skip_test "Could not store test memory"
		teardown
		return 0
	fi

	# Fresh memory should be kept
	local result
	result=$("$AI_JUDGMENT" should-prune --memory-id "$mem_id" 2>/dev/null)
	assert_contains "$result" "keep" "Fresh memory is kept"

	teardown
	return 0
}

# ============================================================
# Test: batch-prune-check with no old memories
# ============================================================
test_batch_prune_empty() {
	echo "Test: batch-prune-check with no old memories"
	setup

	# Store a fresh memory
	"$MEMORY_HELPER" store --content "Fresh memory" --type WORKING_SOLUTION 2>/dev/null || true

	# Batch check should find nothing to prune
	local result
	result=$("$AI_JUDGMENT" batch-prune-check --older-than-days 60 --dry-run 2>&1)
	assert_contains "$result" "No memories older than" "No old memories to evaluate"

	teardown
	return 0
}

# ============================================================
# Test: judgment cache initialization
# ============================================================
test_judgment_cache() {
	echo "Test: judgment cache table creation"
	setup

	# Run any command to trigger cache init
	"$AI_JUDGMENT" is-memory-relevant --content "test" --age-days 10 2>/dev/null || true

	# Check that cache table exists
	local tables
	tables=$(sqlite3 "$WORK_DIR/memory.db" ".tables" 2>/dev/null || echo "")
	assert_contains "$tables" "ai_judgment_cache" "Cache table created"

	teardown
	return 0
}

# ============================================================
# Test: AI judgment (requires API key)
# ============================================================
test_ai_judgment_with_api() {
	echo "Test: AI judgment with API key"

	if ! has_api_key; then
		skip_test "ANTHROPIC_API_KEY not set — skipping AI judgment tests"
		return 0
	fi

	setup

	# Test ai-research-helper.sh with a simple prompt
	local result
	result=$("$AI_RESEARCH" --prompt "Respond with only the word 'hello'" --model haiku --max-tokens 10 2>/dev/null || echo "")
	assert_not_empty "$result" "AI research helper returns a response"

	# Test is-memory-relevant with AI
	result=$("$AI_JUDGMENT" is-memory-relevant --content "How to fix CORS errors with nginx reverse proxy: add proxy_set_header Origin" --age-days 120 2>/dev/null)
	# This is a timeless pattern — AI should judge it relevant even though it's old
	assert_not_empty "$result" "AI judgment returns a result for memory relevance"

	teardown
	return 0
}

# ============================================================
# Test: memory-helper.sh prune --intelligent flag
# ============================================================
test_memory_prune_intelligent_flag() {
	echo "Test: memory-helper.sh prune --intelligent flag"
	setup

	# Store a fresh memory
	"$MEMORY_HELPER" store --content "Test memory" --type WORKING_SOLUTION 2>/dev/null || true

	# Run prune with --intelligent --dry-run
	local result
	result=$("$MEMORY_HELPER" prune --intelligent --dry-run 2>&1 || true)
	# Should either use AI judgment or fall back gracefully
	assert_not_empty "$result" "Intelligent prune produces output"

	teardown
	return 0
}

# ============================================================
# Run all tests
# ============================================================
main() {
	echo "============================================"
	echo "  AI Judgment Helper Tests (t1363.6)"
	echo "============================================"
	echo ""

	test_ai_research_helper_exists
	echo ""
	test_ai_research_argument_validation
	echo ""
	test_ai_judgment_helper_exists
	echo ""
	test_is_memory_relevant_fallback
	echo ""
	test_optimal_response_length_defaults
	echo ""
	test_optimal_response_length_with_profile
	echo ""
	test_should_prune
	echo ""
	test_batch_prune_empty
	echo ""
	test_judgment_cache
	echo ""
	test_ai_judgment_with_api
	echo ""
	test_memory_prune_intelligent_flag
	echo ""

	echo "============================================"
	echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
