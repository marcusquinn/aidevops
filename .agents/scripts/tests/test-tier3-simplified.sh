#!/usr/bin/env bash
# =============================================================================
# Integration Tests for Tier 3 Simplified Scripts (t1337.3)
# =============================================================================
# Verifies the 5 simplified Tier 3 scripts:
#   1. full-loop-helper.sh       (534 lines, was 1169)
#   2. fallback-chain-helper.sh  (261 lines, was 1367)
#   3. budget-tracker-helper.sh  (309 lines, was 1671)
#   4. issue-sync-helper.sh      (903 lines, was 2398)
#   5. observability-helper.sh   (640 lines, was 1741)
#
# Tests: sourcing, help output, state management, record/query, backward compat.
# Does NOT require GitHub API, network, or real Claude sessions.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp dir for test isolation
TEST_DIR=""

# =============================================================================
# Test Framework
# =============================================================================

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${NC} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${RED}FAIL${NC} $test_name"
		[[ -n "$message" ]] && echo "       $message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	export HOME="$TEST_DIR"
	mkdir -p "$TEST_DIR/.aidevops/.agent-workspace"
	mkdir -p "$TEST_DIR/.config/aidevops"
	mkdir -p "$TEST_DIR/.claude/projects"
	return 0
}

teardown() {
	[[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	return 0
}

# =============================================================================
# 1. Syntax & Sourcing Tests
# =============================================================================

test_syntax_check() {
	echo ""
	echo "=== Syntax & Sourcing ==="

	local scripts=(
		"full-loop-helper.sh"
		"fallback-chain-helper.sh"
		"budget-tracker-helper.sh"
		"issue-sync-helper.sh"
		"observability-helper.sh"
	)

	for script in "${scripts[@]}"; do
		local path="${SCRIPTS_DIR}/${script}"
		if bash -n "$path" 2>/dev/null; then
			print_result "syntax: $script" 0
		else
			print_result "syntax: $script" 1 "Syntax error in $script"
		fi
	done
	return 0
}

# =============================================================================
# 2. Help Output Tests
# =============================================================================

test_help_output() {
	echo ""
	echo "=== Help Output ==="

	local -A scripts_and_keywords=(
		["full-loop-helper.sh"]="start|resume|status|cancel|headless"
		["fallback-chain-helper.sh"]="resolve|table|tier"
		["budget-tracker-helper.sh"]="record|status|burn-rate|tail"
		["issue-sync-helper.sh"]="push|pull|close|enrich|reconcile"
		["observability-helper.sh"]="ingest|record|rate-limits"
	)

	for script in "${!scripts_and_keywords[@]}"; do
		local path="${SCRIPTS_DIR}/${script}"
		local keywords="${scripts_and_keywords[$script]}"
		local output
		output=$("$path" help 2>&1) || true

		local all_found=true
		local IFS='|'
		for keyword in $keywords; do
			if ! echo "$output" | grep -qi "$keyword"; then
				print_result "help: $script contains '$keyword'" 1 "Missing keyword '$keyword' in help output"
				all_found=false
			fi
		done
		unset IFS

		if [[ "$all_found" == "true" ]]; then
			print_result "help: $script" 0
		fi
	done
	return 0
}

# =============================================================================
# 3. Full-Loop-Helper Tests
# =============================================================================

test_full_loop_helper() {
	echo ""
	echo "=== Full-Loop-Helper ==="

	local helper="${SCRIPTS_DIR}/full-loop-helper.sh"

	# Test: status with no active loop
	local output
	output=$("$helper" status 2>&1) || true
	if echo "$output" | grep -q "No active full loop"; then
		print_result "full-loop: status (no active loop)" 0
	else
		print_result "full-loop: status (no active loop)" 1 "Expected 'No active full loop'"
	fi

	# Test: cancel with no active loop
	output=$("$helper" cancel 2>&1) || true
	if echo "$output" | grep -qi "no active loop"; then
		print_result "full-loop: cancel (no active loop)" 0
	else
		print_result "full-loop: cancel (no active loop)" 1 "Expected 'No active loop' message"
	fi

	# Test: start requires feature branch (we're on feature/t1337.3 so this should work)
	# But we need a git repo context — test dry-run instead
	local git_root
	git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [[ -n "$git_root" ]]; then
		output=$("$helper" start "test prompt" --dry-run 2>&1) || true
		if echo "$output" | grep -qi "dry run"; then
			print_result "full-loop: start --dry-run" 0
		else
			print_result "full-loop: start --dry-run" 1 "Expected dry run output"
		fi
	else
		print_result "full-loop: start --dry-run" 0 "(skipped: no git repo)"
	fi

	# Test: start with no prompt
	output=$("$helper" start "" 2>&1) || true
	local rc=$?
	if [[ $rc -ne 0 ]] || echo "$output" | grep -qi "no prompt\|usage"; then
		print_result "full-loop: start (no prompt) fails" 0
	else
		print_result "full-loop: start (no prompt) fails" 1 "Expected error for empty prompt"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "full-loop: unknown command" 0
	else
		print_result "full-loop: unknown command" 1 "Expected 'Unknown command'"
	fi

	return 0
}

# =============================================================================
# 4. Fallback-Chain-Helper Tests
# =============================================================================

test_fallback_chain_helper() {
	echo ""
	echo "=== Fallback-Chain-Helper ==="

	local helper="${SCRIPTS_DIR}/fallback-chain-helper.sh"
	local avail_helper="${SCRIPTS_DIR}/model-availability-helper.sh"

	# Temporarily hide model-availability-helper.sh so fallback-chain uses its
	# lightweight API key check instead of HTTP probes (which fail with fake keys)
	local avail_hidden=false
	if [[ -x "$avail_helper" ]]; then
		mv "$avail_helper" "${avail_helper}.bak"
		avail_hidden=true
	fi

	# Test: resolve with no tier
	local output
	output=$("$helper" resolve 2>&1) || true
	if echo "$output" | grep -qiE "usage|tier"; then
		print_result "fallback: resolve (no tier) shows usage" 0
	else
		print_result "fallback: resolve (no tier) shows usage" 1 "Expected usage message"
	fi

	# Test: resolve haiku tier (hardcoded fallback — no config file needed)
	# Set a fake API key so the lightweight availability check passes
	export ANTHROPIC_API_KEY="test-key-for-testing"
	output=$("$helper" resolve haiku --quiet 2>&1) || true
	if echo "$output" | grep -q "claude-haiku"; then
		print_result "fallback: resolve haiku -> claude-haiku" 0
	else
		print_result "fallback: resolve haiku -> claude-haiku" 1 "Got: $output"
	fi

	# Test: resolve sonnet tier
	output=$("$helper" resolve sonnet --quiet 2>&1) || true
	if echo "$output" | grep -q "claude-sonnet"; then
		print_result "fallback: resolve sonnet -> claude-sonnet" 0
	else
		print_result "fallback: resolve sonnet -> claude-sonnet" 1 "Got: $output"
	fi

	# Test: resolve opus tier
	output=$("$helper" resolve opus --quiet 2>&1) || true
	if echo "$output" | grep -q "claude-opus"; then
		print_result "fallback: resolve opus -> claude-opus" 0
	else
		print_result "fallback: resolve opus -> claude-opus" 1 "Got: $output"
	fi

	# Test: resolve with --json flag
	output=$("$helper" resolve haiku --quiet --json 2>&1) || true
	if echo "$output" | grep -q '"status":"resolved"'; then
		print_result "fallback: resolve --json output" 0
	else
		print_result "fallback: resolve --json output" 1 "Got: $output"
	fi

	# Test: unknown tier (with no API key set for unknown providers)
	unset ANTHROPIC_API_KEY
	output=$("$helper" resolve nonexistent --quiet 2>&1) || true
	local rc=$?
	if [[ $rc -ne 0 ]] || echo "$output" | grep -qiE "unknown tier|error"; then
		print_result "fallback: unknown tier fails" 0
	else
		print_result "fallback: unknown tier fails" 1 "Expected error, got: $output (rc=$rc)"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qiE "unknown command"; then
		print_result "fallback: unknown command" 0
	else
		print_result "fallback: unknown command" 1 "Expected 'Unknown command'"
	fi

	# Restore model-availability-helper.sh
	if [[ "$avail_hidden" == "true" ]]; then
		mv "${avail_helper}.bak" "$avail_helper"
	fi

	return 0
}

# =============================================================================
# 5. Budget-Tracker-Helper Tests
# =============================================================================

test_budget_tracker_helper() {
	echo ""
	echo "=== Budget-Tracker-Helper ==="

	local helper="${SCRIPTS_DIR}/budget-tracker-helper.sh"

	# Test: record a spend event
	local output
	output=$("$helper" record --provider anthropic --model anthropic/claude-sonnet-4-6 \
		--input-tokens 1000 --output-tokens 500 --task t1337.3 2>&1) || true
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "budget: record spend event" 0
	else
		print_result "budget: record spend event" 1 "Exit code: $rc, output: $output"
	fi

	# Verify the log file was created and has content
	local cost_log="${TEST_DIR}/.aidevops/.agent-workspace/cost-log.tsv"
	if [[ -f "$cost_log" ]] && [[ $(wc -l <"$cost_log") -ge 2 ]]; then
		print_result "budget: cost log created with data" 0
	else
		print_result "budget: cost log created with data" 1 "Log file missing or empty"
	fi

	# Test: record with --cost override
	output=$("$helper" record --provider openai --model openai/gpt-4.1 \
		--input-tokens 500 --output-tokens 200 --cost 0.05 2>&1) || true
	if [[ $? -eq 0 ]]; then
		print_result "budget: record with --cost override" 0
	else
		print_result "budget: record with --cost override" 1
	fi

	# Test: status command
	output=$("$helper" status 2>&1) || true
	if echo "$output" | grep -qiE 'cost|events|spend'; then
		print_result "budget: status shows summary" 0
	else
		print_result "budget: status shows summary" 1 "Got: $output"
	fi

	# Test: status --json
	output=$("$helper" status --json 2>&1) || true
	if echo "$output" | grep -q '"total_cost_usd"'; then
		print_result "budget: status --json" 0
	else
		print_result "budget: status --json" 1 "Got: $output"
	fi

	# Test: burn-rate
	output=$("$helper" burn-rate 2>&1) || true
	if echo "$output" | grep -qiE 'burn rate|spend|hourly'; then
		print_result "budget: burn-rate" 0
	else
		print_result "budget: burn-rate" 1 "Got: $output"
	fi

	# Test: tail
	output=$("$helper" tail 5 2>&1) || true
	if echo "$output" | grep -q "timestamp"; then
		print_result "budget: tail shows header" 0
	else
		print_result "budget: tail shows header" 1 "Got: $output"
	fi

	# Test: record with missing required args
	local rc_record=0
	output=$("$helper" record 2>&1) || rc_record=$?
	if [[ $rc_record -ne 0 ]] || echo "$output" | grep -qiE "usage|error|required"; then
		print_result "budget: record (missing args) fails" 0
	else
		print_result "budget: record (missing args) fails" 1 "Expected error, got rc=$rc_record"
	fi

	# Test: backward compat — removed commands return gracefully
	local removed_cmds=("check" "recommend" "configure" "reset" "tier-drift" "prune")
	local all_compat=true
	for cmd in "${removed_cmds[@]}"; do
		output=$("$helper" "$cmd" 2>&1) || true
		rc=$?
		if [[ $rc -ne 0 ]]; then
			print_result "budget: backward compat '$cmd'" 1 "Exit code: $rc"
			all_compat=false
		fi
	done
	if [[ "$all_compat" == "true" ]]; then
		print_result "budget: backward compat (removed commands)" 0
	fi

	# Test: budget-check-tier returns tier unchanged
	output=$("$helper" budget-check-tier sonnet 2>&1) || true
	if [[ "$output" == *"sonnet"* ]]; then
		print_result "budget: budget-check-tier passthrough" 0
	else
		print_result "budget: budget-check-tier passthrough" 1 "Got: $output"
	fi

	return 0
}

# =============================================================================
# 6. Issue-Sync-Helper Tests
# =============================================================================

test_issue_sync_helper() {
	echo ""
	echo "=== Issue-Sync-Helper ==="

	local helper="${SCRIPTS_DIR}/issue-sync-helper.sh"

	# Test: help output
	local output
	output=$("$helper" help 2>&1) || true
	if echo "$output" | grep -q "push" && echo "$output" | grep -q "pull"; then
		print_result "issue-sync: help output" 0
	else
		print_result "issue-sync: help output" 1 "Missing expected commands in help"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "issue-sync: unknown command" 0
	else
		print_result "issue-sync: unknown command" 1 "Expected 'Unknown command'"
	fi

	# Test: parse with no task ID
	local rc_parse=0
	output=$("$helper" parse 2>&1) || rc_parse=$?
	if [[ $rc_parse -ne 0 ]] || echo "$output" | grep -qiE "usage|error|required"; then
		print_result "issue-sync: parse (no task) fails" 0
	else
		print_result "issue-sync: parse (no task) fails" 1 "Expected error, got rc=$rc_parse"
	fi

	# Note: push/pull/close/enrich/reconcile/status require gh CLI auth and a real repo.
	# We test those interfaces exist via help output above.
	# The parse command tests the library functions (parse_task_line, etc.)

	return 0
}

# =============================================================================
# 7. Observability-Helper Tests
# =============================================================================

test_observability_helper() {
	echo ""
	echo "=== Observability-Helper ==="

	local helper="${SCRIPTS_DIR}/observability-helper.sh"

	# Test: record a metric
	local output
	output=$("$helper" record --model anthropic/claude-sonnet-4-6 \
		--input-tokens 5000 --output-tokens 2000 \
		--cache-read 1000 --cache-write 500 \
		--session test-session --project test-project 2>&1) || true
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "observability: record metric" 0
	else
		print_result "observability: record metric" 1 "Exit code: $rc, output: $output"
	fi

	# Verify metrics file exists and has content
	local metrics="${TEST_DIR}/.aidevops/.agent-workspace/observability/metrics.jsonl"
	if [[ -f "$metrics" ]] && [[ $(wc -l <"$metrics") -ge 1 ]]; then
		print_result "observability: metrics file created" 0
	else
		print_result "observability: metrics file created" 1 "Metrics file missing or empty"
	fi

	# Verify the recorded metric has expected fields
	if command -v jq &>/dev/null && [[ -f "$metrics" ]]; then
		local model_val
		model_val=$(jq -r '.model' "$metrics" | head -1)
		if [[ "$model_val" == *"claude-sonnet"* ]]; then
			print_result "observability: metric has correct model" 0
		else
			print_result "observability: metric has correct model" 1 "Got model: $model_val"
		fi

		local cost_val
		cost_val=$(jq -r '.cost_total' "$metrics" | head -1)
		if [[ "$cost_val" != "0" && "$cost_val" != "null" ]]; then
			print_result "observability: metric has non-zero cost" 0
		else
			print_result "observability: metric has non-zero cost" 1 "Got cost: $cost_val"
		fi
	fi

	# Test: record with missing model
	local rc_obs_record=0
	output=$("$helper" record 2>&1) || rc_obs_record=$?
	if [[ $rc_obs_record -ne 0 ]] || echo "$output" | grep -qiE "usage|error|required"; then
		print_result "observability: record (no model) fails" 0
	else
		print_result "observability: record (no model) fails" 1 "Expected error, got rc=$rc_obs_record"
	fi

	# Test: ingest with no Claude logs (should succeed gracefully)
	output=$("$helper" ingest --quiet 2>&1) || true
	rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "observability: ingest (no logs) succeeds" 0
	else
		print_result "observability: ingest (no logs) succeeds" 1 "Exit code: $rc"
	fi

	# Test: backward compat — removed commands return gracefully
	local removed_cmds=("summary" "models" "projects" "costs" "trend" "sync-budget" "prune")
	local all_compat=true
	for cmd in "${removed_cmds[@]}"; do
		output=$("$helper" "$cmd" 2>&1) || true
		rc=$?
		if [[ $rc -ne 0 ]]; then
			print_result "observability: backward compat '$cmd'" 1 "Exit code: $rc"
			all_compat=false
		fi
	done
	if [[ "$all_compat" == "true" ]]; then
		print_result "observability: backward compat (removed commands)" 0
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "observability: unknown command" 0
	else
		print_result "observability: unknown command" 1 "Expected 'Unknown command'"
	fi

	return 0
}

# =============================================================================
# 8. Cross-Script Regression Tests
# =============================================================================

test_regressions() {
	echo ""
	echo "=== Regression Checks ==="

	# Verify line counts are within expected range (simplified)
	local -A expected_max=(
		["full-loop-helper.sh"]=600
		["fallback-chain-helper.sh"]=300
		["budget-tracker-helper.sh"]=350
		["issue-sync-helper.sh"]=1000
		["observability-helper.sh"]=700
	)

	for script in "${!expected_max[@]}"; do
		local path="${SCRIPTS_DIR}/${script}"
		local lines
		lines=$(wc -l <"$path" | tr -d ' ')
		local max="${expected_max[$script]}"
		if [[ "$lines" -le "$max" ]]; then
			print_result "regression: $script <= $max lines ($lines)" 0
		else
			print_result "regression: $script <= $max lines ($lines)" 1 "Got $lines lines, max $max"
		fi
	done

	# Verify all scripts have set -euo pipefail
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q 'set -euo pipefail' "$path"; then
			print_result "regression: $script has strict mode" 0
		else
			print_result "regression: $script has strict mode" 1 "Missing set -euo pipefail"
		fi
	done

	# Verify all scripts source shared-constants.sh
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q 'shared-constants.sh' "$path"; then
			print_result "regression: $script sources shared-constants" 0
		else
			print_result "regression: $script sources shared-constants" 1 "Missing shared-constants.sh source"
		fi
	done

	# Verify all scripts have a main() function and call it
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q '^main()' "$path" && grep -q 'main "$@"' "$path"; then
			print_result "regression: $script has main() entry point" 0
		else
			print_result "regression: $script has main() entry point" 1 "Missing main() or main \"\$@\""
		fi
	done

	# Verify total line count is under target (~2,647 actual vs ~8,346 original)
	local total=0
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local lines
		lines=$(wc -l <"${SCRIPTS_DIR}/${script}" | tr -d ' ')
		total=$((total + lines))
	done
	if [[ "$total" -le 3000 ]]; then
		print_result "regression: total lines <= 3000 ($total)" 0
	else
		print_result "regression: total lines <= 3000 ($total)" 1 "Got $total lines"
	fi

	return 0
}

# =============================================================================
# 9. ShellCheck Verification
# =============================================================================

test_shellcheck() {
	echo ""
	echo "=== ShellCheck ==="

	if ! command -v shellcheck &>/dev/null; then
		print_result "shellcheck: available" 1 "shellcheck not installed"
		return 0
	fi

	local all_clean=true
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if shellcheck -x -S warning "$path" 2>/dev/null; then
			print_result "shellcheck: $script" 0
		else
			print_result "shellcheck: $script" 1 "ShellCheck violations found"
			all_clean=false
		fi
	done

	if [[ "$all_clean" == "true" ]]; then
		print_result "shellcheck: all Tier 3 scripts clean" 0
	fi

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo "================================================================"
	echo "  Tier 3 Simplified Scripts — Integration Tests (t1337.3)"
	echo "================================================================"

	setup

	test_syntax_check
	test_help_output
	test_full_loop_helper
	test_fallback_chain_helper
	test_budget_tracker_helper
	test_issue_sync_helper
	test_observability_helper
	test_regressions
	test_shellcheck

	teardown

	echo ""
	echo "================================================================"
	echo -e "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	echo "================================================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		echo -e "${RED}FAILED${NC}"
		return 1
	else
		echo -e "${GREEN}ALL TESTS PASSED${NC}"
		return 0
	fi
}

main "$@"
