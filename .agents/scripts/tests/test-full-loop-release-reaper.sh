#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tests the stale release worktree reaper (GH#37339). Removal is recorded by a
# stub; the audited fence itself is covered by test-full-loop-release-helper.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
mkdir -p "$HOME"

# shellcheck source=../full-loop-release-worktree-lib.sh
source "$SCRIPT_DIR/full-loop-release-worktree-lib.sh"

REMOVED_LOG="$ROOT/removed.log"
_full_loop_release_remove_worktree() {
	printf '%s %s\n' "${1##*/}" "$2" >>"$REMOVED_LOG"
	return 0
}

FAILURES=0
check() {
	local label="$1"
	local condition="$2"
	if [[ "$condition" == "true" ]]; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s\n' "$label"
		FAILURES=$((FAILURES + 1))
	fi
	return 0
}

removed() {
	[[ -f "$REMOVED_LOG" ]] && grep -qxF -- "$1 $2" "$REMOVED_LOG" && echo true || echo false
	return 0
}

count_removed() {
	[[ -f "$REMOVED_LOG" ]] || {
		echo 0
		return 0
	}
	wc -l <"$REMOVED_LOG" | tr -d ' '
	return 0
}

# A guaranteed-dead PID.
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" || true
LIVE_PID=$$

age_path() {
	local ts
	ts=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)
	touch -t "$ts" "$1"
	return 0
}

BASE="$ROOT/worktrees"
mkdir -p "$BASE"
make_tree() {
	local name="$1"
	local age="${2:-old}"
	mkdir -p "$BASE/$name"
	printf 'gitdir: x\n' >"$BASE/$name/.git"
	if [[ "$age" == "old" ]]; then
		age_path "$BASE/$name/.git"
		age_path "$BASE/$name"
	fi
	return 0
}

reset_case() {
	rm -rf "$BASE" "$REMOVED_LOG"
	mkdir -p "$BASE"
	return 0
}

# 1. Dead-owner idle trees are removed with the matching reason.
reset_case
make_tree "aidevops-release-reconcile-3.39.1-${DEAD_PID}"
make_tree "aidevops-release-500-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 10
check "reconcile removed" "$(removed "aidevops-release-reconcile-3.39.1-${DEAD_PID}" release-reconcile-stale)"
check "preparation removed" "$(removed "aidevops-release-500-${DEAD_PID}" release-preparation-stale)"

# 2. Keep rules.
reset_case
make_tree "aidevops-release-501-${LIVE_PID}"
make_tree "aidevops-release-502-${DEAD_PID}" young
make_tree "aidevops-release-control-${DEAD_PID}"
make_tree "aidevops-release-aggregate-recovery-503-${DEAD_PID}"
make_tree "aidevops-release-504-${DEAD_PID}x"
mkdir -p "$BASE/aidevops-release-505-${DEAD_PID}"
mkdir -p "$ROOT/elsewhere"
printf 'gitdir: x\n' >"$ROOT/elsewhere/.git"
ln -s "$ROOT/elsewhere" "$BASE/aidevops-release-506-${DEAD_PID}"
age_path "$BASE/aidevops-release-505-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 10
check "keeps live, young, foreign, symlink, no .git" "$([[ "$(count_removed)" == 0 ]] && echo true || echo false)"

# 3. Lane protection.
reset_case
make_tree "aidevops-release-600-${DEAD_PID}"
make_tree "aidevops-release-601-${DEAD_PID}"
make_tree "aidevops-release-reconcile-3.40.0-${DEAD_PID}"
make_tree "aidevops-release-reconcile-3.40.1-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "600" "3.40.0" 10
check "lane PR kept" "$(removed "aidevops-release-600-${DEAD_PID}" release-preparation-stale | sed 's/true/false/;t;s/false/true/')"
check "lane version kept" "$(removed "aidevops-release-reconcile-3.40.0-${DEAD_PID}" release-reconcile-stale | sed 's/true/false/;t;s/false/true/')"
check "other PR reaped" "$(removed "aidevops-release-601-${DEAD_PID}" release-preparation-stale)"
check "other version reaped" "$(removed "aidevops-release-reconcile-3.40.1-${DEAD_PID}" release-reconcile-stale)"
reset_case
make_tree "aidevops-release-602-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "$DEAD_PID" "" "" 10
check "lane executor PID kept" "$([[ "$(count_removed)" == 0 ]] && echo true || echo false)"

# 4. Limit.
reset_case
make_tree "aidevops-release-700-${DEAD_PID}"
make_tree "aidevops-release-701-${DEAD_PID}"
make_tree "aidevops-release-702-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 2
check "limit honoured" "$([[ "$(count_removed)" == 2 ]] && echo true || echo false)"

# 5. Lane wrapper: read failure reaps nothing; no lane / inactive lane protects nothing.
export AIDEVOPS_WORKTREE_BASE_DIR="$BASE"
reset_case
make_tree "aidevops-release-800-${DEAD_PID}"
STUB_LANE_RC=0
STUB_LANE_JSON=''
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON="$STUB_LANE_JSON"
	return "$STUB_LANE_RC"
}
STUB_LANE_RC=75
_full_loop_release_reap_with_lane owner/repo 10
check "lane read failure reaps nothing" "$([[ "$(count_removed)" == 0 ]] && echo true || echo false)"
STUB_LANE_RC=2
_full_loop_release_reap_with_lane owner/repo 10
check "no lane protects nothing" "$([[ "$(count_removed)" == 1 ]] && echo true || echo false)"
reset_case
make_tree "aidevops-release-801-${DEAD_PID}"
make_tree "aidevops-release-802-${DEAD_PID}"
make_tree "aidevops-release-reconcile-3.41.0-${DEAD_PID}"
STUB_LANE_RC=0
STUB_LANE_JSON='{"active":true,"source_pr":801,"tag":"v3.41.0","executor":{"pid":1}}'
_full_loop_release_reap_with_lane owner/repo 10
check "active lane keeps its trees" "$([[ "$(count_removed)" == 1 ]] && [[ "$(removed "aidevops-release-802-${DEAD_PID}" release-preparation-stale)" == true ]] && echo true || echo false)"
reset_case
make_tree "aidevops-release-803-${DEAD_PID}"
STUB_LANE_JSON='{"active":false,"source_pr":803,"tag":null,"executor":{"pid":1}}'
_full_loop_release_reap_with_lane owner/repo 10
check "inactive lane protects nothing" "$([[ "$(count_removed)" == 1 ]] && echo true || echo false)"

if [[ "$FAILURES" -ne 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All release reaper tests passed\n'
exit 0
