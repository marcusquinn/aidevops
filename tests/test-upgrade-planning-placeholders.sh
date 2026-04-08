#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-upgrade-planning-placeholders.sh
#
# Regression test for GH#17804: upgrade-planning must not extract template
# placeholder task IDs (tXXX, tYYY, tZZZ) from the Format section as real tasks.
#
# Usage: bash tests/test-upgrade-planning-placeholders.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

summary() {
	echo ""
	printf "Results: %d passed, %d failed, %d total\n" "$PASS_COUNT" "$FAIL_COUNT" "$TOTAL_COUNT"
	if [[ "$FAIL_COUNT" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# --- Fixtures ---

# Create a v1.0-style TODO.md with format examples that look like tasks
# This simulates the scenario where format examples are outside code blocks
# and inside the Backlog section (or where the parser doesn't respect code blocks)
create_fixture_v1_with_format_in_backlog() {
	local dir="$1"
	cat >"$dir/TODO.md" <<'FIXTURE'
# TODO

## Format

**Human-readable:**

```markdown
- [ ] tXXX Task description @owner #tag ~4h (ai:2h test:1h read:30m) logged:2025-01-15
- [ ] tYYY Dependent task blocked-by:tXXX ~2h
- [ ] tXXX.1 Subtask of tXXX ~1h
- [x] tZZZ Completed task ~2h actual:1.5h logged:2025-01-10 completed:2025-01-15
```

## Backlog

- [ ] t001 Real task one @dev #feature ~2h logged:2025-06-01
- [ ] t002 Real task two blocked-by:t001 ~1h logged:2025-06-02
- [x] t003 Completed real task ~30m actual:25m completed:2025-06-03

## In Progress

## Done
FIXTURE
	return 0
}

# Create a v1.0-style TODO.md where format examples leaked into Backlog
# (simulates the actual bug scenario)
create_fixture_v1_format_leaked_to_backlog() {
	local dir="$1"
	cat >"$dir/TODO.md" <<'FIXTURE'
# TODO

## Format

**Human-readable:**

Format: `- [ ] tNNN Description @owner #tag ~estimate`

## Backlog

- [ ] tXXX Task description @owner #tag ~4h (ai:2h test:1h read:30m) logged:2025-01-15
- [ ] tYYY Dependent task blocked-by:tXXX ~2h
- [ ] tXXX.1 Subtask of tXXX ~1h
- [x] tZZZ Completed task ~2h actual:1.5h logged:2025-01-10 completed:2025-01-15
- [ ] t001 Real task one @dev #feature ~2h logged:2025-06-01
- [ ] t002 Real task two blocked-by:t001 ~1h logged:2025-06-02

## In Progress

## Done
FIXTURE
	return 0
}

# Create a TODO.md with only real numeric tasks (no placeholders)
create_fixture_clean() {
	local dir="$1"
	cat >"$dir/TODO.md" <<'FIXTURE'
# TODO

## Format

**Human-readable:**

Format: `- [ ] tNNN Description @owner #tag ~estimate`

## Backlog

- [ ] t001 Real task one @dev #feature ~2h logged:2025-06-01
- [ ] t002 Real task two blocked-by:t001 ~1h logged:2025-06-02
- [ ] t001.1 Subtask of t001 ~30m logged:2025-06-03
- [x] t003 Completed real task ~30m actual:25m completed:2025-06-03

### Subsection Header

- [ ] t004 Task in subsection ~1h logged:2025-06-04

## In Progress

## Done
FIXTURE
	return 0
}

# --- Extract the awk logic from aidevops.sh for testing ---
# This mirrors the extraction + filtering logic in _upgrade_todo()

extract_and_filter_tasks() {
	local todo_file="$1"

	# Step 1: Section-aware extraction (skip ## Format, skip code blocks)
	local existing_tasks
	existing_tasks=$(awk '
		# Section-aware: track when inside ## Format to skip its content
		/^## Format/ { in_format=1; next }
		in_format && /^## / { in_format=0 }
		in_format { next }
		# Also skip content inside markdown code blocks (``` fenced blocks)
		/^```/ { in_codeblock = !in_codeblock; next }
		in_codeblock { next }
		# Extract from ## Backlog to next ## header
		/^## Backlog/ { found=1; next }
		found && /^## / { exit }
		found
	' "$todo_file" 2>/dev/null || echo "")

	# Step 2: Filter out non-numeric task IDs
	if [[ -n "$existing_tasks" ]]; then
		existing_tasks=$(printf '%s\n' "$existing_tasks" | awk '
			# Keep non-task lines (subsection headers, comments, blank lines)
			!/^- \[[ x-]\] t/ { print; next }
			# For task lines: extract the ID and validate it is numeric
			{
				id = $0
				sub(/^- \[[ x-]\] /, "", id)
				sub(/ .*/, "", id)
				# Valid IDs: t followed by digits, optionally .digits (subtasks)
				if (id ~ /^t[0-9]+(\.[0-9]+)*$/) print
			}
		')
	fi

	printf '%s\n' "$existing_tasks"
	return 0
}

# --- Tests ---

echo "=== GH#17804: upgrade-planning placeholder extraction regression tests ==="
echo ""

# Test 1: Format examples in code block should not be extracted
echo "Test 1: Format examples inside code blocks are skipped"
TMPDIR1=$(mktemp -d)
trap 'rm -rf "$TMPDIR1"' EXIT
create_fixture_v1_with_format_in_backlog "$TMPDIR1"
result=$(extract_and_filter_tasks "$TMPDIR1/TODO.md")
if echo "$result" | grep -q "tXXX\|tYYY\|tZZZ"; then
	fail "Placeholder IDs found in extracted tasks" "$(echo "$result" | grep 'tXXX\|tYYY\|tZZZ')"
else
	pass "No placeholder IDs in extracted tasks"
fi
# Verify real tasks ARE preserved
if echo "$result" | grep -q "t001 Real task one"; then
	pass "Real task t001 preserved"
else
	fail "Real task t001 missing from extracted tasks"
fi
if echo "$result" | grep -q "t002 Real task two"; then
	pass "Real task t002 preserved"
else
	fail "Real task t002 missing from extracted tasks"
fi
if echo "$result" | grep -q "t003 Completed real task"; then
	pass "Completed task t003 preserved"
else
	fail "Completed task t003 missing from extracted tasks"
fi

# Test 2: Placeholder IDs leaked into Backlog are filtered out
echo ""
echo "Test 2: Placeholder IDs in Backlog section are filtered by ID validator"
TMPDIR2=$(mktemp -d)
trap 'rm -rf "$TMPDIR1" "$TMPDIR2"' EXIT
create_fixture_v1_format_leaked_to_backlog "$TMPDIR2"
result2=$(extract_and_filter_tasks "$TMPDIR2/TODO.md")
if echo "$result2" | grep -q "tXXX\|tYYY\|tZZZ"; then
	fail "Placeholder IDs found in extracted tasks" "$(echo "$result2" | grep 'tXXX\|tYYY\|tZZZ')"
else
	pass "No placeholder IDs in extracted tasks"
fi
# Verify real tasks ARE preserved
if echo "$result2" | grep -q "t001 Real task one"; then
	pass "Real task t001 preserved"
else
	fail "Real task t001 missing from extracted tasks"
fi
if echo "$result2" | grep -q "t002 Real task two"; then
	pass "Real task t002 preserved"
else
	fail "Real task t002 missing from extracted tasks"
fi

# Test 3: Clean TODO.md with only real tasks — all preserved
echo ""
echo "Test 3: Clean TODO.md with only real numeric tasks — all preserved"
TMPDIR3=$(mktemp -d)
trap 'rm -rf "$TMPDIR1" "$TMPDIR2" "$TMPDIR3"' EXIT
create_fixture_clean "$TMPDIR3"
result3=$(extract_and_filter_tasks "$TMPDIR3/TODO.md")
task_count=$(echo "$result3" | grep -c '^- \[' || true)
if [[ "$task_count" -eq 5 ]]; then
	pass "All 5 real tasks preserved (t001, t002, t001.1, t003, t004)"
else
	fail "Expected 5 tasks, got $task_count" "$result3"
fi
# Verify subtask preserved
if echo "$result3" | grep -q "t001.1 Subtask of t001"; then
	pass "Subtask t001.1 preserved"
else
	fail "Subtask t001.1 missing from extracted tasks"
fi
# Verify subsection header preserved
if echo "$result3" | grep -q "### Subsection Header"; then
	pass "Subsection header preserved"
else
	fail "Subsection header missing from extracted tasks"
fi

# Test 4: Template itself has no extractable task lines
echo ""
echo "Test 4: Updated template has no extractable task-like lines outside HTML comments"
template_file="$REPO_DIR/.agents/templates/todo-template.md"
if [[ -f "$template_file" ]]; then
	# Extract lines that look like tasks but are NOT inside HTML comments or code blocks
	leaked_tasks=$(awk '
		/^<!--/ { in_comment=1 }
		/-->/ { if (in_comment) { in_comment=0; next } }
		in_comment { next }
		/^```/ { in_codeblock = !in_codeblock; next }
		in_codeblock { next }
		/^- \[[ x-]\] t[0-9]/ { print }
	' "$template_file" || true)
	if [[ -z "$leaked_tasks" ]]; then
		pass "Template has no extractable task lines outside comments/code blocks"
	else
		fail "Template has extractable task lines" "$leaked_tasks"
	fi
else
	fail "Template file not found: $template_file"
fi

# Test 5: Various non-numeric ID patterns are rejected
echo ""
echo "Test 5: Non-numeric task ID patterns are rejected"
TMPDIR5=$(mktemp -d)
trap 'rm -rf "$TMPDIR1" "$TMPDIR2" "$TMPDIR3" "$TMPDIR5"' EXIT
cat >"$TMPDIR5/TODO.md" <<'FIXTURE'
# TODO

## Backlog

- [ ] tXXX Placeholder task ~1h
- [ ] tYYY Another placeholder ~2h
- [ ] tZZZ Yet another ~30m
- [ ] tABC Letters only ~1h
- [ ] t12X Mixed digits and letters ~1h
- [ ] t Real task with no digits ~1h
- [ ] t001 Valid numeric task ~1h
- [ ] t999 Another valid task ~2h
- [ ] t001.2 Valid subtask ~30m
- [ ] t001.2.3 Valid sub-subtask ~15m

## Done
FIXTURE
result5=$(extract_and_filter_tasks "$TMPDIR5/TODO.md")
valid_count=$(echo "$result5" | grep -c '^- \[' || true)
if [[ "$valid_count" -eq 4 ]]; then
	pass "Only 4 valid numeric tasks kept (t001, t999, t001.2, t001.2.3)"
else
	fail "Expected 4 valid tasks, got $valid_count" "$result5"
fi

# --- Summary ---
echo ""
summary
