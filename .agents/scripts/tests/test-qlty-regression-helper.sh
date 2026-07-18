#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for deterministic direct/isolated Qlty scans (GH#28162).

set -u

TESTS_RUN=0
TESTS_FAILED=0

assert_rc() {
	local _label="$1"
	local _expected="$2"
	local _actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$_expected" = "$_actual" ]; then
		printf 'PASS: %s\n' "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL: %s (expected %s, got %s)\n' "$_label" "$_expected" "$_actual"
	fi
	return 0
}

assert_contains() {
	local _label="$1"
	local _needle="$2"
	local _haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_haystack" == *"$_needle"* ]]; then
		printf 'PASS: %s\n' "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL: %s (missing %s)\n' "$_label" "$_needle"
	fi
	return 0
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$SCRIPT_DIR/qlty-regression-helper.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qlty-regression-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$TMP_ROOT/repo"
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$REPO" "$BIN_DIR"

cat >"$BIN_DIR/qlty" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
	printf 'qlty 0.635.0 linux-x64\n'
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "base-fail" ] && [ "$(basename "$PWD")" = "base-worktree" ]; then
	printf 'simulated base failure\n' >&2
	exit 2
fi
if [ "${QLTY_STUB_MODE:-parity}" = "mismatch" ] && [ "$(basename "$PWD")" = "repo" ]; then
	printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.sh"}}}]}]}]}'
	exit 0
fi
printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
exit 0
STUB
chmod +x "$BIN_DIR/qlty"
ln -s /usr/bin/git "$BIN_DIR/git"

/usr/bin/git -C "$REPO" init --quiet
/usr/bin/git -C "$REPO" config user.name "Qlty Test"
/usr/bin/git -C "$REPO" config user.email "qlty-test@example.invalid"
printf 'sample\n' >"$REPO/a.sh"
/usr/bin/git -C "$REPO" add a.sh
/usr/bin/git -C "$REPO" commit --quiet -m "fixture"

PATH="$BIN_DIR:$PATH"
export PATH

QLTY_STUB_MODE=parity
export QLTY_STUB_MODE
parity_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
parity_rc=$?
assert_rc "same tree passes with direct and standalone-clone scans" "0" "$parity_rc"
assert_contains "base metadata identifies isolated clone" "mode=isolated-clone" "$parity_output"
assert_contains "head metadata identifies direct checkout" "mode=direct-checkout" "$parity_output"
assert_contains "same-tree identity parity is explicit" "identical normalized SARIF identities" "$parity_output"
assert_contains "resolved Qlty version is logged" "version=qlty 0.635.0 linux-x64" "$parity_output"
assert_contains "per-rule counts are logged" $'1\tqlty:similar-code' "$parity_output"

QLTY_STUB_MODE=mismatch
export QLTY_STUB_MODE
mismatch_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
mismatch_rc=$?
assert_rc "same-tree normalized mismatch blocks" "1" "$mismatch_rc"
assert_contains "mismatch includes tree evidence" "produced different normalized SARIF identities" "$mismatch_output"
assert_contains "mismatch includes normalized URI difference" $'+qlty:similar-code\tb.sh' "$mismatch_output"

QLTY_STUB_MODE=base-fail
export QLTY_STUB_MODE
fallback_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
fallback_rc=$?
assert_rc "base scan failure retains diagnostic fallback" "0" "$fallback_rc"
assert_contains "base failure fallback is logged" "base scan failed; treating base count as equal to head" "$fallback_output"

if [ "$TESTS_FAILED" -eq 0 ]; then
	printf 'All %s tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%s of %s tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
