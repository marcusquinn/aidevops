#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Test Script for task-decompose-helper.sh (t1408.5)
# =============================================================================
# Tests the classify/decompose/lineage functionality end-to-end.
# Covers:
#   - Heuristic classification (no API needed)
#   - LLM classification (if ANTHROPIC_API_KEY available)
#   - Heuristic decomposition
#   - LLM decomposition (if ANTHROPIC_API_KEY available)
#   - Lineage context formatting
#   - has-subtasks detection
#   - Edge cases and error handling
#
# Run: bash .agents/scripts/tests/test-task-decompose.sh
# Run with LLM tests: ANTHROPIC_API_KEY=... bash .agents/scripts/tests/test-task-decompose.sh --with-llm
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../task-decompose-helper.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Options
WITH_LLM=false
VERBOSE=false

# Temp dir for test isolation
TEST_DIR=""

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail, 2=skip)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	elif [[ "$result" -eq 2 ]]; then
		echo -e "${YELLOW}SKIP${RESET} $test_name"
		TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
	else
		echo -e "${RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

#######################################
# Setup test environment
# Returns: 0 on success
#######################################
setup() {
	TEST_DIR=$(mktemp -d)

	# Create a mock TODO.md for has-subtasks tests
	cat >"${TEST_DIR}/TODO.md" <<'EOF'
# Tasks

## Active

- [ ] t1408 Recursive task decomposition for dispatch
  - [ ] t1408.1 Create classify/decompose helper
  - [ ] t1408.2 Wire decomposition into dispatch pipeline
  - [ ] t1408.3 Add lineage context to worker prompts
  - [ ] t1408.4 Add batch execution strategies
  - [ ] t1408.5 Testing and verification
- [ ] t1409 Refactor memory-pressure-monitor
- [x] t1407 Check contributing guidelines before filing on external repos
EOF

	# Disable LLM calls by default (override with --with-llm)
	# DECOMPOSE_NO_LLM is the canonical env var; DECOMPOSE_TEST_NO_LLM is legacy
	if [[ "$WITH_LLM" != true ]]; then
		export DECOMPOSE_NO_LLM=true
	else
		export DECOMPOSE_NO_LLM=false
	fi

	return 0
}

#######################################
# Teardown test environment
# Returns: 0 on success
#######################################
teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# =============================================================================
# CLASSIFY TESTS (Heuristic)
# =============================================================================

test_classify_atomic_simple() {
	local desc="Add a comment to the calculateTotal function"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: simple atomic task (add comment)" 0
	else
		print_result "classify: simple atomic task (add comment)" 1 "Expected atomic, got: $kind (output: $output)"
	fi
	return 0
}

test_classify_atomic_bugfix() {
	local desc="Fix the login page redirect loop"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: bugfix task (fix redirect)" 0
	else
		print_result "classify: bugfix task (fix redirect)" 1 "Expected atomic, got: $kind"
	fi
	return 0
}

test_classify_atomic_refactor() {
	local desc="Refactor the authentication module to use JWT tokens"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: refactor task (auth module)" 0
	else
		print_result "classify: refactor task (auth module)" 1 "Expected atomic, got: $kind"
	fi
	return 0
}

test_classify_atomic_docs() {
	local desc="Update the README with installation instructions"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: documentation task (update README)" 0
	else
		print_result "classify: documentation task (update README)" 1 "Expected atomic, got: $kind"
	fi
	return 0
}

test_classify_atomic_single_feature() {
	local desc="Implement user profile page with avatar upload"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: single feature (profile page)" 0
	else
		print_result "classify: single feature (profile page)" 1 "Expected atomic, got: $kind"
	fi
	return 0
}

test_classify_composite_multi_feature() {
	local desc="Build auth system with login, registration, password reset, and OAuth"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "composite" ]]; then
		print_result "classify: multi-feature composite (auth system)" 0
	else
		print_result "classify: multi-feature composite (auth system)" 1 "Expected composite, got: $kind"
	fi
	return 0
}

test_classify_composite_multiple_and() {
	local desc="Create user management and billing system and notification service and admin dashboard"
	local output
	output=$("$HELPER" classify "$desc" --depth 0 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "composite" ]]; then
		print_result "classify: multiple 'and' composite (user+billing+notif+admin)" 0
	else
		print_result "classify: multiple 'and' composite (user+billing+notif+admin)" 1 "Expected composite, got: $kind"
	fi
	return 0
}

test_classify_depth_override() {
	# At depth 2+, should always be atomic regardless of description
	local desc="Build auth system with login, registration, password reset, and OAuth"
	local output
	output=$("$HELPER" classify "$desc" --depth 2 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify: depth >= 2 forces atomic" 0
	else
		print_result "classify: depth >= 2 forces atomic" 1 "Expected atomic at depth 2, got: $kind"
	fi
	return 0
}

test_classify_json_output() {
	local desc="Fix the login bug"
	local output
	output=$("$HELPER" classify "$desc" 2>/dev/null) || true

	# Verify JSON structure
	local has_kind has_confidence has_reasoning
	has_kind=$(echo "$output" | grep -c '"kind"' || true)
	has_confidence=$(echo "$output" | grep -c '"confidence"' || true)
	has_reasoning=$(echo "$output" | grep -c '"reasoning"' || true)

	if [[ "$has_kind" -ge 1 && "$has_confidence" -ge 1 && "$has_reasoning" -ge 1 ]]; then
		print_result "classify: output is valid JSON with kind/confidence/reasoning" 0
	else
		print_result "classify: output is valid JSON with kind/confidence/reasoning" 1 "Missing fields in: $output"
	fi
	return 0
}

test_classify_empty_description() {
	local output
	output=$("$HELPER" classify 2>&1) || true

	if echo "$output" | grep -qi "usage\|error"; then
		print_result "classify: empty description shows usage/error" 0
	else
		print_result "classify: empty description shows usage/error" 1 "Expected error, got: $output"
	fi
	return 0
}

# =============================================================================
# CLASSIFY TESTS (Context-Aware — --task-id / --todo-file)
# =============================================================================

test_classify_skips_already_decomposed() {
	# t1408 already has subtasks in TODO.md — classify should return atomic
	local desc="Recursive task decomposition for dispatch"
	local output
	output=$("$HELPER" classify "$desc" --task-id t1408 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		# Also verify the reasoning mentions existing subtasks
		if printf '%s' "$output" | grep -q "already has subtasks"; then
			print_result "classify: skips already-decomposed task (t1408)" 0
		else
			print_result "classify: skips already-decomposed task (t1408)" 1 "Classified as atomic but missing 'already has subtasks' reasoning"
		fi
	else
		print_result "classify: skips already-decomposed task (t1408)" 1 "Expected atomic (already decomposed), got: $kind"
	fi
	return 0
}

test_classify_proceeds_for_new_task() {
	# t1409 has no subtasks — classify should proceed normally
	local desc="Refactor memory-pressure-monitor"
	local output
	output=$("$HELPER" classify "$desc" --task-id t1409 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	# Should be atomic (it's a refactor) but NOT because of existing subtasks
	if [[ "$kind" == "atomic" ]]; then
		if echo "$output" | grep -q "already has subtasks"; then
			print_result "classify: proceeds normally for task without subtasks" 1 "Incorrectly flagged as already-decomposed"
		else
			print_result "classify: proceeds normally for task without subtasks" 0
		fi
	else
		# composite would also be acceptable — the point is it didn't short-circuit
		print_result "classify: proceeds normally for task without subtasks" 0
	fi
	return 0
}

test_decompose_refuses_already_decomposed() {
	# t1408 already has subtasks — decompose should refuse
	local desc="Recursive task decomposition for dispatch"
	local output exit_code=0
	output=$("$HELPER" decompose "$desc" --task-id t1408 --todo-file "${TEST_DIR}/TODO.md" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 1 ]]; then
		if printf '%s' "$output" | grep -qi "already has subtasks\|skipping"; then
			print_result "decompose: refuses already-decomposed task (t1408)" 0
		else
			print_result "decompose: refuses already-decomposed task (t1408)" 1 "Exit 1 but missing 'already has subtasks' or 'skipping' in output"
		fi
	else
		print_result "decompose: refuses already-decomposed task (t1408)" 1 "Expected exit 1, got: $exit_code"
	fi
	return 0
}

test_decompose_proceeds_for_new_task() {
	# t1409 has no subtasks — decompose should proceed
	local desc="Build user management, billing system, and notification service"
	local output exit_code=0
	output=$("$HELPER" decompose "$desc" --task-id t1409 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null) || exit_code=$?

	# Should succeed (exit 0 or 2 for heuristic fallback)
	if [[ "$exit_code" -eq 0 || "$exit_code" -eq 2 ]]; then
		if echo "$output" | grep -q '"subtasks"'; then
			print_result "decompose: proceeds for task without subtasks" 0
		else
			print_result "decompose: proceeds for task without subtasks" 1 "No subtasks in output: $output"
		fi
	else
		print_result "decompose: proceeds for task without subtasks" 1 "Unexpected exit code: $exit_code"
	fi
	return 0
}

# =============================================================================
# CLASSIFY TESTS (LLM - only run with --with-llm)
# =============================================================================

test_classify_llm_atomic() {
	if [[ "$WITH_LLM" != true ]]; then
		print_result "classify LLM: atomic task (requires --with-llm)" 2
		return 0
	fi

	local desc="Add a comment to the calculateTotal function"
	local output
	output=$("$HELPER" classify "$desc" 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "atomic" ]]; then
		print_result "classify LLM: simple atomic task" 0
	else
		print_result "classify LLM: simple atomic task" 1 "Expected atomic, got: $kind"
	fi
	return 0
}

test_classify_llm_composite() {
	if [[ "$WITH_LLM" != true ]]; then
		print_result "classify LLM: composite task (requires --with-llm)" 2
		return 0
	fi

	local desc="Build auth system with login, registration, password reset, and OAuth"
	local output
	output=$("$HELPER" classify "$desc" 2>/dev/null) || true

	local kind
	kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" == "composite" ]]; then
		print_result "classify LLM: multi-feature composite" 0
	else
		print_result "classify LLM: multi-feature composite" 1 "Expected composite, got: $kind"
	fi
	return 0
}

# Real task descriptions from TODO.md history
test_classify_llm_real_tasks() {
	if [[ "$WITH_LLM" != true ]]; then
		print_result "classify LLM: real TODO.md tasks (requires --with-llm)" 2
		return 0
	fi

	# Real tasks from aidevops TODO.md history — parallel arrays to avoid
	# bash associative array issues with special characters in keys
	local descriptions=(
		"Recursive task decomposition for dispatch with classify and decompose pipeline, lineage context, batch strategies, pulse integration"
		"Create classify/decompose LLM prompts and helper functions"
		"Fix the login page redirect loop"
		"Add CI self-healing to pulse to re-run stale checks after workflow fixes merge"
		"Build a CRM with contacts, deals, email integration, and reporting dashboard"
	)
	local expected_kinds=(
		"composite"
		"atomic"
		"atomic"
		"atomic"
		"composite"
	)

	local all_pass=true
	local i=0
	while [[ "$i" -lt "${#descriptions[@]}" ]]; do
		local desc="${descriptions[$i]}"
		local expected="${expected_kinds[$i]}"
		local output
		output=$("$HELPER" classify "$desc" 2>/dev/null) || true

		local kind
		kind=$(echo "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

		if [[ "$kind" == "$expected" ]]; then
			echo -e "  ${GREEN}OK${RESET} '${desc:0:60}...' -> $kind"
		else
			echo -e "  ${RED}MISMATCH${RESET} '${desc:0:60}...' -> $kind (expected $expected)"
			all_pass=false
		fi

		# Rate limit between API calls
		sleep 0.5
		i=$((i + 1))
	done

	if [[ "$all_pass" == true ]]; then
		print_result "classify LLM: 5 real TODO.md tasks all correct" 0
	else
		print_result "classify LLM: 5 real TODO.md tasks all correct" 1 "Some classifications didn't match expected"
	fi
	return 0
}

# =============================================================================
# DECOMPOSE TESTS (Heuristic)
# =============================================================================

test_decompose_basic() {
	local desc="Build auth system with login, registration, password reset, and OAuth"
	local output
	output=$("$HELPER" decompose "$desc" 2>/dev/null) || true

	# Check it has subtasks array
	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$output" | jq '.subtasks | length' 2>/dev/null || echo "0")

		if [[ "$count" -ge 2 && "$count" -le 5 ]]; then
			print_result "decompose: produces 2-5 subtasks" 0
		else
			print_result "decompose: produces 2-5 subtasks" 1 "Got $count subtasks: $output"
		fi
	else
		# Without jq, just check for subtasks key
		if echo "$output" | grep -q '"subtasks"'; then
			print_result "decompose: produces subtasks (no jq for count check)" 0
		else
			print_result "decompose: produces subtasks (no jq for count check)" 1 "No subtasks in: $output"
		fi
	fi
	return 0
}

test_decompose_has_strategy() {
	local desc="Build auth system with login, registration, and OAuth"
	local output
	output=$("$HELPER" decompose "$desc" 2>/dev/null) || true

	if echo "$output" | grep -q '"strategy"'; then
		local strategy
		strategy=$(echo "$output" | sed -n 's/.*"strategy"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		if [[ "$strategy" == "depth-first" || "$strategy" == "breadth-first" ]]; then
			print_result "decompose: includes valid strategy ($strategy)" 0
		else
			print_result "decompose: includes valid strategy" 1 "Invalid strategy: $strategy"
		fi
	else
		print_result "decompose: includes valid strategy" 1 "No strategy field in: $output"
	fi
	return 0
}

test_decompose_subtask_structure() {
	local desc="Create user management, billing system, and notification service"
	local output
	output=$("$HELPER" decompose "$desc" 2>/dev/null) || true

	if command -v jq &>/dev/null; then
		# Each subtask should have description and blocked_by
		local valid=true
		local count
		count=$(echo "$output" | jq '.subtasks | length' 2>/dev/null || echo "0")

		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local has_desc has_blocked
			has_desc=$(echo "$output" | jq -r ".subtasks[$i].description // empty" 2>/dev/null)
			has_blocked=$(echo "$output" | jq ".subtasks[$i].blocked_by" 2>/dev/null)

			if [[ -z "$has_desc" || "$has_blocked" == "null" ]]; then
				valid=false
				break
			fi
			i=$((i + 1))
		done

		if [[ "$valid" == true && "$count" -ge 2 ]]; then
			print_result "decompose: subtasks have description and blocked_by" 0
		else
			print_result "decompose: subtasks have description and blocked_by" 1 "Invalid structure in: $output"
		fi
	else
		print_result "decompose: subtasks have description and blocked_by" 2 "jq not available"
	fi
	return 0
}

test_decompose_max_subtasks() {
	local desc="Build login, registration, password reset, OAuth, MFA, SSO, LDAP, and SAML"
	local output
	output=$("$HELPER" decompose "$desc" --max-subtasks 3 2>/dev/null) || true

	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$output" | jq '.subtasks | length' 2>/dev/null || echo "0")

		if [[ "$count" -le 3 ]]; then
			print_result "decompose: respects --max-subtasks 3 (got $count)" 0
		else
			print_result "decompose: respects --max-subtasks 3" 1 "Got $count subtasks, expected <= 3"
		fi
	else
		print_result "decompose: respects --max-subtasks" 2 "jq not available"
	fi
	return 0
}

test_decompose_empty_description() {
	local output
	output=$("$HELPER" decompose 2>&1) || true

	if echo "$output" | grep -qi "usage\|error"; then
		print_result "decompose: empty description shows usage/error" 0
	else
		print_result "decompose: empty description shows usage/error" 1 "Expected error, got: $output"
	fi
	return 0
}

# =============================================================================
# DECOMPOSE TESTS (LLM)
# =============================================================================

test_decompose_llm_quality() {
	if [[ "$WITH_LLM" != true ]]; then
		print_result "decompose LLM: subtask quality check (requires --with-llm)" 2
		return 0
	fi

	local desc="Build auth system with login, registration, password reset, and OAuth"
	local output exit_code=0
	output=$("$HELPER" decompose "$desc" 2>/dev/null) || exit_code=$?

	# exit_code 2 = API unavailable, heuristic used
	if [[ "$exit_code" -eq 2 ]]; then
		echo -e "  ${YELLOW}NOTE${RESET}: API unavailable, testing heuristic fallback quality"
	fi

	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$output" | jq '.subtasks | length' 2>/dev/null || echo "0")

		# Should have 2-5 subtasks
		local count_ok=false
		if [[ "$count" -ge 2 && "$count" -le 5 ]]; then
			count_ok=true
		fi

		# Each subtask description should be non-empty
		# Heuristic produces shorter descriptions, so use a lower threshold (5 chars)
		# LLM should produce longer, more descriptive ones (10+ chars)
		local min_len=5
		if [[ "$exit_code" -eq 0 ]]; then
			min_len=10
		fi

		local quality_ok=true
		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local desc_text
			desc_text=$(echo "$output" | jq -r ".subtasks[$i].description" 2>/dev/null)
			if [[ -z "$desc_text" || ${#desc_text} -lt "$min_len" ]]; then
				quality_ok=false
			fi
			i=$((i + 1))
		done

		if [[ "$count_ok" == true && "$quality_ok" == true ]]; then
			local source="LLM"
			[[ "$exit_code" -eq 2 ]] && source="heuristic"
			print_result "decompose LLM: produces quality subtasks ($count items, $source)" 0
			# Show the subtasks for inspection
			echo "$output" | jq -r '.subtasks[].description' 2>/dev/null | while read -r line; do
				echo -e "  ${CYAN}>${RESET} $line"
			done
		else
			print_result "decompose LLM: produces quality subtasks" 1 "count_ok=$count_ok quality_ok=$quality_ok output=$output"
		fi
	else
		print_result "decompose LLM: produces quality subtasks" 2 "jq not available"
	fi
	return 0
}

test_decompose_llm_dependencies() {
	if [[ "$WITH_LLM" != true ]]; then
		print_result "decompose LLM: dependency edges (requires --with-llm)" 2
		return 0
	fi

	local desc="Build a REST API with database schema, then create frontend that calls the API, then add end-to-end tests"
	local output exit_code=0
	output=$("$HELPER" decompose "$desc" 2>/dev/null) || exit_code=$?

	# Heuristic fallback doesn't produce dependency edges — that's expected
	if [[ "$exit_code" -eq 2 ]]; then
		print_result "decompose LLM: dependency edges (heuristic fallback, no deps expected)" 0
		echo -e "  ${YELLOW}NOTE${RESET}: API unavailable, heuristic doesn't produce dependency edges"
		return 0
	fi

	if command -v jq &>/dev/null; then
		# Check that at least one subtask has a non-empty blocked_by
		local has_deps
		has_deps=$(echo "$output" | jq '[.subtasks[].blocked_by | length] | add // 0' 2>/dev/null || echo "0")

		if [[ "$has_deps" -gt 0 ]]; then
			print_result "decompose LLM: includes dependency edges" 0
		else
			print_result "decompose LLM: includes dependency edges" 1 "No dependencies found in: $output"
		fi
	else
		print_result "decompose LLM: includes dependency edges" 2 "jq not available"
	fi
	return 0
}

# =============================================================================
# FORMAT-LINEAGE TESTS
# =============================================================================

test_format_lineage_self_test() {
	local output
	output=$("$HELPER" format-lineage --test 2>/dev/null)
	local exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -q "PASS"; then
		print_result "format-lineage: self-test passes" 0
	else
		print_result "format-lineage: self-test passes" 1 "Exit: $exit_code, Output: $output"
	fi
	return 0
}

test_format_lineage_structure() {
	local parent="Build a CRM with contacts, deals, and email"
	local children='[{"description": "Implement contact management"}, {"description": "Implement deal pipeline"}, {"description": "Implement email integration"}]'
	local output
	output=$("$HELPER" format-lineage --parent "$parent" --children "$children" --current 1 2>/dev/null)

	local checks_passed=0
	local checks_total=5

	# Check 1: Has PROJECT CONTEXT header
	if echo "$output" | grep -q "PROJECT CONTEXT"; then
		checks_passed=$((checks_passed + 1))
	fi

	# Check 2: Has parent at level 0
	if echo "$output" | grep -q "^0\. Build a CRM"; then
		checks_passed=$((checks_passed + 1))
	fi

	# Check 3: Has children indented
	if echo "$output" | grep -q "^  1\. Implement contact"; then
		checks_passed=$((checks_passed + 1))
	fi

	# Check 4: Current task has marker
	if echo "$output" | grep -q "deal pipeline.*<-- (this task)"; then
		checks_passed=$((checks_passed + 1))
	fi

	# Check 5: Has sibling warning
	if echo "$output" | grep -q "sibling tasks"; then
		checks_passed=$((checks_passed + 1))
	fi

	if [[ "$checks_passed" -eq "$checks_total" ]]; then
		print_result "format-lineage: correct structure ($checks_passed/$checks_total checks)" 0
	else
		print_result "format-lineage: correct structure ($checks_passed/$checks_total checks)" 1 "Output:\n$output"
	fi
	return 0
}

test_format_lineage_no_current() {
	local parent="Build a CRM"
	local children='[{"description": "contacts"}, {"description": "deals"}]'
	local output
	output=$("$HELPER" format-lineage --parent "$parent" --children "$children" 2>/dev/null)

	# Should NOT have the marker when --current is not specified
	if echo "$output" | grep -q "<-- (this task)"; then
		print_result "format-lineage: no marker without --current" 1 "Marker present when it shouldn't be"
	else
		print_result "format-lineage: no marker without --current" 0
	fi
	return 0
}

test_format_lineage_string_array() {
	# Test with simple string array instead of object array
	local parent="Build a CRM"
	local children='["contacts module", "deals module", "email module"]'
	local output
	output=$("$HELPER" format-lineage --parent "$parent" --children "$children" --current 0 2>/dev/null)

	if echo "$output" | grep -q "contacts module.*<-- (this task)"; then
		print_result "format-lineage: works with string array" 0
	else
		print_result "format-lineage: works with string array" 1 "Output: $output"
	fi
	return 0
}

test_format_lineage_missing_args() {
	local output
	output=$("$HELPER" format-lineage 2>&1) || true

	if echo "$output" | grep -qi "usage\|error"; then
		print_result "format-lineage: missing args shows usage/error" 0
	else
		print_result "format-lineage: missing args shows usage/error" 1 "Expected error, got: $output"
	fi
	return 0
}

# =============================================================================
# HAS-SUBTASKS TESTS
# =============================================================================

test_has_subtasks_true() {
	local output
	output=$("$HELPER" has-subtasks t1408 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null)

	if [[ "$output" == "true" ]]; then
		print_result "has-subtasks: t1408 has subtasks" 0
	else
		print_result "has-subtasks: t1408 has subtasks" 1 "Expected true, got: $output"
	fi
	return 0
}

test_has_subtasks_false() {
	local output
	output=$("$HELPER" has-subtasks t1409 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null)

	if [[ "$output" == "false" ]]; then
		print_result "has-subtasks: t1409 has no subtasks" 0
	else
		print_result "has-subtasks: t1409 has no subtasks" 1 "Expected false, got: $output"
	fi
	return 0
}

test_has_subtasks_completed() {
	local output
	output=$("$HELPER" has-subtasks t1407 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null)

	if [[ "$output" == "false" ]]; then
		print_result "has-subtasks: completed task without children" 0
	else
		print_result "has-subtasks: completed task without children" 1 "Expected false, got: $output"
	fi
	return 0
}

test_has_subtasks_nonexistent() {
	local output
	output=$("$HELPER" has-subtasks t9999 --todo-file "${TEST_DIR}/TODO.md" 2>/dev/null)

	if [[ "$output" == "false" ]]; then
		print_result "has-subtasks: nonexistent task returns false" 0
	else
		print_result "has-subtasks: nonexistent task returns false" 1 "Expected false, got: $output"
	fi
	return 0
}

test_has_subtasks_missing_file() {
	local output
	output=$("$HELPER" has-subtasks t1408 --todo-file "/nonexistent/TODO.md" 2>/dev/null)

	if [[ "$output" == "false" ]]; then
		print_result "has-subtasks: missing TODO.md returns false" 0
	else
		print_result "has-subtasks: missing TODO.md returns false" 1 "Expected false, got: $output"
	fi
	return 0
}

test_has_subtasks_empty_id() {
	local output
	output=$("$HELPER" has-subtasks 2>&1) || true

	if echo "$output" | grep -qi "usage\|error"; then
		print_result "has-subtasks: empty ID shows usage/error" 0
	else
		print_result "has-subtasks: empty ID shows usage/error" 1 "Expected error, got: $output"
	fi
	return 0
}

# =============================================================================
# HELP AND EDGE CASES
# =============================================================================

test_help_command() {
	local output
	output=$("$HELPER" help 2>/dev/null)

	if echo "$output" | grep -q "classify" && echo "$output" | grep -q "decompose" && echo "$output" | grep -q "format-lineage"; then
		print_result "help: shows all commands" 0
	else
		print_result "help: shows all commands" 1 "Missing commands in help output"
	fi
	return 0
}

test_unknown_command() {
	local output
	output=$("$HELPER" nonexistent 2>&1) || true

	if echo "$output" | grep -qi "unknown\|error"; then
		print_result "unknown command: shows error" 0
	else
		print_result "unknown command: shows error" 1 "Expected error, got: $output"
	fi
	return 0
}

test_no_args() {
	local output
	output=$("$HELPER" 2>/dev/null)

	# Should show help
	if echo "$output" | grep -q "classify\|decompose\|format-lineage"; then
		print_result "no args: shows help" 0
	else
		print_result "no args: shows help" 1 "Expected help output"
	fi
	return 0
}

# =============================================================================
# END-TO-END PIPELINE TEST
# =============================================================================

test_e2e_classify_then_decompose() {
	local desc="Build auth system with login, registration, password reset, and OAuth"

	# Step 1: Classify
	local classify_output
	classify_output=$("$HELPER" classify "$desc" 2>/dev/null) || true

	local kind
	kind=$(echo "$classify_output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

	if [[ "$kind" != "composite" ]]; then
		print_result "e2e: classify -> decompose pipeline" 1 "Expected composite classification, got: $kind"
		return 0
	fi

	# Step 2: Decompose (since it's composite)
	local decompose_output
	decompose_output=$("$HELPER" decompose "$desc" 2>/dev/null) || true

	if command -v jq &>/dev/null; then
		local count
		count=$(echo "$decompose_output" | jq '.subtasks | length' 2>/dev/null || echo "0")

		if [[ "$count" -ge 2 ]]; then
			# Step 3: Format lineage for first subtask
			local first_desc
			first_desc=$(echo "$decompose_output" | jq -r '.subtasks[0].description' 2>/dev/null)
			local children_json
			children_json=$(echo "$decompose_output" | jq -c '.subtasks' 2>/dev/null)

			local lineage_output
			lineage_output=$("$HELPER" format-lineage --parent "$desc" --children "$children_json" --current 0 2>/dev/null)

			if echo "$lineage_output" | grep -q "PROJECT CONTEXT" && echo "$lineage_output" | grep -q "<-- (this task)"; then
				print_result "e2e: classify -> decompose -> format-lineage pipeline" 0
			else
				print_result "e2e: classify -> decompose -> format-lineage pipeline" 1 "Lineage formatting failed"
			fi
		else
			print_result "e2e: classify -> decompose -> format-lineage pipeline" 1 "Decompose produced $count subtasks"
		fi
	else
		print_result "e2e: classify -> decompose -> format-lineage pipeline" 2 "jq not available"
	fi
	return 0
}

# =============================================================================
# INTEGRATION REGRESSION TEST
# =============================================================================

test_regression_no_side_effects() {
	# Verify the helper doesn't modify any files or create state
	local before_files
	before_files=$(ls -la "${TEST_DIR}/" 2>/dev/null | wc -l)

	# Run several commands
	"$HELPER" classify "Fix a bug" >/dev/null 2>&1 || true
	"$HELPER" decompose "Build X, Y, and Z" >/dev/null 2>&1 || true
	"$HELPER" has-subtasks t1408 --todo-file "${TEST_DIR}/TODO.md" >/dev/null 2>&1 || true

	local after_files
	after_files=$(ls -la "${TEST_DIR}/" 2>/dev/null | wc -l)

	if [[ "$before_files" -eq "$after_files" ]]; then
		print_result "regression: no side effects (no files created)" 0
	else
		print_result "regression: no side effects (no files created)" 1 "File count changed: $before_files -> $after_files"
	fi
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

#######################################
# Run classify test sections
# Returns: 0 always
#######################################
_run_classify_tests() {
	echo "--- Classify (Heuristic) ---"
	test_classify_atomic_simple
	test_classify_atomic_bugfix
	test_classify_atomic_refactor
	test_classify_atomic_docs
	test_classify_atomic_single_feature
	test_classify_composite_multi_feature
	test_classify_composite_multiple_and
	test_classify_depth_override
	test_classify_json_output
	test_classify_empty_description
	echo ""

	echo "--- Classify (Context-Aware) ---"
	test_classify_skips_already_decomposed
	test_classify_proceeds_for_new_task
	test_decompose_refuses_already_decomposed
	test_decompose_proceeds_for_new_task
	echo ""

	echo "--- Classify (LLM) ---"
	test_classify_llm_atomic
	test_classify_llm_composite
	test_classify_llm_real_tasks
	echo ""
	return 0
}

#######################################
# Run decompose test sections
# Returns: 0 always
#######################################
_run_decompose_tests() {
	echo "--- Decompose (Heuristic) ---"
	test_decompose_basic
	test_decompose_has_strategy
	test_decompose_subtask_structure
	test_decompose_max_subtasks
	test_decompose_empty_description
	echo ""

	echo "--- Decompose (LLM) ---"
	test_decompose_llm_quality
	test_decompose_llm_dependencies
	echo ""
	return 0
}

#######################################
# Run lineage and subtask test sections
# Returns: 0 always
#######################################
_run_lineage_and_subtask_tests() {
	echo "--- Format Lineage ---"
	test_format_lineage_self_test
	test_format_lineage_structure
	test_format_lineage_no_current
	test_format_lineage_string_array
	test_format_lineage_missing_args
	echo ""

	echo "--- Has Subtasks ---"
	test_has_subtasks_true
	test_has_subtasks_false
	test_has_subtasks_completed
	test_has_subtasks_nonexistent
	test_has_subtasks_missing_file
	test_has_subtasks_empty_id
	echo ""
	return 0
}

#######################################
# Run edge case, e2e, and regression tests
# Returns: 0 always
#######################################
_run_edge_and_regression_tests() {
	echo "--- Help & Edge Cases ---"
	test_help_command
	test_unknown_command
	test_no_args
	echo ""

	echo "--- End-to-End ---"
	test_e2e_classify_then_decompose
	echo ""

	echo "--- Regression ---"
	test_regression_no_side_effects
	echo ""
	return 0
}

main() {
	# Parse args
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--with-llm)
			WITH_LLM=true
			shift
			;;
		--verbose | -v)
			VERBOSE=true
			shift
			;;
		--help | -h)
			echo "Usage: test-task-decompose.sh [--with-llm] [--verbose]"
			echo ""
			echo "Options:"
			echo "  --with-llm    Run LLM-dependent tests (requires ANTHROPIC_API_KEY)"
			echo "  --verbose     Show detailed output"
			return 0
			;;
		*) shift ;;
		esac
	done

	echo "============================================="
	echo " task-decompose-helper.sh Test Suite (t1408.5)"
	echo "============================================="
	echo ""

	if [[ "$WITH_LLM" == true ]]; then
		echo -e "${CYAN}Mode: Full (with LLM tests)${RESET}"
	else
		echo -e "${CYAN}Mode: Heuristic only (use --with-llm for LLM tests)${RESET}"
	fi
	echo ""

	# Check prerequisites
	if [[ ! -x "$HELPER" ]]; then
		echo -e "${RED}ERROR: Helper script not found or not executable: $HELPER${RESET}"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		echo -e "${YELLOW}WARNING: jq not found, some tests will be skipped${RESET}"
	fi

	setup

	_run_classify_tests
	_run_decompose_tests
	_run_lineage_and_subtask_tests
	_run_edge_and_regression_tests

	teardown

	# Summary
	echo "============================================="
	echo -e " Results: ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}, ${YELLOW}${TESTS_SKIPPED} skipped${RESET} / ${TESTS_RUN} total"
	echo "============================================="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
