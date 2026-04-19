#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2219: PR body with For/Ref references must not
# trigger the issue-sync.yml title-fallback against the referenced issues.
#
# This test exercises the regex extraction and conditional skip logic
# from .github/workflows/issue-sync.yml in isolation (fixture-based,
# no act or Docker dependency).
set -euo pipefail

PASS=0
FAIL=0
RESULT_PREFIX_OK="PASS"
RESULT_PREFIX_BAD="FAIL"

# --- Helpers: simulate the extract step regexes ---
extract_for_ref() {
  local body="$1"
  echo "$body" | grep -oiE '(for|ref)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
  return 0
}

extract_linked() {
  local body="$1"
  echo "$body" | grep -oiE '(closes?|fixes?|resolves?)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
  return 0
}

# --- Helper: simulate the title-fallback skip check ---
# Returns 0 (skip) if FOUND is in FOR_REF_ISSUES, 1 (accept) otherwise.
should_skip_for_ref() {
  local found="$1"
  local for_ref_set="$2"
  if [[ " $for_ref_set " == *" $found "* ]]; then
    return 0
  fi
  return 1
}

# --- Single assertion function (avoids repeated-literal warnings) ---
check() {
  local ok="$1" tc="$2" detail="$3"
  if [[ "$ok" == "1" ]]; then
    PASS=$((PASS + 1)); echo "${RESULT_PREFIX_OK}: $tc"
  else
    FAIL=$((FAIL + 1)); echo "${RESULT_PREFIX_BAD}: $tc — $detail"
  fi
  return 0
}

# ============================================================
# Test 1: PR body with only For references
# ============================================================
PR_BODY_1='## Summary

Plans three follow-up tasks.

For #19692
For #19693
For #19694
'

linked_1=$(extract_linked "$PR_BODY_1")
fr_1=$(extract_for_ref "$PR_BODY_1")

[[ -z "${linked_1// /}" ]] && ok=1 || ok=0
check "$ok" "Test 1a: LINKED_ISSUES is empty for For-only body" "got '$linked_1'"

[[ "$fr_1" == "19692 19693 19694 " ]] && ok=1 || ok=0
check "$ok" "Test 1b: FOR_REF_ISSUES extracted correctly" "got '$fr_1'"

should_skip_for_ref "19692" "$fr_1" && ok=1 || ok=0
check "$ok" "Test 1c: title-fallback skips #19692 (in For/Ref set)" "should skip"

should_skip_for_ref "19693" "$fr_1" && ok=1 || ok=0
check "$ok" "Test 1d: title-fallback skips #19693 (in For/Ref set)" "should skip"

# ============================================================
# Test 2: PR body with Closes + For (mixed)
# ============================================================
PR_BODY_2='Resolves #100

For #200
Ref #300
'

linked_2=$(extract_linked "$PR_BODY_2")
fr_2=$(extract_for_ref "$PR_BODY_2")

[[ "$linked_2" == "100 " ]] && ok=1 || ok=0
check "$ok" "Test 2a: LINKED_ISSUES captures Resolves #100" "got '$linked_2'"

[[ "$fr_2" == "200 300 " ]] && ok=1 || ok=0
check "$ok" "Test 2b: FOR_REF_ISSUES captures For #200 and Ref #300" "got '$fr_2'"

# Title-fallback wouldn't fire here (LINKED_ISSUES is non-empty), but the
# skip check should still work correctly if called.
should_skip_for_ref "200" "$fr_2" && ok=1 || ok=0
check "$ok" "Test 2c: skip check works for #200 in mixed body" "should skip"

! should_skip_for_ref "100" "$fr_2" && ok=1 || ok=0
check "$ok" "Test 2d: skip check does NOT match #100 (Resolves, not For/Ref)" "should not skip"

# ============================================================
# Test 3: PR body with no For/Ref references
# ============================================================
PR_BODY_3='Closes #500

Regular PR body with no planning references.
'

fr_3=$(extract_for_ref "$PR_BODY_3")

[[ -z "${fr_3// /}" ]] && ok=1 || ok=0
check "$ok" "Test 3a: FOR_REF_ISSUES is empty when no For/Ref in body" "got '$fr_3'"

! should_skip_for_ref "500" "$fr_3" && ok=1 || ok=0
check "$ok" "Test 3b: skip check does NOT fire with empty For/Ref set" "should not skip"

# ============================================================
# Test 4: Case-insensitive For/Ref matching
# ============================================================
PR_BODY_4='FOR #10
for #20
Ref #30
REF #40
'

fr_4=$(extract_for_ref "$PR_BODY_4")
[[ "$fr_4" == "10 20 30 40 " ]] && ok=1 || ok=0
check "$ok" "Test 4a: case-insensitive For/Ref extraction" "got '$fr_4'"

# ============================================================
# Test 5: Issue NOT in For/Ref set should NOT be skipped
# ============================================================
! should_skip_for_ref "99999" "$fr_1" && ok=1 || ok=0
check "$ok" "Test 5a: issue not in For/Ref set is not skipped" "should not skip"

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
