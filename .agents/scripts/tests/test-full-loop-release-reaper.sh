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

# Inverse of removed(); shell comparison so BSD sed (no ';t;' labels) is not needed.
not_removed() {
	local name="$1"
	local reason="$2"
	if [[ "$(removed "$name" "$reason")" == true ]]; then
		echo false
	else
		echo true
	fi
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
# Real detached worktrees of an empty commit, so the reaper's git status probe
# succeeds; a failed probe must keep the tree (case 6).
REPO="$ROOT/repo"
git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" -c user.name=reaper-test -c user.email=reaper-test@example.invalid \
	commit -q --allow-empty -m init
make_tree() {
	local name="$1"
	local age="${2:-old}"
	git -C "$REPO" worktree add -q --detach "$BASE/$name" HEAD
	if [[ "$age" == "old" ]]; then
		age_path "$BASE/$name/.git"
		age_path "$BASE/$name"
	fi
	return 0
}

reset_case() {
	rm -rf "$BASE" "$REMOVED_LOG"
	git -C "$REPO" worktree prune
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
check "lane PR kept" "$(not_removed "aidevops-release-600-${DEAD_PID}" release-preparation-stale)"
check "lane version kept" "$(not_removed "aidevops-release-reconcile-3.40.0-${DEAD_PID}" release-reconcile-stale)"
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
REPO_ROOT="$REPO"
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

# 5b. Only the lane repository's trees are candidates (GH#37433).
reset_case
OTHER="$ROOT/other"
git -c init.defaultBranch=main init -q "$OTHER"
git -C "$OTHER" -c user.name=reaper-test -c user.email=reaper-test@example.invalid \
	commit -q --allow-empty -m init
git -C "$OTHER" worktree add -q --detach "$BASE/aidevops-release-950-${DEAD_PID}" HEAD
age_path "$BASE/aidevops-release-950-${DEAD_PID}/.git"
age_path "$BASE/aidevops-release-950-${DEAD_PID}"
make_tree "aidevops-release-951-${DEAD_PID}"
STUB_LANE_RC=2
_full_loop_release_reap_with_lane owner/repo 10
check "other repository tree kept" "$(not_removed "aidevops-release-950-${DEAD_PID}" release-preparation-stale)"
check "own repository tree reaped" "$(removed "aidevops-release-951-${DEAD_PID}" release-preparation-stale)"

# 5c. Inherited repository-location variables must not redirect identity probes.
reset_case
git -C "$OTHER" worktree prune
git -C "$OTHER" worktree add -q --detach "$BASE/aidevops-release-960-${DEAD_PID}" HEAD
age_path "$BASE/aidevops-release-960-${DEAD_PID}/.git"
age_path "$BASE/aidevops-release-960-${DEAD_PID}"
make_tree "aidevops-release-961-${DEAD_PID}"
STUB_LANE_RC=2
GIT_COMMON_DIR="$OTHER/.git" GIT_DIR="$OTHER/.git" _full_loop_release_reap_with_lane owner/repo 10
check "inherited GIT_* keeps other repository tree" "$(not_removed "aidevops-release-960-${DEAD_PID}" release-preparation-stale)"
check "inherited GIT_* still reaps own tree" "$(removed "aidevops-release-961-${DEAD_PID}" release-preparation-stale)"

# 6. Fail closed: a failed status probe or a dirty tree is kept.
reset_case
BROKEN="$BASE/aidevops-release-900-${DEAD_PID}"
mkdir -p "$BROKEN"
printf 'gitdir: x\n' >"$BROKEN/.git"
age_path "$BROKEN/.git"
age_path "$BROKEN"
make_tree "aidevops-release-901-${DEAD_PID}"
printf 'wip\n' >"$BASE/aidevops-release-901-${DEAD_PID}/wip.txt"
age_path "$BASE/aidevops-release-901-${DEAD_PID}/wip.txt"
age_path "$BASE/aidevops-release-901-${DEAD_PID}"
make_tree "aidevops-release-902-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 10
check "status probe failure keeps tree" "$(not_removed "aidevops-release-900-${DEAD_PID}" release-preparation-stale)"
check "dirty tree kept" "$(not_removed "aidevops-release-901-${DEAD_PID}" release-preparation-stale)"
check "clean sibling still reaped" "$(removed "aidevops-release-902-${DEAD_PID}" release-preparation-stale)"

# 7. GH#37424: a freshly created Spotlight marker (which also bumps the root
# mtime) does not reset idleness; any other recent entry still does.
reset_case
printf '/.metadata_never_index\n' >>"$REPO/.git/info/exclude"
make_tree "aidevops-release-reconcile-3.39.2-${DEAD_PID}"
: >"$BASE/aidevops-release-reconcile-3.39.2-${DEAD_PID}/.metadata_never_index"
make_tree "aidevops-release-reconcile-3.39.3-${DEAD_PID}"
touch "$BASE/aidevops-release-reconcile-3.39.3-${DEAD_PID}/.git"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 10
check "marker-only change still idle" "$(removed "aidevops-release-reconcile-3.39.2-${DEAD_PID}" release-reconcile-stale)"
check "other recent entry keeps tree" "$(not_removed "aidevops-release-reconcile-3.39.3-${DEAD_PID}" release-reconcile-stale)"

# 8. GH#37424: newest-first, so low-numbered legacy trees cannot spend the limit.
reset_case
make_tree "aidevops-release-35956-${DEAD_PID}"
make_tree "aidevops-release-reconcile-3.39.4-${DEAD_PID}"
_full_loop_release_reap_stale_release_worktrees "$BASE" "" "" "" 1
check "newest candidate attempted first" "$([[ "$(count_removed)" == 1 ]] && [[ "$(removed "aidevops-release-reconcile-3.39.4-${DEAD_PID}" release-reconcile-stale)" == true ]] && echo true || echo false)"

# 9. Only the empty root marker file is ignored; anything else with that name
# is task data and counts as activity (directly on the idleness helper).
recently_active() {
	if _full_loop_release_tree_recently_active "$1"; then echo true; else echo false; fi
	return 0
}
idle() {
	if _full_loop_release_tree_recently_active "$1"; then echo false; else echo true; fi
	return 0
}
reset_case
for marker_case in empty nonempty dir nested symlink; do
	make_tree "aidevops-release-reconcile-3.39.9-${marker_case}"
done
MARKER_TREE="$BASE/aidevops-release-reconcile-3.39.9"
: >"${MARKER_TREE}-empty/.metadata_never_index"
printf 'task data\n' >"${MARKER_TREE}-nonempty/.metadata_never_index"
mkdir "${MARKER_TREE}-dir/.metadata_never_index"
age_path "${MARKER_TREE}-dir/.metadata_never_index"
touch "${MARKER_TREE}-dir/.metadata_never_index/task.txt"
mkdir "${MARKER_TREE}-nested/sub"
: >"${MARKER_TREE}-nested/sub/.metadata_never_index"
age_path "${MARKER_TREE}-nested/sub"
ln -s "$ROOT/elsewhere" "${MARKER_TREE}-symlink/.metadata_never_index"
check "empty root marker is idle" "$(idle "${MARKER_TREE}-empty")"
check "non-empty marker counts" "$(recently_active "${MARKER_TREE}-nonempty")"
check "marker directory contents count" "$(recently_active "${MARKER_TREE}-dir")"
check "nested marker-named entry counts" "$(recently_active "${MARKER_TREE}-nested")"
check "marker symlink counts" "$(recently_active "${MARKER_TREE}-symlink")"
check "unreadable tree fails closed" "$(recently_active "$BASE/missing-tree")"

if [[ "$FAILURES" -ne 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All release reaper tests passed\n'
exit 0
