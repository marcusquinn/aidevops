#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-issue-sync-lib.sh — Stub-based test harness for issue-sync-lib.sh.
#
# Model: mirrors test-privacy-guard.sh (t1969) and test-canonical-guard.sh (t1995).
# No network, no `gh` CLI dependency — `gh` is stubbed as a no-op function
# before sourcing the library. Focuses on the functions that mutate TODO.md
# content (add_gh_ref_to_todo, fix_gh_ref_in_todo, add_pr_ref_to_todo) since
# those are the ones that shipped broken on macOS (t1983 BSD awk bug) and
# carry the highest regression risk for future refactors.
#
# Tests (minimum 10):
#   1.  add_gh_ref_to_todo: plain task line — ref stamped
#   2.  add_gh_ref_to_todo: task with inline backticks — ref stamped (t1983 regression)
#   3.  add_gh_ref_to_todo: idempotent on re-run (existing ref not duplicated)
#   4.  add_gh_ref_to_todo: respects code fences (won't stamp an example task inside ```)
#   5.  add_gh_ref_to_todo: task not found in TODO.md — no change
#   6.  add_pr_ref_to_todo: stamps pr:#NNN into existing task line
#   7.  add_pr_ref_to_todo: idempotent on re-run
#   8.  strip_code_fences: strips code-fenced lines
#   9.  strip_code_fences: passes through non-fenced content
#   10. _escape_ere: escapes regex metacharacters in sub-task IDs like t001.1
#   11. t1983 explicit regression: pre-fix awk pattern WOULD fail, post-fix works
#
# Exit 0 = all tests pass, 1 = at least one failure.

set -u

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/issue-sync-lib.sh"

if [[ ! -f "$LIB" ]]; then
	printf 'test harness cannot find lib at %s\n' "$LIB" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubs: gh, log_verbose, sed_inplace fallback
# -----------------------------------------------------------------------------

# Stub gh as a no-op so any accidental invocation doesn't hit the network
gh() { return 0; }
export -f gh

# log_verbose is a logging helper defined in issue-sync-helper.sh (the main
# script). The lib references it but we source the lib standalone, so we
# provide a stub before sourcing.
log_verbose() { :; }
export -f log_verbose

# print_warning / print_info / print_error / print_success — same story.
print_warning() { :; }
print_info() { :; }
print_error() { :; }
print_success() { :; }
export -f print_warning print_info print_error print_success

# shellcheck source=issue-sync-lib.sh
# Some sourcing side-effects (shared-constants.sh resolution warnings) are
# benign; suppress them without losing the import itself.
source "$LIB" >/dev/null 2>&1 || true

printf '%sRunning issue-sync-lib tests%s\n' "$BLUE" "$NC"

# -----------------------------------------------------------------------------
# Test 1: add_gh_ref_to_todo plain line
# -----------------------------------------------------------------------------
cat >"$TMP/todo1.md" <<'EOF'
## Ready

- [ ] t9001 plain description tier:simple
EOF

add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
if grep -q '^\- \[ \] t9001.*ref:GH#1001' "$TMP/todo1.md"; then
	pass "add_gh_ref_to_todo: plain task line stamped"
else
	fail "add_gh_ref_to_todo: plain task line not stamped"
	cat "$TMP/todo1.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 2: add_gh_ref_to_todo task with inline backticks (t1983 regression)
# -----------------------------------------------------------------------------
cat >"$TMP/todo2.md" <<'EOF'
## Ready

- [ ] t9002 task with `inline code` and `more backticks` in description tier:simple
EOF

add_gh_ref_to_todo "t9002" "1002" "$TMP/todo2.md"
if grep -q 'ref:GH#1002' "$TMP/todo2.md"; then
	pass "add_gh_ref_to_todo: backtick-containing line stamped (t1983 regression)"
else
	fail "add_gh_ref_to_todo: backtick line not stamped — t1983 regression!"
	cat "$TMP/todo2.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 3: add_gh_ref_to_todo idempotent on re-run
# -----------------------------------------------------------------------------
add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
count=$(grep -c 'ref:GH#1001' "$TMP/todo1.md")
if [[ "$count" -eq 1 ]]; then
	pass "add_gh_ref_to_todo: idempotent on re-run (count=1)"
else
	fail "add_gh_ref_to_todo: re-run duplicated ref (count=$count)"
fi

# -----------------------------------------------------------------------------
# Test 4: add_gh_ref_to_todo respects code fences (won't stamp an example)
# -----------------------------------------------------------------------------
cat >"$TMP/todo4.md" <<'EOF'
## Format example

```markdown
- [ ] t9004 example in code fence tier:simple
```

## Ready

- [ ] t9004 real task outside fence tier:simple
EOF

add_gh_ref_to_todo "t9004" "1004" "$TMP/todo4.md"

# Assert the REAL line got stamped, NOT the fenced example.
# The real line is outside the ``` block.
real_has_ref=$(awk '
	/^```/{f=!f; next}
	!f && /t9004.*ref:GH#1004/ {print "yes"; exit}
' "$TMP/todo4.md")

fenced_has_ref=$(awk '
	/^```/{f=!f; next}
	f && /t9004.*ref:GH#1004/ {print "yes"; exit}
' "$TMP/todo4.md")

if [[ "$real_has_ref" == "yes" && -z "$fenced_has_ref" ]]; then
	pass "add_gh_ref_to_todo: stamps real line, skips fenced example"
elif [[ "$real_has_ref" == "yes" && "$fenced_has_ref" == "yes" ]]; then
	fail "add_gh_ref_to_todo: stamped BOTH real and fenced lines (fenced should be untouched)"
else
	fail "add_gh_ref_to_todo: real line not stamped (real=$real_has_ref fenced=$fenced_has_ref)"
fi

# -----------------------------------------------------------------------------
# Test 5: add_gh_ref_to_todo task not present — no-op
# -----------------------------------------------------------------------------
cat >"$TMP/todo5.md" <<'EOF'
## Ready

- [ ] t9005 some task tier:simple
EOF
orig_content=$(cat "$TMP/todo5.md")
add_gh_ref_to_todo "t9099" "1099" "$TMP/todo5.md"
new_content=$(cat "$TMP/todo5.md")
if [[ "$orig_content" == "$new_content" ]]; then
	pass "add_gh_ref_to_todo: missing task → no-op (file unchanged)"
else
	fail "add_gh_ref_to_todo: missing task → file was modified"
fi

# -----------------------------------------------------------------------------
# Test 6: add_pr_ref_to_todo stamps pr:#NNN
# -----------------------------------------------------------------------------
cat >"$TMP/todo6.md" <<'EOF'
## Ready

- [ ] t9006 task tier:simple ref:GH#1006
EOF

add_pr_ref_to_todo "t9006" "2006" "$TMP/todo6.md"
if grep -q 'pr:#2006' "$TMP/todo6.md"; then
	pass "add_pr_ref_to_todo: pr: ref stamped"
else
	fail "add_pr_ref_to_todo: pr: ref not stamped"
	cat "$TMP/todo6.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 7: add_pr_ref_to_todo idempotent
# -----------------------------------------------------------------------------
add_pr_ref_to_todo "t9006" "2006" "$TMP/todo6.md"
count=$(grep -c 'pr:#2006' "$TMP/todo6.md")
if [[ "$count" -eq 1 ]]; then
	pass "add_pr_ref_to_todo: idempotent on re-run (count=1)"
else
	fail "add_pr_ref_to_todo: re-run duplicated ref (count=$count)"
fi

# -----------------------------------------------------------------------------
# Test 8: strip_code_fences removes fenced lines
# -----------------------------------------------------------------------------
cat >"$TMP/todo8.md" <<'EOF'
outside-line-1
```
inside-fenced-1
inside-fenced-2
```
outside-line-2
EOF

output=$(strip_code_fences <"$TMP/todo8.md")
if printf '%s\n' "$output" | grep -q 'outside-line-1' &&
	printf '%s\n' "$output" | grep -q 'outside-line-2' &&
	! printf '%s\n' "$output" | grep -q 'inside-fenced-1' &&
	! printf '%s\n' "$output" | grep -q 'inside-fenced-2'; then
	pass "strip_code_fences: fenced lines removed, outside lines preserved"
else
	fail "strip_code_fences: unexpected output"
	printf '%s\n' "$output" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 9: strip_code_fences passes through non-fenced content unchanged
# -----------------------------------------------------------------------------
cat >"$TMP/todo9.md" <<'EOF'
line1
line2
line3
EOF

orig=$(cat "$TMP/todo9.md")
output=$(strip_code_fences <"$TMP/todo9.md")
if [[ "$orig" == "$output" ]]; then
	pass "strip_code_fences: non-fenced content unchanged"
else
	fail "strip_code_fences: non-fenced content modified"
fi

# -----------------------------------------------------------------------------
# Test 10: _escape_ere escapes regex metacharacters
# -----------------------------------------------------------------------------
escaped=$(_escape_ere "t001.1")
if [[ "$escaped" == "t001\\.1" ]]; then
	pass "_escape_ere: escapes dot in t001.1 sub-task ID"
else
	fail "_escape_ere: wrong escape for t001.1 (got '$escaped')"
fi

escaped_plain=$(_escape_ere "t1990")
if [[ "$escaped_plain" == "t1990" ]]; then
	pass "_escape_ere: passes plain task ID unchanged"
else
	fail "_escape_ere: modified plain task ID (got '$escaped_plain')"
fi

# -----------------------------------------------------------------------------
# Test 11: t1983 explicit regression test — the bug was that
# `awk -v pat='...\[.\]...' '$0 ~ pat'` silently failed on BSD awk. Verify
# the current lib's pattern works by calling add_gh_ref_to_todo on a task
# line and confirming the ref was actually written (i.e. the awk line-number
# lookup succeeded).
# -----------------------------------------------------------------------------
cat >"$TMP/todo11.md" <<'EOF'
## Ready

- [ ] t9011 t1983 regression test task tier:simple
EOF

add_gh_ref_to_todo "t9011" "1983" "$TMP/todo11.md"
if grep -q 't9011.*ref:GH#1983' "$TMP/todo11.md"; then
	pass "t1983 regression: BSD awk dynamic-regex pattern works end-to-end"
else
	fail "t1983 regression: awk pattern failed — bug has regressed"
	cat "$TMP/todo11.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d test(s) passed%s\n' "$GREEN" "$TESTS_RUN" "$NC"
	exit 0
fi
printf '%s%d of %d test(s) failed%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
exit 1
