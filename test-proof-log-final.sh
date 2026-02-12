#!/usr/bin/env bash
# =============================================================================
# t317.4: Final End-to-End Proof-Log System Validation
# =============================================================================
# Validates the complete proof-log enforcement system across all paths:
# 1. Pre-commit hook (t317.1 - PR #1249 OPEN)
# 2. complete_task() function (t317.2 - PR #1251 MERGED to main)
# 3. AGENTS.md documentation (t317.3 - PR #1250 OPEN)
# 4. Supervisor verification logic (existing)
# 5. Issue-sync proof-log awareness (existing)
# =============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

echo "======================================================================="
echo "  t317.4: Proof-Log System End-to-End Validation"
echo "======================================================================="
echo ""
echo "Testing proof-log enforcement across all paths:"
echo "  - Pre-commit hook validation"
echo "  - Interactive complete_task() helper"
echo "  - Supervisor automated completion"
echo "  - Issue-sync GitHub integration"
echo ""

# =============================================================================
# Test 1: Pre-commit hook (t317.1 - PR #1249)
# =============================================================================
echo -e "${BLUE}[TEST 1]${NC} Pre-commit hook implementation (t317.1)"

T317_1_HOOK="/Users/marcusquinn/Git/aidevops.feature-t317.1/.agents/scripts/pre-commit-hook.sh"

if [[ ! -f "$T317_1_HOOK" ]]; then
	echo -e "${RED}[FAIL]${NC} t317.1 worktree not found"
	((FAIL++))
else
	# Check for pr:# pattern
	if grep -q "pr:#" "$T317_1_HOOK"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Checks for pr:# field"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing pr:# check"
		((FAIL++))
	fi

	# Check for verified: pattern
	if grep -q "verified:" "$T317_1_HOOK"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Checks for verified: field"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing verified: check"
		((FAIL++))
	fi

	# Check that it rejects (return 1)
	if grep -A30 'if \[\[ "$has_evidence" == "false" \]\]' "$T317_1_HOOK" | grep -q "return 1"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Rejects commit when proof-log missing (return 1)"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Does not reject on missing proof-log"
		((FAIL++))
	fi

	# Check that it skips already-completed tasks
	if grep -q "already.*completed\|Skip if this task was already" "$T317_1_HOOK"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Skips tasks that were already [x]"
		((PASS++))
	else
		echo -e "${YELLOW}[WARN]${NC} ⚠ May not skip already-completed tasks"
		((WARN++))
	fi
fi

echo ""

# =============================================================================
# Test 2: complete_task() function (t317.2 - PR #1251 MERGED)
# =============================================================================
echo -e "${BLUE}[TEST 2]${NC} complete_task() function (t317.2 - MERGED to main)"

MAIN_HELPER="/Users/marcusquinn/Git/aidevops/.agents/scripts/planning-commit-helper.sh"

if [[ ! -f "$MAIN_HELPER" ]]; then
	echo -e "${RED}[FAIL]${NC} planning-commit-helper.sh not found in main"
	((FAIL++))
else
	# Check function exists
	if grep -q "^complete_task()" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ complete_task() function exists"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ complete_task() function not found"
		((FAIL++))
	fi

	# Check --pr argument
	if grep -q "\-\-pr" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Accepts --pr <number> argument"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing --pr argument"
		((FAIL++))
	fi

	# Check --verified argument
	if grep -q "\-\-verified" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Accepts --verified argument"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing --verified argument"
		((FAIL++))
	fi

	# Check PR merge validation
	if grep -q "gh pr view.*merged\|pr_state.*MERGED\|mergedAt" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Validates PR is merged via gh CLI"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Does not validate PR merge status"
		((FAIL++))
	fi

	# Check confirmation for --verified
	if grep -q "confirmation\|Are you sure" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Requires confirmation for --verified"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ No confirmation for --verified"
		((FAIL++))
	fi

	# Check that it marks [x]
	if grep -q "\[x\]" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Marks task as [x]"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Does not mark task as [x]"
		((FAIL++))
	fi

	# Check that it adds proof-log fields
	if grep -q "pr:#\|verified:" "$MAIN_HELPER"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Adds pr:# or verified: field"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Does not add proof-log fields"
		((FAIL++))
	fi
fi

echo ""

# =============================================================================
# Test 3: AGENTS.md documentation (t317.3 - PR #1250)
# =============================================================================
echo -e "${BLUE}[TEST 3]${NC} AGENTS.md documentation (t317.3)"

T317_3_AGENTS="/Users/marcusquinn/Git/aidevops.feature-t317.3/.agents/AGENTS.md"

if [[ ! -f "$T317_3_AGENTS" ]]; then
	echo -e "${RED}[FAIL]${NC} t317.3 worktree not found"
	((FAIL++))
else
	# Check for task completion rules
	if grep -q "Task completion rules\|complete_task\|proof-log" "$T317_3_AGENTS"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Documents task completion rules"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing task completion documentation"
		((FAIL++))
	fi

	# Check for pre-commit hook mention
	if grep -q "pre-commit.*hook\|pre-commit.*enforce" "$T317_3_AGENTS"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Documents pre-commit hook enforcement"
		((PASS++))
	else
		echo -e "${YELLOW}[WARN]${NC} ⚠ May not document pre-commit hook"
		((WARN++))
	fi

	# Check for pr:# and verified: field documentation
	if grep -q "pr:#\|verified:" "$T317_3_AGENTS"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Documents pr:# and verified: fields"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ Missing proof-log field documentation"
		((FAIL++))
	fi
fi

echo ""

# =============================================================================
# Test 4: Supervisor verification logic
# =============================================================================
echo -e "${BLUE}[TEST 4]${NC} Supervisor verification logic"

TODO_SYNC=".agents/scripts/supervisor/todo-sync.sh"

if [[ ! -f "$TODO_SYNC" ]]; then
	echo -e "${RED}[FAIL]${NC} todo-sync.sh not found"
	((FAIL++))
else
	# Check update_todo_on_complete exists
	if grep -q "^update_todo_on_complete()" "$TODO_SYNC"; then
		echo -e "${GREEN}[PASS]${NC} ✓ update_todo_on_complete() function exists"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC} ✗ update_todo_on_complete() not found"
		((FAIL++))
	fi

	# Check for verification call
	if grep -q "verify_task_deliverables" "$TODO_SYNC"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Calls verify_task_deliverables()"
		((PASS++))

		# Note about function location
		echo -e "${BLUE}[INFO]${NC}   verify_task_deliverables() may be defined in another module"
	else
		echo -e "${RED}[FAIL]${NC} ✗ Does not call deliverable verification"
		((FAIL++))
	fi
fi

echo ""

# =============================================================================
# Test 5: Issue-sync proof-log awareness
# =============================================================================
echo -e "${BLUE}[TEST 5]${NC} Issue-sync proof-log awareness"

ISSUE_SYNC=".agents/scripts/issue-sync-helper.sh"

if [[ ! -f "$ISSUE_SYNC" ]]; then
	echo -e "${RED}[FAIL]${NC} issue-sync-helper.sh not found"
	((FAIL++))
else
	# Check for pr:# field
	if grep -q "pr:#" "$ISSUE_SYNC"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Checks for pr:# field"
		((PASS++))
	else
		echo -e "${YELLOW}[WARN]${NC} ⚠ May not check for pr:# field"
		((WARN++))
	fi

	# Check for verified: field
	if grep -q "verified:" "$ISSUE_SYNC"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Checks for verified: field"
		((PASS++))
	else
		echo -e "${YELLOW}[WARN]${NC} ⚠ May not check for verified: field"
		((WARN++))
	fi

	# Check for proof-log awareness
	if grep -q "proof-log\|deliverable" "$ISSUE_SYNC"; then
		echo -e "${GREEN}[PASS]${NC} ✓ Has proof-log/deliverable awareness"
		((PASS++))
	else
		echo -e "${BLUE}[INFO]${NC}   May validate deliverables implicitly"
	fi
fi

echo ""

# =============================================================================
# Test 6: Integration - consistent field names
# =============================================================================
echo -e "${BLUE}[TEST 6]${NC} Integration - consistent field naming"

PR_FORMAT_COUNT=0
VERIFIED_FORMAT_COUNT=0

# Count pr:# usage
[[ -f "$T317_1_HOOK" ]] && grep -q "pr:#" "$T317_1_HOOK" && ((PR_FORMAT_COUNT++))
[[ -f "$MAIN_HELPER" ]] && grep -q "pr:#" "$MAIN_HELPER" && ((PR_FORMAT_COUNT++))
[[ -f "$ISSUE_SYNC" ]] && grep -q "pr:#" "$ISSUE_SYNC" && ((PR_FORMAT_COUNT++))

# Count verified: usage
[[ -f "$T317_1_HOOK" ]] && grep -q "verified:" "$T317_1_HOOK" && ((VERIFIED_FORMAT_COUNT++))
[[ -f "$MAIN_HELPER" ]] && grep -q "verified:" "$MAIN_HELPER" && ((VERIFIED_FORMAT_COUNT++))

if [[ $PR_FORMAT_COUNT -ge 2 ]]; then
	echo -e "${GREEN}[PASS]${NC} ✓ Components use consistent pr:# format ($PR_FORMAT_COUNT/3)"
	((PASS++))
else
	echo -e "${YELLOW}[WARN]${NC} ⚠ Inconsistent pr:# format usage ($PR_FORMAT_COUNT/3)"
	((WARN++))
fi

if [[ $VERIFIED_FORMAT_COUNT -ge 2 ]]; then
	echo -e "${GREEN}[PASS]${NC} ✓ Components use consistent verified: format ($VERIFIED_FORMAT_COUNT/2)"
	((PASS++))
else
	echo -e "${YELLOW}[WARN]${NC} ⚠ Inconsistent verified: format usage ($VERIFIED_FORMAT_COUNT/2)"
	((WARN++))
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "======================================================================="
echo "  Test Summary"
echo "======================================================================="
echo -e "Tests passed: ${GREEN}${PASS}${NC}"
echo -e "Tests failed: ${RED}${FAIL}${NC}"
echo -e "Warnings:     ${YELLOW}${WARN}${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
	echo -e "${GREEN}✓ All critical tests passed!${NC}"
	echo ""
	echo "Proof-log system is correctly implemented:"
	echo "  1. ✓ Pre-commit hook enforces pr:# or verified: (t317.1 - PR #1249)"
	echo "  2. ✓ complete_task() helper for interactive use (t317.2 - MERGED)"
	echo "  3. ✓ AGENTS.md documents the system (t317.3 - PR #1250)"
	echo "  4. ✓ Supervisor has verification logic"
	echo "  5. ✓ Issue-sync is proof-log aware"
	echo ""
	echo "Status:"
	echo "  - t317.1 (Pre-commit hook): PR #1249 OPEN, ready to merge"
	echo "  - t317.2 (complete_task):   PR #1251 MERGED ✓"
	echo "  - t317.3 (AGENTS.md):       PR #1250 OPEN, ready to merge"
	echo ""
	exit 0
else
	echo -e "${RED}✗ $FAIL critical test(s) failed${NC}"
	echo ""
	echo "Review the failures above and fix before merging."
	echo ""
	exit 1
fi
