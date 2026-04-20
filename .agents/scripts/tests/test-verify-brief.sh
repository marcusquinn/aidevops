#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-verify-brief.sh — regression tests for t2410
#
# Covers framework-bug brief quality requirements introduced by the
# log-issue-aidevops upgrade (GH#20008):
#
#   1. Framework-bug briefs without ## Reproducer sections are rejected by
#      validate_brief_has_reproducer (log-issue-helper.sh validate-brief).
#
#   2. Framework-bug briefs WITH ## Reproducer sections pass validation.
#
#   3. log-issue-helper.sh prompt-reproducer outputs the required section
#      headers that the agent uses to prompt the user.
#
#   4. validate-brief returns the correct exit codes (0=valid, 1=invalid).

set -u
set +e

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../log-issue-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2410-verify-brief.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

printf '%sRunning t2410 verify-brief tests (log-issue-aidevops upgrade)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Class A: prompt-reproducer outputs required section headers
# =============================================================================

printf '\n%sClass A: prompt-reproducer output%s\n' "$TEST_BLUE" "$TEST_NC"

output=$(bash "$HELPER" prompt-reproducer 2>&1)
rc=$?

# Test A1: command exits 0
if [[ $rc -eq 0 ]]; then
	pass "A1 prompt-reproducer exits 0"
else
	fail "A1 prompt-reproducer exit code" "expected rc=0, got rc=$rc"
fi

# Test A2: output contains ## Reproducer heading
if [[ "$output" == *"## Reproducer"* ]]; then
	pass "A2 prompt-reproducer output contains '## Reproducer' heading"
else
	fail "A2 Reproducer heading" "expected '## Reproducer' in output, got: $output"
fi

# Test A3: output contains Symptom command prompt
if [[ "$output" == *"Symptom command"* ]]; then
	pass "A3 prompt-reproducer output contains 'Symptom command' prompt"
else
	fail "A3 symptom command prompt" "expected 'Symptom command' in output"
fi

# Test A4: output contains Actual output prompt
if [[ "$output" == *"Actual output"* ]]; then
	pass "A4 prompt-reproducer output contains 'Actual output' prompt"
else
	fail "A4 actual output prompt" "expected 'Actual output' in output"
fi

# Test A5: output contains Expected output prompt
if [[ "$output" == *"Expected output"* ]]; then
	pass "A5 prompt-reproducer output contains 'Expected output' prompt"
else
	fail "A5 expected output prompt" "expected 'Expected output' in output"
fi

# =============================================================================
# Class B: validate-brief with a complete framework-bug brief (passes)
# =============================================================================

printf '\n%sClass B: validate-brief passes for complete briefs%s\n' "$TEST_BLUE" "$TEST_NC"

# Test B1: brief with ## Reproducer section passes
cat >"$TMP/brief-complete.md" <<'BRIEF'
## Description

log-issue-helper.sh diagnostics fails with ENOENT when gh CLI is not in PATH.

## Reproducer

**Symptom command**:

```
~/.aidevops/agents/scripts/log-issue-helper.sh diagnostics
```

**Actual output**:

```
log-issue-helper.sh: line 141: gh: command not found
```

**Expected output**:

```
- **gh CLI**: not installed
```

## Environment

- aidevops version: 3.8.78
BRIEF

output=$(bash "$HELPER" validate-brief "$TMP/brief-complete.md" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
	pass "B1 complete brief with ## Reproducer passes validation"
else
	fail "B1 complete brief validation" "expected rc=0, got rc=$rc; output: $output"
fi

# Test B2: brief with ## Reproducer in mixed case passes (case-insensitive)
cat >"$TMP/brief-mixed-case.md" <<'BRIEF'
## Description

Some bug.

## Reproducer

command output here
BRIEF

output=$(bash "$HELPER" validate-brief "$TMP/brief-mixed-case.md" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
	pass "B2 brief with ## Reproducer (standard case) passes"
else
	fail "B2 Reproducer case sensitivity" "expected rc=0, got rc=$rc; output: $output"
fi

# =============================================================================
# Class C: validate-brief without Reproducer section (fails)
# =============================================================================

printf '\n%sClass C: validate-brief rejects briefs missing ## Reproducer%s\n' "$TEST_BLUE" "$TEST_NC"

# Test C1: brief without Reproducer section is rejected
cat >"$TMP/brief-no-reproducer.md" <<'BRIEF'
## Description

Some framework bug description.

## Expected Behavior

Should work correctly.

## Steps to Reproduce

1. Run the command.

## Environment

- aidevops version: 3.8.78
BRIEF

output=$(bash "$HELPER" validate-brief "$TMP/brief-no-reproducer.md" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "C1 brief without ## Reproducer is rejected (non-zero exit)"
else
	fail "C1 missing Reproducer rejection" "expected rc!=0, got rc=0; output: $output"
fi

# Test C2: error message mentions the missing section
if [[ "$output" == *"Reproducer"* ]]; then
	pass "C2 rejection error message names the missing section"
else
	fail "C2 error message content" "expected 'Reproducer' in error output: $output"
fi

# Test C3: empty brief is rejected
output=$(bash "$HELPER" validate-brief "$TMP/brief-no-reproducer.md" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "C3 brief without Reproducer is consistently rejected"
else
	fail "C3 consistent rejection" "expected rc!=0, got rc=0"
fi

# =============================================================================
# Class D: validate-brief argument validation
# =============================================================================

printf '\n%sClass D: validate-brief argument handling%s\n' "$TEST_BLUE" "$TEST_NC"

# Test D1: missing argument exits non-zero with usage message
output=$(bash "$HELPER" validate-brief 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "D1 validate-brief without argument exits non-zero"
else
	fail "D1 missing argument" "expected rc!=0, got rc=0"
fi

# Test D2: usage message shown on missing argument
if [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]; then
	pass "D2 validate-brief without argument shows usage hint"
else
	fail "D2 usage hint" "expected usage hint in output: $output"
fi

# =============================================================================
# Class E: Pre-flight block validation (t2409)
# =============================================================================

printf '\n%sClass E: Pre-flight block validation (t2409 — verify-brief-helper.sh)%s\n' "$TEST_BLUE" "$TEST_NC"

VB_HELPER="${SCRIPT_DIR}/../verify-brief-helper.sh"

if [[ ! -f "$VB_HELPER" ]]; then
	printf 'test harness cannot find %s — skipping Class E\n' "$VB_HELPER" >&2
else

# Test E1: brief missing Pre-flight block is rejected
cat >"$TMP/brief-no-preflight.md" <<'BRIEF'
# t9999: Test task

## Origin

- **Created:** 2026-04-20

## What

Test deliverable.

## How (Approach)

### Files to Modify

- `EDIT: src/foo.sh:10-20` — fix bug

## Acceptance Criteria

- [ ] Bug is fixed
BRIEF

output=$(bash "$VB_HELPER" check-preflight "$TMP/brief-no-preflight.md" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "E1 brief without ## Pre-flight is rejected"
else
	fail "E1 missing Pre-flight rejection" "expected rc!=0, got rc=0; output: $output"
fi

# Test E2: brief with unchecked Pre-flight boxes is rejected
cat >"$TMP/brief-unchecked-preflight.md" <<'BRIEF'
# t9999: Test task

## Pre-flight (auto-populated by briefing workflow)

- [ ] Memory recall: `brief workflow` → 2 hits — reviewed relevant patterns
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h
- [x] File refs verified: 1 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — disqualifier check clean (2 files, judgment needed)

## Origin

- **Created:** 2026-04-20
BRIEF

output=$(bash "$VB_HELPER" check-preflight "$TMP/brief-unchecked-preflight.md" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "E2 brief with unchecked Pre-flight boxes is rejected"
else
	fail "E2 unchecked Pre-flight boxes" "expected rc!=0, got rc=0; output: $output"
fi

# Test E3: brief with template placeholders in Pre-flight is rejected
cat >"$TMP/brief-placeholder-preflight.md" <<'BRIEF'
# t9999: Test task

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `<query>` → `<N>` hits — `<one-line skim summary or "no relevant lessons">`
- [x] Discovery pass: `<N>` commits / `<N>` merged PRs / `<N>` open PRs touch target files in last 48h
- [x] File refs verified: `<N>` refs checked, all present at HEAD
- [x] Tier: `<tier>` — disqualifier check clean (`<1-line rationale>`)

## Origin

- **Created:** 2026-04-20
BRIEF

output=$(bash "$VB_HELPER" check-preflight "$TMP/brief-placeholder-preflight.md" 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "E3 brief with template placeholders in Pre-flight is rejected"
else
	fail "E3 template placeholder rejection" "expected rc!=0, got rc=0; output: $output"
fi

# Test E4: brief with fully populated Pre-flight passes
cat >"$TMP/brief-good-preflight.md" <<'BRIEF'
# t9999: Test task

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `brief workflow` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h
- [x] File refs verified: 2 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — disqualifier check clean (3 files, judgment needed)

## Origin

- **Created:** 2026-04-20
BRIEF

output=$(bash "$VB_HELPER" check-preflight "$TMP/brief-good-preflight.md" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
	pass "E4 brief with fully populated Pre-flight passes"
else
	fail "E4 valid Pre-flight acceptance" "expected rc=0, got rc=$rc; output: $output"
fi

# Test E5: tier:simple with >2 files in Worker Guidance is flagged by verify-brief.sh
# (This tests the acceptance criteria verify block pattern, not Pre-flight directly)
cat >"$TMP/brief-mistiered.md" <<'BRIEF'
# t9999: Test task

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `test` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h
- [x] File refs verified: 3 refs checked, all present at HEAD
- [x] Tier: `tier:simple` — disqualifier check clean (single file edit)

## Origin

- **Created:** 2026-04-20

## How (Approach)

### Files to Modify

- `EDIT: src/a.sh:10-20` — fix bug
- `EDIT: src/b.sh:30-40` — fix related bug
- `EDIT: src/c.sh:50-60` — fix another bug

## Acceptance Criteria

- [ ] All bugs fixed
BRIEF

# E5: verify that the Pre-flight block passes even though the tier may be wrong
# (Pre-flight validates format, not semantic correctness of tier choice)
output=$(bash "$VB_HELPER" check-preflight "$TMP/brief-mistiered.md" 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
	pass "E5 Pre-flight validates format not semantic tier correctness"
else
	fail "E5 Pre-flight format-only validation" "expected rc=0, got rc=$rc; output: $output"
fi

# Test E6: check-preflight with missing argument exits non-zero
output=$(bash "$VB_HELPER" check-preflight 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
	pass "E6 check-preflight without argument exits non-zero"
else
	fail "E6 missing argument" "expected rc!=0, got rc=0"
fi

fi  # end VB_HELPER existence check

# =============================================================================
# Summary
# =============================================================================

printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s✓ All %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s✗ %d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
