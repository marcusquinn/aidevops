#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t3204 — issue-sync auto-close path emits unsigned
# closing comments. Verifies that _close_comment and _reopen_comment in
# .agents/scripts/issue-sync-helper-close.sh both append the canonical
# `<!-- aidevops:sig -->` marker to their output.
#
# The bash close path bypasses the `gh` PATH shim entirely because
# `issue:close --comment` is not in the shim's intercept list (only
# issue:comment / issue:edit / issue:create / pr:* are routed). Without
# explicit signature injection in the helper, every TODO.md `[x]` push
# closes its issue with a bare one-liner — losing the audit-trail
# metadata (runtime, version, model, tokens, session-time) that every
# other agent-authored comment carries.
#
# Mentor pattern: a future regression that re-introduces the bare
# echo statement in _close_comment will trip "no marker" failures here
# and explain — via this header comment — why the marker matters.
set -euo pipefail

PASS=0
FAIL=0

# --- Test fixture: isolate signature helper ---------------------------------
TMPDIR=$(mktemp -d)
# Cleanup on exit; the trap fires regardless of pass/fail/early-error.
trap 'rm -rf "$TMPDIR"' EXIT

# Mock signature helper. Emits a leading newline + canonical marker block,
# matching the real helper's format — the leading `\n` mirrors the real
# `gh-signature-helper.sh footer` output (verified: xxd shows `0a3c 212d 2d20`
# = newline + `<!-- `). The `[mock-sig]` line stands in for the real
# `[aidevops.sh](...)` body so we can detect mock-vs-real footers without
# brittle version-string matching.
cat >"$TMPDIR/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '\n<!-- aidevops:sig -->\n---\n[mock-sig]\n'
exit 0
STUB
chmod +x "$TMPDIR/gh-signature-helper.sh"
export PATH="$TMPDIR:$PATH"

# --- Source the close helper ------------------------------------------------
# Resolve the helper relative to this test file's location so the test is
# worktree-portable (works in canonical repo, linked worktrees, deployed copy).
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../issue-sync-helper-close.sh"

if [[ ! -f "$HELPER_PATH" ]]; then
	echo "FAIL: issue-sync-helper-close.sh not found at $HELPER_PATH" >&2
	exit 1
fi

# Sourcing the close helper is safe because it has no top-level executable
# code beyond the include guard and SCRIPT_DIR fallback. The helper functions
# (_close_comment, _reopen_comment) only call _is_cancelled_or_deferred (also
# defined in the same file) and our mocked gh-signature-helper.sh on PATH.
# shellcheck source=../issue-sync-helper-close.sh
source "$HELPER_PATH"

# --- Single-assertion helper (de-duplicates output formatting) --------------
check_marker() {
	local label="$1" body="$2"
	if echo "$body" | grep -q '<!-- aidevops:sig -->'; then
		PASS=$((PASS + 1))
		echo "PASS: $label"
	else
		FAIL=$((FAIL + 1))
		echo "FAIL: $label"
		echo "  Output was:"
		echo "$body" | sed 's/^/    /'
	fi
	return 0
}

# ============================================================================
# Test cases for _close_comment
# ============================================================================
# The function has four output branches based on input:
#   (a) cancelled/deferred/declined  → "Closing as not planned (...)"
#   (b) pr_num + pr_url present       → "Completed via [PR #N](url)..."
#   (c) pr_num present, no url        → "Completed via PR #N..."
#   (d) verified: date present        → "Completed (verified: D)..."
#   (e) fallback                      → "Completed."
#
# Each branch must end with the signature marker. The acceptance criteria
# in the t3204 issue body explicitly call out (a), (b/c/d), and the reopen
# path — covering all five branches keeps future regressions cheap.

# (b) Completed via PR with URL — most common production case.
out=$(_close_comment "t999" \
	"- [x] t999 sample task pr:#42 completed:2026-01-01" \
	"42" "https://github.com/owner/repo/pull/42" \
	"owner/repo" "100")
check_marker "_close_comment: completed-PR-with-URL variant carries signature footer" "$out"

# (c) Completed via PR number only — rare but exercised by older TODO entries.
out=$(_close_comment "t999" \
	"- [x] t999 sample task pr:#42" \
	"42" "" \
	"owner/repo" "100")
check_marker "_close_comment: completed-PR-no-URL variant carries signature footer" "$out"

# (d) Completed with verified: date but no PR — common for hand-verified tasks.
out=$(_close_comment "t999" \
	"- [x] t999 sample task verified:2026-01-01" \
	"" "" \
	"owner/repo" "100")
check_marker "_close_comment: verified-only variant carries signature footer" "$out"

# (e) Completed with no PR and no verified date — fallback branch.
out=$(_close_comment "t999" \
	"- [x] t999 sample task" \
	"" "" \
	"owner/repo" "100")
check_marker "_close_comment: fallback completed variant carries signature footer" "$out"

# (a) Cancelled — must also be signed. The acceptance criteria explicitly
# enumerates "completed, cancelled, deferred, and declined task variants".
out=$(_close_comment "t999" \
	"- [-] t999 sample task cancelled:2026-01-01" \
	"" "" \
	"owner/repo" "100")
check_marker "_close_comment: cancelled variant carries signature footer" "$out"

# (a) Deferred variant.
out=$(_close_comment "t999" \
	"- [-] t999 sample task deferred:2026-01-01" \
	"" "" \
	"owner/repo" "100")
check_marker "_close_comment: deferred variant carries signature footer" "$out"

# (a) Declined variant.
out=$(_close_comment "t999" \
	"- [-] t999 sample task declined:2026-01-01" \
	"" "" \
	"owner/repo" "100")
check_marker "_close_comment: declined variant carries signature footer" "$out"

# Defensive: missing repo/issue_number args. The helper falls back to the
# unscoped footer call rather than emitting an unsigned body — verify that
# the marker is still present in the bare-args case (matches fail-open
# semantics in the helper comment block).
out=$(_close_comment "t999" \
	"- [x] t999 sample task" \
	"42" "https://github.com/o/r/pull/42" \
	"" "")
check_marker "_close_comment: missing repo/issue_number still signs (fail-open)" "$out"

# ============================================================================
# Test cases for _reopen_comment
# ============================================================================

# Standard call with both args.
out=$(_reopen_comment "owner/repo" "100")
check_marker "_reopen_comment: standard reopen comment carries signature footer" "$out"

# Defensive: missing args still signs (fail-open path).
out=$(_reopen_comment "" "")
check_marker "_reopen_comment: missing args still signs (fail-open)" "$out"

# Verify the body text is preserved alongside the footer — guards against a
# regression that swaps the body for the footer rather than appending.
out=$(_reopen_comment "owner/repo" "100")
if echo "$out" | grep -q "Reopened: TODO.md still has this as"; then
	PASS=$((PASS + 1))
	echo "PASS: _reopen_comment: body text preserved alongside signature"
else
	FAIL=$((FAIL + 1))
	echo "FAIL: _reopen_comment: body text missing"
	echo "$out" | sed 's/^/    /'
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
