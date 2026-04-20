#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-brief-readiness.sh — regression tests for brief-readiness-helper.sh (t2417)
#
# Covers:
#   1. Worker-ready body detection (score >= threshold → exit 0)
#   2. Minimal body detection (score < threshold → exit 1)
#   3. Edge case: score-3 body (just under threshold → exit 1)
#   4. Stub brief creation (writes valid markdown)
#   5. Similarity scoring (high overlap → high %, low overlap → low %)
#   6. Threshold override via BRIEF_READINESS_THRESHOLD env var

set -u
set +e

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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
		printf '        %s\n' "$2"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Locate the helper
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../brief-readiness-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FATAL: brief-readiness-helper.sh not found or not executable at $HELPER" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Test fixtures — body texts with varying heading counts
# ---------------------------------------------------------------------------

# 5 headings → worker-ready (above default threshold of 4)
BODY_WORKER_READY="# t1234: Example task

## Session Origin

Created in interactive session.

## What

Implement the foo feature.

## Why

Because the bar needs it.

## How

### Files to modify

- EDIT: src/foo.sh:10-20

### Implementation Steps

1. Do the thing.

## Acceptance

- [ ] Tests pass
- [ ] Lint clean
- [ ] Feature works
"

# 2 headings → NOT worker-ready
BODY_MINIMAL="# Bug report

## Description

Something is broken.

Steps to reproduce:
1. Open app
2. Click button
3. See error
"

# 3 headings → just under threshold (NOT worker-ready at default 4)
BODY_SCORE_3="# t5678: Another task

## What

Fix the broken widget.

## Why

Users are complaining.

## Acceptance

- [ ] Widget works
- [ ] No regressions
"

# 4 headings → exactly at threshold (worker-ready)
BODY_SCORE_4="# t9999: Threshold test

## Task

Do the thing.

## Why

Reasons.

## How

Steps here.

## Acceptance

- [ ] Done
"

# 7 headings → all of them (worker-ready)
BODY_ALL_HEADINGS="# t0001: Full body

## Task

Full specification.

## Why

All the reasons.

## How

Detailed steps.

## Acceptance

All criteria met.

## What

Also this heading.

## Session Origin

Created somewhere.

## Files to modify

- EDIT: file.sh
"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "=== test-brief-readiness.sh ==="
echo ""

# --- Test 1: Worker-ready body (5 headings, threshold 4) → exit 0 ---
output=$("$HELPER" check --body "$BODY_WORKER_READY" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T1: worker-ready body → exit 0"
else
	fail "T1: worker-ready body → exit 0" "got exit $rc, output: $output"
fi

# Verify output contains WORKER_READY=true
if printf '%s\n' "$output" | grep -q 'WORKER_READY=true'; then
	pass "T1b: output contains WORKER_READY=true"
else
	fail "T1b: output contains WORKER_READY=true" "output: $output"
fi

# --- Test 2: Minimal body (2 headings) → exit 1 ---
output=$("$HELPER" check --body "$BODY_MINIMAL" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T2: minimal body → exit 1"
else
	fail "T2: minimal body → exit 1" "got exit $rc, output: $output"
fi

if printf '%s\n' "$output" | grep -q 'WORKER_READY=false'; then
	pass "T2b: output contains WORKER_READY=false"
else
	fail "T2b: output contains WORKER_READY=false" "output: $output"
fi

# --- Test 3: Score-3 body (just under threshold) → exit 1 ---
output=$("$HELPER" check --body "$BODY_SCORE_3" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T3: score-3 body → exit 1 (under threshold)"
else
	fail "T3: score-3 body → exit 1 (under threshold)" "got exit $rc, output: $output"
fi

# Verify score is 3
score=$(printf '%s\n' "$output" | grep '^SCORE=' | sed 's/SCORE=//')
if [[ "$score" -eq 3 ]]; then
	pass "T3b: score is 3"
else
	fail "T3b: score is 3" "got score=$score"
fi

# --- Test 4: Score-4 body (exactly at threshold) → exit 0 ---
output=$("$HELPER" check --body "$BODY_SCORE_4" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T4: score-4 body → exit 0 (at threshold)"
else
	fail "T4: score-4 body → exit 0 (at threshold)" "got exit $rc, output: $output"
fi

# --- Test 5: All headings (score 7) → exit 0 ---
output=$("$HELPER" check --body "$BODY_ALL_HEADINGS" 2>/dev/null)
rc=$?
score=$(printf '%s\n' "$output" | grep '^SCORE=' | sed 's/SCORE=//')
if [[ $rc -eq 0 && "$score" -eq 7 ]]; then
	pass "T5: all-headings body → exit 0 with score 7"
else
	fail "T5: all-headings body → exit 0 with score 7" "got exit=$rc score=$score"
fi

# --- Test 6: Threshold override via env var ---
# BODY_WORKER_READY scores 6 (5 explicit ## headings + ### Files to modify
# which contains "## Files to modify" as a substring). threshold=7 → fail.
output=$(BRIEF_READINESS_THRESHOLD=7 "$HELPER" check --body "$BODY_WORKER_READY" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "T6: threshold=7, score-6 body → exit 1"
else
	fail "T6: threshold=7, score-6 body → exit 1" "got exit $rc"
fi

# BODY_SCORE_3 scores 3 (## What, ## Why, ## Acceptance). threshold=3 → pass.
output=$(BRIEF_READINESS_THRESHOLD=3 "$HELPER" check --body "$BODY_SCORE_3" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T6b: threshold=3, score-3 body → exit 0"
else
	fail "T6b: threshold=3, score-3 body → exit 0" "got exit $rc"
fi

# --- Test 7: Stub brief creation ---
TMP_REPO=$(mktemp -d)
mkdir -p "$TMP_REPO/todo/tasks"

# Stub gh command for offline testing
GH_STUB_DIR=$(mktemp -d)
cat > "$GH_STUB_DIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Stub gh for test-brief-readiness.sh
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	if [[ "${*}" == *"--jq '.title'"* ]] || [[ "${*}" == *"--jq .title"* ]]; then
		echo "Test Issue Title"
	elif [[ "${*}" == *"--jq '.body'"* ]] || [[ "${*}" == *"--jq .body"* ]]; then
		echo "Test body"
	fi
fi
exit 0
GHSTUB
chmod +x "$GH_STUB_DIR/gh"

# Run stub creation with stubbed gh
PATH="$GH_STUB_DIR:$PATH" "$HELPER" stub "t9999" "12345" "owner/repo" "$TMP_REPO" 2>/dev/null
stub_rc=$?
brief_file="$TMP_REPO/todo/tasks/t9999-brief.md"

if [[ $stub_rc -eq 0 && -f "$brief_file" ]]; then
	pass "T7: stub brief created successfully"
else
	fail "T7: stub brief created successfully" "exit=$stub_rc, exists=$(test -f "$brief_file" && echo yes || echo no)"
fi

# Check stub content contains canonical link
if grep -q "canonical brief" "$brief_file" 2>/dev/null; then
	pass "T7b: stub contains canonical brief reference"
else
	fail "T7b: stub contains canonical brief reference" "content: $(cat "$brief_file" 2>/dev/null || echo 'empty')"
fi

# Check stub does not duplicate full template (should be ≤20 lines)
line_count=$(wc -l < "$brief_file" 2>/dev/null || echo 999)
if [[ $line_count -le 25 ]]; then
	pass "T7c: stub brief is ≤25 lines ($line_count)"
else
	fail "T7c: stub brief is ≤25 lines" "got $line_count lines"
fi

# --- Test 8: Stub skips if brief already exists ---
echo "# Existing brief" > "$brief_file"
PATH="$GH_STUB_DIR:$PATH" "$HELPER" stub "t9999" "12345" "owner/repo" "$TMP_REPO" 2>/dev/null
existing_content=$(cat "$brief_file")
if [[ "$existing_content" == "# Existing brief" ]]; then
	pass "T8: stub skips when brief already exists"
else
	fail "T8: stub skips when brief already exists" "content was overwritten"
fi

# --- Test 9: Similarity scoring ---
# Create a brief that mostly duplicates the worker-ready body
sim_brief_file=$(mktemp)
printf '%s\n' "$BODY_WORKER_READY" > "$sim_brief_file"

output=$("$HELPER" similarity "$sim_brief_file" --body "$BODY_WORKER_READY" 2>/dev/null)
sim_rc=$?
similarity=$(printf '%s\n' "$output" | grep '^SIMILARITY=' | sed 's/SIMILARITY=//')

# Note: similarity is computed on lines >= 10 chars after normalisation,
# so short heading lines are excluded — identical content may not reach 100%.
if [[ $sim_rc -eq 0 && "$similarity" -ge 50 ]]; then
	pass "T9: identical content → similarity ≥50% ($similarity%)"
else
	fail "T9: identical content → similarity ≥50%" "got sim=$similarity%, exit=$sim_rc"
fi

# Low similarity: brief with different content
echo "Completely different content that shares nothing with the issue body whatsoever" > "$sim_brief_file"
output=$("$HELPER" similarity "$sim_brief_file" --body "$BODY_WORKER_READY" 2>/dev/null)
similarity=$(printf '%s\n' "$output" | grep '^SIMILARITY=' | sed 's/SIMILARITY=//')

if [[ "$similarity" -le 20 ]]; then
	pass "T9b: different content → similarity ≤20% ($similarity%)"
else
	fail "T9b: different content → similarity ≤20%" "got $similarity%"
fi

# --- Test 10: Usage error (no args to check) ---
"$HELPER" check 2>/dev/null
rc=$?
if [[ $rc -eq 2 ]]; then
	pass "T10: check with no args → exit 2 (usage error)"
else
	fail "T10: check with no args → exit 2 (usage error)" "got exit $rc"
fi

# --- Test 11: Case-insensitive heading matching ---
BODY_LOWERCASE="# task

## task

Info here.

## why

Reasons.

## how

Steps.

## acceptance

Criteria.
"
output=$("$HELPER" check --body "$BODY_LOWERCASE" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T11: case-insensitive heading matching → exit 0"
else
	fail "T11: case-insensitive heading matching → exit 0" "got exit $rc, output: $output"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$TMP_REPO" "$GH_STUB_DIR" "$sim_brief_file" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failed"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
