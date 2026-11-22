#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-squash-continuation.sh — GH#39862 regression guard.
#
# Uses a real local bare origin. A first partial PR is squash-merged from a
# worker head, the base later changes the shared coverage ledger, and the same
# worker commits the next unit on the original head. commit-and-pr's staging
# step (_stage_and_commit) must:
#   1. replay only the post-merge unit onto the refreshed base, on a fresh
#      "<branch>-s2" branch, leaving the merged remote ref untouched;
#   2. publish that fresh head through _push_branch without a force-push;
#   3. leave a never-merged branch exactly as before;
#   4. continue an open PR on the same head unchanged;
#   5. refuse a merged head with no new commits;
#   6. restore the original tip when replaying the unit conflicts.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$1"
	return 0
}
fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t gh39862.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
LOG="${TMP}/log"
: >"$LOG"

print_info() { printf '[INFO] %s\n' "$*" >>"$LOG"; return 0; }
print_error() { printf '[ERROR] %s\n' "$*" >>"$LOG"; return 0; }
print_warning() { printf '[WARN] %s\n' "$*" >>"$LOG"; return 0; }
print_success() { printf '[OK] %s\n' "$*" >>"$LOG"; return 0; }

# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPTS_DIR}/full-loop-helper-commit.sh"

# REST PR listing stub: prints the preformatted _list_head_ref_prs rows.
GH_PULLS_OUTPUT=""
gh() {
	printf 'gh %s\n' "$*" >>"$LOG"
	[[ "$*" == *"/pulls"* && -n "$GH_PULLS_OUTPUT" ]] && printf '%b\n' "$GH_PULLS_OUTPUT"
	return 0
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
setup_identity() {
	git config user.email t@example.invalid
	git config user.name t
	git config core.hooksPath /dev/null
	return 0
}

# Coverage ledger with separated hunks: 2023 row, 2024 row, base footer.
write_ledger() {
	local y2023="$1" y2024="$2" footer="$3" i=0
	{
		printf 'coverage ledger\n2023: %s\n' "$y2023"
		for i in 1 2 3 4 5 6 7 8; do printf 'filler-a-%s\n' "$i"; done
		printf '2024: %s\n' "$y2024"
		for i in 1 2 3 4 5 6 7 8; do printf 'filler-b-%s\n' "$i"; done
		printf 'footer: %s\n' "$footer"
	} >ledger.txt
	return 0
}
remote_sha() { git ls-remote --heads origin "refs/heads/$1" | awk '{print $1}'; return 0; }

git init -q --bare -b main "${TMP}/origin.git"
git init -q -b main "${TMP}/work"
cd "${TMP}/work" || exit 1
setup_identity
git remote add origin "${TMP}/origin.git"
mkdir -p results
write_ledger pending pending base-0
git add -A && git commit -q -m base
git push -q origin main
git remote set-head origin main

BR="feature/auto-20261122-000000-gh101"
git checkout -q -b "$BR"
printf '2024 rows\n' >results/2024.txt
write_ledger pending partial base-0
git add -A && git commit -q -m "data: 2024 results part 1"
write_ledger pending complete base-0
git add -A && git commit -q -m "data: 2024 results part 2"
git push -q origin "$BR"
merged_head=$(git rev-parse HEAD)

# Squash-merge the first PR, then change the shared ledger on the base.
git clone -q "${TMP}/origin.git" "${TMP}/merger"
(
	cd "${TMP}/merger" || exit 1
	setup_identity
	git merge -q --squash "origin/${BR}" >/dev/null && git commit -q -m "GH#101: 2024 results (#5)" &&
		git push -q origin main &&
		write_ledger pending complete base-1 && git commit -q -am "chore: base ledger update" &&
		git push -q origin main
) || exit 1
git fetch -q origin main
squash_sha=$(git rev-parse origin/main~1)

# Same worker commits the next unit on the original (already merged) head.
printf '2023 rows\n' >results/2023.txt
write_ledger complete complete base-0
git add -A && git commit -q -m "data: 2023 results"
original_tip=$(git rev-parse HEAD)

naive_count=$(git rev-list --count origin/main..HEAD)
if [[ "$naive_count" == 3 ]]; then
	pass "reproduction: original head still carries the 2 already-merged commits"
else
	fail "reproduction: original head still carries the 2 already-merged commits" "count=${naive_count}"
fi

# 1. Squash-merged continuation → fresh branch with only the new unit.
repo="owner/repo"
branch="$BR"
replacement_pr=""
summary_decisions=""
GH_PULLS_OUTPUT="merged\t5\t${merged_head}\t${squash_sha}"
# --no-rebase must refuse recovery before replay or branch renaming.
skip_rebase=1
: >"$LOG"
rc=0
_stage_and_commit "data: 2023 results" || rc=$?
if [[ "$rc" -ne 0 && "$(git rev-parse HEAD)" == "$original_tip" &&
	"$(git branch --show-current)" == "$BR" && -z "$FULL_LOOP_CONTINUATION_BRANCH" &&
	! -e "$(git rev-parse --git-path rebase-merge)" ]] &&
	grep -q -- '--no-rebase' "$LOG" && ! grep -q 'Replaying' "$LOG"; then
	pass "--no-rebase refuses continuation replay without changing HEAD or branch"
else
	fail "--no-rebase refuses continuation replay without changing HEAD or branch" "rc=${rc}; $(cat "$LOG")"
fi
skip_rebase=0

# Restrict the configured mapping and leave origin/main behind the live base.
# Recovery must explicitly refresh the ref it uses, not just FETCH_HEAD.
current_base=$(git rev-parse origin/main)
git update-ref refs/remotes/origin/main "$squash_sha"
git config remote.origin.fetch "+refs/heads/${BR}:refs/remotes/origin/${BR}"
: >"$LOG"
rc=0
_stage_and_commit "data: 2023 results" || rc=$?
if [[ "$(git rev-parse origin/main)" == "$current_base" ]] &&
	git merge-base --is-ancestor "$current_base" HEAD; then
	pass "restricted fetch refspec still refreshes origin/main and replays on current base"
else
	fail "restricted fetch refspec still refreshes origin/main and replays on current base"
fi
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
subjects=$(git log --format=%s origin/main..HEAD)
files=$(git diff --name-only origin/main HEAD | tr '\n' ' ')
if [[ "$rc" -eq 0 && "$branch" == "${BR}-s2" && "$(git branch --show-current)" == "${BR}-s2" &&
	"$FULL_LOOP_CONTINUATION_BRANCH" == "${BR}-s2" ]]; then
	pass "continuation moved to fresh branch ${BR}-s2"
else
	fail "continuation moved to fresh branch ${BR}-s2" "rc=${rc}; branch=${branch}; $(cat "$LOG")"
fi
if [[ "$subjects" == "data: 2023 results" && "$files" == "ledger.txt results/2023.txt " ]]; then
	pass "origin/main..HEAD holds only the new unit's commit and diff"
else
	fail "origin/main..HEAD holds only the new unit's commit and diff" "subjects=${subjects}; files=${files}"
fi
if grep -q '^footer: base-1$' ledger.txt && grep -q '^2023: complete$' ledger.txt; then
	pass "base ledger update preserved under the replayed unit"
else
	fail "base ledger update preserved under the replayed unit" "$(tr '\n' ';' <ledger.txt)"
fi
if mt_out=$(git merge-tree --write-tree origin/main HEAD 2>&1); then
	pass "continuation merges cleanly into the updated base (not DIRTY)"
elif [[ "$mt_out" == *"usage"* || "$mt_out" == *"unknown option"* ]]; then
	pass "continuation mergeability (skipped: git merge-tree --write-tree unavailable)"
else
	fail "continuation merges cleanly into the updated base (not DIRTY)" "$mt_out"
fi
if [[ "$summary_decisions" == *"PR #5"* && "$summary_decisions" == *"GH#39862"* ]] &&
	grep -q -- "head=.*${BR}" "$LOG"; then
	pass "merge summary decisions record the continuation; lookup used the head ref"
else
	fail "merge summary decisions record the continuation; lookup used the head ref" "decisions=${summary_decisions}; $(cat "$LOG")"
fi

# 2. Publish the fresh head: merged ref untouched, no force-push needed.
: >"$LOG"
if _push_branch "$branch" 0 "$repo" && [[ "$FULL_LOOP_PUSHED_BRANCH" == "${BR}-s2" ]] &&
	[[ "$(remote_sha "${BR}-s2")" == "$(git rev-parse HEAD)" ]] &&
	[[ "$(remote_sha "$BR")" == "$merged_head" ]]; then
	pass "push publishes ${BR}-s2 and preserves the merged ref"
else
	fail "push publishes ${BR}-s2 and preserves the merged ref" "$(cat "$LOG")"
fi

# 3. Never-merged branch → unchanged behaviour.
git checkout -q -b feature/auto-20261122-000001-gh102 origin/main
printf 'fresh\n' >results/2022.txt
git add -A && git commit -q -m "data: 2022 results"
plain_tip=$(git rev-parse HEAD)
branch="feature/auto-20261122-000001-gh102"
GH_PULLS_OUTPUT=""
: >"$LOG"
rc=0
_stage_and_commit "data: 2022 results" || rc=$?
if [[ "$rc" -eq 0 && "$branch" == "feature/auto-20261122-000001-gh102" && -z "$FULL_LOOP_CONTINUATION_BRANCH" &&
	"$(git rev-parse HEAD)" == "$plain_tip" && "$(git branch --show-current)" == "$branch" ]]; then
	pass "never-merged branch keeps its name and history"
else
	fail "never-merged branch keeps its name and history" "rc=${rc}; branch=${branch}; $(cat "$LOG")"
fi

# 4. Merged head that also backs an open PR → continued unchanged.
git checkout -q -b "$BR" "$original_tip"
branch="$BR"
GH_PULLS_OUTPUT="merged\t5\t${merged_head}\t${squash_sha}\nopen\t6\t${original_tip}\t"
: >"$LOG"
rc=0
_stage_and_commit "data: 2023 results" || rc=$?
if [[ "$rc" -eq 0 && "$branch" == "$BR" && "$(git rev-parse HEAD)" == "$original_tip" ]] &&
	grep -q 'backs an open PR' "$LOG"; then
	pass "open PR on the merged head is continued unchanged with a warning"
else
	fail "open PR on the merged head is continued unchanged with a warning" "rc=${rc}; $(cat "$LOG")"
fi

# 5. Merged head with nothing new → refused, nothing renamed.
git checkout -q -b feature/auto-20261122-000002-gh103 "$merged_head"
branch="feature/auto-20261122-000002-gh103"
GH_PULLS_OUTPUT="merged\t5\t${merged_head}\t${squash_sha}"
: >"$LOG"
rc=0
_stage_and_commit "data: nothing new" || rc=$?
if [[ "$rc" -ne 0 && "$(git branch --show-current)" == "$branch" && "$(git rev-parse HEAD)" == "$merged_head" ]] &&
	grep -q 'no commits beyond' "$LOG"; then
	pass "merged head without new commits is refused"
else
	fail "merged head without new commits is refused" "rc=${rc}; $(cat "$LOG")"
fi

# 6. Conflicting replay → original tip and branch restored, nothing pushed.
git checkout -q -b feature/auto-20261122-000003-gh104 "$merged_head"
write_ledger pending complete base-local
git commit -q -am "data: conflicting footer"
conflict_tip=$(git rev-parse HEAD)
branch="feature/auto-20261122-000003-gh104"
: >"$LOG"
rc=0
_stage_and_commit "data: conflicting footer" || rc=$?
if [[ "$rc" -ne 0 && "$(git branch --show-current)" == "$branch" && "$(git rev-parse HEAD)" == "$conflict_tip" ]] &&
	[[ ! -e "$(git rev-parse --git-path rebase-merge)" && -z "$(remote_sha "${branch}-s2")" ]] &&
	grep -q 'conflicted; HEAD restored' "$LOG"; then
	pass "conflicting replay restores the original tip and pushes nothing"
else
	fail "conflicting replay restores the original tip and pushes nothing" "rc=${rc}; $(cat "$LOG")"
fi

printf '\n%d/%d passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
