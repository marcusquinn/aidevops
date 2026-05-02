#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name" >&2
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${SCRIPT_DIR}/issue-sync-git-push-helper.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_init_repo() {
	local repo_dir="$1"
	git -C "$repo_dir" config user.name "Issue Sync Test"
	git -C "$repo_dir" config user.email "issue-sync-test@example.invalid"
	git -C "$repo_dir" config commit.gpgsign false
	return 0
}

create_origin() {
	local origin_dir="$1"
	local seed_dir="$2"
	git init --bare "$origin_dir" >/dev/null
	git init "$seed_dir" >/dev/null
	git_init_repo "$seed_dir"
	cat >"$seed_dir/TODO.md" <<'EOF'
## Ready

- [ ] t9001 original task ref:GH#9001
EOF
	git -C "$seed_dir" add TODO.md
	git -C "$seed_dir" commit -m "seed TODO" >/dev/null
	git -C "$seed_dir" branch -M main
	git -C "$seed_dir" remote add origin "$origin_dir"
	git -C "$seed_dir" push -u origin main >/dev/null
	git --git-dir="$origin_dir" symbolic-ref HEAD refs/heads/main
	return 0
}

test_successful_push() {
	local origin_dir="$TMP/success-origin.git"
	local seed_dir="$TMP/success-seed"
	local work_dir="$TMP/success-work"
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	printf '\n- [ ] t9002 new task ref:GH#9002\n' >>"$work_dir/TODO.md"
	git -C "$work_dir" add TODO.md
	git -C "$work_dir" commit -m "sync TODO" >/dev/null
	if (cd "$work_dir" && bash "$HELPER" push-todo main 2 >/tmp/issue-sync-success.log 2>&1); then
		pass "push helper pushes clean TODO.md commit"
	else
		fail "push helper pushes clean TODO.md commit"
	fi
	return 0
}

test_rebase_conflict_neutralizes_cleanly() {
	local origin_dir="$TMP/conflict-origin.git"
	local seed_dir="$TMP/conflict-seed"
	local work_dir="$TMP/conflict-work"
	local other_dir="$TMP/conflict-other"
	create_origin "$origin_dir" "$seed_dir"
	git clone "$origin_dir" "$work_dir" >/dev/null 2>&1
	git clone "$origin_dir" "$other_dir" >/dev/null 2>&1
	git_init_repo "$work_dir"
	git_init_repo "$other_dir"
	perl -0pi -e 's/original task/original task worker edit/' "$work_dir/TODO.md"
	git -C "$work_dir" add TODO.md
	git -C "$work_dir" commit -m "sync TODO worker" >/dev/null
	perl -0pi -e 's/original task/original task origin edit/' "$other_dir/TODO.md"
	git -C "$other_dir" add TODO.md
	git -C "$other_dir" commit -m "sync TODO origin" >/dev/null
	git -C "$other_dir" push origin main >/dev/null

	if (cd "$work_dir" && bash "$HELPER" push-todo main 2 >/tmp/issue-sync-conflict.log 2>&1); then
		if git -C "$work_dir" diff --quiet && ! git -C "$work_dir" status --porcelain | grep -q '^UU'; then
			pass "rebase conflict exits neutral with clean index"
		else
			fail "rebase conflict exits neutral with clean index"
		fi
	else
		fail "rebase conflict exits neutral with clean index"
	fi
	return 0
}

test_successful_push
test_rebase_conflict_neutralizes_cleanly

printf 'Tests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
