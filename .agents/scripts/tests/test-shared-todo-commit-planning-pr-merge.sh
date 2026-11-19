#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: planning PR fallback merges onto origin/<default> (GH#39120)
# Cases: stale-base add, conflicting edit, unnamed deletion, named deletion.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}/.."
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=../shared-todo-commit.sh
source "${SCRIPT_DIR}/shared-todo-commit.sh"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/planning-pr-merge-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
LOG="${ROOT}/log"
: >"$LOG"
FAILS=0

fail() {
	printf 'FAIL: %s\n' "$1"
	FAILS=$((FAILS + 1))
	return 0
}

# setup <name>: bare origin, caller clone at the old HEAD, origin/main one commit ahead.
setup() {
	local name="$1"
	local d="${ROOT}/${name}"
	mkdir -p "$d"
	git init -q --bare -b main "${d}/origin.git"
	git clone -q "${d}/origin.git" "${d}/caller" 2>/dev/null
	printf -- '- [ ] t1 first\n- [ ] t2 second\n- [x] t3 third\n' >"${d}/caller/TODO.md"
	git -C "${d}/caller" add TODO.md
	git -C "${d}/caller" commit -q -m "init"
	git -C "${d}/caller" push -q origin HEAD:main
	git clone -q "${d}/origin.git" "${d}/other" 2>/dev/null
	printf -- '- [ ] t1 first\n- [ ] t2 second\n- [x] t3 third\n- [ ] t4 newer on main\n' >"${d}/other/TODO.md"
	git -C "${d}/other" commit -q -am "plan: add t4"
	git -C "${d}/other" push -q origin HEAD:main
	git -C "${d}/caller" fetch -q origin
	git -C "${d}/caller" worktree add -q --detach "${d}/wt" origin/main
	printf '%s' "$d"
	return 0
}

# run_commit <dir> <message>: returns the commit function's exit code.
run_commit() {
	local d="$1"
	local msg="$2"
	_TODO_PLANNING_PR_REUSED=0
	if _todo_commit_planning_worktree "${d}/caller" "${d}/wt" "TODO.md" "TODO.md" "$msg" "planning/test" "pub-test" "$LOG" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Case 1: stale-base add keeps newer main rows.
d=$(setup add)
printf -- '- [ ] t5 mine\n- [ ] t1 first\n- [ ] t2 second\n- [x] t3 third\n' >"${d}/caller/TODO.md"
if run_commit "$d" "plan: add t5"; then
	deleted=$(git -C "${d}/wt" diff --numstat origin/main HEAD -- TODO.md | cut -f2)
	[[ "$deleted" == "0" ]] || fail "stale-base add deleted ${deleted} lines"
	git -C "${d}/wt" show HEAD:TODO.md | grep -q 't4 newer' || fail "t4 missing after merge"
	git -C "${d}/wt" show HEAD:TODO.md | grep -q 't5 mine' || fail "t5 missing after merge"
else
	fail "stale-base add was refused: $(tail -n 5 "$LOG")"
fi

# Case 2: conflicting edit fails before push and keeps caller edits.
d=$(setup conflict)
printf -- '- [ ] t1 edited on main\n- [ ] t2 second\n- [x] t3 third\n- [ ] t4 newer on main\n' >"${d}/other/TODO.md"
git -C "${d}/other" commit -q -am "plan: edit t1"
git -C "${d}/other" push -q origin HEAD:main
git -C "${d}/caller" fetch -q origin
git -C "${d}/caller" worktree remove --force "${d}/wt"
git -C "${d}/caller" worktree add -q --detach "${d}/wt" origin/main
printf -- '- [ ] t1 edited by caller\n- [ ] t2 second\n- [x] t3 third\n' >"${d}/caller/TODO.md"
if run_commit "$d" "plan: edit t1"; then
	fail "conflicting edit was published"
fi
grep -q 'edited by caller' "${d}/caller/TODO.md" || fail "caller edits not preserved"
grep -q 'Retryable' "$LOG" || fail "retry message missing"
[[ -z "$(git -C "${d}/origin.git" branch --list planning/test)" ]] || fail "conflict pushed a branch"

# Case 3: unnamed deletion refused; Case 4: named deletion allowed.
d=$(setup unnamed)
printf -- '- [ ] t1 first\n- [x] t3 third\n' >"${d}/caller/TODO.md"
if run_commit "$d" "plan: tidy"; then
	fail "unnamed deletion was published"
fi
[[ -z "$(git -C "${d}/origin.git" branch --list planning/test)" ]] || fail "refused deletion pushed a branch"

d=$(setup named)
printf -- '- [ ] t1 first\n- [x] t3 third\n' >"${d}/caller/TODO.md"
run_commit "$d" "plan: remove t2" || fail "named deletion was refused"

if [[ "$FAILS" -ne 0 ]]; then
	printf '%s case(s) failed\n' "$FAILS"
	exit 1
fi
printf 'PASS: planning PR fallback merge and regression guard\n'
exit 0
