#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for gh-thread-clean-helper.sh PR/issue JSON cleaning.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."
HELPER="${PARENT_DIR}/gh-thread-clean-helper.sh"

PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
	local label="$1"
	local needle="$2"
	local haystack_file="$3"
	if grep -Fq -- "$needle" "$haystack_file"; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label"
	echo "    missing: $needle"
	FAIL=$((FAIL + 1))
	return 1
}

assert_not_contains() {
	local label="$1"
	local needle="$2"
	local haystack_file="$3"
	if grep -Fq -- "$needle" "$haystack_file"; then
		echo "  FAIL: $label"
		echo "    unexpected: $needle"
		FAIL=$((FAIL + 1))
		return 1
	fi
	echo "  PASS: $label"
	PASS=$((PASS + 1))
	return 0
}

assert_exit_zero() {
	local label="$1"
	local status="$2"
	if [[ "$status" -eq 0 ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label (exit $status)"
	FAIL=$((FAIL + 1))
	return 1
}

echo "Test: gh-thread-clean-helper.sh PR thread shape tolerance"
echo "========================================================="
echo ""

fixture="$TMPDIR/pr-thread-int-comments.json"
output="$TMPDIR/output.txt"

cat >"$fixture" <<'JSON'
{
  "body": "PR body\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh)",
  "comments": 7,
  "reviewDecision": "",
  "latestReviews": {
    "totalCount": 1,
    "nodes": [
      {
        "author": {"login": "reviewer"},
        "body": "Review note at .agents/scripts/gh-thread-clean-helper.sh:84"
      }
    ]
  }
}
JSON

set +e
"$HELPER" clean-file "$fixture" >"$output" 2>&1
status=$?
set -e

assert_exit_zero "integer comments field does not crash cleaner" "$status"
assert_contains "body is preserved" "PR body" "$output"
assert_not_contains "signature footer is stripped" "aidevops.sh" "$output"
assert_not_contains "python TypeError is absent" "TypeError" "$output"

fixture="$TMPDIR/pr-thread-object-comments.json"
output="$TMPDIR/object-output.txt"

cat >"$fixture" <<'JSON'
{
  "body": "PR body",
  "comments": {
    "totalCount": 1,
    "nodes": [
      {
        "user": {"login": "commenter"},
        "body": "Actionable comment at path/to/file.sh:12"
      }
    ]
  }
}
JSON

"$HELPER" clean-file "$fixture" >"$output"
assert_contains "comments.nodes object shape is emitted" "Actionable comment at path/to/file.sh:12" "$output"
assert_contains "user login fallback is preserved" "Comment 1 (commenter)" "$output"

echo ""
echo "========================================================="
echo "Result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
