#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../repo-sync-helper.sh"

failures=0
declare -a TEMP_DIRS=()

cleanup() {
	rm -rf "${TEMP_DIRS[@]}"
	return 0
}
trap cleanup EXIT

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	failures=$((failures + 1))
	return 0
}

make_fake_tools() {
	local tmp_dir="$1"
	mkdir -p "${tmp_dir}/bin"
	ln -s "${SCRIPT_DIR}/fixtures/repo-sync-fake-git.sh" "${tmp_dir}/bin/git"
	ln -s "${SCRIPT_DIR}/fixtures/repo-sync-fake-gh.sh" "${tmp_dir}/bin/gh"
	return 0
}

run_case() {
	local case_name
	case_name="$1"
	shift
	local tmp_dir
	tmp_dir=$(mktemp -d)
	TEMP_DIRS+=("$tmp_dir")
	mkdir -p "${tmp_dir}/home/.config/aidevops" "${tmp_dir}/parent/repo/.git"
	make_fake_tools "$tmp_dir"
	printf '{"git_parent_dirs":["%s"]}\n' "${tmp_dir}/parent" >"${tmp_dir}/home/.config/aidevops/repos.json"

	local rc=0
	local repeats=1 arg i
	for arg in "$@"; do
		if [[ "$arg" == FAKE_REPEAT=* ]]; then
			repeats="${arg#FAKE_REPEAT=}"
		fi
	done
	for ((i = 0; i < repeats; i++)); do
		env -i \
			HOME="${tmp_dir}/home" \
			PATH="${tmp_dir}/bin:${PATH}" \
			FAKE_GIT_LOG="${tmp_dir}/git.log" \
			FAKE_GH_LOG="${tmp_dir}/gh.log" \
			FAKE_TOKEN="SECRET_TOKEN_${case_name}" \
			"$@" \
			"$HELPER" check >"${tmp_dir}/stdout.log" 2>"${tmp_dir}/stderr.log" || rc=$?
	done

	LAST_CASE_DIR="$tmp_dir"
	LAST_CASE_RC="$rc"
	return 0
}

run_canonical_guard_case() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	TEMP_DIRS+=("$tmp_dir")
	local repo="${tmp_dir}/parent/repo"
	local remote="${tmp_dir}/remote.git"
	mkdir -p "${tmp_dir}/bin" "${tmp_dir}/home/.config/aidevops" "${tmp_dir}/parent"
	ln -s "${SCRIPT_DIR}/../git" "${tmp_dir}/bin/git"
	ln -s "${SCRIPT_DIR}/fixtures/repo-sync-fake-gh.sh" "${tmp_dir}/bin/gh"

	/usr/bin/git init -q --bare "$remote"
	/usr/bin/git init -q -b main "$repo" 2>/dev/null || {
		/usr/bin/git init -q "$repo"
		/usr/bin/git -C "$repo" checkout -q -b main
	}
	/usr/bin/git -C "$repo" config user.name Test
	/usr/bin/git -C "$repo" config user.email test@example.invalid
	printf 'seed\n' >"${repo}/README.md"
	/usr/bin/git -C "$repo" add README.md
	/usr/bin/git -C "$repo" commit -q -m seed
	/usr/bin/git -C "$repo" remote add origin "$remote"
	/usr/bin/git -C "$repo" push -q -u origin main
	/usr/bin/git clone -q -b main "$remote" "${tmp_dir}/writer"
	/usr/bin/git -C "${tmp_dir}/writer" config user.name Test
	/usr/bin/git -C "${tmp_dir}/writer" config user.email test@example.invalid
	printf 'second\n' >"${tmp_dir}/writer/second.txt"
	/usr/bin/git -C "${tmp_dir}/writer" add second.txt
	/usr/bin/git -C "${tmp_dir}/writer" commit -q -m second
	/usr/bin/git -C "${tmp_dir}/writer" push -q origin main
	/usr/bin/git -C "$repo" fetch -q origin main
	printf '{"git_parent_dirs":["%s"]}\n' "${tmp_dir}/parent" >"${tmp_dir}/home/.config/aidevops/repos.json"

	local before
	before=$(/usr/bin/git -C "$repo" show-ref)
	local rc=0
	env \
		HOME="${tmp_dir}/home" \
		PATH="${tmp_dir}/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
		FAKE_GH_LOG="${tmp_dir}/gh.log" \
		"$HELPER" check >"${tmp_dir}/stdout.log" 2>"${tmp_dir}/stderr.log" || rc=$?
	local after
	after=$(/usr/bin/git -C "$repo" show-ref)

	LAST_CASE_DIR="$tmp_dir"
	LAST_CASE_RC="$rc"
	LAST_CANONICAL_REFS_UNCHANGED=0
	[[ "$before" == "$after" ]] && LAST_CANONICAL_REFS_UNCHANGED=1
	return 0
}

assert_file_contains() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"
	if grep -qF "$pattern" "$file_path" 2>/dev/null; then
		pass "$message"
	else
		fail "$message"
	fi
	return 0
}

assert_file_not_contains() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"
	if grep -qF "$pattern" "$file_path" 2>/dev/null; then
		fail "$message"
	else
		pass "$message"
	fi
	return 0
}

assert_rc() {
	local expected_rc="$1"
	local actual_rc="$2"
	local message="$3"
	if [[ "$actual_rc" == "$expected_rc" ]]; then
		pass "$message"
	else
		fail "$message (expected ${expected_rc}, got ${actual_rc})"
	fi
	return 0
}

run_case plain_success FAKE_FETCH_MODE=success
assert_rc 0 "$LAST_CASE_RC" "plain fetch success exits cleanly"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "plain fetch success does not use gh credential helper"
assert_file_not_contains "${LAST_CASE_DIR}/gh.log" "auth status" "plain fetch success does not call gh"

run_case github_fallback FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=https://github.com/example/repo.git
assert_rc 0 "$LAST_CASE_RC" "GitHub auth failure retries successfully"
assert_file_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "GitHub auth fallback uses transient gh credential helper"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "retrying git ls-remote with gh credential helper" "GitHub auth fallback is logged without credentials"
assert_file_not_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "SECRET_TOKEN_github_fallback" "GitHub auth fallback log does not contain token"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "SECRET_TOKEN_github_fallback" "GitHub auth fallback command line does not contain token"

run_case github_ssh_fallback FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=git@github.com:example/repo.git
assert_rc 0 "$LAST_CASE_RC" "GitHub SSH auth failure retries over HTTPS"
assert_file_contains "${LAST_CASE_DIR}/git.log" "ls-remote https://github.com/example/repo.git refs/heads/main" "SSH fallback passes HTTPS URL explicitly"
assert_file_contains "${LAST_CASE_DIR}/git.log" "ssh_command=ssh -o BatchMode=yes" "SSH attempt disables interactive askpass"
assert_file_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "SSH fallback uses gh credential helper"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "remote set-url" "SSH fallback does not alter configured remote"

run_case github_ssh_scheme FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=ssh://git@github.com/example/repo.git
assert_rc 0 "$LAST_CASE_RC" "GitHub ssh:// URL retries over HTTPS"

run_case untrusted_ssh_host FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=git@notgithub.com:example/repo.git
assert_rc 1 "$LAST_CASE_RC" "non-GitHub SSH remote does not get GitHub credentials"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "non-GitHub SSH remote has no gh retry"

run_case non_github_no_fallback FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=https://gitlab.com/example/repo.git
assert_rc 1 "$LAST_CASE_RC" "non-GitHub auth failure still fails"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "non-GitHub remote does not use gh credential helper"

run_case dirty_skip FAKE_DIRTY=1 FAKE_FETCH_MODE=auth_then_success
assert_rc 0 "$LAST_CASE_RC" "dirty worktree remains skipped"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "ls-remote origin" "dirty worktree skips remote diagnostic before auth fallback"

run_case untracked_skip FAKE_UNTRACKED=1 FAKE_FETCH_MODE=auth_then_success
assert_rc 0 "$LAST_CASE_RC" "untracked worktree remains skipped"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "ls-remote origin" "untracked files block canonical eligibility"

run_case branch_skip FAKE_CURRENT_BRANCH=feature FAKE_FETCH_MODE=success
assert_rc 0 "$LAST_CASE_RC" "non-default branch remains skipped"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "ls-remote origin" "non-default branch avoids remote diagnostic"

run_case diverged_pull FAKE_FETCH_MODE=success FAKE_LOCAL_SHA=aaaa FAKE_UPSTREAM_SHA=bbbb
assert_rc 0 "$LAST_CASE_RC" "diverged canonical is diagnostic-only"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" " pull " "diverged canonical is never pulled"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "human checkout left unchanged" "diverged canonical reports read-only result"

run_case github_fallback_failure_redacts FAKE_FETCH_MODE=auth_always_fail FAKE_REMOTE_URL=https://github.com/example/repo.git
assert_rc 1 "$LAST_CASE_RC" "failed GitHub fallback exits with failure"
assert_file_not_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "SECRET_TOKEN_github_fallback_failure_redacts" "failed GitHub fallback log redacts token"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "[redacted-credential]" "failed GitHub fallback log includes redacted credential marker"

run_case repeated_failures FAKE_REPEAT=3 FAKE_FETCH_MODE=auth_always_fail FAKE_REMOTE_URL=https://github.com/example/repo.git
assert_rc 1 "$LAST_CASE_RC" "three failing runs retain failure exit"
if [[ "$(jq -r '.repo_observations | to_entries[0].value.fail_runs' "${LAST_CASE_DIR}/home/.aidevops/cache/repo-sync-state.json")" == 3 ]]; then
	pass "persistent failure counter records three consecutive runs"
else
	fail "persistent failure counter records three consecutive runs"
fi

run_canonical_guard_case
assert_rc 0 "$LAST_CASE_RC" "repo-sync completes through the deployed canonical Git shim"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "CONVERGENCE_ELIGIBLE (read-only default)" "clean strictly-behind canonical is reported eligible"
assert_file_not_contains "${LAST_CASE_DIR}/stderr.log" "BLOCKED by canonical Git guard" "canonical repo-sync is not rejected as mutation"
assert_rc 1 "$LAST_CANONICAL_REFS_UNCHANGED" "canonical repo-sync leaves local refs unchanged"

if [[ $failures -gt 0 ]]; then
	printf '\n%d repo-sync gh-auth test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll repo-sync gh-auth tests passed\n'
exit 0
