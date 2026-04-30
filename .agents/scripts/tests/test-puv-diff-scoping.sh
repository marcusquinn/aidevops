#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for pulse-unbound-var-check.yml diff-scoping logic (t3209).
#
# Verifies that the diff-scoping step uses `git diff MERGE_BASE..HEAD` (net
# diff) rather than `git log -p --first-parent` (per-commit aggregate).
#
# The bug (t3209): if commit 1 adds a buggy `local foo bar` and commit 2
# replaces it with `local foo="" bar=""`, `git log -p` included BOTH versions
# in its aggregated output. The scanner then flagged the buggy version even
# though it no longer existed in HEAD. PR #21908 / t3198 was forced to
# squash+push the branch to clear the false positive.
#
# The fix: `git diff MERGE_BASE..HEAD` computes the NET patch — only lines
# that survive to HEAD. Replaced-then-fixed lines disappear from this view.
#
# Coverage:
#   1. Net-diff (git diff): diff file contains corrected line, NOT buggy line.
#   2. Aggregate-diff (git log -p) [documents old bug]: diff file contains
#      BOTH lines — demonstrating what the old logic would have produced.
#   3. Net-diff: single-commit addition (no replacement) still captured.
#   4. Net-diff: entirely removed line is absent from diff file.
#
# All tests run inside a sandboxed git repo; no system state is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Test runtime constants.
TEST_RED='\033[0;31m'
TEST_GREEN='\033[0;32m'
TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SANDBOX=""

cleanup() {
	[[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local outcome="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$outcome" == "PASS" ]]; then
		printf '  %b%s%b: %s\n' "$TEST_GREEN" "$outcome" "$TEST_RESET" "$test_name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %b%s%b: %s%s\n' "$TEST_RED" "$outcome" "$TEST_RESET" "$test_name" \
			"${detail:+ — $detail}"
	fi
	return 0
}

# Build a sandboxed git repo with:
#   main: initial commit with pulse-test.sh (base content)
#   feature branch: commit 1 adds buggy line, commit 2 replaces with fix
# Returns: sets SANDBOX, MERGE_BASE, HEAD_SHA, PULSE_FILE globals.
_setup_sandbox() {
	SANDBOX=$(mktemp -d -t puv-diff-test-XXXXXX)

	# Configure git identity for the sandbox (required for commits).
	export GIT_AUTHOR_NAME="Test"
	export GIT_AUTHOR_EMAIL="test@test.invalid"
	export GIT_COMMITTER_NAME="Test"
	export GIT_COMMITTER_EMAIL="test@test.invalid"

	# Init repo in sandbox.
	git -C "$SANDBOX" init -q --initial-branch=main 2>/dev/null \
		|| git -C "$SANDBOX" init -q  # fallback for older git without --initial-branch

	# main: initial commit with a minimal pulse-test.sh.
	PULSE_FILE=".agents/scripts/pulse-test.sh"
	mkdir -p "$SANDBOX/$(dirname "$PULSE_FILE")"
	cat > "$SANDBOX/$PULSE_FILE" <<'PULSE_EOF'
#!/usr/bin/env bash
# placeholder pulse script for diff-scoping tests
_existing_func() {
	local existing_var=""
	echo "$existing_var"
	return 0
}
PULSE_EOF
	git -C "$SANDBOX" add "$PULSE_FILE"
	git -C "$SANDBOX" commit -q -m "initial: add pulse-test.sh"
	BASE_SHA=$(git -C "$SANDBOX" rev-parse HEAD)

	# Feature branch: two commits.
	git -C "$SANDBOX" checkout -q -b feature/test-branch

	# Commit 1: add a function with a buggy multi-var local declaration.
	cat >> "$SANDBOX/$PULSE_FILE" <<'BUGGY_EOF'
_buggy_func() {
	local foo bar
	if [[ -n "${1:-}" ]]; then
		foo="set"
		bar="also_set"
	fi
	echo "$foo $bar"
	return 0
}
BUGGY_EOF
	git -C "$SANDBOX" add "$PULSE_FILE"
	git -C "$SANDBOX" commit -q -m "commit 1: add buggy local foo bar (no init)"

	# Commit 2: replace the buggy declaration with the correct one.
	# Use sed via temp-file (portable across BSD sed on macOS and GNU sed on Linux —
	# `sed -i` differs incompatibly between the two: BSD requires `-i ''`, GNU does not).
	sed 's/	local foo bar$/	local foo="" bar=""/' "$SANDBOX/$PULSE_FILE" \
		> "$SANDBOX/$PULSE_FILE.new"
	mv "$SANDBOX/$PULSE_FILE.new" "$SANDBOX/$PULSE_FILE"
	git -C "$SANDBOX" add "$PULSE_FILE"
	git -C "$SANDBOX" commit -q -m "commit 2: fix local foo bar -> local foo='' bar=''"

	HEAD_SHA=$(git -C "$SANDBOX" rev-parse HEAD)
	MERGE_BASE=$(git -C "$SANDBOX" merge-base "$BASE_SHA" "$HEAD_SHA")
	return 0
}

_teardown_sandbox() {
	[[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX" 2>/dev/null || true
	SANDBOX=""
	return 0
}

# Run the NET diff (the fixed logic: git diff MERGE_BASE..HEAD).
# Outputs added lines to a temp file; prints the path.
_run_net_diff() {
	local sandbox="$1"
	local merge_base="$2"
	local head_sha="$3"
	local pulse_file="$4"
	local out_file
	out_file=$(mktemp -t puv-net-diff-XXXXXX)
	git -C "$sandbox" diff "${merge_base}..${head_sha}" -- "$pulse_file" \
		| grep '^+' | grep -v '^+++' | sed 's/^+//' \
		> "$out_file" 2>/dev/null || true
	printf '%s' "$out_file"
	return 0
}

# Run the AGGREGATE diff (the old buggy logic: git log -p --first-parent).
# Outputs added lines to a temp file; prints the path.
_run_aggregate_diff() {
	local sandbox="$1"
	local merge_base="$2"
	local head_sha="$3"
	local pulse_file="$4"
	local out_file
	out_file=$(mktemp -t puv-agg-diff-XXXXXX)
	git -C "$sandbox" log -p --first-parent "${merge_base}..${head_sha}" -- "$pulse_file" \
		| grep '^+' | grep -v '^+++' | sed 's/^+//' \
		> "$out_file" 2>/dev/null || true
	printf '%s' "$out_file"
	return 0
}

echo "test-puv-diff-scoping.sh"

# --- Test 1: net-diff does NOT include the replaced buggy line ---
_setup_sandbox
diff_file=$(_run_net_diff "$SANDBOX" "$MERGE_BASE" "$HEAD_SHA" "$PULSE_FILE")
if grep -q 'local foo bar$' "$diff_file" 2>/dev/null; then
	print_result "net-diff excludes replaced buggy line (local foo bar)" "FAIL" \
		"buggy line found in net diff — double-count bug persists"
else
	print_result "net-diff excludes replaced buggy line (local foo bar)" "PASS"
fi
rm -f "$diff_file"
_teardown_sandbox

# --- Test 2: net-diff DOES include the correct replacement line ---
_setup_sandbox
diff_file=$(_run_net_diff "$SANDBOX" "$MERGE_BASE" "$HEAD_SHA" "$PULSE_FILE")
if grep -q 'local foo="" bar=""' "$diff_file" 2>/dev/null; then
	print_result "net-diff includes corrected line (local foo=\"\" bar=\"\")" "PASS"
else
	print_result "net-diff includes corrected line (local foo=\"\" bar=\"\")" "FAIL" \
		"corrected line missing from net diff"
fi
rm -f "$diff_file"
_teardown_sandbox

# --- Test 3: aggregate-diff (old logic) WOULD have included the buggy line ---
# This test documents the pre-fix behaviour as a regression reference.
_setup_sandbox
agg_file=$(_run_aggregate_diff "$SANDBOX" "$MERGE_BASE" "$HEAD_SHA" "$PULSE_FILE")
if grep -q 'local foo bar$' "$agg_file" 2>/dev/null; then
	print_result "aggregate-diff (old logic) double-counts buggy line (expected)" "PASS"
else
	print_result "aggregate-diff (old logic) double-counts buggy line (expected)" "FAIL" \
		"aggregate diff did not reproduce the double-count — test setup may be wrong"
fi
rm -f "$agg_file"
_teardown_sandbox

# --- Test 4: net-diff captures a line added in a single commit (no replacement) ---
_setup_sandbox
# Add one more commit on the feature branch: add a new clean function.
cat >> "$SANDBOX/$PULSE_FILE" <<'CLEAN_EOF'
_clean_func() {
	local result=""
	result="clean_value"
	echo "$result"
	return 0
}
CLEAN_EOF
git -C "$SANDBOX" add "$PULSE_FILE"
git -C "$SANDBOX" commit -q -m "commit 3: add clean function (single-commit addition)"
HEAD_SHA=$(git -C "$SANDBOX" rev-parse HEAD)

diff_file=$(_run_net_diff "$SANDBOX" "$MERGE_BASE" "$HEAD_SHA" "$PULSE_FILE")
if grep -q 'local result=""' "$diff_file" 2>/dev/null; then
	print_result "net-diff captures single-commit addition (local result=\"\")" "PASS"
else
	print_result "net-diff captures single-commit addition (local result=\"\")" "FAIL" \
		"single-commit addition missing from net diff"
fi
rm -f "$diff_file"
_teardown_sandbox

# --- Test 5: net-diff excludes a line added then entirely deleted ---
_setup_sandbox
# Snapshot the file BEFORE adding temp_func — restoring this snapshot in commit 2
# is the cleanest way to delete every line introduced in commit 1, without relying
# on regex alternation that varies between BSD grep (macOS) and GNU grep (Linux).
cp "$SANDBOX/$PULSE_FILE" "$SANDBOX/$PULSE_FILE.pre-temp"

# Commit 1: append a function with an uninitialised local temp_var.
cat >> "$SANDBOX/$PULSE_FILE" <<'TEMP_EOF'
_temp_func() {
	local temp_var
	echo "$temp_var"
	return 0
}
TEMP_EOF
git -C "$SANDBOX" add "$PULSE_FILE"
git -C "$SANDBOX" commit -q -m "commit 1: add temp_func with uninitialised temp_var"

# Commit 2: restore the pre-temp snapshot — every line added in commit 1 is gone.
cp "$SANDBOX/$PULSE_FILE.pre-temp" "$SANDBOX/$PULSE_FILE"
rm -f "$SANDBOX/$PULSE_FILE.pre-temp"

git -C "$SANDBOX" add "$PULSE_FILE"
git -C "$SANDBOX" commit -q -m "commit 2: remove temp_func entirely"
HEAD_SHA=$(git -C "$SANDBOX" rev-parse HEAD)

diff_file=$(_run_net_diff "$SANDBOX" "$MERGE_BASE" "$HEAD_SHA" "$PULSE_FILE")
if grep -q 'local temp_var' "$diff_file" 2>/dev/null; then
	print_result "net-diff excludes added-then-deleted line (local temp_var)" "FAIL" \
		"deleted line was included in net diff"
else
	print_result "net-diff excludes added-then-deleted line (local temp_var)" "PASS"
fi
rm -f "$diff_file"
_teardown_sandbox

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
