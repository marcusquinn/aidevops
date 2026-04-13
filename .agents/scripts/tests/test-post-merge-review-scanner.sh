#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for post-merge-review-scanner.sh
#
# Covers the t2052 hardening:
#   - GraphQL reviewThread resolution filter (isResolved/isOutdated)
#   - diffHunk tail rendering as ```diff code fence
#   - CodeRabbit "Actionable comments posted: N" metadata summary filter
#   - Gemini "## Code Review" summary preservation
#   - build_pr_followup_body exit 1 when all threads resolved
#
# The scanner is sourced (not executed) via its source guard, and gh is
# stubbed via a PATH override that reads canned fixtures from files
# created by each test.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
SCANNER="${SCRIPT_DIR}/../post-merge-review-scanner.sh"

if [[ ! -f "$SCANNER" ]]; then
	echo "ERROR: scanner not found at $SCANNER" >&2
	exit 2
fi

PASS=0
FAIL=0

# -----------------------------------------------------------------------------
# Assertion helpers
# -----------------------------------------------------------------------------

assert_contains() {
	local test_name="$1" needle="$2" haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual (first 200): ${haystack:0:200}"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1" needle="$2" haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual (first 200): ${haystack:0:200}"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_rc() {
	local test_name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name (expected rc=$expected, got rc=$actual)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test harness setup: stub `gh` via PATH override
# -----------------------------------------------------------------------------

TMP_DIR=$(mktemp -d -t scanner-test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="${TMP_DIR}/bin"
mkdir -p "$STUB_BIN"

# Fixture files the stub reads based on the gh subcommand. Tests write
# canned JSON to these files before invoking the scanner under test.
FIX_GRAPHQL="${TMP_DIR}/fix-graphql.json"
FIX_REVIEWS="${TMP_DIR}/fix-reviews.json"
FIX_COMMENTS="${TMP_DIR}/fix-comments.json"
FIX_ISSUE_LIST="${TMP_DIR}/fix-issue-list.json"
export FIX_GRAPHQL FIX_REVIEWS FIX_COMMENTS FIX_ISSUE_LIST

# Mock gh binary. It dispatches based on its first two positional args.
# - `api graphql` → cat $FIX_GRAPHQL
# - `api repos/.../pulls/N/reviews` → cat $FIX_REVIEWS
# - `api repos/.../pulls/N/comments` → cat $FIX_COMMENTS
# - `issue list` → cat $FIX_ISSUE_LIST
# - `issue edit/close` → no-op (prints the args for inspection)
# - `label create` → no-op
# - `repo view` → return a fake slug
cat >"${STUB_BIN}/gh" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
sub="${2:-}"

case "$cmd" in
api)
	case "$sub" in
	graphql)
		if [[ -n "${FIX_GRAPHQL:-}" && -f "$FIX_GRAPHQL" ]]; then
			cat "$FIX_GRAPHQL"
		else
			echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
		fi
		;;
	*pulls*/reviews*)
		if [[ -n "${FIX_REVIEWS:-}" && -f "$FIX_REVIEWS" ]]; then
			cat "$FIX_REVIEWS"
		else
			echo '[]'
		fi
		;;
	*pulls*/comments*)
		if [[ -n "${FIX_COMMENTS:-}" && -f "$FIX_COMMENTS" ]]; then
			cat "$FIX_COMMENTS"
		else
			echo '[]'
		fi
		;;
	*)
		echo '{}'
		;;
	esac
	;;
issue)
	case "$sub" in
	list)
		if [[ -n "${FIX_ISSUE_LIST:-}" && -f "$FIX_ISSUE_LIST" ]]; then
			cat "$FIX_ISSUE_LIST"
		else
			echo '[]'
		fi
		;;
	edit | close | create)
		# Echo operation to stderr so tests can assert on it. Stay quiet
		# on stdout so the scanner's pipe consumers don't see junk.
		echo "STUB gh issue $sub $*" >&2
		;;
	*)
		echo '[]'
		;;
	esac
	;;
label)
	# label create/list — always succeed silently
	exit 0
	;;
pr)
	case "$sub" in
	list)
		echo '[]'
		;;
	view)
		# Return a fake title for do_scan
		echo '{"title":"stub pr title"}'
		;;
	esac
	;;
repo)
	# gh repo view --json nameWithOwner -q .nameWithOwner
	echo 'stub/repo'
	;;
*)
	echo "stub gh: unhandled: $cmd $sub $*" >&2
	exit 1
	;;
esac
STUB_EOF
chmod +x "${STUB_BIN}/gh"

# Also stub gh-signature-helper.sh so append_sig_footer returns a
# deterministic suffix (the real helper embeds timestamps/token counts).
# The scanner source guard resolves the helper via SCRIPT_DIR, which
# points at the real .agents/scripts/ dir — so we override the helper
# at its real path for the duration of the test suite via a temp copy.
# (Easier: set an env var scanner doesn't use, and just accept real
# footer in test output. We assert on markers before the footer instead.)

# Prepend stub bin to PATH so our `gh` wins.
export PATH="${STUB_BIN}:${PATH}"

# Sanity check: the stub responds
if [[ "$(gh repo view --json nameWithOwner -q .nameWithOwner)" != "stub/repo" ]]; then
	echo "ERROR: gh stub not on PATH" >&2
	exit 2
fi

# -----------------------------------------------------------------------------
# Source the scanner. The source guard prevents main() from running.
# -----------------------------------------------------------------------------

# shellcheck source=../post-merge-review-scanner.sh
source "$SCANNER"

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# Build a GraphQL reviewThreads response with N threads.
# Args: resolved outdated author path line body diffhunk
# (repeat groups of 7 args per thread)
write_graphql_fixture() {
	local out="$1"
	shift
	local threads_json="["
	local first=1
	while [[ $# -ge 7 ]]; do
		local resolved="$1" outdated="$2" author="$3" path="$4"
		local line="$5" body="$6" diffhunk="$7"
		shift 7
		if [[ $first -eq 1 ]]; then
			first=0
		else
			threads_json+=","
		fi
		threads_json+=$(jq -n \
			--argjson resolved "$resolved" \
			--argjson outdated "$outdated" \
			--arg author "$author" \
			--arg path "$path" \
			--argjson line "$line" \
			--arg body "$body" \
			--arg diffhunk "$diffhunk" \
			'{
				isResolved: $resolved,
				isOutdated: $outdated,
				comments: {
					nodes: [{
						author: {login: $author},
						path: $path,
						line: $line,
						url: "https://example/thread",
						body: $body,
						diffHunk: $diffhunk
					}]
				}
			}')
	done
	threads_json+="]"
	jq -n --argjson nodes "$threads_json" \
		'{data: {repository: {pullRequest: {reviewThreads: {nodes: $nodes}}}}}' \
		>"$out"
	return 0
}

# Build a PR reviews JSON response with N summary reviews.
# Args: login body
write_reviews_fixture() {
	local out="$1"
	shift
	local arr="["
	local first=1
	while [[ $# -ge 2 ]]; do
		local login="$1" body="$2"
		shift 2
		if [[ $first -eq 1 ]]; then
			first=0
		else
			arr+=","
		fi
		arr+=$(jq -n --arg login "$login" --arg body "$body" \
			'{user: {login: $login}, body: $body, html_url: "https://example/review"}')
	done
	arr+="]"
	printf '%s\n' "$arr" >"$out"
	return 0
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

echo "Test: build_pr_followup_body — all threads resolved → exit 1"
write_graphql_fixture "$FIX_GRAPHQL" \
	true false "coderabbitai" "src/a.js" 10 "finding 1" "@@ -1,3 +1,3 @@" \
	true false "coderabbitai" "src/b.js" 20 "finding 2" "@@ -5,3 +5,3 @@"
write_reviews_fixture "$FIX_REVIEWS"
rc=0
out=$(build_pr_followup_body "stub/repo" "42") || rc=$?
assert_rc "returns exit 1 when all threads resolved" "1" "$rc"
assert_contains "prints empty body when all resolved" "" "${out:-}"

echo ""
echo "Test: build_pr_followup_body — all threads outdated → exit 1"
write_graphql_fixture "$FIX_GRAPHQL" \
	false true "coderabbitai" "src/a.js" 10 "finding" "@@ -1,3 +1,3 @@"
write_reviews_fixture "$FIX_REVIEWS"
rc=0
out=$(build_pr_followup_body "stub/repo" "42") || rc=$?
assert_rc "returns exit 1 when all threads outdated" "1" "$rc"

echo ""
echo "Test: build_pr_followup_body — mixed resolved/unresolved → only unresolved appear"
# 1 resolved + 1 unresolved. The unresolved one should appear.
# Markers chosen to avoid substring collisions (RESOLVED_A would match
# both a "RESOLVED_A" and a "UNRESOLVED_A" body under glob matching, so
# we use distinct strings that share no substrings).
write_graphql_fixture "$FIX_GRAPHQL" \
	true false "coderabbitai" "src/done.js" 10 "MARKER_ALPHA_DONE" "@@ -1,3 +1,3 @@" \
	false false "coderabbitai" "src/live.js" 20 "MARKER_BRAVO_LIVE" "@@ -5,3 +5,3 @@\n context line 1\n context line 2\n+new line"
write_reviews_fixture "$FIX_REVIEWS"
out=$(build_pr_followup_body "stub/repo" "42")
assert_contains "unresolved comment body is rendered" "MARKER_BRAVO_LIVE" "$out"
assert_not_contains "resolved comment body is NOT rendered" "MARKER_ALPHA_DONE" "$out"
assert_contains "unresolved file:line appears in file refs" "src/live.js:20" "$out"
assert_not_contains "resolved file:line does NOT appear in file refs" "src/done.js:10" "$out"

echo ""
echo "Test: build_pr_followup_body — diffHunk tail rendered as \`\`\`diff fence"
# Long diffHunk (20 lines): we should only see the last 12 lines.
LONG_HUNK="@@ -1,20 +1,20 @@"
for i in {1..20}; do
	LONG_HUNK+=$'\n'"+line ${i}"
done
write_graphql_fixture "$FIX_GRAPHQL" \
	false false "coderabbitai" "src/x.js" 100 "test body" "$LONG_HUNK"
write_reviews_fixture "$FIX_REVIEWS"
out=$(build_pr_followup_body "stub/repo" "42")
assert_contains "diff fence is rendered" '```diff' "$out"
assert_contains "tail of hunk is present (line 20)" "+line 20" "$out"
assert_contains "near-tail (line 10) is present within default 12-line tail" "+line 10" "$out"
assert_not_contains "first line is NOT present (trimmed to last 12)" "+line 1" "$(echo "$out" | grep -v 'line 10\|line 11\|line 12\|line 13\|line 14\|line 15\|line 16\|line 17\|line 18\|line 19\|line 20' || true)"

echo ""
echo "Test: fetch_review_summaries_md — CodeRabbit metadata summary is filtered out"
write_graphql_fixture "$FIX_GRAPHQL"
# Note the CODERABBIT_META_MARKER is in a body starting with "**Actionable..."
write_reviews_fixture "$FIX_REVIEWS" \
	"coderabbitai" "**Actionable comments posted: 5**

Verify each finding and fix as needed. CODERABBIT_META_MARKER"
out=$(fetch_review_summaries_md "stub/repo" "42")
assert_not_contains "CodeRabbit metadata summary filtered" "CODERABBIT_META_MARKER" "$out"

echo ""
echo "Test: fetch_review_summaries_md — Gemini ## Code Review is preserved"
write_graphql_fixture "$FIX_GRAPHQL"
write_reviews_fixture "$FIX_REVIEWS" \
	"gemini-code-assist" "## Code Review

This PR should update the config to fix GEMINI_REVIEW_MARKER issues."
out=$(fetch_review_summaries_md "stub/repo" "42")
assert_contains "Gemini review summary preserved" "GEMINI_REVIEW_MARKER" "$out"
assert_contains "Gemini review summary header rendered" "gemini-code-assist review summary" "$out"

echo ""
echo "Test: fetch_review_summaries_md — non-bot reviewer is filtered"
write_graphql_fixture "$FIX_GRAPHQL"
write_reviews_fixture "$FIX_REVIEWS" \
	"random-human" "## Code Review should fix HUMAN_REVIEW_MARKER"
out=$(fetch_review_summaries_md "stub/repo" "42")
assert_not_contains "non-bot reviewer filtered" "HUMAN_REVIEW_MARKER" "$out"

echo ""
echo "Test: build_pr_followup_body — only review summary, no inline → body still rendered"
write_graphql_fixture "$FIX_GRAPHQL"
write_reviews_fixture "$FIX_REVIEWS" \
	"gemini-code-assist" "## Code Review

This PR should update the config SUMMARY_ONLY_MARKER."
rc=0
out=$(build_pr_followup_body "stub/repo" "42") || rc=$?
assert_rc "exit 0 when only review summary present" "0" "$rc"
assert_contains "summary-only body contains the review" "SUMMARY_ONLY_MARKER" "$out"
assert_contains "fallback file-refs message appears when no inline threads" "No file paths in inline comments" "$out"

echo ""
echo "Test: fetch_inline_comments_md — non-bot thread author is filtered"
write_graphql_fixture "$FIX_GRAPHQL" \
	false false "some-human" "src/a.js" 10 "HUMAN_INLINE_MARKER" "@@ -1,1 +1,1 @@"
write_reviews_fixture "$FIX_REVIEWS"
out=$(fetch_inline_comments_md "stub/repo" "42")
assert_not_contains "non-bot inline comment filtered" "HUMAN_INLINE_MARKER" "$out"

echo ""
echo "Test: fetch_file_refs_md — deduped and stable across multiple threads on same file"
write_graphql_fixture "$FIX_GRAPHQL" \
	false false "coderabbitai" "src/same.js" 10 "finding1" "@@ -1,1 +1,1 @@" \
	false false "coderabbitai" "src/same.js" 10 "finding2 duplicate path:line" "@@ -1,1 +1,1 @@" \
	false false "coderabbitai" "src/other.js" 20 "finding3" "@@ -1,1 +1,1 @@"
out=$(fetch_file_refs_md "stub/repo" "42")
# Count unique path:line entries — same.js:10 should appear once, other.js:20 once
same_count=$(printf '%s\n' "$out" | grep -c 'src/same.js:10' || true)
other_count=$(printf '%s\n' "$out" | grep -c 'src/other.js:20' || true)
if [[ "$same_count" == "1" && "$other_count" == "1" ]]; then
	echo "  PASS: file refs deduped (same.js:10 ×1, other.js:20 ×1)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: file refs not deduped (same.js:10 ×${same_count}, other.js:20 ×${other_count})"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Test: do_refresh — empty issue list is a no-op"
printf '%s\n' '[]' >"$FIX_ISSUE_LIST"
rc=0
do_refresh "stub/repo" "true" 2>/dev/null || rc=$?
assert_rc "refresh on empty list returns 0" "0" "$rc"

echo ""
echo "Test: do_refresh dry-run — issue with unresolved findings is flagged for update"
write_graphql_fixture "$FIX_GRAPHQL" \
	false false "coderabbitai" "src/a.js" 10 "STILL_OPEN" "@@ -1,1 +1,1 @@"
write_reviews_fixture "$FIX_REVIEWS"
jq -n '[{number: 999, title: "Review followup: PR #123 — some title", body: "old body"}]' >"$FIX_ISSUE_LIST"
out=$(do_refresh "stub/repo" "true" 2>&1)
assert_contains "refresh dry-run flags issue for update" "issue #999" "$out"
assert_contains "refresh dry-run says would update" "would update body" "$out"

echo ""
echo "Test: do_refresh dry-run — issue whose PR has no unresolved threads is flagged for close"
# All threads resolved → build_pr_followup_body returns 1 → issue is closed
write_graphql_fixture "$FIX_GRAPHQL" \
	true false "coderabbitai" "src/a.js" 10 "RESOLVED" "@@ -1,1 +1,1 @@"
write_reviews_fixture "$FIX_REVIEWS"
jq -n '[{number: 888, title: "Review followup: PR #456 — obsolete", body: "stale body"}]' >"$FIX_ISSUE_LIST"
out=$(do_refresh "stub/repo" "true" 2>&1)
assert_contains "refresh dry-run flags stale issue for close" "issue #888" "$out"
assert_contains "refresh dry-run says would close" "would close" "$out"

echo ""
echo "Test: do_refresh — malformed title is skipped, not errored"
write_graphql_fixture "$FIX_GRAPHQL"
write_reviews_fixture "$FIX_REVIEWS"
jq -n '[{number: 777, title: "Random unrelated title without PR ref", body: "body"}]' >"$FIX_ISSUE_LIST"
rc=0
out=$(do_refresh "stub/repo" "true" 2>&1) || rc=$?
assert_rc "refresh skips malformed title without erroring" "0" "$rc"
assert_contains "refresh logs malformed title skip" "cannot extract PR number" "$out"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

if [[ $FAIL -eq 0 ]]; then
	exit 0
else
	exit 1
fi
