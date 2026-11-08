#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/remote-branch-cleanup-helper.sh"
GIT_SHIM="${SCRIPTS_DIR}/git"
TEST_ROOT="${PWD}/.agents/tmp/test-remote-branch-cleanup.$$"
export WORKTREE_REGISTRY_DIR="$TEST_ROOT/registry"
export WORKTREE_REGISTRY_DB="$WORKTREE_REGISTRY_DIR/owners.db"
export AIDEVOPS_LIFECYCLE_STATE_DIR="$TEST_ROOT/lifecycle-state"
# Every scan now fetches through a linked transport (GH#36601); keep those
# transports inside the fixture instead of the user's worktree base.
export AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT/worktrees"
export REMOTE_BRANCH_CLEANUP_STUB_CLOSED_JSON="$TEST_ROOT/closed-prs.json"

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

assert_row() {
	local output="$1"
	local action="$2"
	local branch="$3"
	local reason="$4"
	local message="$5"
	local row=""
	row=$(printf '%-10s %-55s %s' "$action" "$branch" "$reason")
	assert_contains "$output" "$row" "$message"
	return 0
}

assert_no_phantom_rows() {
	local output="$1"
	local message="$2"
	if grep -Eq '^[a-z-]+ +(origin|HEAD) ' <<<"$output"; then
		fail "$message"
	fi
	pass "$message"
	return 0
}

assert_no_transport() {
	local repo="$1"
	local message="$2"
	if git -C "$repo" worktree list --porcelain | grep -F "$AIDEVOPS_WORKTREE_BASE_DIR" >/dev/null 2>&1; then
		fail "$message"
	fi
	pass "$message"
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
	git -C "$repo" -c commit.gpgsign=false commit -qm "add ${file}"
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
	git -C "$repo" -c commit.gpgsign=false merge -q --no-ff "$branch" -m "merge ${branch}"
	git -C "$repo" push -q origin main
	return 0
}

advance_origin_main() {
	local origin_repo="$1"
	local update_repo="$2"
	local update_name="${update_repo##*/}"
	git clone -q "$origin_repo" "$update_repo"
	git -C "$update_repo" config user.email test@example.invalid
	git -C "$update_repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$update_repo" "${update_name}.txt" "$update_name"
	git -C "$update_repo" push -q origin main
	return 0
}

install_gh_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"${REMOTE_BRANCH_CLEANUP_GH_CALL_LOG:-/dev/null}"
[[ "${1:-}" == "api" ]] || exit 1
endpoint="${2:-}"
case "$endpoint" in
*"pulls?state=open&per_page=100&page=1"*)
	if [[ "${REMOTE_BRANCH_CLEANUP_STUB_FULL_PAGE:-0}" == "1" ]]; then
		jq -cn '[range(0; 100) | {head: {ref: ("open-pr-" + (. | tostring))}, merged_at: null}]'
	else
		printf '%s\n' '[{"head":{"ref":"open-pr"},"merged_at":null}]'
	fi
	;;
*"pulls?state=open&per_page=100&page=2"*)
	printf '%s\n' '[{"head":{"ref":"open-pr"},"merged_at":null}]'
	;;
*"pulls?state=closed&per_page=100&page=1"*)
	if [[ -f "${REMOTE_BRANCH_CLEANUP_STUB_CLOSED_JSON:-}" ]]; then
		cat "$REMOTE_BRANCH_CLEANUP_STUB_CLOSED_JSON"
	else
		printf '%s\n' '[]'
	fi
	;;
*) exit 1 ;;
esac
exit 0
STUB
	chmod +x "${bin_dir}/gh"
	return 0
}

install_fetch_failure_git_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	# Token assembled at runtime so no token-shaped literal is committed.
	FAKE_FETCH_TOKEN="ghp_""PLACEHOLDERSUFFIX1234"
	cat >"${bin_dir}/git" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ " \$* " == *" fetch "* ]]; then
	printf '%s\n' \\
		"fatal: Authentication failed for https://x:${FAKE_FETCH_TOKEN}@example.invalid/r.git" \\
		"fetch diagnostic line 2" \\
		"fetch diagnostic line 3" \\
		"fetch diagnostic line 4" >&2
	exit 1
fi
exec "${GIT_SHIM}" "\$@"
STUB
	chmod +x "${bin_dir}/git"
	return 0
}

# Closed-PR fixture rows. head.repo.full_name must equal the helper's slug
# (the origin URL minus .git) to count as same-repository evidence.
closed_pr_row() {
	local number="$1"
	local ref="$2"
	local sha="$3"
	local merged="$4"
	local full_name="$5"
	jq -cn --argjson n "$number" --arg ref "$ref" --arg sha "$sha" \
		--arg merged "$merged" --arg full_name "$full_name" \
		'{number: $n, merged_at: (if $merged == "1" then "2026-01-01T00:00:00Z" else null end),
		  head: {ref: $ref, sha: $sha, repo: {full_name: $full_name}}}'
	return 0
}

setup_pr_evidence_fixtures() {
	local repo="$1"
	local slug="${TEST_ROOT}/origin"
	local exact_sha after_head ancestor_head fork_sha closed_exact_sha closed_after_head
	local rows=()

	# Squash-merged head: PR head SHA equals the branch tip.
	make_branch "$repo" squash-exact squash-exact.txt squash-exact
	exact_sha=$(git -C "$repo" rev-parse HEAD)

	# Post-merge commit: the PR merged at an earlier head (issue scenario).
	make_branch "$repo" squash-after squash-after.txt squash-after
	after_head=$(git -C "$repo" rev-parse HEAD)
	make_commit "$repo" squash-after-2.txt post-merge
	git -C "$repo" push -q origin squash-after

	# Tip is an ancestor of the merged PR head (later head commit not pushed).
	make_branch "$repo" squash-ancestor squash-ancestor.txt squash-ancestor
	make_commit "$repo" squash-ancestor-2.txt later
	ancestor_head=$(git -C "$repo" rev-parse HEAD)

	# A fork PR whose head.ref happens to equal an origin branch name.
	make_branch "$repo" fork-same-name fork.txt fork
	fork_sha=$(git -C "$repo" rev-parse HEAD)

	make_branch "$repo" closed-exact closed-exact.txt closed-exact
	closed_exact_sha=$(git -C "$repo" rev-parse HEAD)

	make_branch "$repo" closed-after closed-after.txt closed-after
	closed_after_head=$(git -C "$repo" rev-parse HEAD)
	make_commit "$repo" closed-after-2.txt post-close
	git -C "$repo" push -q origin closed-after

	git -C "$repo" checkout -q main
	rows+=("$(closed_pr_row 101 squash-exact "$exact_sha" 1 "$slug")")
	rows+=("$(closed_pr_row 102 squash-after "$after_head" 1 "$slug")")
	rows+=("$(closed_pr_row 103 squash-ancestor "$ancestor_head" 1 "$slug")")
	rows+=("$(closed_pr_row 104 fork-same-name "$fork_sha" 1 "someone-else/fork")")
	rows+=("$(closed_pr_row 105 closed-exact "$closed_exact_sha" 0 "$slug")")
	rows+=("$(closed_pr_row 106 closed-after "$closed_after_head" 0 "$slug")")
	printf '%s\n' "${rows[@]}" | jq -cs '.' >"$REMOTE_BRANCH_CLEANUP_STUB_CLOSED_JSON"
	return 0
}

install_readback_failure_git_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/git" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *"ls-remote --exit-code --heads origin refs/heads/merged-readback"* ]]; then
	exit 1
fi
exec "${GIT_SHIM}" "\$@"
STUB
	chmod +x "${bin_dir}/git"
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

	setup_pr_evidence_fixtures "$TEST_ROOT/repo"

	git -C "$TEST_ROOT/repo" fetch -q origin
	# refs/remotes/origin/HEAD abbreviates to "origin" with %(refname:short).
	git -C "$TEST_ROOT/repo" remote set-head origin main >/dev/null
	return 0
}

run_dry_run_assertions() {
	local repo="$1"
	local output gh_calls
	local gh_bin="$TEST_ROOT/bin"
	local gh_call_log="$TEST_ROOT/gh-calls.log"
	install_gh_stub "$gh_bin"
	: >"$gh_call_log"
	output=$(REMOTE_BRANCH_CLEANUP_GH_CALL_LOG="$gh_call_log" \
		REMOTE_BRANCH_CLEANUP_STUB_FULL_PAGE=1 \
		PATH="$gh_bin:$PATH" bash "$HELPER" --repo "$repo" --skip-fetch)
	gh_calls=$(<"$gh_call_log")

	assert_contains "$output" "would-del  merged-safe" "merged branch is a deletion candidate"
	assert_contains "$output" "review     unmerged" "unmerged branch is manual-review only"
	assert_contains "$output" "skip       open-pr" "open PR branch is skipped"
	assert_contains "$output" "open PR exists" "open PR skip reason is shown"
	assert_contains "$output" "skip       active-worktree" "active worktree branch is skipped"
	assert_contains "$output" "protected/default branch" "default branch is protected"
	assert_contains "$output" "Dry-run only" "default mode is dry-run"
	assert_contains "$gh_calls" "remote-branch-cleanup-pr-branches-rest|api repos/" "PR branch evidence uses attributed REST reads"
	assert_contains "$gh_calls" "pulls?state=open&per_page=100&page=1" "open PR branches use the first bounded REST page"
	assert_contains "$gh_calls" "pulls?state=open&per_page=100&page=2" "a full first page reads the second bounded REST page"
	if [[ "$gh_calls" == *"page=3"* || "$gh_calls" == *"--paginate"* ]]; then
		fail "remote branch cleanup must not exceed its two-page REST bound"
	fi
	pass "remote branch cleanup caps REST history reads at two pages"
	if [[ "$gh_calls" == *"pr list"* ]]; then
		fail "remote branch cleanup must not use native gh pr list"
	fi
	pass "remote branch cleanup avoids native gh pr list"

	# GH#36601: merged/closed PR evidence is bound to the branch tip SHA.
	assert_row "$output" would-del squash-exact "merged PR #101 head SHA" "exact merged PR head is a deletion candidate"
	assert_row "$output" would-del squash-ancestor "merged PR #103 head ancestor" "tip behind merged PR head is a deletion candidate"
	assert_row "$output" review squash-after "tip differs from merged PR #102 head" "post-merge commits require review"
	assert_row "$output" review fork-same-name "unmerged/no closed evidence" "same-named fork PR is not merged evidence"
	assert_row "$output" review closed-exact "unmerged/no closed evidence" "closed PR is not evidence without --include-closed-pr"
	assert_no_phantom_rows "$output" "remote HEAD symref does not appear as a branch row"
	assert_contains "$output" "refs=unfetched" "--skip-fetch reports unfetched refs"

	output=$(PATH="$gh_bin:$PATH" bash "$HELPER" --repo "$repo" --skip-fetch --include-closed-pr)
	assert_row "$output" would-del closed-exact "closed PR #105 head SHA (--include-closed-pr)" "exact closed PR head is a candidate with --include-closed-pr"
	assert_row "$output" review closed-after "tip differs from closed PR #106 head" "post-close commits require review"
	return 0
}

run_fetch_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	local fail_bin="$TEST_ROOT/fetch-fail-bin"
	local repos_file="$TEST_ROOT/repos.json"
	local late_clone="$TEST_ROOT/late-clone"
	local output=""
	local direct_rc=0
	local rc=0
	printf '{"initialized_repos":[{"path":"%s"}]}\n' "$repo" >"$repos_file"

	# A branch pushed elsewhere is unknown until the scan refreshes refs.
	git clone -q "$TEST_ROOT/origin.git" "$late_clone"
	git -C "$late_clone" config user.email test@example.invalid
	git -C "$late_clone" config user.name "Remote Branch Cleanup Test"
	git -C "$late_clone" checkout -qb late-branch
	make_commit "$late_clone" late.txt late
	git -C "$late_clone" push -q origin late-branch

	if (cd "$repo" && AIDEVOPS_REPOS_FILE="$repos_file" PATH="$SCRIPTS_DIR:$PATH" git fetch -q origin >/dev/null 2>&1); then
		fail "direct canonical git fetch must remain blocked"
	else
		direct_rc=$?
	fi
	[[ "$direct_rc" -eq 42 ]] || fail "direct canonical git fetch returns guard exit 42 (rc=$direct_rc)"
	pass "direct canonical git fetch remains blocked"

	# Inherited context from a different repository must not redirect the scan
	# or register its transport in that repository. late_clone already holds the
	# late-branch objects, so an inherited object directory or alternate would
	# let fetch move the ref without storing those objects in --repo.
	output=$(GIT_DIR="$late_clone/.git" GIT_WORK_TREE="$late_clone" \
		GIT_COMMON_DIR="$late_clone/.git" GIT_INDEX_FILE="$late_clone/.git/index" \
		GIT_OBJECT_DIRECTORY="$late_clone/.git/objects" \
		GIT_ALTERNATE_OBJECT_DIRECTORIES="$late_clone/.git/objects" \
		AIDEVOPS_REPOS_FILE="$repos_file" PATH="$SCRIPTS_DIR:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" 2>&1)
	assert_contains "$output" "refs=fresh" "canonical scan refreshes refs through the linked transport"
	assert_row "$output" review late-branch "unmerged/no closed evidence" "refreshed refs include a newly pushed branch"
	assert_row "$output" would-del squash-exact "merged PR #101 head SHA" "inherited Git context does not redirect repository reads"
	assert_no_transport "$late_clone" "inherited Git context does not register transport in another repository"
	if git -C "$repo" cat-file -e "refs/remotes/origin/late-branch^{commit}" 2>/dev/null; then
		pass "inherited object directories do not divert fetched objects from --repo"
	else
		fail "inherited object directories do not divert fetched objects from --repo"
	fi
	if [[ "$output" == *"Fetch/prune failed"* ]]; then
		fail "canonical scan must not report a fetch failure"
	fi
	pass "canonical scan does not report a fetch failure"
	assert_no_transport "$repo" "dry-run retires its fetch transport"

	install_fetch_failure_git_stub "$fail_bin"
	output=$(AIDEVOPS_REPOS_FILE="$repos_file" PATH="$fail_bin:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" 2>&1)
	assert_contains "$output" "refs=stale" "failed fetch marks a dry-run audit stale"
	assert_contains "$output" "dry-run audit uses stale remote-tracking refs" "failed fetch warns in dry-run"
	assert_contains "$output" "fetch failed: fatal: Authentication failed" "failed fetch reports its cause"
	assert_contains "$output" "fetch diagnostic line 3" "fetch failure diagnostic keeps the first three lines"
	if [[ "$output" == *"fetch diagnostic line 4"* ]]; then
		fail "fetch failure diagnostic must be limited to three lines"
	fi
	if [[ "$output" == *"$FAKE_FETCH_TOKEN"* ]]; then
		fail "fetch failure diagnostic must not leak the token"
	fi
	pass "fetch failure diagnostic scrubs the token"

	if output=$(AIDEVOPS_REPOS_FILE="$repos_file" PATH="$fail_bin:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" --apply 2>&1); then
		fail "apply must refuse when fetch/prune fails"
	else
		rc=$?
	fi
	[[ "$rc" -eq 1 ]] || fail "refused apply returns 1 (rc=$rc)"
	assert_contains "$output" "refusing --apply against stale remote-tracking refs" "apply reports stale-ref refusal"
	assert_ref_exists "$repo" merged-safe "refused apply deletes nothing"
	assert_ref_exists "$repo" squash-exact "refused apply preserves PR-evidence candidates"
	assert_no_transport "$repo" "refused apply retires its fetch transport"
	return 0
}

run_apply_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	local repos_file="$TEST_ROOT/repos.json"
	local worktree_base="$TEST_ROOT/worktrees"
	local direct_output=""
	local direct_rc=0
	printf '{"initialized_repos":[{"path":"%s"}]}\n' "$repo" >"$repos_file"
	if direct_output=$(cd "$repo" && AIDEVOPS_REPOS_FILE="$repos_file" PATH="$SCRIPTS_DIR:$PATH" git push origin --delete merged-safe 2>&1); then
		fail "direct canonical git push must remain blocked"
	else
		direct_rc=$?
	fi
	[[ "$direct_rc" -eq 42 ]] || fail "direct canonical git push returns guard exit 42 (rc=$direct_rc)"
	assert_contains "$direct_output" "BLOCKED by canonical Git guard" "direct canonical git push remains blocked"
	assert_ref_exists "$repo" merged-safe "blocked direct push preserves merged branch"

	AIDEVOPS_REPOS_FILE="$repos_file" \
		AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" \
		PATH="$SCRIPTS_DIR:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" --skip-fetch --apply >/dev/null

	assert_ref_missing "$repo" merged-safe "apply deletes merged safe branch"
	assert_ref_missing "$repo" squash-exact "apply deletes exact merged PR head"
	assert_ref_missing "$repo" squash-ancestor "apply deletes tip behind merged PR head"
	assert_ref_exists "$repo" squash-after "apply preserves post-merge commits"
	assert_ref_exists "$repo" fork-same-name "apply preserves branch matched only by a fork PR"
	assert_ref_exists "$repo" closed-exact "apply preserves closed PR branch without --include-closed-pr"
	assert_ref_exists "$repo" unmerged "apply preserves unmerged branch"
	assert_ref_exists "$repo" open-pr "apply preserves open PR branch"
	assert_ref_exists "$repo" active-worktree "apply preserves active worktree branch"
	assert_ref_exists "$repo" main "apply preserves default branch"
	# The creator retires its own transport on every platform (GH#35490).
	if git -C "$repo" worktree list --porcelain | grep -F "$worktree_base" >/dev/null 2>&1; then
		fail "apply must remove its isolated deletion transport"
	fi
	pass "apply removes its isolated deletion transport"
	return 0
}

run_readback_failure_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	local git_bin="$TEST_ROOT/readback-bin"
	local repos_file="$TEST_ROOT/repos.json"
	local worktree_base="$TEST_ROOT/worktrees"
	local output=""
	local rc=0

	make_branch "$repo" merged-readback merged-readback.txt merged-readback
	merge_branch_to_main "$repo" merged-readback
	git -C "$repo" fetch -q origin
	install_readback_failure_git_stub "$git_bin"
	if output=$(AIDEVOPS_REPOS_FILE="$repos_file" \
		AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" \
		PATH="$git_bin:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" --skip-fetch --apply 2>&1); then
		fail "apply must fail when remote absence read-back is indeterminate"
	else
		rc=$?
	fi
	[[ "$rc" -eq 1 ]] || fail "indeterminate read-back returns terminal failure (rc=$rc)"
	assert_contains "$output" "remote absence verification failed" "apply reports indeterminate remote read-back"
	assert_ref_missing "$repo" merged-readback "fixture confirms deletion occurred before read-back failure"
	return 0
}

run_sync_assertions() {
	local origin_repo="$TEST_ROOT/sync-origin.git"
	local repo="$TEST_ROOT/sync-repo"
	local output ahead_count
	git init -q --bare "$origin_repo"
	git clone -q "$origin_repo" "$repo"
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$repo" base.txt base
	git -C "$repo" branch -M main
	git -C "$repo" push -q -u origin main
	git -C "$origin_repo" symbolic-ref HEAD refs/heads/main

	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo")
	assert_contains "$output" "would-ff" "dry-run reports pending default-branch fast-forward"
	assert_contains "$output" "behind origin/main; dry-run only" "dry-run explains sync is not applied"
	ahead_count=$(git -C "$repo" rev-list --count HEAD..origin/main)
	[[ "$ahead_count" == "1" ]] || fail "dry-run must not fast-forward local main"
	pass "dry-run leaves local main behind origin/main"

	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "fast-fwd" "apply fast-forwards clean default branch"
	ahead_count=$(git -C "$repo" rev-list --count HEAD..origin/main)
	[[ "$ahead_count" == "0" ]] || fail "apply should fast-forward local main"
	pass "apply reconciles local main with origin/main"

	git -C "$repo" checkout -qb feature-work
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "not default branch (main)" "non-default branch sync is skipped"

	git -C "$repo" checkout -q main
	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater-dirty"
	printf '%s\n' dirty >>"${repo}/base.txt"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "worktree or index is dirty" "dirty default branch sync is skipped"
	git -C "$repo" reset --hard -q HEAD
	git -C "$repo" merge --ff-only -q origin/main

	make_commit "$repo" local-ahead.txt local-ahead
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "local branch is ahead of origin/main" "ahead default branch sync is skipped"

	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater-diverged"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "local branch has diverged from origin/main" "diverged default branch sync is skipped"
	return 0
}

main() {
	setup_repo
	run_dry_run_assertions "$TEST_ROOT/repo"
	run_fetch_assertions "$TEST_ROOT/repo"
	run_apply_assertions "$TEST_ROOT/repo"
	run_readback_failure_assertions "$TEST_ROOT/repo"
	run_sync_assertions
	return 0
}

main "$@"
