#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-verify-brief.sh — t2409 regression tests for Pre-flight validation.
#
# Asserts:
#   1. A brief missing the Pre-flight block is rejected by verify-brief.sh
#   2. A brief with placeholder Pre-flight text is rejected
#   3. A brief with populated Pre-flight passes
#   4. A brief claiming tier:simple with >2 files is rejected
#   5. verify-brief-helper.sh check-preflight rejects missing section
#   6. verify-brief-helper.sh check-preflight rejects placeholders
#   7. verify-brief-helper.sh check-preflight passes populated brief

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Create temp directory for fixtures
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Initialize a minimal git repo so verify-brief.sh can resolve repo path
mkdir -p "${TEST_ROOT}/repo"
(cd "${TEST_ROOT}/repo" && git init -q 2>/dev/null) || true

# ============================================================================
# Fixture: brief with NO Pre-flight section
# ============================================================================
cat > "${TEST_ROOT}/brief-no-preflight.md" << 'BRIEF_EOF'
---
mode: subagent
---

# t9999: Test Task

## Origin

- **Created:** 2026-04-20

## What

Test deliverable.

## Acceptance Criteria

- [ ] Something works
BRIEF_EOF

# ============================================================================
# Fixture: brief with PLACEHOLDER Pre-flight section
# ============================================================================
cat > "${TEST_ROOT}/brief-placeholder.md" << 'BRIEF_EOF'
---
mode: subagent
---

# t9999: Test Task

## Pre-flight (auto-populated by briefing workflow)

- [ ] Memory recall: `<query>` -> `<N>` hits | no results
- [ ] Discovery pass: `<N>` commits / `<N>` merged PRs / `<N>` open PRs touch target files since `<date>`
- [ ] File refs verified: `<N>` refs checked, all present | `<N>` missing (list)
- [ ] Tier: `<tier>` -- disqualifier check clean | disqualified from `<tier>` because `<reason>`

## Origin

- **Created:** 2026-04-20

## What

Test deliverable.

## Acceptance Criteria

- [ ] Something works
BRIEF_EOF

# ============================================================================
# Fixture: brief with POPULATED Pre-flight section
# ============================================================================
cat > "${TEST_ROOT}/brief-populated.md" << 'BRIEF_EOF'
---
mode: subagent
---

# t9999: Test Task

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `brief workflow` -> 2 hits, reviewed relevant lessons
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files since 2026-04-18
- [x] File refs verified: 3 refs checked, all present
- [x] Tier: `tier:standard` -- disqualifier check clean

## Origin

- **Created:** 2026-04-20

## What

Test deliverable.

## Acceptance Criteria

- [ ] Something works
BRIEF_EOF

# ============================================================================
# Fixture: brief with tier:simple but >2 files
# ============================================================================
cat > "${TEST_ROOT}/brief-tier-mismatch.md" << 'BRIEF_EOF'
---
mode: subagent
---

# t9999: Test Task

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `tier test` -> no results
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files since 2026-04-18
- [x] File refs verified: 3 refs checked, all present
- [x] Tier: `tier:simple` -- disqualifier check clean

## Origin

- **Created:** 2026-04-20

## Tier

**Selected tier:** `tier:simple`

## How (Approach)

### Files to Modify

- `EDIT: src/foo.ts:10-20` -- change A
- `EDIT: src/bar.ts:30-40` -- change B
- `NEW: src/baz.ts` -- new file

### Implementation Steps

1. Do something.

### Verification

```bash
echo "ok"
```

## Acceptance Criteria

- [ ] Something works
BRIEF_EOF

# ============================================================================
# Test 1: verify-brief.sh rejects brief missing Pre-flight
# ============================================================================
test_verify_brief_rejects_missing_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief.sh" "${TEST_ROOT}/brief-no-preflight.md" \
		--repo-path "${TEST_ROOT}/repo" >/dev/null 2>&1 || rc=$?
	# Should fail (exit 1) because Pre-flight is missing
	if [[ $rc -ne 0 ]]; then
		print_result "verify-brief.sh rejects missing Pre-flight" 0
	else
		print_result "verify-brief.sh rejects missing Pre-flight" 1 "(expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test 2: verify-brief.sh rejects brief with placeholder Pre-flight
# ============================================================================
test_verify_brief_rejects_placeholder_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief.sh" "${TEST_ROOT}/brief-placeholder.md" \
		--repo-path "${TEST_ROOT}/repo" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		print_result "verify-brief.sh rejects placeholder Pre-flight" 0
	else
		print_result "verify-brief.sh rejects placeholder Pre-flight" 1 "(expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test 3: verify-brief.sh passes brief with populated Pre-flight
# ============================================================================
test_verify_brief_passes_populated_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief.sh" "${TEST_ROOT}/brief-populated.md" \
		--repo-path "${TEST_ROOT}/repo" >/dev/null 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "verify-brief.sh passes populated Pre-flight" 0
	else
		print_result "verify-brief.sh passes populated Pre-flight" 1 "(expected exit 0, got $rc)"
	fi
	return 0
}

# ============================================================================
# Test 4: verify-brief.sh rejects tier:simple with >2 files
# ============================================================================
test_verify_brief_rejects_tier_mismatch() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief.sh" "${TEST_ROOT}/brief-tier-mismatch.md" \
		--repo-path "${TEST_ROOT}/repo" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		print_result "verify-brief.sh rejects tier:simple with >2 files" 0
	else
		print_result "verify-brief.sh rejects tier:simple with >2 files" 1 "(expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test 5: verify-brief-helper.sh check-preflight rejects missing section
# ============================================================================
test_helper_rejects_missing_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief-helper.sh" check-preflight \
		"${TEST_ROOT}/brief-no-preflight.md" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		print_result "helper check-preflight rejects missing section" 0
	else
		print_result "helper check-preflight rejects missing section" 1 "(expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test 6: verify-brief-helper.sh check-preflight rejects placeholders
# ============================================================================
test_helper_rejects_placeholder_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief-helper.sh" check-preflight \
		"${TEST_ROOT}/brief-placeholder.md" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		print_result "helper check-preflight rejects placeholders" 0
	else
		print_result "helper check-preflight rejects placeholders" 1 "(expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test 7: verify-brief-helper.sh check-preflight passes populated brief
# ============================================================================
test_helper_passes_populated_preflight() {
	local rc=0
	bash "${TEST_SCRIPTS_DIR}/verify-brief-helper.sh" check-preflight \
		"${TEST_ROOT}/brief-populated.md" >/dev/null 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "helper check-preflight passes populated brief" 0
	else
		print_result "helper check-preflight passes populated brief" 1 "(expected exit 0, got $rc)"
	fi
	return 0
}

# ============================================================================
# Run all tests
# ============================================================================
main() {
	printf '=== test-verify-brief.sh (t2409) ===\n\n'

	test_verify_brief_rejects_missing_preflight
	test_verify_brief_rejects_placeholder_preflight
	test_verify_brief_passes_populated_preflight
	test_verify_brief_rejects_tier_mismatch
	test_helper_rejects_missing_preflight
	test_helper_rejects_placeholder_preflight
	test_helper_passes_populated_preflight

	printf '\n--- Summary ---\n'
	printf 'Tests: %d  Failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ $TESTS_FAILED -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
