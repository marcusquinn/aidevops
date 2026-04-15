#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-guard.sh — fixture-based test harness for gh-wrapper-guard.sh
#
# Tests:
#   1. _scan_line detects raw "gh issue create" in code lines
#   2. _scan_line detects raw "gh pr create" in code lines
#   3. _scan_line skips allowlisted lines
#   4. _scan_line skips comment-only lines
#   5. _scan_line allows gh_create_issue / gh_create_pr (wrapper calls)
#   6. check-full catches violations in fixture files
#   7. check-full skips shared-constants.sh (exclusion)
#   8. check-full skips .agents/scripts/tests/ (exclusion)
#   9. GH_WRAPPER_GUARD_DISABLE=1 bypasses entirely
#  10. _scan_line detects subshell calls: $(gh issue create ...)
#
# Usage: bash test-gh-wrapper-guard.sh
# Environment: requires git repo context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../gh-wrapper-guard.sh"

pass_count=0
fail_count=0

_pass() {
	printf 'PASS: %s\n' "$1"
	pass_count=$((pass_count + 1))
}

_fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
	fail_count=$((fail_count + 1))
}

# -----------------------------------------------------------------------
# Source the guard to get access to _scan_line for unit tests
# -----------------------------------------------------------------------

# We can't source the whole file (it has main at the bottom), so we extract
# the functions we need by sourcing up to main.
# Instead, we'll test via the CLI interface and use fixture files.

# Create temp dir for fixtures
TMPDIR_FIX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIX"' EXIT

# -----------------------------------------------------------------------
# Test 1: Detects raw "gh issue create"
# -----------------------------------------------------------------------
cat >"$TMPDIR_FIX/test-violation.sh" <<'FIXTURE'
#!/usr/bin/env bash
# A script with a violation
some_function() {
	local result
	result=$(gh issue create --title "test" --body "test")
	echo "$result"
}
FIXTURE

# We'll use check-full in a synthetic git repo to test
TMPGIT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIX" "$TMPGIT"' EXIT

(
	cd "$TMPGIT"
	git init -q
	git config user.email "test@test.com"
	git config user.name "Test"
	mkdir -p .agents/scripts .agents/hooks
	cp "$TMPDIR_FIX/test-violation.sh" .agents/scripts/test-violation.sh
	git add -A
	git commit -q -m "init"
)

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && echo "$output" | grep -q "gh issue create"; then
	_pass "check-full detects raw 'gh issue create'"
else
	_fail "check-full should detect raw 'gh issue create'" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 2: Detects raw "gh pr create"
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/test-pr-violation.sh" <<'FIXTURE'
#!/usr/bin/env bash
deploy() {
	gh pr create --title "deploy" --body "auto"
}
FIXTURE

(cd "$TMPGIT" && git add -A && git commit -q -m "add pr violation")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && echo "$output" | grep -q "gh pr create"; then
	_pass "check-full detects raw 'gh pr create'"
else
	_fail "check-full should detect raw 'gh pr create'" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 3: Skips allowlisted lines
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/test-allowed.sh" <<'FIXTURE'
#!/usr/bin/env bash
allowed_call() {
	gh issue create --title "test" # aidevops-allow: raw-gh-wrapper
	gh pr create --title "test" # aidevops-allow: raw-gh-wrapper
}
FIXTURE

# Remove the violation files
rm -f "$TMPGIT/.agents/scripts/test-violation.sh" "$TMPGIT/.agents/scripts/test-pr-violation.sh"
(cd "$TMPGIT" && git add -A && git commit -q -m "allowlisted only")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "check-full skips allowlisted lines"
else
	_fail "check-full should skip allowlisted lines" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 4: Skips comment-only lines
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/test-comments.sh" <<'FIXTURE'
#!/usr/bin/env bash
# gh issue create is used like this
# Usage: gh pr create --title "..."
# This is a comment about gh issue create
  # indented comment: gh pr create --base main
FIXTURE

rm -f "$TMPGIT/.agents/scripts/test-allowed.sh"
(cd "$TMPGIT" && git add -A && git commit -q -m "comments only")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "check-full skips comment-only lines"
else
	_fail "check-full should skip comment-only lines" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 5: Allows wrapper calls (gh_create_issue / gh_create_pr)
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/test-wrappers.sh" <<'FIXTURE'
#!/usr/bin/env bash
source shared-constants.sh
good_function() {
	gh_create_issue --title "test" --body "proper usage"
	gh_create_pr --head feature --base main --title "correct"
}
FIXTURE

rm -f "$TMPGIT/.agents/scripts/test-comments.sh"
(cd "$TMPGIT" && git add -A && git commit -q -m "wrapper calls")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "check-full allows gh_create_issue / gh_create_pr wrapper calls"
else
	_fail "check-full should allow wrapper calls" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 6: Skips shared-constants.sh (file exclusion)
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/shared-constants.sh" <<'FIXTURE'
#!/usr/bin/env bash
gh_create_issue() {
	gh issue create "$@" --label "origin:worker"
}
gh_create_pr() {
	gh pr create "$@" --label "origin:worker"
}
FIXTURE

rm -f "$TMPGIT/.agents/scripts/test-wrappers.sh"
(cd "$TMPGIT" && git add -A && git commit -q -m "shared-constants exclusion")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "check-full skips shared-constants.sh"
else
	_fail "check-full should skip shared-constants.sh" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 7: Skips .agents/scripts/tests/ (file exclusion)
# -----------------------------------------------------------------------
mkdir -p "$TMPGIT/.agents/scripts/tests"
cat >"$TMPGIT/.agents/scripts/tests/test-fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Test fixture that legitimately uses raw calls
test_raw_call() {
	gh issue create --title "test fixture"
	gh pr create --title "test fixture"
}
FIXTURE

(cd "$TMPGIT" && git add -A && git commit -q -m "tests exclusion")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "check-full skips .agents/scripts/tests/ directory"
else
	_fail "check-full should skip .agents/scripts/tests/" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 8: GH_WRAPPER_GUARD_DISABLE=1 bypasses entirely
# -----------------------------------------------------------------------
# Add a real violation
cat >"$TMPGIT/.agents/scripts/test-bypass.sh" <<'FIXTURE'
#!/usr/bin/env bash
bad_call() {
	gh issue create --title "violation"
}
FIXTURE

(cd "$TMPGIT" && git add -A && git commit -q -m "bypass test")

output=$(cd "$TMPGIT" && GH_WRAPPER_GUARD_DISABLE=1 bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	_pass "GH_WRAPPER_GUARD_DISABLE=1 bypasses the guard"
else
	_fail "GH_WRAPPER_GUARD_DISABLE=1 should bypass" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 9: Detects subshell calls $(gh issue create ...)
# -----------------------------------------------------------------------
cat >"$TMPGIT/.agents/scripts/test-subshell.sh" <<'FIXTURE'
#!/usr/bin/env bash
get_url() {
	local url
	url=$(gh issue create --title "in subshell" --body "bad")
	echo "$url"
}
FIXTURE

rm -f "$TMPGIT/.agents/scripts/test-bypass.sh"
(cd "$TMPGIT" && git add -A && git commit -q -m "subshell violation")

output=$(cd "$TMPGIT" && bash "$GUARD" check-full 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && echo "$output" | grep -q "gh issue create"; then
	_pass "check-full detects subshell \$(gh issue create ...) calls"
else
	_fail "check-full should detect subshell calls" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Test 10: check --base detects violations in diff
# -----------------------------------------------------------------------
# Reset to clean state
rm -f "$TMPGIT/.agents/scripts/test-subshell.sh"
rm -f "$TMPGIT/.agents/scripts/shared-constants.sh"
rm -rf "$TMPGIT/.agents/scripts/tests"
cat >"$TMPGIT/.agents/scripts/clean.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "clean"
FIXTURE

(cd "$TMPGIT" && git add -A && git commit -q -m "clean base")
base_sha=$(cd "$TMPGIT" && git rev-parse HEAD)

# Add a violation on a new "branch"
cat >"$TMPGIT/.agents/scripts/new-violation.sh" <<'FIXTURE'
#!/usr/bin/env bash
create_issue() {
	gh issue create --title "violation in diff"
}
FIXTURE

(cd "$TMPGIT" && git add -A && git commit -q -m "add violation")

output=$(cd "$TMPGIT" && bash "$GUARD" check --base "$base_sha" 2>&1) && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && echo "$output" | grep -q "gh issue create"; then
	_pass "check --base detects violations in diff"
else
	_fail "check --base should detect violations in diff" "rc=$rc output=$output"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "================================"
printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"
echo "================================"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi
exit 0
