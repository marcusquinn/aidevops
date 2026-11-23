#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# GH#39985: commit-and-pr must not ship TODO.md lines that belong to other tasks.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/full-loop-helper-commit.sh"
print_warning() { printf 'WARN %s\n' "$*"; return 0; }
eval "$(sed -n '/^_derive_pr_title_prefix()/,/^}/p;/^_unstage_foreign_todo_lines()/,/^}/p' "$SRC")"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q .
git config user.email t@example.com
git config user.name t
printf -- '- [ ] t1 own ref:GH#10\n' >TODO.md
git add . && git commit -qm init

issue_number=10
fail=0

printf -- '- [ ] t2 other ref:GH#20\n' >>TODO.md
git add -A
_unstage_foreign_todo_lines >/dev/null
if git diff --cached --quiet -- TODO.md && grep -q 't2 other' TODO.md; then
	echo "PASS foreign-only unstaged, working tree kept"
else
	echo "FAIL foreign-only"
	fail=1
fi

printf -- '- [x] t1 own ref:GH#10\n' >>TODO.md
git add -A
_unstage_foreign_todo_lines >/dev/null
if ! git diff --cached --quiet -- TODO.md; then
	echo "PASS own-task line stays staged"
else
	echo "FAIL own-task"
	fail=1
fi
exit "$fail"
