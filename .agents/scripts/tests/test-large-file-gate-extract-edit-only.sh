#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-extract-edit-only.sh — t2164 Fix A regression guard.
#
# `_large_file_gate_extract_paths()` in pulse-dispatch-large-file-gate.sh
# previously matched any backticked .sh/.py/.js/.ts path on a line starting
# with `- ` or `* ` (a list item). This conflated edit targets with context
# references — brief authors routinely cite related files for investigation
# context (e.g. as `grep -rn` search targets), and those citations were
# tripping the large-file gate.
#
# Concrete failure (GH#19415, t2152):
#   Brief listed `pulse-triage.sh:255-330` as the actual investigation target
#   (under threshold), but ALSO listed `.agents/scripts/issue-sync-helper.sh`
#   on a list item as a search target for step 4 (over threshold). The gate
#   matched the search target as if it were an edit target and held the
#   parent issue behind a needs-simplification label that pointed to a
#   phantom "recently-closed continuation" (#18706, whose merge PR actually
#   added +29 lines to the file).
#
# Fix (t2164): tighten the line filter from
#   ^\s*[-*]\s|^(EDIT|NEW|File):
# to
#   ^\s*[-*]\s+(EDIT|NEW|File):|^(EDIT|NEW|File):
# so backtick paths are only extracted when the line carries an explicit
# edit-intent prefix. Brief authors who declare intent get matched; brief
# authors who cite context for investigation do not.
#
# Tests:
#   1. List-item with no EDIT prefix       → NOT extracted (the bug)
#   2. List-item with EDIT prefix          → extracted (still works)
#   3. List-item with NEW prefix           → extracted
#   4. List-item with File prefix          → extracted
#   5. Bare EDIT line                      → extracted (branch 1 path)
#   6. Bare list-item with backtick path   → NOT extracted
#   7. Mixed brief (the GH#19415 shape)    → only EDIT-prefixed paths returned
#
# Cross-references: GH#19415 / t2152 (the blocked investigation that
# surfaced this bug), GH#19483 / t2164 (this fix).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# Source the gate module. It uses an include guard, so we only get one load
# per test process. LOGFILE is referenced via ${LOGFILE:-/dev/null} in this
# extractor's siblings but the extractor itself doesn't need it — we set
# it anyway so any later-sourced helper that does is safe.
LOGFILE="/dev/null"
export LOGFILE
# shellcheck source=/dev/null
source "$GATE_SCRIPT"

assert_extract_eq() {
	local test_name="$1"
	local body="$2"
	local expected="$3"

	local actual
	actual=$(_large_file_gate_extract_paths "$body" | sort | tr '\n' ',' | sed 's/,$//')
	local expected_sorted
	expected_sorted=$(printf '%s' "$expected" | tr ',' '\n' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected_sorted" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected: %q\n' "$expected_sorted"
	printf '       actual:   %q\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

printf '\n=== test-large-file-gate-extract-edit-only.sh (t2164 Fix A) ===\n\n'

# Test 1: list-item with no EDIT prefix → NOT extracted (the GH#19415 bug)
assert_extract_eq \
	"list-item without EDIT prefix → no extraction" \
	"- \`.agents/scripts/issue-sync-helper.sh\` — search for any path that adds something" \
	""

# Test 2: list-item with EDIT prefix → extracted (intent declared)
assert_extract_eq \
	"list-item with EDIT prefix → extracted" \
	"- EDIT: \`pulse-triage.sh\` — fix the gate" \
	"pulse-triage.sh"

# Test 3: list-item with NEW prefix → extracted
assert_extract_eq \
	"list-item with NEW prefix → extracted" \
	"- NEW: \`tests/test-foo.sh\` — regression coverage" \
	"tests/test-foo.sh"

# Test 4: list-item with File prefix → extracted
assert_extract_eq \
	"list-item with File prefix → extracted" \
	"- File: \`pulse-wrapper.sh\` — orchestrator" \
	"pulse-wrapper.sh"

# Test 5: bare EDIT line (no list marker) → extracted via branch 1
# Branch 1's regex requires "agents/scripts/" literally in the path,
# so use that form here.
assert_extract_eq \
	"bare EDIT line with agents/scripts path → extracted" \
	"EDIT: .agents/scripts/pulse-triage.sh" \
	".agents/scripts/pulse-triage.sh"

# Test 6: bare list-item backtick path (no prefix) → NOT extracted
assert_extract_eq \
	"bare list-item backtick path → no extraction" \
	"- \`pulse-triage.sh\` (mentioned in passing)" \
	""

# Test 7: mixed brief in the GH#19415 shape — only EDIT-prefixed paths returned.
# This is the canonical failing brief: the actual investigation file
# `pulse-triage.sh` is referenced with a line range so the gate's scoped-range
# handler skips it; the search-target file `issue-sync-helper.sh` (over
# threshold) is on a list item with no EDIT: prefix and must NOT be extracted.
GH19415_BRIEF=$(
	cat <<'EOF'
## What

Identify why `_issue_needs_consolidation` returned 0.

### Files to investigate

- `.agents/scripts/pulse-triage.sh:255-330` — `_issue_needs_consolidation` (the gate)
- `.agents/scripts/pulse-triage.sh:344-380` — `_reevaluate_consolidation_labels`
- `.agents/scripts/issue-sync-helper.sh` — search for any path that adds `needs-consolidation`

### Investigation steps

1. Reproduce the bot-type contract.
2. Audit the body-vs-comments contract.
EOF
)
assert_extract_eq \
	"GH#19415 brief shape → no extraction (regression for the actual bug)" \
	"$GH19415_BRIEF" \
	""

# Test 8: same brief but with proper EDIT: declarations → extracts only
# the declared edit targets, not the bare context references.
GH19415_FIXED_BRIEF=$(
	cat <<'EOF'
## What

Fix the gate.

### Files to modify

- EDIT: `.agents/scripts/pulse-triage.sh` — gate logic
- NEW: `.agents/scripts/tests/test-gate.sh` — regression test

### Reference (context only — must NOT be extracted)

- `.agents/scripts/issue-sync-helper.sh` — search target for cross-reference
EOF
)
assert_extract_eq \
	"brief with EDIT: declarations → extracts only declared targets" \
	"$GH19415_FIXED_BRIEF" \
	".agents/scripts/pulse-triage.sh,.agents/scripts/tests/test-gate.sh"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
