#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# SC2034: Variables set for sourced scripts (BLUE, SUPERVISOR_DB, etc.)
# SC1090: Non-constant source paths (test harness pattern)
#
# test-ai-actions.sh - Unit tests for AI supervisor action executor (t1085.3)
#
# Tests validation logic, field checking, and action type handling
# without requiring GitHub API access or a real supervisor DB.
#
# Usage: bash tests/test-ai-actions.sh
# Exit codes: 0 = all pass, 1 = failures

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIONS_SCRIPT="$REPO_DIR/.agents/scripts/supervisor/ai-actions.sh"

PASS=0
FAIL=0
TOTAL=0

pass() {
	PASS=$((PASS + 1))
	TOTAL=$((TOTAL + 1))
	echo "  PASS: $1"
}

fail() {
	FAIL=$((FAIL + 1))
	TOTAL=$((TOTAL + 1))
	echo "  FAIL: $1"
}

echo "=== AI Actions Executor Tests (t1085.3) ==="
echo ""

# ─── Test 1: Syntax check ───────────────────────────────────────────
echo "Test 1: Syntax check"
if bash -n "$ACTIONS_SCRIPT" 2>/dev/null; then
	pass "ai-actions.sh passes bash -n"
else
	fail "ai-actions.sh has syntax errors"
	bash -n "$ACTIONS_SCRIPT" 2>&1 | head -5
fi

# ─── Test 2: Source without errors ──────────────────────────────────
echo "Test 2: Source without errors"

# Create a minimal environment for sourcing
_test_source() {
	(
		# Prevent standalone CLI block from running
		BASH_SOURCE_OVERRIDE="sourced"

		# Provide required globals
		BLUE='\033[0;34m'
		GREEN='\033[0;32m'
		YELLOW='\033[1;33m'
		RED='\033[0;31m'
		NC='\033[0m'
		SUPERVISOR_DB="/tmp/test-ai-actions-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_REASON_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"

		# Stub required functions
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test context"; }
		run_ai_reasoning() { echo '[]'; }

		export -f db log_info log_success log_warn log_error log_verbose sql_escape
		export -f detect_repo_slug commit_and_push_todo find_task_issue_number
		export -f build_ai_context run_ai_reasoning

		# Source the module (not as main script)
		source "$ACTIONS_SCRIPT"

		# Verify key functions exist
		declare -f validate_action_type &>/dev/null || exit 1
		declare -f validate_action_fields &>/dev/null || exit 1
		declare -f execute_action_plan &>/dev/null || exit 1
		declare -f execute_single_action &>/dev/null || exit 1
		declare -f run_ai_actions_pipeline &>/dev/null || exit 1

		# Clean up
		rm -rf "/tmp/test-ai-actions-logs-$$"
		rm -f "$SUPERVISOR_DB"
	)
}

if _test_source 2>/dev/null; then
	pass "ai-actions.sh sources without errors and exports key functions"
else
	fail "ai-actions.sh failed to source or missing key functions"
fi

# ─── Test 3: validate_action_type ───────────────────────────────────
echo "Test 3: Action type validation"

_test_action_types() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local failures=0

		# Valid types should pass
		for t in comment_on_issue create_task create_subtasks flag_for_review adjust_priority close_verified request_info; do
			if ! validate_action_type "$t"; then
				echo "FAIL: valid type '$t' rejected"
				failures=$((failures + 1))
			fi
		done

		# Invalid types should fail
		for t in delete_repo force_push unknown "" "drop_table"; do
			if validate_action_type "$t" 2>/dev/null; then
				echo "FAIL: invalid type '$t' accepted"
				failures=$((failures + 1))
			fi
		done

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit "$failures"
	)
}

if _test_action_types 2>/dev/null; then
	pass "all 7 valid types accepted, invalid types rejected"
else
	fail "action type validation has errors"
fi

# ─── Test 4: validate_action_fields ─────────────────────────────────
echo "Test 4: Field validation"

_test_field_validation() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local failures=0

		# comment_on_issue: valid
		local result
		result=$(validate_action_fields '{"type":"comment_on_issue","issue_number":123,"body":"test comment"}' "comment_on_issue")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid comment_on_issue rejected: $result"
			failures=$((failures + 1))
		fi

		# comment_on_issue: missing body
		result=$(validate_action_fields '{"type":"comment_on_issue","issue_number":123}' "comment_on_issue")
		if [[ -z "$result" ]]; then
			echo "FAIL: comment_on_issue without body accepted"
			failures=$((failures + 1))
		fi

		# comment_on_issue: missing issue_number
		result=$(validate_action_fields '{"type":"comment_on_issue","body":"test"}' "comment_on_issue")
		if [[ -z "$result" ]]; then
			echo "FAIL: comment_on_issue without issue_number accepted"
			failures=$((failures + 1))
		fi

		# comment_on_issue: non-numeric issue_number
		result=$(validate_action_fields '{"type":"comment_on_issue","issue_number":"abc","body":"test"}' "comment_on_issue")
		if [[ -z "$result" ]]; then
			echo "FAIL: comment_on_issue with non-numeric issue_number accepted"
			failures=$((failures + 1))
		fi

		# comment_on_issue: zero issue_number
		result=$(validate_action_fields '{"type":"comment_on_issue","issue_number":0,"body":"test"}' "comment_on_issue")
		if [[ -z "$result" ]]; then
			echo "FAIL: comment_on_issue with zero issue_number accepted"
			failures=$((failures + 1))
		fi

		# create_task: valid
		result=$(validate_action_fields '{"type":"create_task","title":"Test task"}' "create_task")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid create_task rejected: $result"
			failures=$((failures + 1))
		fi

		# create_task: missing title
		result=$(validate_action_fields '{"type":"create_task"}' "create_task")
		if [[ -z "$result" ]]; then
			echo "FAIL: create_task without title accepted"
			failures=$((failures + 1))
		fi

		# create_subtasks: valid
		result=$(validate_action_fields '{"type":"create_subtasks","parent_task_id":"t100","subtasks":[{"title":"sub1"}]}' "create_subtasks")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid create_subtasks rejected: $result"
			failures=$((failures + 1))
		fi

		# create_subtasks: empty subtasks array
		result=$(validate_action_fields '{"type":"create_subtasks","parent_task_id":"t100","subtasks":[]}' "create_subtasks")
		if [[ -z "$result" ]]; then
			echo "FAIL: create_subtasks with empty array accepted"
			failures=$((failures + 1))
		fi

		# create_subtasks: missing parent_task_id
		result=$(validate_action_fields '{"type":"create_subtasks","subtasks":[{"title":"sub1"}]}' "create_subtasks")
		if [[ -z "$result" ]]; then
			echo "FAIL: create_subtasks without parent_task_id accepted"
			failures=$((failures + 1))
		fi

		# flag_for_review: valid
		result=$(validate_action_fields '{"type":"flag_for_review","issue_number":42,"reason":"needs human judgment"}' "flag_for_review")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid flag_for_review rejected: $result"
			failures=$((failures + 1))
		fi

		# flag_for_review: missing reason
		result=$(validate_action_fields '{"type":"flag_for_review","issue_number":42}' "flag_for_review")
		if [[ -z "$result" ]]; then
			echo "FAIL: flag_for_review without reason accepted"
			failures=$((failures + 1))
		fi

		# adjust_priority: valid
		result=$(validate_action_fields '{"type":"adjust_priority","task_id":"t100","new_priority":"high"}' "adjust_priority")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid adjust_priority rejected: $result"
			failures=$((failures + 1))
		fi

		# adjust_priority: missing task_id
		result=$(validate_action_fields '{"type":"adjust_priority","new_priority":"high"}' "adjust_priority")
		if [[ -z "$result" ]]; then
			echo "FAIL: adjust_priority without task_id accepted"
			failures=$((failures + 1))
		fi

		# close_verified: valid
		result=$(validate_action_fields '{"type":"close_verified","issue_number":10,"pr_number":20}' "close_verified")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid close_verified rejected: $result"
			failures=$((failures + 1))
		fi

		# close_verified: missing pr_number (CRITICAL safety check)
		result=$(validate_action_fields '{"type":"close_verified","issue_number":10}' "close_verified")
		if [[ -z "$result" ]]; then
			echo "FAIL: close_verified without pr_number accepted (SAFETY VIOLATION)"
			failures=$((failures + 1))
		fi

		# close_verified: zero pr_number
		result=$(validate_action_fields '{"type":"close_verified","issue_number":10,"pr_number":0}' "close_verified")
		if [[ -z "$result" ]]; then
			echo "FAIL: close_verified with zero pr_number accepted"
			failures=$((failures + 1))
		fi

		# request_info: valid
		result=$(validate_action_fields '{"type":"request_info","issue_number":5,"questions":["What version?"]}' "request_info")
		if [[ -n "$result" ]]; then
			echo "FAIL: valid request_info rejected: $result"
			failures=$((failures + 1))
		fi

		# request_info: missing questions
		result=$(validate_action_fields '{"type":"request_info","issue_number":5}' "request_info")
		if [[ -z "$result" ]]; then
			echo "FAIL: request_info without questions accepted"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit "$failures"
	)
}

if _test_field_validation 2>/dev/null; then
	pass "all field validation checks passed (20 cases)"
else
	fail "field validation has errors"
fi

# ─── Test 5: execute_action_plan with empty plan ────────────────────
echo "Test 5: Empty action plan"

_test_empty_plan() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local result
		result=$(execute_action_plan '[]' "$REPO_DIR" "execute")
		local executed
		executed=$(printf '%s' "$result" | jq -r '.executed')
		if [[ "$executed" != "0" ]]; then
			echo "FAIL: empty plan should have 0 executed, got $executed"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_empty_plan 2>/dev/null; then
	pass "empty action plan returns 0 executed"
else
	fail "empty action plan handling broken"
fi

# ─── Test 6: execute_action_plan with invalid JSON ──────────────────
echo "Test 6: Invalid JSON input"

_test_invalid_json() {
	(
		set +e # Disable errexit — we expect failures here
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local result
		result=$(execute_action_plan 'not json at all' "$REPO_DIR" "execute" 2>/dev/null)
		local rc=$?
		# Should return non-zero for invalid JSON
		if [[ $rc -eq 0 ]]; then
			echo "FAIL: invalid JSON should return non-zero exit code"
			exit 1
		fi
		# Output should contain error
		local has_error
		has_error=$(printf '%s' "$result" | jq -r 'has("error")' 2>/dev/null || echo "false")
		if [[ "$has_error" != "true" ]]; then
			echo "FAIL: invalid JSON should return error JSON, got: $result"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_invalid_json 2>/dev/null; then
	pass "invalid JSON input returns error"
else
	fail "invalid JSON handling broken"
fi

# ─── Test 7: validate-only mode ────────────────────────────────────
echo "Test 7: Validate-only mode"

_test_validate_only() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local plan='[{"type":"comment_on_issue","issue_number":1,"body":"test","reasoning":"test"}]'
		local result
		result=$(execute_action_plan "$plan" "$REPO_DIR" "validate-only")
		local skipped
		skipped=$(printf '%s' "$result" | jq -r '.skipped')
		if [[ "$skipped" != "1" ]]; then
			echo "FAIL: validate-only should skip execution, got skipped=$skipped"
			exit 1
		fi
		local status
		status=$(printf '%s' "$result" | jq -r '.actions[0].status')
		if [[ "$status" != "validated" ]]; then
			echo "FAIL: validate-only should set status=validated, got $status"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_validate_only 2>/dev/null; then
	pass "validate-only mode validates without executing"
else
	fail "validate-only mode broken"
fi

# ─── Test 8: dry-run mode ──────────────────────────────────────────
echo "Test 8: Dry-run mode"

_test_dry_run() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local plan='[{"type":"create_task","title":"Test task","reasoning":"test"},{"type":"flag_for_review","issue_number":5,"reason":"test","reasoning":"test"}]'
		local result
		result=$(execute_action_plan "$plan" "$REPO_DIR" "dry-run")
		local executed
		executed=$(printf '%s' "$result" | jq -r '.executed')
		if [[ "$executed" != "2" ]]; then
			echo "FAIL: dry-run should count as executed, got $executed"
			exit 1
		fi
		local status
		status=$(printf '%s' "$result" | jq -r '.actions[0].status')
		if [[ "$status" != "dry_run" ]]; then
			echo "FAIL: dry-run should set status=dry_run, got $status"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_dry_run 2>/dev/null; then
	pass "dry-run mode simulates without executing"
else
	fail "dry-run mode broken"
fi

# ─── Test 9: Safety limit enforcement ──────────────────────────────
echo "Test 9: Safety limit (max actions per cycle)"

_test_safety_limit() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		AI_MAX_ACTIONS_PER_CYCLE=2
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		# Create a plan with 5 actions but limit is 2
		local plan='[
			{"type":"create_task","title":"Task 1","reasoning":"test"},
			{"type":"create_task","title":"Task 2","reasoning":"test"},
			{"type":"create_task","title":"Task 3","reasoning":"test"},
			{"type":"create_task","title":"Task 4","reasoning":"test"},
			{"type":"create_task","title":"Task 5","reasoning":"test"}
		]'
		local result
		result=$(execute_action_plan "$plan" "$REPO_DIR" "validate-only")
		local action_count
		action_count=$(printf '%s' "$result" | jq '.actions | length')
		if [[ "$action_count" != "2" ]]; then
			echo "FAIL: safety limit should cap at 2, got $action_count actions"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_safety_limit 2>/dev/null; then
	pass "safety limit caps actions at configured maximum"
else
	fail "safety limit enforcement broken"
fi

# ─── Test 10: Invalid action type skipped ───────────────────────────
echo "Test 10: Invalid action types are skipped"

_test_invalid_type_skipped() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		db() { sqlite3 -cmd ".timeout 5000" "$@" 2>/dev/null || true; }
		log_info() { :; }
		log_success() { :; }
		log_warn() { :; }
		log_error() { :; }
		log_verbose() { :; }
		sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
		detect_repo_slug() { echo "test/repo"; }
		commit_and_push_todo() { :; }
		find_task_issue_number() { echo ""; }
		build_ai_context() { echo "# test"; }
		run_ai_reasoning() { echo '[]'; }

		source "$ACTIONS_SCRIPT"

		local plan='[{"type":"delete_everything","reasoning":"evil"},{"type":"create_task","title":"Good task","reasoning":"valid"}]'
		local result
		result=$(execute_action_plan "$plan" "$REPO_DIR" "validate-only")
		local skipped
		skipped=$(printf '%s' "$result" | jq -r '.skipped')
		# Both should be skipped in validate-only: 1 for invalid type, 1 for validated
		local first_status
		first_status=$(printf '%s' "$result" | jq -r '.actions[0].status')
		if [[ "$first_status" != "skipped" ]]; then
			echo "FAIL: invalid type should be skipped, got $first_status"
			exit 1
		fi
		local first_reason
		first_reason=$(printf '%s' "$result" | jq -r '.actions[0].reason')
		if [[ "$first_reason" != "invalid_action_type" ]]; then
			echo "FAIL: skip reason should be invalid_action_type, got $first_reason"
			exit 1
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit 0
	)
}

if _test_invalid_type_skipped 2>/dev/null; then
	pass "invalid action types are skipped with correct reason"
else
	fail "invalid action type handling broken"
fi

# ─── Test 11: CLI help flag ────────────────────────────────────────
echo "Test 11: CLI --help flag"
_help_output=$(bash "$ACTIONS_SCRIPT" --help 2>/dev/null || true)
if printf '%s' "$_help_output" | grep -q "Usage:"; then
	pass "CLI --help shows usage"
else
	fail "CLI --help does not show usage (output: ${_help_output:0:80})"
fi

# ─── Test 12: Supervisor-helper.sh sources all modules ──────────────
echo "Test 12: supervisor-helper.sh sources ai-actions.sh"
if bash -u "$REPO_DIR/.agents/scripts/supervisor-helper.sh" help >/dev/null 2>&1; then
	pass "supervisor-helper.sh help runs with ai-actions.sh sourced"
else
	fail "supervisor-helper.sh help failed after ai-actions.sh addition"
	bash -u "$REPO_DIR/.agents/scripts/supervisor-helper.sh" help 2>&1 | head -5
fi

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
