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
SUPERVISOR="$REPO_DIR/.agents/scripts/supervisor-helper.sh"

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	echo "  PASS: $1"
}
fail() {
	FAIL=$((FAIL + 1))
	echo "  FAIL: $1"
}

echo "=== Supervisor Globals Test ==="
echo ""

# Test 1: supervisor-helper.sh sources without errors under set -u
echo "Test 1: Source all modules (set -u)"
if bash -u "$SUPERVISOR" help >/dev/null 2>&1; then
	pass "supervisor-helper.sh help runs without unbound variable errors"
else
	fail "supervisor-helper.sh help failed — likely unbound variable"
	# Show the actual error
	bash -u "$SUPERVISOR" help 2>&1 | head -5
fi

# Test 2: bash -n syntax check on all module files
echo "Test 2: Syntax check all modules"
syntax_ok=true
for module in "$REPO_DIR/.agents/scripts/supervisor/"*.sh; do
	if ! bash -n "$module" 2>/dev/null; then
		fail "syntax error in $(basename "$module")"
		syntax_ok=false
	fi
done
if [[ "$syntax_ok" == "true" ]]; then
	pass "all module files pass bash -n"
fi

# Test 3: Key globals are defined after sourcing
echo "Test 3: Key globals defined"
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

all_files="$SUPERVISOR $(echo "$REPO_DIR/.agents/scripts/supervisor/"*.sh)"
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

# Test 4: No module references a variable that isn't defined anywhere
echo "Test 4: Cross-reference module variables"
# Extract variables used in modules (excluding env vars with :- defaults)
module_dir="$REPO_DIR/.agents/scripts/supervisor"
# Find bare $VAR references (no :- default) that look like supervisor globals
missing_count=0
for var in SUPERVISOR_DIR SUPERVISOR_DB SUPERVISOR_LOG PULSE_LOCK_DIR PULSE_LOCK_TIMEOUT SCRIPT_DIR SUPERVISOR_MODULE_DIR; do
	# Check if used in modules
	if grep -rq "\$${var}\b\|\${${var}}" "$module_dir/" 2>/dev/null; then
		# Check if defined in monolith or _common.sh
		# shellcheck disable=SC2086
		if ! grep -q "^[[:space:]]*\(readonly \)\{0,1\}${var}=" $all_files 2>/dev/null; then
			fail "$var used in modules but not defined anywhere"
			missing_count=$((missing_count + 1))
		fi
	fi
done
if [[ "$missing_count" -eq 0 ]]; then
	pass "all module-referenced globals are defined"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
