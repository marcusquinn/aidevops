#!/usr/bin/env bash
# test-verify-brief.sh
#
# Unit tests for verify-brief.sh (t1313):
# - Parsing acceptance criteria from brief files
# - All 4 verify methods: bash, codebase, subagent, manual
# - Edge cases: no criteria, no verify blocks, invalid YAML
# - JSON output mode
# - Dry-run mode
# - Integration with task-complete-helper.sh --verify flag
#
# Uses isolated temp directories with synthetic brief files.
#
# Usage: bash tests/test-verify-brief.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
VERIFY_SCRIPT="$SCRIPTS_DIR/verify-brief.sh"
VERBOSE="${1:-}"
export VERBOSE # used by verify-brief.sh --verbose passthrough

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	local msg="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$msg"
	return 0
}

fail() {
	local msg="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$msg"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	local msg="$1"
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$msg"
	return 0
}

section() {
	local title="$1"
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$title"
	return 0
}

# --- Setup ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Verify the script exists
if [[ ! -x "$VERIFY_SCRIPT" ]]; then
	echo "ERROR: verify-brief.sh not found or not executable at $VERIFY_SCRIPT"
	exit 1
fi

# --- Helper: create brief files ---

# Brief with all 4 verify methods
create_full_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t999: Test task

## Acceptance Criteria

- [ ] File exists check
  ```yaml
  verify:
    method: bash
    run: "test -f /etc/hosts"
  ```
- [ ] Pattern found in codebase
  ```yaml
  verify:
    method: codebase
    pattern: "verify:"
    path: ".agents/templates/brief-template.md"
  ```
- [ ] Subagent review needed
  ```yaml
  verify:
    method: subagent
    prompt: "Review the implementation"
    files: "src/main.ts"
  ```
- [ ] Human must check UI
  ```yaml
  verify:
    method: manual
    prompt: "Check the UI renders correctly"
  ```

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with no verify blocks
create_bare_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t998: Bare task

## Acceptance Criteria

- [ ] First criterion
- [ ] Second criterion
- [ ] Tests pass

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with no acceptance criteria section
create_no_criteria_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t997: No criteria task

## What

Something.

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with failing bash verification
create_failing_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t996: Failing task

## Acceptance Criteria

- [ ] This will fail
  ```yaml
  verify:
    method: bash
    run: "false"
  ```
- [ ] This will pass
  ```yaml
  verify:
    method: bash
    run: "true"
  ```

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with codebase absent check
create_absent_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t995: Absent check task

## Acceptance Criteria

- [ ] Pattern must NOT exist
  ```yaml
  verify:
    method: codebase
    pattern: "THIS_PATTERN_SHOULD_NEVER_EXIST_ANYWHERE_12345"
    path: ".agents/templates/"
    expect: absent
  ```

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with invalid verify block
create_invalid_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t994: Invalid verify

## Acceptance Criteria

- [ ] Missing method field
  ```yaml
  verify:
    run: "echo hello"
  ```

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with mixed verified and unverified criteria
create_mixed_brief() {
	local file="$1"
	cat >"$file" <<'BRIEF'
---
mode: subagent
---
# t993: Mixed task

## Acceptance Criteria

- [ ] Verified criterion
  ```yaml
  verify:
    method: bash
    run: "true"
  ```
- [ ] Unverified criterion
- [ ] Another verified criterion
  ```yaml
  verify:
    method: bash
    run: "true"
  ```

## Context & Decisions

None.
BRIEF
	return 0
}

# Brief with YAML double-backslash escaping
create_escaped_brief() {
	local file="$1"
	# Use printf to ensure literal backslashes in the file
	printf '%s\n' '---' 'mode: subagent' '---' '# t992: Escaped patterns' '' \
		'## Acceptance Criteria' '' \
		'- [ ] Pattern with escaped dot' \
		'  ```yaml' \
		'  verify:' \
		'    method: codebase' \
		'    pattern: "verify-brief\\.sh"' \
		'    path: ".agents/scripts/"' \
		'  ```' '' \
		'## Context & Decisions' '' 'None.' >"$file"
	return 0
}

# ============================================================
section "Script existence and help"
# ============================================================

if [[ -x "$VERIFY_SCRIPT" ]]; then
	pass "verify-brief.sh is executable"
else
	fail "verify-brief.sh is not executable"
fi

# Test --help
help_output=$("$VERIFY_SCRIPT" --help 2>&1) || true
if echo "$help_output" | grep -q "verify-brief.sh"; then
	pass "--help shows usage information"
else
	fail "--help does not show usage" "Output: $help_output"
fi

# Test missing argument
rc=0
"$VERIFY_SCRIPT" 2>/dev/null || rc=$?
if [[ $rc -eq 2 ]]; then
	pass "Missing argument returns exit code 2"
else
	fail "Missing argument should return exit 2, got $rc"
fi

# Test nonexistent file
rc=0
"$VERIFY_SCRIPT" "/nonexistent/file.md" 2>/dev/null || rc=$?
if [[ $rc -eq 2 ]]; then
	pass "Nonexistent file returns exit code 2"
else
	fail "Nonexistent file should return exit 2, got $rc"
fi

# ============================================================
section "Parsing: full brief with all 4 methods"
# ============================================================

FULL_BRIEF="$TEMP_DIR/full-brief.md"
create_full_brief "$FULL_BRIEF"

# Dry-run should parse all 4 criteria
dry_output=$("$VERIFY_SCRIPT" "$FULL_BRIEF" --repo-path "$REPO_DIR" --dry-run 2>&1) || true
if echo "$dry_output" | grep -q "Total criteria: 4"; then
	pass "Dry-run finds 4 criteria"
else
	fail "Dry-run should find 4 criteria" "Output: $dry_output"
fi

if echo "$dry_output" | grep -q "\[bash\]"; then
	pass "Dry-run identifies bash method"
else
	fail "Dry-run should identify bash method"
fi

if echo "$dry_output" | grep -q "\[codebase\]"; then
	pass "Dry-run identifies codebase method"
else
	fail "Dry-run should identify codebase method"
fi

if echo "$dry_output" | grep -q "\[subagent\]"; then
	pass "Dry-run identifies subagent method"
else
	fail "Dry-run should identify subagent method"
fi

if echo "$dry_output" | grep -q "\[manual\]"; then
	pass "Dry-run identifies manual method"
else
	fail "Dry-run should identify manual method"
fi

# ============================================================
section "Execution: bash method"
# ============================================================

# Full brief has a passing bash check (test -f /etc/hosts)
exec_output=$("$VERIFY_SCRIPT" "$FULL_BRIEF" --repo-path "$REPO_DIR" 2>&1) || true
if echo "$exec_output" | grep -q "\[PASS\].*File exists check"; then
	pass "Bash method passes for existing file"
else
	fail "Bash method should pass for /etc/hosts" "Output: $exec_output"
fi

# Failing bash check
FAIL_BRIEF="$TEMP_DIR/fail-brief.md"
create_failing_brief "$FAIL_BRIEF"

rc=0
fail_output=$("$VERIFY_SCRIPT" "$FAIL_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 1 ]]; then
	pass "Failing bash method returns exit code 1"
else
	fail "Failing bash method should return exit 1, got $rc"
fi

if echo "$fail_output" | grep -q "\[FAIL\].*This will fail"; then
	pass "Failing criterion is reported as FAIL"
else
	fail "Failing criterion should be reported as FAIL"
fi

if echo "$fail_output" | grep -q "\[PASS\].*This will pass"; then
	pass "Passing criterion still passes alongside failure"
else
	fail "Passing criterion should still pass"
fi

# ============================================================
section "Execution: codebase method"
# ============================================================

if echo "$exec_output" | grep -q "\[PASS\].*Pattern found in codebase"; then
	pass "Codebase method passes for existing pattern"
else
	fail "Codebase method should pass for 'verify:' in brief-template.md"
fi

# Absent check
ABSENT_BRIEF="$TEMP_DIR/absent-brief.md"
create_absent_brief "$ABSENT_BRIEF"

rc=0
absent_output=$("$VERIFY_SCRIPT" "$ABSENT_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "Codebase absent check passes when pattern not found"
else
	fail "Codebase absent check should pass, got exit $rc"
fi

if echo "$absent_output" | grep -q "\[PASS\]"; then
	pass "Absent check reports PASS"
else
	fail "Absent check should report PASS"
fi

# ============================================================
section "Execution: subagent method"
# ============================================================

if echo "$exec_output" | grep -q "\[SKIP\].*Manual verification required\|Subagent verification"; then
	pass "Subagent method reports SKIP"
else
	fail "Subagent method should report SKIP" "Output: $exec_output"
fi

# ============================================================
section "Execution: manual method"
# ============================================================

if echo "$exec_output" | grep -q "\[SKIP\].*Manual verification required"; then
	pass "Manual method reports SKIP"
else
	fail "Manual method should report SKIP"
fi

# Manual should not cause failure
if echo "$exec_output" | grep -q "Failed: "; then
	fail "Manual-only criteria should not cause failure"
else
	pass "Manual criteria do not cause failure"
fi

# ============================================================
section "Edge cases"
# ============================================================

# No verify blocks
BARE_BRIEF="$TEMP_DIR/bare-brief.md"
create_bare_brief "$BARE_BRIEF"

rc=0
bare_output=$("$VERIFY_SCRIPT" "$BARE_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "Brief with no verify blocks returns exit 0"
else
	fail "Brief with no verify blocks should return exit 0, got $rc"
fi

if echo "$bare_output" | grep -q "Unverified: 3"; then
	pass "All 3 criteria reported as unverified"
else
	fail "Should report 3 unverified criteria" "Output: $bare_output"
fi

# No criteria section
NO_CRITERIA="$TEMP_DIR/no-criteria-brief.md"
create_no_criteria_brief "$NO_CRITERIA"

rc=0
"$VERIFY_SCRIPT" "$NO_CRITERIA" --repo-path "$REPO_DIR" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "Brief with no criteria section returns exit 0"
else
	fail "Brief with no criteria section should return exit 0, got $rc"
fi

# Invalid verify block
INVALID_BRIEF="$TEMP_DIR/invalid-brief.md"
create_invalid_brief "$INVALID_BRIEF"

rc=0
invalid_output=$("$VERIFY_SCRIPT" "$INVALID_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 1 ]]; then
	pass "Invalid verify block returns exit code 1"
else
	fail "Invalid verify block should return exit 1, got $rc"
fi

if echo "$invalid_output" | grep -q "missing 'method' field\|Verify block missing"; then
	pass "Invalid block reports missing method field"
else
	fail "Should report missing method field" "Output: $invalid_output"
fi

# Mixed verified and unverified
MIXED_BRIEF="$TEMP_DIR/mixed-brief.md"
create_mixed_brief "$MIXED_BRIEF"

rc=0
mixed_output=$("$VERIFY_SCRIPT" "$MIXED_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "Mixed brief with passing checks returns exit 0"
else
	fail "Mixed brief should return exit 0, got $rc"
fi

if echo "$mixed_output" | grep -q "Passed: 2"; then
	pass "Mixed brief reports 2 passed"
else
	fail "Mixed brief should report 2 passed" "Output: $mixed_output"
fi

if echo "$mixed_output" | grep -q "Unverified: 1"; then
	pass "Mixed brief reports 1 unverified"
else
	fail "Mixed brief should report 1 unverified" "Output: $mixed_output"
fi

# YAML double-backslash escaping
ESCAPED_BRIEF="$TEMP_DIR/escaped-brief.md"
create_escaped_brief "$ESCAPED_BRIEF"

rc=0
escaped_output=$("$VERIFY_SCRIPT" "$ESCAPED_BRIEF" --repo-path "$REPO_DIR" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "YAML double-backslash pattern is unescaped correctly"
else
	fail "YAML double-backslash should be unescaped, got exit $rc" "Output: $escaped_output"
fi

# ============================================================
section "JSON output"
# ============================================================

json_output=$("$VERIFY_SCRIPT" "$FULL_BRIEF" --repo-path "$REPO_DIR" --json 2>/dev/null) || true
if echo "$json_output" | grep -q '"summary"'; then
	pass "JSON output contains summary"
else
	fail "JSON output should contain summary" "Output: $json_output"
fi

if echo "$json_output" | grep -q '"total": 4'; then
	pass "JSON summary has correct total"
else
	fail "JSON summary should have total: 4" "Output: $json_output"
fi

if echo "$json_output" | grep -q '"results"'; then
	pass "JSON output contains results array"
else
	fail "JSON output should contain results array"
fi

# ============================================================
section "Integration: task-complete-helper.sh --verify flag"
# ============================================================

COMPLETE_SCRIPT="$SCRIPTS_DIR/task-complete-helper.sh"
if [[ -f "$COMPLETE_SCRIPT" ]]; then
	# Check that --verify is documented in the header comments
	if grep -q '\-\-verify' "$COMPLETE_SCRIPT"; then
		pass "task-complete-helper.sh contains --verify flag"
	else
		fail "task-complete-helper.sh should contain --verify flag"
	fi

	# Check that --verify case branch exists in parse_args
	if grep -q "VERIFY_BRIEF=true" "$COMPLETE_SCRIPT"; then
		pass "task-complete-helper.sh has --verify implementation"
	else
		fail "task-complete-helper.sh should implement --verify"
	fi

	# Check that verify-brief.sh is called when --verify is set
	if grep -q "verify-brief.sh" "$COMPLETE_SCRIPT"; then
		pass "task-complete-helper.sh calls verify-brief.sh"
	else
		fail "task-complete-helper.sh should call verify-brief.sh"
	fi
else
	skip "task-complete-helper.sh not found"
fi

# ============================================================
# Summary
# ============================================================

echo ""
printf "\033[1m=== Summary ===\033[0m\n"
printf "  Total: %d  " "$TOTAL_COUNT"
printf "\033[0;32mPass: %d\033[0m  " "$PASS_COUNT"
printf "\033[0;31mFail: %d\033[0m  " "$FAIL_COUNT"
printf "\033[0;33mSkip: %d\033[0m\n" "$SKIP_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi
exit 0
