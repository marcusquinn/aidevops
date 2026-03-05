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
# Test: evaluate command — help lists evaluate (t1394)
# ============================================================
test_evaluate_help_listed() {
	echo "Test: evaluate command listed in help (t1394)"

	local output
	output=$("$AI_JUDGMENT" help 2>&1)
	assert_contains "$output" "evaluate" "Help lists evaluate command"
	assert_contains "$output" "faithfulness" "Help lists faithfulness evaluator"
	assert_contains "$output" "relevancy" "Help lists relevancy evaluator"
	assert_contains "$output" "safety" "Help lists safety evaluator"
	assert_contains "$output" "format-validity" "Help lists format-validity evaluator"
	assert_contains "$output" "completeness" "Help lists completeness evaluator"
	assert_contains "$output" "conciseness" "Help lists conciseness evaluator"

	return 0
}

# ============================================================
# Test: evaluate command — missing --type returns error
# ============================================================
test_evaluate_missing_type() {
	echo "Test: evaluate requires --type flag (t1394)"
	setup

	local exit_code=0
	"$AI_JUDGMENT" evaluate --output "test" 2>/dev/null || exit_code=$?
	assert_eq "1" "$exit_code" "Exits 1 when --type is missing"

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — missing --output returns error
# ============================================================
test_evaluate_missing_output() {
	echo "Test: evaluate requires --output or --dataset (t1394)"
	setup

	local exit_code=0
	"$AI_JUDGMENT" evaluate --type faithfulness --input "test" 2>/dev/null || exit_code=$?
	assert_eq "1" "$exit_code" "Exits 1 when --output and --dataset are missing"

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — fallback when API unavailable
# ============================================================
test_evaluate_fallback() {
	echo "Test: evaluate fallback when API unavailable (t1394)"
	setup

	# Unset API key to force fallback
	local saved_key="${ANTHROPIC_API_KEY:-}"
	unset ANTHROPIC_API_KEY

	local result
	result=$("$AI_JUDGMENT" evaluate --type faithfulness \
		--input "What is the capital of France?" \
		--output "The capital of France is Paris." 2>/dev/null)

	# Should return JSON with null score and null passed (not 0/false)
	assert_contains "$result" "\"score\": null" "Fallback returns null score"
	assert_contains "$result" "\"passed\": null" "Fallback returns null passed"
	assert_contains "$result" "\"evaluator\": \"faithfulness\"" "Fallback includes evaluator name"
	assert_contains "$result" "API unavailable" "Fallback mentions API unavailable"

	# Restore key if it was set
	if [[ -n "$saved_key" ]]; then
		export ANTHROPIC_API_KEY="$saved_key"
	fi

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — multiple evaluators (comma-separated)
# ============================================================
test_evaluate_multiple_types() {
	echo "Test: evaluate with multiple types (t1394)"
	setup

	# Unset API key to force fallback — we're testing the multi-type parsing
	local saved_key="${ANTHROPIC_API_KEY:-}"
	unset ANTHROPIC_API_KEY

	local result
	result=$("$AI_JUDGMENT" evaluate --type "faithfulness,relevancy,safety" \
		--input "test" --output "test output" 2>/dev/null)

	# Should return JSON array with 3 results
	assert_contains "$result" "[" "Multiple types returns JSON array"
	assert_contains "$result" "faithfulness" "Array contains faithfulness result"
	assert_contains "$result" "relevancy" "Array contains relevancy result"
	assert_contains "$result" "safety" "Array contains safety result"

	if [[ -n "$saved_key" ]]; then
		export ANTHROPIC_API_KEY="$saved_key"
	fi

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — dataset mode
# ============================================================
test_evaluate_dataset() {
	echo "Test: evaluate with --dataset flag (t1394)"
	setup

	# Unset API key to force fallback
	local saved_key="${ANTHROPIC_API_KEY:-}"
	unset ANTHROPIC_API_KEY

	# Create a test dataset
	local dataset_file="$WORK_DIR/test-dataset.jsonl"
	echo '{"input": "What is 2+2?", "output": "4"}' >"$dataset_file"
	echo '{"input": "Capital of France?", "output": "Paris", "context": "France capital is Paris"}' >>"$dataset_file"

	local result
	result=$("$AI_JUDGMENT" evaluate --type relevancy --dataset "$dataset_file" 2>/dev/null)

	# Should contain row results and summary
	assert_contains "$result" "\"row\":" "Dataset output contains row numbers"
	assert_contains "$result" "\"summary\":" "Dataset output contains summary"
	assert_contains "$result" "\"rows\": 2" "Summary shows correct row count"

	if [[ -n "$saved_key" ]]; then
		export ANTHROPIC_API_KEY="$saved_key"
	fi

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — dataset file not found
# ============================================================
test_evaluate_dataset_not_found() {
	echo "Test: evaluate --dataset with missing file (t1394)"
	setup

	local exit_code=0
	"$AI_JUDGMENT" evaluate --type relevancy --dataset "/nonexistent/file.jsonl" 2>/dev/null || exit_code=$?
	assert_eq "1" "$exit_code" "Exits 1 when dataset file not found"

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — custom evaluator with --prompt-file
# ============================================================
test_evaluate_custom_prompt_file() {
	echo "Test: evaluate with custom --prompt-file (t1394)"
	setup

	# Unset API key to force fallback
	local saved_key="${ANTHROPIC_API_KEY:-}"
	unset ANTHROPIC_API_KEY

	# Create a custom prompt file
	local prompt_file="$WORK_DIR/custom-eval.txt"
	echo 'You are a custom evaluator. Score the output.' >"$prompt_file"

	local result
	result=$("$AI_JUDGMENT" evaluate --type custom --prompt-file "$prompt_file" \
		--input "test" --output "test output" 2>/dev/null)

	# Should return fallback JSON (API unavailable)
	assert_contains "$result" "\"evaluator\": \"custom\"" "Custom evaluator returns correct type"

	if [[ -n "$saved_key" ]]; then
		export ANTHROPIC_API_KEY="$saved_key"
	fi

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — custom prompt file not found
# ============================================================
test_evaluate_custom_prompt_not_found() {
	echo "Test: evaluate with missing --prompt-file (t1394)"
	setup

	local result
	result=$("$AI_JUDGMENT" evaluate --type custom --prompt-file "/nonexistent/prompt.txt" \
		--input "test" --output "test output" 2>/dev/null)

	assert_contains "$result" "Prompt file not found" "Reports missing prompt file"
	assert_contains "$result" "\"score\": null" "Returns null score for missing prompt"

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — result caching
# ============================================================
test_evaluate_caching() {
	echo "Test: evaluate result caching (t1394)"
	setup

	# Unset API key to force fallback
	local saved_key="${ANTHROPIC_API_KEY:-}"
	unset ANTHROPIC_API_KEY

	# Run evaluation twice with same inputs — second should use cache
	"$AI_JUDGMENT" evaluate --type faithfulness \
		--input "test input" --output "test output" 2>/dev/null || true

	# Check that cache table has entries
	local cache_count
	cache_count=$(sqlite3 "$WORK_DIR/memory.db" \
		"SELECT COUNT(*) FROM ai_judgment_cache WHERE key LIKE 'eval:%';" 2>/dev/null || echo "0")

	# Note: fallback results are NOT cached (only AI results are cached)
	# So with no API key, cache should be empty
	assert_eq "0" "$cache_count" "Fallback results are not cached (correct behavior)"

	if [[ -n "$saved_key" ]]; then
		export ANTHROPIC_API_KEY="$saved_key"
	fi

	teardown
	return 0
}

# ============================================================
# Test: evaluate command — with API key (live test)
# ============================================================
test_evaluate_with_api() {
	echo "Test: evaluate with API key (t1394)"

	if ! has_api_key; then
		skip_test "ANTHROPIC_API_KEY not set — skipping live evaluate tests"
		return 0
	fi

	setup

	# Test faithfulness evaluator with clear-cut case
	local result
	result=$("$AI_JUDGMENT" evaluate --type faithfulness \
		--input "What is the capital of France?" \
		--output "The capital of France is Paris." \
		--context "France is a country in Western Europe. Its capital is Paris." 2>/dev/null)

	assert_contains "$result" "\"score\":" "Live evaluation returns a score"
	assert_contains "$result" "\"passed\":" "Live evaluation returns passed field"
	assert_contains "$result" "\"evaluator\": \"faithfulness\"" "Live evaluation returns evaluator name"

	# Verify caching works with API
	local cache_count
	cache_count=$(sqlite3 "$WORK_DIR/memory.db" \
		"SELECT COUNT(*) FROM ai_judgment_cache WHERE key LIKE 'eval:%';" 2>/dev/null || echo "0")
	assert_eq "1" "$cache_count" "Live evaluation result is cached"

	teardown
	return 0
}

# ============================================================
# Run all tests
# ============================================================
main() {
	echo "============================================"
	echo "  AI Judgment Helper Tests (t1363.6 + t1394)"
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
	test_evaluate_help_listed
	echo ""
	test_evaluate_missing_type
	echo ""
	test_evaluate_missing_output
	echo ""
	test_evaluate_fallback
	echo ""
	test_evaluate_multiple_types
	echo ""
	test_evaluate_dataset
	echo ""
	test_evaluate_dataset_not_found
	echo ""
	test_evaluate_custom_prompt_file
	echo ""
	test_evaluate_custom_prompt_not_found
	echo ""
	test_evaluate_caching
	echo ""
	test_evaluate_with_api
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
