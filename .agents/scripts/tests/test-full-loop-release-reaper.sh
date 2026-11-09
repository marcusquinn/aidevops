#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#37339: stale release preparation and reconcile-tag worktree reaper.
# The audited removal fence itself is covered by test-full-loop-release-helper.sh;
# this suite pins which trees reach it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
ROOT=$(mktemp -d)
LIVE_PID=""
cleanup_fixture() {
	[[ -z "$LIVE_PID" ]] || kill "$LIVE_PID" 2>/dev/null || true
	rm -rf "$ROOT"
	return 0
}
trap cleanup_fixture EXIT

export HOME="$ROOT/home"
export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees"
mkdir -p "$HOME" "$AIDEVOPS_WORKTREE_BASE_DIR"
# shellcheck source=../full-loop-release-worktree-lib.sh
source "$SCRIPT_DIR/full-loop-release-worktree-lib.sh"

REMOVED_LOG="$ROOT/removed.log"
_full_loop_release_remove_worktree() {
	local wt_path="$1"
	local reason="$2"
	printf '%s %s\n' "${wt_path##*/}" "$reason" >>"$REMOVED_LOG"
	rm -rf "$wt_path"
	return 0
}

sleep 300 &
LIVE_PID=$!
(exit 0) &
DEAD_PID=$!
wait "$DEAD_PID" || true

FAILURES=0
fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	FAILURES=$((FAILURES + 1))
	return 0
}

# Args: $1=tree name, $2=old|young
make_tree() {
	local name="$1"
	local age="$2"
	mkdir -p "$AIDEVOPS_WORKTREE_BASE_DIR/$name"
	: >"$AIDEVOPS_WORKTREE_BASE_DIR/$name/.git"
	[[ "$age" != "old" ]] || touch -t 202001010000 "$AIDEVOPS_WORKTREE_BASE_DIR/$name"
	return 0
}

reset_fixture() {
	rm -rf "${AIDEVOPS_WORKTREE_BASE_DIR:?}" "$REMOVED_LOG"
	mkdir -p "$AIDEVOPS_WORKTREE_BASE_DIR"
	: >"$REMOVED_LOG"
	return 0
}

assert_present() {
	local name="$1"
	[[ -d "$AIDEVOPS_WORKTREE_BASE_DIR/$name" ]] || fail "$name should be preserved"
	return 0
}

assert_removed() {
	local name="$1"
	local reason="$2"
	[[ ! -e "$AIDEVOPS_WORKTREE_BASE_DIR/$name" ]] || fail "$name should be removed"
	grep -qx "$name $reason" "$REMOVED_LOG" || fail "$name should be removed with $reason"
	return 0
}

# --- guards ---
reset_fixture
make_tree "aidevops-release-reconcile-3.39.140-${DEAD_PID}" old
make_tree "aidevops-release-32417-${DEAD_PID}" old
make_tree "aidevops-release-32418-${LIVE_PID}" old
make_tree "aidevops-release-32419-${DEAD_PID}" young
make_tree "aidevops-release-control-${DEAD_PID}" old
make_tree "aidevops-release-abc-${DEAD_PID}" old
mkdir -p "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-32420-${DEAD_PID}"
touch -t 202001010000 "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-32420-${DEAD_PID}"
make_tree "symlink-target" old
ln -s "$AIDEVOPS_WORKTREE_BASE_DIR/symlink-target" "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-32421-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$AIDEVOPS_WORKTREE_BASE_DIR" "" "" "" 50 2>/dev/null
assert_removed "aidevops-release-reconcile-3.39.140-${DEAD_PID}" release-reconcile-stale
assert_removed "aidevops-release-32417-${DEAD_PID}" release-preparation-stale
assert_present "aidevops-release-32418-${LIVE_PID}"
assert_present "aidevops-release-32419-${DEAD_PID}"
assert_present "aidevops-release-control-${DEAD_PID}"
assert_present "aidevops-release-abc-${DEAD_PID}"
assert_present "aidevops-release-32420-${DEAD_PID}"
[[ -L "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-32421-${DEAD_PID}" ]] || fail "symlinked tree should be preserved"
[[ "$(wc -l <"$REMOVED_LOG" | tr -d ' ')" == "2" ]] || fail "only dead, idle, well-formed trees should be removed"
printf 'PASS only dead, idle, well-formed preparation and reconcile trees are reaped\n'

# --- active-lane protection ---
reset_fixture
make_tree "aidevops-release-500-${DEAD_PID}" old
make_tree "aidevops-release-reconcile-3.39.150-${DEAD_PID}" old
make_tree "aidevops-release-501-1" old
make_tree "aidevops-release-502-${DEAD_PID}" old
_full_loop_release_reap_stale_release_worktrees "$AIDEVOPS_WORKTREE_BASE_DIR" 1 500 3.39.150 50 2>/dev/null
assert_present "aidevops-release-500-${DEAD_PID}"
assert_present "aidevops-release-reconcile-3.39.150-${DEAD_PID}"
assert_present "aidevops-release-501-1"
assert_removed "aidevops-release-502-${DEAD_PID}" release-preparation-stale
printf 'PASS active lane source, tag and executor trees are protected\n'

# --- limit ---
reset_fixture
make_tree "aidevops-release-600-${DEAD_PID}" old
make_tree "aidevops-release-601-${DEAD_PID}" old
make_tree "aidevops-release-602-${DEAD_PID}" old
_full_loop_release_reap_stale_release_worktrees "$AIDEVOPS_WORKTREE_BASE_DIR" "" "" "" 2 2>/dev/null
[[ "$(wc -l <"$REMOVED_LOG" | tr -d ' ')" == "2" ]] || fail "limit should cap removal attempts"
printf 'PASS removal attempts are capped by the limit\n'

# --- lane read outcomes ---
# Globals, not locals: Bash dynamic scoping would resolve a stub's local name
# through the caller's own `lane_rc`.
FIXTURE_LANE_RC=0
FIXTURE_LANE_JSON=""
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON="$FIXTURE_LANE_JSON"
	if [[ "$FIXTURE_LANE_RC" -ne 0 ]]; then
		return "$FIXTURE_LANE_RC"
	fi
	return 0
}

lane_case() {
	FIXTURE_LANE_RC="$1"
	FIXTURE_LANE_JSON="$2"
	reset_fixture
	make_tree "aidevops-release-700-${DEAD_PID}" old
	make_tree "aidevops-release-701-${DEAD_PID}" old
	_full_loop_release_reap_with_lane test/repo 50 2>/dev/null
	return 0
}

lane_case 1 ""
assert_present "aidevops-release-700-${DEAD_PID}"
assert_present "aidevops-release-701-${DEAD_PID}"
printf 'PASS an unreadable lane reaps nothing\n'

lane_case 0 '{"active":true,"source_pr":700,"phase":"reserved","tag":null}'
assert_present "aidevops-release-700-${DEAD_PID}"
assert_present "aidevops-release-701-${DEAD_PID}"
printf 'PASS an active lane without a valid executor reaps nothing\n'

lane_case 0 '{"active":true,"source_pr":700,"phase":"preparing","tag":null,"executor":{"pid":1}}'
assert_present "aidevops-release-700-${DEAD_PID}"
assert_removed "aidevops-release-701-${DEAD_PID}" release-preparation-stale
printf 'PASS an active lane protects only its own source\n'

lane_case 0 '{"active":false,"source_pr":700,"phase":"terminal","tag":"v3.39.150"}'
assert_removed "aidevops-release-700-${DEAD_PID}" release-preparation-stale
assert_removed "aidevops-release-701-${DEAD_PID}" release-preparation-stale
printf 'PASS an inactive lane protects nothing\n'

lane_case 2 ""
assert_removed "aidevops-release-700-${DEAD_PID}" release-preparation-stale
assert_removed "aidevops-release-701-${DEAD_PID}" release-preparation-stale
printf 'PASS a missing lane protects nothing\n'

[[ "$FAILURES" -eq 0 ]] || exit 1
printf 'All release reaper checks passed\n'
