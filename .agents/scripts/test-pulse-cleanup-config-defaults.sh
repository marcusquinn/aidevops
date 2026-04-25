#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for t2859: pulse-cleanup.sh must remain protected against
# unbound config variables (ORPHAN_WORKTREE_GRACE_SECS, ORPHAN_MAX_AGE,
# PULSE_IDLE_CPU_THRESHOLD).
#
# Background: cleanup-worktrees-async-helper.sh sources pulse-cleanup.sh but
# NOT pulse-wrapper-config.sh. Before t2859, this caused $ORPHAN_WORKTREE_GRACE_SECS
# to expand to empty string in numeric comparisons, treated as 0, collapsing
# the 30-minute grace period to zero seconds and destroying live worktrees.
#
# This test:
#   1. Verifies pulse-cleanup.sh sources pulse-wrapper-config.sh defensively
#      (so config defaults are present after sourcing).
#   2. Verifies inline ${VAR:-default} fallbacks behave correctly when the
#      config file is missing/unreadable (belt-and-suspenders defence).
#   3. Verifies _evaluate_worktree_removal correctly applies the 30-minute
#      grace period to fresh worktrees with 0 commits and no PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Track failures
declare -i FAIL_COUNT=0

fail() {
	local msg="$1"
	echo "FAIL: $msg" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

pass() {
	local msg="$1"
	echo "PASS: $msg"
	return 0
}

# ============================================================================
# Test 1: Sourcing pulse-cleanup.sh in isolation (mimicking
# cleanup-worktrees-async-helper.sh, which sources only shared-constants.sh
# + pulse-cleanup.sh, NOT pulse-wrapper-config.sh) does not produce
# unbound-variable errors when _evaluate_worktree_removal is called.
#
# This is the canonical regression: a fresh worktree (0 commits, 60s old)
# must be protected by the inline ${ORPHAN_WORKTREE_GRACE_SECS:-1800}
# fallback at use site (line ~280). Without the fallback, the unbound
# expansion would coerce to 0 and the worktree would be eligible for
# destruction.
# ============================================================================
echo ""
echo "=== Test 1: Standalone source path does not produce unbound-var errors ==="
(
	# Subshell isolation: explicitly unset config vars to prove the inline
	# fallbacks at use sites work without pulse-wrapper-config.sh being
	# sourced. Mirrors the broken state cleanup-worktrees-async-helper.sh
	# was running in before t2859.
	unset ORPHAN_WORKTREE_GRACE_SECS ORPHAN_MAX_AGE PULSE_IDLE_CPU_THRESHOLD 2>/dev/null || true

	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/pulse-cleanup.sh"

	# Activate strict mode AFTER sourcing — pulse-cleanup.sh is permissive
	# at source time but use sites must not trip nounset.
	set -u

	# Smoke call: 60s-old, 0-commit, 0-dirty, no branch, no slug.
	# With inline fallback ${ORPHAN_WORKTREE_GRACE_SECS:-1800}, this is
	# protected (60 < 1800). Without the fallback, would be eligible.
	if ! reason=$(_evaluate_worktree_removal 0 0 60 "" "" 2>&1) && [[ "$reason" == *"unbound variable"* ]]; then
		echo "FAIL: unbound-variable error during _evaluate_worktree_removal: $reason"
		exit 1
	fi
	echo "PASS: no unbound-variable errors under set -u with config unset"
) || fail "Standalone source produced unbound-variable errors"

# ============================================================================
# Test 2: With config defined, _evaluate_worktree_removal correctly grants
# the 30-minute grace period to a fresh 0-commit worktree.
# ============================================================================
echo ""
echo "=== Test 2: 30-minute grace period applies to fresh 0-commit worktree ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/pulse-cleanup.sh"

	# 0 commits, 0 dirty, 60s old, no branch, no slug
	# With grace=1800, 60 < 1800 → outer fast-path condition false →
	#   later elif branches all need clean+>=3h or dirty+>=6h or commits+>=24h →
	#   none match → return 1 (not eligible).
	if _evaluate_worktree_removal 0 0 60 "" "" >/dev/null 2>&1; then
		echo "FAIL: 60s-old worktree treated as eligible (grace period broken)"
		exit 1
	fi
	echo "PASS: 60s-old worktree correctly protected by grace period"
) || fail "Fresh worktree not protected by grace period"

# ============================================================================
# Test 3: Inline fallback works when config file is unavailable.
# Simulates the broken state: pulse-wrapper-config.sh missing, only
# pulse-cleanup.sh sourced. The use-site ${VAR:-default} fallbacks should
# still produce correct behaviour.
# ============================================================================
echo ""
echo "=== Test 3: Inline fallbacks protect against missing config ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/pulse-cleanup.sh"

	# Belt-and-suspenders test: explicitly unset the config var AFTER
	# sourcing, then call _evaluate_worktree_removal. The inline
	# ${ORPHAN_WORKTREE_GRACE_SECS:-1800} at line 280 should still
	# produce the correct grace value.
	unset ORPHAN_WORKTREE_GRACE_SECS

	# Same call as Test 2 — should still be protected by inline default.
	if _evaluate_worktree_removal 0 0 60 "" "" >/dev/null 2>&1; then
		echo "FAIL: inline fallback did not apply (60s worktree treated as eligible)"
		exit 1
	fi
	echo "PASS: inline fallback correctly applied 1800s grace"
) || fail "Inline fallback failed when config var unset"

# ============================================================================
# Test 4: Old worktree past grace period IS eligible (sanity — we did not
# accidentally break the actual cleanup path).
# ============================================================================
echo ""
echo "=== Test 4: Worktree past grace period is correctly eligible ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/pulse-cleanup.sh"

	# 0 commits, 0 dirty, 7200s (2h) old, no branch, no slug.
	# 7200 >= 1800 → outer fast-path matches → has_open_pr stays false
	# (no slug to query) → returns 0 with crashed-worker reason.
	if ! _evaluate_worktree_removal 0 0 7200 "" "" >/dev/null 2>&1; then
		echo "FAIL: 2h-old 0-commit worktree should be eligible after grace period"
		exit 1
	fi
	echo "PASS: 2h-old worktree correctly eligible after grace period"
) || fail "Past-grace worktree not eligible"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
	echo "=== All tests passed ==="
	exit 0
else
	echo "=== $FAIL_COUNT test(s) failed ==="
	exit 1
fi
