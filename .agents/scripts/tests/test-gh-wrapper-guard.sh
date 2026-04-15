#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-gh-wrapper-guard.sh — coverage for gh-wrapper-guard.sh (t2113).
#
# Strategy: create a temp git repo, stage a base commit with a clean script,
# then make a second commit that introduces a mix of allowed/disallowed/
# allowlisted/excluded lines. Run `gh-wrapper-guard.sh check --base HEAD~1`
# and assert the reported violations match expectations.

set -u

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly TEST_REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly GUARD="${TEST_REPO_ROOT}/.agents/scripts/gh-wrapper-guard.sh"

TEST_TMPDIR=$(mktemp -d /tmp/test-gh-wrapper-guard.XXXXXX)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

failed=0

# ---------------------------------------------------------------------------
# Helper: create fresh git repo, make base commit, then a change commit with
# the specified content, and run the guard. Returns exit code in $?, stdout
# in $GUARD_OUT.
# ---------------------------------------------------------------------------
make_repo_and_run() {
	local repo_dir="$1"
	local target_rel="$2"
	local base_content="$3"
	local new_content="$4"
	rm -rf "$repo_dir"
	mkdir -p "$repo_dir/$(dirname "$target_rel")"
	(
		cd "$repo_dir" || exit 1
		git init --quiet -b main
		git config user.email "test@example.com"
		git config user.name "Test"
	)
	printf '%s\n' "$base_content" >"$repo_dir/$target_rel"
	(
		cd "$repo_dir" || exit 1
		git add .
		git commit --quiet -m "base"
	)
	printf '%s\n' "$new_content" >"$repo_dir/$target_rel"
	(
		cd "$repo_dir" || exit 1
		git add .
		git commit --quiet -m "change"
	)

	GUARD_OUT=$(cd "$repo_dir" && "$GUARD" check --base HEAD~1 --head HEAD 2>&1)
	GUARD_RC=$?
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: clean file — no violations, exit 0
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t1" ".agents/scripts/clean-script.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
# Clean addition using the wrapper
gh_create_issue --repo owner/repo --title "foo"'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 1 (clean): expected exit 0, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 2: bare `gh issue create` — violation, exit 1
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t2" ".agents/scripts/bad-script.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
out=$(gh issue create --repo owner/repo --title "foo")'

if [[ "$GUARD_RC" -ne 1 ]]; then
	printf 'FAIL test 2 (raw gh issue create): expected exit 1, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi
if [[ "$GUARD_OUT" != *"bad-script.sh"*"gh issue create"* ]]; then
	printf 'FAIL test 2: expected violation report for bad-script.sh\n'
	printf '  got: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 3: bare `gh pr create` — violation, exit 1
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t3" ".agents/scripts/bad-pr.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
	gh pr create --repo owner/repo --title "foo"'

if [[ "$GUARD_RC" -ne 1 ]]; then
	printf 'FAIL test 3 (raw gh pr create): expected exit 1, got %d\n' "$GUARD_RC"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 4: allowlisted raw call — accepted, exit 0
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t4" ".agents/scripts/allowlisted.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
gh issue create --repo owner/repo --title "foo" # aidevops-allow: raw-gh-wrapper'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 4 (allowlisted): expected exit 0, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 5: excluded file — shared-constants.sh is the definition site
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t5" ".agents/scripts/shared-constants.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
gh_create_issue() {
  gh issue create "$@"
}'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 5 (excluded file): expected exit 0, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 6: test fixture path — should be excluded
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t6" ".agents/scripts/tests/test-fixture.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
gh issue create --repo fake/fake --title "fixture"'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 6 (tests/ excluded): expected exit 0, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 7: log_info guidance string — `: gh pr create` inside a quoted string.
# The tighter regex requires a space/paren/etc before `gh`. A string like
# `log_info "Create PR manually: gh pr create"` has `: ` before `gh` — space
# matches. THIS is an accepted false-positive corner case — must use the
# allowlist marker.
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t7" ".agents/scripts/log-line.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
log_info "Create PR manually: gh pr create --head foo"'

# This IS flagged (space before gh matches). Expected: user adds the marker.
if [[ "$GUARD_RC" -ne 1 ]]; then
	printf 'FAIL test 7: expected log_info string WITHOUT marker to be flagged\n'
	failed=1
fi

# And with marker, clean
make_repo_and_run "$TEST_TMPDIR/t7b" ".agents/scripts/log-line-ok.sh" \
	'#!/usr/bin/env bash
echo "base"' \
	'#!/usr/bin/env bash
echo "base"
log_info "Create PR manually: gh pr create --head foo" # aidevops-allow: raw-gh-wrapper'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 7b: expected log_info with allowlist marker to pass, got %d\n' "$GUARD_RC"
	printf '  out: %s\n' "$GUARD_OUT"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 8: non-matching file path outside .agents/scripts — not scanned
# ---------------------------------------------------------------------------
make_repo_and_run "$TEST_TMPDIR/t8" "docs/example.md" \
	'base docs' \
	'# Example
Run `gh issue create --repo owner/repo` manually.'

if [[ "$GUARD_RC" -ne 0 ]]; then
	printf 'FAIL test 8 (docs/ path): expected exit 0, got %d\n' "$GUARD_RC"
	failed=1
fi

# ---------------------------------------------------------------------------
# Test 9: check-full on a mini tree — finds the violation, exits 1
# ---------------------------------------------------------------------------
t9="$TEST_TMPDIR/t9"
mkdir -p "$t9/.agents/scripts" "$t9/.agents/hooks"
cat >"$t9/.agents/scripts/full-bad.sh" <<'EOF'
#!/usr/bin/env bash
echo "bad"
result=$(gh issue create --repo x/y --title z)
EOF
out=$("$GUARD" check-full --root "$t9" 2>&1)
rc=$?
if [[ "$rc" -ne 1 ]]; then
	printf 'FAIL test 9 (check-full): expected exit 1 on a raw call, got %d\n' "$rc"
	printf '  out: %s\n' "$out"
	failed=1
fi
if [[ "$out" != *"full-bad.sh"* ]]; then
	printf 'FAIL test 9: expected full-bad.sh in check-full output\n'
	printf '  got: %s\n' "$out"
	failed=1
fi

if [[ "$failed" -eq 0 ]]; then
	printf 'PASS: test-gh-wrapper-guard — all assertions green\n'
	exit 0
fi
printf '\nFAIL: test-gh-wrapper-guard — see diagnostics above\n'
exit 1
