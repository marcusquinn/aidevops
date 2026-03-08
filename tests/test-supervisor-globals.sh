#!/usr/bin/env bash
# test-supervisor-globals.sh
#
# Verify all supervisor modules can be sourced without unbound variable errors.
# This catches the class of bug where modularization moves functions but drops
# the global variable definitions they depend on.
#
# How it works:
# 1. Sources supervisor-helper.sh (which sources all modules) with set -u
# 2. Runs `supervisor-helper.sh help` to exercise the main code path
# 3. Checks that key globals are defined and non-empty
#
# Usage: bash tests/test-supervisor-globals.sh
# Exit codes: 0 = pass, 1 = failure

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Only test the active (non-archived) supervisor-helper.sh.
# Archived scripts lack co-located dependencies and cannot be sourced.
if [[ -f "$REPO_DIR/.agents/scripts/supervisor-helper.sh" ]]; then
	SUPERVISOR="$REPO_DIR/.agents/scripts/supervisor-helper.sh"
else
	SUPERVISOR=""
fi

# shellcheck source=tests/test-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

echo "=== Supervisor Globals Test ==="
echo ""

# Test 1: supervisor-helper.sh sources without errors under set -u
echo "Test 1: Source all modules (set -u)"
if [[ -z "$SUPERVISOR" ]]; then
	echo "  SKIP: supervisor-helper.sh not found (archived)"
else
	if bash -u "$SUPERVISOR" help >/dev/null 2>&1; then
		pass "supervisor-helper.sh help runs without unbound variable errors"
	else
		fail "supervisor-helper.sh help failed — likely unbound variable"
		# Show the actual error
		bash -u "$SUPERVISOR" help 2>&1 | head -5
	fi
fi

# Test 2: bash -n syntax check on all module files
echo "Test 2: Syntax check all modules"
module_dir="$REPO_DIR/.agents/scripts/supervisor"
if [[ ! -d "$module_dir" ]]; then
	echo "  SKIP: supervisor modules directory not found (archived)"
else
	syntax_ok=true
	for module in "$module_dir/"*.sh; do
		if ! bash -n "$module" 2>/dev/null; then
			fail "syntax error in $(basename "$module")"
			syntax_ok=false
		fi
	done
	if [[ "$syntax_ok" == "true" ]]; then
		pass "all module files pass bash -n"
	fi
fi

# Test 3: Key globals are defined after sourcing
echo "Test 3: Key globals defined"
if [[ -z "$SUPERVISOR" ]]; then
	echo "  SKIP: supervisor-helper.sh not found (archived)"
else
	# We can't source directly (readonly conflicts), so check via grep
	required_globals=(
		"SUPERVISOR_DIR"
		"SUPERVISOR_DB"
		"SUPERVISOR_LOG"
		"PULSE_LOCK_DIR"
		"PULSE_LOCK_TIMEOUT"
		"VALID_STATES"
		"VALID_TRANSITIONS"
	)

	all_files="$SUPERVISOR"
	if [[ -d "$module_dir" ]]; then
		all_files="$SUPERVISOR $(echo "$module_dir/"*.sh)"
	fi
	for var in "${required_globals[@]}"; do
		# Check if the variable is assigned (not just referenced) in any file
		# Handles: VAR=, readonly VAR=, readonly -a VAR=(
		# shellcheck disable=SC2086
		if grep -qE "^[[:space:]]*(readonly( -a)? )?${var}=" $all_files 2>/dev/null; then
			pass "$var is defined"
		else
			fail "$var is NOT defined in any supervisor file"
		fi
	done
fi

# Test 4: No module references a variable that isn't defined anywhere
echo "Test 4: Cross-reference module variables"
if [[ ! -d "$module_dir" ]]; then
	echo "  SKIP: supervisor modules directory not found (archived)"
else
	# Extract variables used in modules (excluding env vars with :- defaults)
	# Find bare $VAR references (no :- default) that look like supervisor globals
	all_files="$SUPERVISOR"
	if [[ -n "$SUPERVISOR" ]]; then
		all_files="$SUPERVISOR $(echo "$module_dir/"*.sh)"
	else
		all_files="$(echo "$module_dir/"*.sh)"
	fi
	missing_count=0
	for var in SUPERVISOR_DIR SUPERVISOR_DB SUPERVISOR_LOG PULSE_LOCK_DIR PULSE_LOCK_TIMEOUT SCRIPT_DIR SUPERVISOR_MODULE_DIR; do
		# Check if used in modules
		if grep -rq "\$${var}\b\|\${${var}}" "$module_dir/" 2>/dev/null; then
			# Check if defined in monolith or _common.sh
			# shellcheck disable=SC2086
			if ! grep -qE "^[[:space:]]*(readonly( -a)? )?${var}=" $all_files 2>/dev/null; then
				fail "$var used in modules but not defined anywhere"
				missing_count=$((missing_count + 1))
			fi
		fi
	done
	if [[ "$missing_count" -eq 0 ]]; then
		pass "all module-referenced globals are defined"
	fi
fi

print_summary
exit $?
