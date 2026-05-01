#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/remote-branch-cleanup-helper.sh"
TEST_ROOT="${PWD}/.agents/tmp/test-remote-branch-cleanup.$$"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local message="$3"
	case "$haystack" in
	*"$needle"*) pass "$message" ;;
	*) fail "$message (missing: $needle)" ;;
	esac
	return 0
}

assert_ref_exists() {
	local repo="$1"
	local branch="$2"
	local message="$3"
	git -C "$repo" ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null 2>&1 || fail "$message"
	pass "$message"
	return 0
}

assert_ref_missing() {
	local repo="$1"
	local branch="$2"
	local message="$3"
	if git -C "$repo" ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null 2>&1; then
		fail "$message"
	fi
	pass "$message"
	return 0
}

cleanup() {
	git -C "$TEST_ROOT/repo" worktree remove --force "$TEST_ROOT/active-wt" >/dev/null 2>&1 || true
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

make_commit() {
	local repo="$1"
	local file="$2"
	local content="$3"
	printf '%s\n' "$content" >"${repo}/${file}"
	git -C "$repo" add "$file"
	git -C "$repo" commit -qm "add ${file}"
	return 0
}

make_branch() {
	local repo="$1"
	local branch="$2"
	local file="$3"
	local content="$4"
	git -C "$repo" checkout -q main
	git -C "$repo" checkout -qb "$branch"
	make_commit "$repo" "$file" "$content"
	git -C "$repo" push -q origin "$branch"
	return 0
}

merge_branch_to_main() {
	local repo="$1"
	local branch="$2"
	git -C "$repo" checkout -q main
	git -C "$repo" merge -q --no-ff "$branch" -m "merge ${branch}"
	git -C "$repo" push -q origin main
	return 0
}

install_gh_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=""
while [[ $# -gt 0 ]]; do
	case "${1:-}" in
	--state)
		state="${2:-}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
if [[ "$state" == "open" ]]; then
	printf '%s\n' "open-pr"
fi
STUB
	chmod +x "${bin_dir}/gh"
	return 0
}

setup_repo() {
	mkdir -p "$TEST_ROOT"
	git init -q --bare "$TEST_ROOT/origin.git"
	git clone -q "$TEST_ROOT/origin.git" "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email test@example.invalid
	git -C "$TEST_ROOT/repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$TEST_ROOT/repo" base.txt base
	git -C "$TEST_ROOT/repo" branch -M main
	git -C "$TEST_ROOT/repo" push -q -u origin main
	git -C "$TEST_ROOT/origin.git" symbolic-ref HEAD refs/heads/main

	make_branch "$TEST_ROOT/repo" merged-safe merged.txt merged
	merge_branch_to_main "$TEST_ROOT/repo" merged-safe

	make_branch "$TEST_ROOT/repo" unmerged unmerged.txt unmerged

	make_branch "$TEST_ROOT/repo" open-pr open.txt open
	merge_branch_to_main "$TEST_ROOT/repo" open-pr

	make_branch "$TEST_ROOT/repo" active-worktree active.txt active
	merge_branch_to_main "$TEST_ROOT/repo" active-worktree
	git -C "$TEST_ROOT/repo" worktree add -q "$TEST_ROOT/active-wt" active-worktree

	git -C "$TEST_ROOT/repo" fetch -q origin
	return 0
}

run_dry_run_assertions() {
	local repo="$1"
	local output
	local gh_bin="$TEST_ROOT/bin"
	install_gh_stub "$gh_bin"
	output=$(PATH="$gh_bin:$PATH" bash "$HELPER" --repo "$repo" --skip-fetch)

	assert_contains "$output" "would-del  merged-safe" "merged branch is a deletion candidate"
	assert_contains "$output" "review     unmerged" "unmerged branch is manual-review only"
	assert_contains "$output" "skip       open-pr" "open PR branch is skipped"
	assert_contains "$output" "open PR exists" "open PR skip reason is shown"
	assert_contains "$output" "skip       active-worktree" "active worktree branch is skipped"
	assert_contains "$output" "protected/default branch" "default branch is protected"
	assert_contains "$output" "Dry-run only" "default mode is dry-run"
	return 0
}

run_apply_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	PATH="$gh_bin:$PATH" bash "$HELPER" --repo "$repo" --skip-fetch --apply >/dev/null

	assert_ref_missing "$repo" merged-safe "apply deletes merged safe branch"
	assert_ref_exists "$repo" unmerged "apply preserves unmerged branch"
	assert_ref_exists "$repo" open-pr "apply preserves open PR branch"
	assert_ref_exists "$repo" active-worktree "apply preserves active worktree branch"
	assert_ref_exists "$repo" main "apply preserves default branch"
	return 0
}

main() {
	setup_repo
	run_dry_run_assertions "$TEST_ROOT/repo"
	run_apply_assertions "$TEST_ROOT/repo"
	return 0
}

main "$@"
