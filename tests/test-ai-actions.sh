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

		# adjust_priority: missing new_priority is OK — executor infers from reasoning
		result=$(validate_action_fields '{"type":"adjust_priority","task_id":"t100"}' "adjust_priority")
		if [[ -n "$result" ]]; then
			echo "FAIL: adjust_priority without new_priority should be accepted (executor infers from reasoning): $result"
			failures=$((failures + 1))
		fi

		# adjust_priority: invalid new_priority value must be rejected (t1197)
		result=$(validate_action_fields '{"type":"adjust_priority","task_id":"t100","new_priority":"urgent"}' "adjust_priority")
		if [[ -z "$result" ]]; then
			echo "FAIL: adjust_priority with invalid new_priority value accepted (must be high|medium|low|critical)"
			failures=$((failures + 1))
		fi

		# adjust_priority: valid new_priority values
		for prio in high medium low critical; do
			result=$(validate_action_fields "{\"type\":\"adjust_priority\",\"task_id\":\"t100\",\"new_priority\":\"$prio\"}" "adjust_priority")
			if [[ -n "$result" ]]; then
				echo "FAIL: adjust_priority with new_priority='$prio' rejected: $result"
				failures=$((failures + 1))
			fi
		done

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

# ─── Test 13: _extract_action_target returns correct keys ───────────
echo "Test 13: Target extraction for dedup"

_test_target_extraction() {
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

		# Issue-based actions
		local target
		target=$(_extract_action_target '{"issue_number":1572}' "comment_on_issue")
		[[ "$target" == "issue:1572" ]] || {
			echo "FAIL: comment_on_issue target=$target"
			failures=$((failures + 1))
		}

		target=$(_extract_action_target '{"issue_number":42}' "flag_for_review")
		[[ "$target" == "issue:42" ]] || {
			echo "FAIL: flag_for_review target=$target"
			failures=$((failures + 1))
		}

		# Task-based actions
		target=$(_extract_action_target '{"task_id":"t1143"}' "adjust_priority")
		[[ "$target" == "task:t1143" ]] || {
			echo "FAIL: adjust_priority target=$target"
			failures=$((failures + 1))
		}

		# Title-based actions
		target=$(_extract_action_target '{"title":"Add retry logic"}' "create_task")
		[[ "$target" == "title:Add retry logic" ]] || {
			echo "FAIL: create_task target=$target"
			failures=$((failures + 1))
		}

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-$$.db"
		exit "$failures"
	)
}

if _test_target_extraction 2>/dev/null; then
	pass "target extraction returns correct keys for all action types"
else
	fail "target extraction has errors"
fi

# ─── Test 14: Cycle-aware dedup with state hash (t1179) ─────────────
echo "Test 14: Cycle-aware dedup — state hash comparison"

_test_cycle_aware_dedup() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-cycle-dedup-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		AI_ACTION_DEDUP_WINDOW=5
		AI_ACTION_CYCLE_AWARE_DEDUP="true"
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

		local failures=0

		# Create the dedup table
		sqlite3 "$SUPERVISOR_DB" "
			CREATE TABLE IF NOT EXISTS action_dedup_log (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				cycle_id TEXT NOT NULL,
				action_type TEXT NOT NULL,
				target TEXT NOT NULL,
				status TEXT NOT NULL DEFAULT 'executed',
				state_hash TEXT DEFAULT '',
				created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			);
		"

		# Record an action with state_hash "abc123"
		_record_action_dedup "cycle-001" "comment_on_issue" "issue:100" "executed" "abc123"

		# Same action, same state hash → should be duplicate (return 0)
		if ! _is_duplicate_action "comment_on_issue" "issue:100" "abc123"; then
			echo "FAIL: same state hash should be detected as duplicate"
			failures=$((failures + 1))
		fi

		# Same action, different state hash → should NOT be duplicate (return 1)
		if _is_duplicate_action "comment_on_issue" "issue:100" "def456"; then
			echo "FAIL: different state hash should allow action through"
			failures=$((failures + 1))
		fi

		# Different target → should NOT be duplicate
		if _is_duplicate_action "comment_on_issue" "issue:200" "abc123"; then
			echo "FAIL: different target should not be duplicate"
			failures=$((failures + 1))
		fi

		# Same action, "unknown" state hash → should fall back to basic dedup (duplicate)
		if ! _is_duplicate_action "comment_on_issue" "issue:100" "unknown"; then
			echo "FAIL: unknown state hash should fall back to basic dedup (suppress)"
			failures=$((failures + 1))
		fi

		# Same action, empty state hash → should fall back to basic dedup (duplicate)
		if ! _is_duplicate_action "comment_on_issue" "issue:100" ""; then
			echo "FAIL: empty state hash should fall back to basic dedup (suppress)"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_cycle_aware_dedup 2>/dev/null; then
	pass "cycle-aware dedup correctly compares state hashes"
else
	fail "cycle-aware dedup has errors"
fi

# ─── Test 15: Cycle-aware dedup disabled falls back to basic ────────
echo "Test 15: Cycle-aware dedup disabled — basic dedup only"

_test_cycle_aware_disabled() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-cycle-disabled-$$.db"
		SUPERVISOR_LOG="/dev/null"
		SCRIPT_DIR="$REPO_DIR/.agents/scripts"
		REPO_PATH="$REPO_DIR"
		AI_ACTIONS_LOG_DIR="/tmp/test-ai-actions-logs-$$"
		AI_ACTION_DEDUP_WINDOW=5
		AI_ACTION_CYCLE_AWARE_DEDUP="false"
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

		local failures=0

		# Create the dedup table
		sqlite3 "$SUPERVISOR_DB" "
			CREATE TABLE IF NOT EXISTS action_dedup_log (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				cycle_id TEXT NOT NULL,
				action_type TEXT NOT NULL,
				target TEXT NOT NULL,
				status TEXT NOT NULL DEFAULT 'executed',
				state_hash TEXT DEFAULT '',
				created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			);
		"

		# Record an action with state_hash "abc123"
		_record_action_dedup "cycle-001" "comment_on_issue" "issue:100" "executed" "abc123"

		# With cycle-aware disabled, different state hash should STILL be duplicate
		if ! _is_duplicate_action "comment_on_issue" "issue:100" "def456"; then
			echo "FAIL: with cycle-aware disabled, different state hash should still be duplicate"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_cycle_aware_disabled 2>/dev/null; then
	pass "cycle-aware dedup disabled correctly falls back to basic dedup"
else
	fail "cycle-aware dedup disabled mode has errors"
fi

# ─── Test 16: _compute_target_state_hash for task targets ───────────
echo "Test 16: State hash computation for task targets"

_test_state_hash_task() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-hash-$$.db"
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

		# Test with a task that exists in TODO.md (use a known task ID)
		# The hash should be non-empty and deterministic
		local hash1 hash2
		hash1=$(_compute_target_state_hash "task:t1179" "$REPO_DIR" "")
		hash2=$(_compute_target_state_hash "task:t1179" "$REPO_DIR" "")

		if [[ -z "$hash1" ]]; then
			echo "FAIL: state hash for existing task should not be empty"
			failures=$((failures + 1))
		fi

		if [[ "$hash1" != "$hash2" ]]; then
			echo "FAIL: state hash should be deterministic ($hash1 != $hash2)"
			failures=$((failures + 1))
		fi

		# Test with a non-existent task — should return "unknown"
		local hash_missing
		hash_missing=$(_compute_target_state_hash "task:t99999" "$REPO_DIR" "")
		if [[ "$hash_missing" != "unknown" ]]; then
			echo "FAIL: non-existent task should return 'unknown', got '$hash_missing'"
			failures=$((failures + 1))
		fi

		# Test title target — should check TODO.md for existence
		local hash_title
		hash_title=$(_compute_target_state_hash "title:Add cycle-aware dedup" "$REPO_DIR" "")
		if [[ -z "$hash_title" || "$hash_title" == "unknown" ]]; then
			echo "FAIL: title target should compute a hash, got '$hash_title'"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_state_hash_task 2>/dev/null; then
	pass "state hash computation works for task and title targets"
else
	fail "state hash computation has errors"
fi

# ─── Test 17: _record_action_dedup stores state_hash ────────────────
echo "Test 17: Dedup record stores state_hash"

_test_record_state_hash() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-record-hash-$$.db"
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

		# Create the dedup table with state_hash column
		sqlite3 "$SUPERVISOR_DB" "
			CREATE TABLE IF NOT EXISTS action_dedup_log (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				cycle_id TEXT NOT NULL,
				action_type TEXT NOT NULL,
				target TEXT NOT NULL,
				status TEXT NOT NULL DEFAULT 'executed',
				state_hash TEXT DEFAULT '',
				created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			);
		"

		# Record with state hash
		_record_action_dedup "cycle-test" "comment_on_issue" "issue:42" "executed" "hash123abc"

		# Verify it was stored
		local stored_hash
		stored_hash=$(sqlite3 "$SUPERVISOR_DB" "SELECT state_hash FROM action_dedup_log WHERE target='issue:42' LIMIT 1;")
		if [[ "$stored_hash" != "hash123abc" ]]; then
			echo "FAIL: stored state_hash should be 'hash123abc', got '$stored_hash'"
			failures=$((failures + 1))
		fi

		# Record without state hash (backward compat)
		_record_action_dedup "cycle-test2" "create_task" "title:Test" "executed"
		local stored_empty
		stored_empty=$(sqlite3 "$SUPERVISOR_DB" "SELECT state_hash FROM action_dedup_log WHERE target='title:Test' LIMIT 1;")
		if [[ "$stored_empty" != "" ]]; then
			echo "FAIL: missing state_hash should store empty string, got '$stored_empty'"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_record_state_hash 2>/dev/null; then
	pass "dedup record correctly stores state_hash"
else
	fail "dedup record state_hash storage has errors"
fi

# ─── Test 18: extract_action_plan edge cases (t1201) ────────────────
echo "Test 18: extract_action_plan — markdown fence stripping and fallback parsing"

_test_extract_action_plan() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-extract-$$.db"
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

		# extract_action_plan is defined in ai-reason.sh — source it for this test
		# shellcheck source=../.agents/scripts/supervisor/ai-reason.sh
		source "$REPO_DIR/.agents/scripts/supervisor/ai-reason.sh"

		source "$ACTIONS_SCRIPT"

		local failures=0

		# Empty response
		local result
		result=$(extract_action_plan "")
		if [[ -n "$result" ]]; then
			echo "FAIL: empty response should return empty string, got: $result"
			failures=$((failures + 1))
		fi

		# Whitespace-only response
		result=$(extract_action_plan "   
	")
		if [[ -n "$result" ]]; then
			echo "FAIL: whitespace-only response should return empty string, got: $result"
			failures=$((failures + 1))
		fi

		# Pure JSON array (no fencing)
		result=$(extract_action_plan '[{"type":"comment_on_issue","issue_number":1,"body":"test","reasoning":"r"}]')
		if [[ -z "$result" ]]; then
			echo "FAIL: pure JSON array should be parsed successfully"
			failures=$((failures + 1))
		fi

		# Markdown-fenced JSON (```json ... ```)
		result=$(extract_action_plan '```json
[{"type":"comment_on_issue","issue_number":1,"body":"test","reasoning":"r"}]
```')
		if [[ -z "$result" ]]; then
			echo "FAIL: markdown-fenced JSON should be extracted and parsed"
			failures=$((failures + 1))
		fi

		# Non-JSON response (preamble text)
		result=$(extract_action_plan "Here is my analysis of the project state...")
		if [[ -n "$result" ]]; then
			echo "FAIL: non-JSON response should return empty string, got: $result"
			failures=$((failures + 1))
		fi

		# Empty array (valid — model has no actions)
		result=$(extract_action_plan '[]')
		if [[ "$result" != "[]" ]]; then
			echo "FAIL: empty array should parse to '[]', got: $result"
			failures=$((failures + 1))
		fi

		# Array embedded in preamble text
		result=$(extract_action_plan 'Here is my action plan:
[{"type":"comment_on_issue","issue_number":1,"body":"test","reasoning":"r"}]
That is all.')
		if [[ -z "$result" ]]; then
			echo "FAIL: array embedded in text should be extracted via bracket fallback"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_extract_action_plan 2>/dev/null; then
	pass "extract_action_plan handles empty, whitespace, fenced, and embedded JSON"
else
	fail "extract_action_plan edge case handling has errors"
fi

# ─── Test 19: adjust_priority new_priority validation (t1126, t1201) ─
echo "Test 19: adjust_priority — new_priority required and validated"

_test_adjust_priority_validation() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-adj-$$.db"
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

		# Valid values must be accepted
		for prio in high medium low critical; do
			local result
			result=$(validate_action_fields "{\"type\":\"adjust_priority\",\"task_id\":\"t100\",\"new_priority\":\"$prio\"}" "adjust_priority")
			if [[ -n "$result" ]]; then
				echo "FAIL: new_priority='$prio' should be valid, got: $result"
				failures=$((failures + 1))
			fi
		done

		# Invalid values must be rejected
		for prio in urgent URGENT "very high" "1" ""; do
			local result
			result=$(validate_action_fields "{\"type\":\"adjust_priority\",\"task_id\":\"t100\",\"new_priority\":\"$prio\"}" "adjust_priority")
			# Empty string is treated as absent (no new_priority field) — that's OK
			if [[ "$prio" == "" ]]; then
				continue
			fi
			if [[ -z "$result" ]]; then
				echo "FAIL: new_priority='$prio' should be invalid but was accepted"
				failures=$((failures + 1))
			fi
		done

		# Missing new_priority is OK (executor infers from reasoning)
		local result
		result=$(validate_action_fields '{"type":"adjust_priority","task_id":"t100"}' "adjust_priority")
		if [[ -n "$result" ]]; then
			echo "FAIL: missing new_priority should be accepted (executor infers), got: $result"
			failures=$((failures + 1))
		fi

		# Invalid: missing task_id
		result=$(validate_action_fields '{"type":"adjust_priority","new_priority":"high"}' "adjust_priority")
		if [[ -z "$result" ]]; then
			echo "FAIL: adjust_priority without task_id should be rejected"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_adjust_priority_validation 2>/dev/null; then
	pass "adjust_priority new_priority validation accepts valid values and rejects invalid ones"
else
	fail "adjust_priority new_priority validation has errors"
fi

# ─── Test 20: Pipeline handles empty model response (t1204) ─────────
echo "Test 20: Pipeline — empty model response returns rc=0 with empty actions"

_test_pipeline_empty_response() {
	(
		set +e
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-pipeline-empty-$$.db"
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

		# Stub run_ai_reasoning to simulate empty model response (the failure mode
		# observed in the 8 consecutive rc=1 failures on Feb 18: 'expected array, got ')
		run_ai_reasoning() {
			echo ""
			return 0
		}
		export -f run_ai_reasoning

		source "$ACTIONS_SCRIPT"

		local result rc
		result=$(run_ai_actions_pipeline "$REPO_DIR" "dry-run" 2>/dev/null)
		rc=$?

		local failures=0

		# rc must be 0 — empty response is not a hard error (t1187, t1197)
		if [[ $rc -ne 0 ]]; then
			echo "FAIL: empty model response should return rc=0, got rc=$rc"
			failures=$((failures + 1))
		fi

		# Result must be valid JSON with executed=0
		local executed
		executed=$(printf '%s' "$result" | jq -r '.executed // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$executed" != "0" ]]; then
			echo "FAIL: empty response should produce executed=0, got executed=$executed (result=$result)"
			failures=$((failures + 1))
		fi

		# Actions array must be empty
		local action_count
		action_count=$(printf '%s' "$result" | jq '.actions | length' 2>/dev/null || echo -1)
		if [[ "$action_count" != "0" ]]; then
			echo "FAIL: empty response should produce 0 actions, got $action_count"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_pipeline_empty_response 2>/dev/null; then
	pass "pipeline: empty model response returns rc=0 with empty actions (t1204)"
else
	fail "pipeline: empty model response handling broken (t1204)"
fi

# ─── Test 21: Pipeline handles malformed JSON response (t1204) ───────
echo "Test 21: Pipeline — malformed JSON response returns rc=0 with empty actions"

_test_pipeline_malformed_json() {
	(
		set +e
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-pipeline-malformed-$$.db"
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

		# Stub run_ai_reasoning to simulate malformed/non-JSON model response
		# (the exact failure mode: model returns prose instead of JSON array)
		run_ai_reasoning() {
			echo "I cannot provide a JSON response at this time. The system is experiencing issues."
			return 0
		}
		export -f run_ai_reasoning

		source "$ACTIONS_SCRIPT"

		local result rc
		result=$(run_ai_actions_pipeline "$REPO_DIR" "dry-run" 2>/dev/null)
		rc=$?

		local failures=0

		# rc must be 0 — non-JSON response is treated as empty plan, not hard error (t1189, t1197)
		if [[ $rc -ne 0 ]]; then
			echo "FAIL: malformed JSON response should return rc=0, got rc=$rc"
			failures=$((failures + 1))
		fi

		# Result must be valid JSON with executed=0
		local executed
		executed=$(printf '%s' "$result" | jq -r '.executed // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$executed" != "0" ]]; then
			echo "FAIL: malformed JSON should produce executed=0, got executed=$executed (result=$result)"
			failures=$((failures + 1))
		fi

		# Actions array must be empty
		local action_count
		action_count=$(printf '%s' "$result" | jq '.actions | length' 2>/dev/null || echo -1)
		if [[ "$action_count" != "0" ]]; then
			echo "FAIL: malformed JSON should produce 0 actions, got $action_count"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_pipeline_malformed_json 2>/dev/null; then
	pass "pipeline: malformed JSON response returns rc=0 with empty actions (t1204)"
else
	fail "pipeline: malformed JSON response handling broken (t1204)"
fi

# ─── Test 22: Pipeline handles valid empty-actions response (t1204) ──
echo "Test 22: Pipeline — valid empty-actions response '[]' passes through cleanly"

_test_pipeline_valid_empty_array() {
	(
		set +e
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-pipeline-empty-array-$$.db"
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

		# Stub run_ai_reasoning to return a valid empty JSON array
		# (the correct model response when no actions are needed)
		run_ai_reasoning() {
			echo "[]"
			return 0
		}
		export -f run_ai_reasoning

		source "$ACTIONS_SCRIPT"

		local result rc
		result=$(run_ai_actions_pipeline "$REPO_DIR" "dry-run" 2>/dev/null)
		rc=$?

		local failures=0

		# rc must be 0
		if [[ $rc -ne 0 ]]; then
			echo "FAIL: valid empty-actions response should return rc=0, got rc=$rc"
			failures=$((failures + 1))
		fi

		# Result must be valid JSON
		if ! printf '%s' "$result" | jq . >/dev/null 2>&1; then
			echo "FAIL: result is not valid JSON: $result"
			failures=$((failures + 1))
		fi

		# executed must be 0 (no actions to execute)
		local executed
		executed=$(printf '%s' "$result" | jq -r '.executed // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$executed" != "0" ]]; then
			echo "FAIL: empty-actions response should produce executed=0, got executed=$executed"
			failures=$((failures + 1))
		fi

		# failed must be 0
		local failed
		failed=$(printf '%s' "$result" | jq -r '.failed // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$failed" != "0" ]]; then
			echo "FAIL: empty-actions response should produce failed=0, got failed=$failed"
			failures=$((failures + 1))
		fi

		# actions array must exist and be empty
		local action_count
		action_count=$(printf '%s' "$result" | jq '.actions | length' 2>/dev/null || echo -1)
		if [[ "$action_count" != "0" ]]; then
			echo "FAIL: empty-actions response should produce 0 actions, got $action_count"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "$SUPERVISOR_DB"
		exit "$failures"
	)
}

if _test_pipeline_valid_empty_array 2>/dev/null; then
	pass "pipeline: valid empty-actions '[]' response passes through cleanly (t1204)"
else
	fail "pipeline: valid empty-actions '[]' response handling broken (t1204)"
fi

# ─── Test 23: create_subtasks executor — grep -c bug fix (t1221) ────
echo "Test 23: create_subtasks executor — grep -c with no matches does not crash"

_test_create_subtasks_grep_c_bug() {
	(
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-subtasks-$$.db"
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

		local failures=0

		# Create a temp directory with a TODO.md containing a parent task but NO existing subtasks.
		# This is the exact scenario that triggered the grep -c bug:
		# grep -c returns exit 1 (no matches) + outputs "0", then || echo 0
		# appends another "0", producing "0\n0" which breaks arithmetic.
		local tmp_dir
		tmp_dir=$(mktemp -d)
		printf '# Test TODO\n\n- [ ] t999 Parent task with no subtasks ~4h\n- [ ] t998 Another task\n' >"$tmp_dir/TODO.md"

		local action
		action='{"type":"create_subtasks","parent_task_id":"t999","subtasks":[{"title":"Sub 1","tags":["#auto-dispatch"],"estimate":"~1h","model":"sonnet"},{"title":"Sub 2","tags":["#auto-dispatch"],"estimate":"~2h","model":"sonnet"}],"reasoning":"test"}'

		local result rc
		result=$(_exec_create_subtasks "$action" "$tmp_dir" 2>/dev/null)
		rc=$?

		# Should succeed (rc=0) and return JSON with created:true
		if [[ $rc -ne 0 ]]; then
			echo "FAIL: create_subtasks should succeed with rc=0, got rc=$rc (result: $result)"
			failures=$((failures + 1))
		fi

		local created
		created=$(printf '%s' "$result" | jq -r '.created // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$created" != "true" ]]; then
			echo "FAIL: create_subtasks should return created:true, got: $result"
			failures=$((failures + 1))
		fi

		# Verify subtasks were actually written to the temp TODO.md
		if ! grep -q "t999.1" "$tmp_dir/TODO.md" 2>/dev/null; then
			echo "FAIL: subtask t999.1 not found in TODO.md after create_subtasks"
			failures=$((failures + 1))
		fi
		if ! grep -q "t999.2" "$tmp_dir/TODO.md" 2>/dev/null; then
			echo "FAIL: subtask t999.2 not found in TODO.md after create_subtasks"
			failures=$((failures + 1))
		fi

		rm -rf "$tmp_dir" "/tmp/test-ai-actions-logs-$$" "/tmp/test-subtasks-$$.db" 2>/dev/null || true
		exit "$failures"
	)
}

if _test_create_subtasks_grep_c_bug 2>/dev/null; then
	pass "create_subtasks: grep -c with no existing subtasks does not crash (t1221)"
else
	fail "create_subtasks: grep -c bug still present (t1221)"
fi

# ─── Test 24: create_subtasks executor — missing parent_task_id (t1221) ─
echo "Test 24: create_subtasks executor — missing parent_task_id returns clear error"

_test_create_subtasks_missing_parent() {
	(
		set +e
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-subtasks-missing-$$.db"
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

		local failures=0

		# Missing parent_task_id — should return clear error, not crash
		local action
		action='{"type":"create_subtasks","subtasks":[{"title":"Sub 1","estimate":"~1h","model":"sonnet"}],"reasoning":"test"}'

		local result rc
		result=$(_exec_create_subtasks "$action" "$REPO_DIR" 2>/dev/null)
		rc=$?

		if [[ $rc -eq 0 ]]; then
			echo "FAIL: missing parent_task_id should return rc=1, got rc=0"
			failures=$((failures + 1))
		fi

		local error_field
		error_field=$(printf '%s' "$result" | jq -r '.error // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$error_field" != "missing_parent_task_id" ]]; then
			echo "FAIL: missing parent_task_id should return error=missing_parent_task_id, got: $result"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-subtasks-missing-$$.db" 2>/dev/null || true
		exit "$failures"
	)
}

if _test_create_subtasks_missing_parent 2>/dev/null; then
	pass "create_subtasks: missing parent_task_id returns clear error (t1221)"
else
	fail "create_subtasks: missing parent_task_id error handling broken (t1221)"
fi

# ─── Test 25: create_subtasks executor — parent not in primary repo (t1221) ─
echo "Test 25: create_subtasks executor — parent task not in primary repo returns clear error"

_test_create_subtasks_cross_repo() {
	(
		set +e
		BLUE='' GREEN='' YELLOW='' RED='' NC=''
		SUPERVISOR_DB="/tmp/test-subtasks-cross-$$.db"
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

		local failures=0

		# Task t99998 does not exist in the aidevops repo TODO.md
		# (simulates a cross-repo task like awardsapp t003) — should return
		# parent_task_not_found with clear diagnostics, not crash silently
		local action
		action='{"type":"create_subtasks","parent_task_id":"t99998","subtasks":[{"title":"Sub 1","estimate":"~1h","model":"sonnet"}],"reasoning":"test"}'

		local result rc
		result=$(_exec_create_subtasks "$action" "$REPO_DIR" 2>/dev/null)
		rc=$?

		if [[ $rc -eq 0 ]]; then
			echo "FAIL: cross-repo task should return rc=1 (not found in primary repo), got rc=0"
			failures=$((failures + 1))
		fi

		local error_field
		error_field=$(printf '%s' "$result" | jq -r '.error // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$error_field" != "parent_task_not_found" ]]; then
			echo "FAIL: cross-repo task should return error=parent_task_not_found, got: $result"
			failures=$((failures + 1))
		fi

		# Verify the error includes the parent_task_id for diagnostics
		local returned_id
		returned_id=$(printf '%s' "$result" | jq -r '.parent_task_id // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")
		if [[ "$returned_id" != "t99998" ]]; then
			echo "FAIL: error should include parent_task_id=t99998, got: $returned_id"
			failures=$((failures + 1))
		fi

		rm -rf "/tmp/test-ai-actions-logs-$$" "/tmp/test-subtasks-cross-$$.db" 2>/dev/null || true
		exit "$failures"
	)
}

if _test_create_subtasks_cross_repo 2>/dev/null; then
	pass "create_subtasks: cross-repo task returns clear parent_task_not_found error (t1221)"
else
	fail "create_subtasks: cross-repo task error handling broken (t1221)"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
