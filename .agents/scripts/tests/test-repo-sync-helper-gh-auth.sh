#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../repo-sync-helper.sh"

failures=0

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

	cat >"${tmp_dir}/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s | fetch_mode=%s pull_mode=%s dirty=%s remote_url=%s\n' \
	"$*" \
	"${FAKE_FETCH_MODE:-unset}" \
	"${FAKE_PULL_MODE:-unset}" \
	"${FAKE_DIRTY:-unset}" \
	"${FAKE_REMOTE_URL:-unset}" >>"${FAKE_GIT_LOG:?}"

repo_path=""
helper_used=0
command_name=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-C)
		repo_path="$2"
		shift 2
		;;
	-c)
		[[ "${2:-}" == "credential.helper=!gh auth git-credential" ]] && helper_used=1
		shift 2
		;;
	*)
		command_name="$1"
		shift
		break
		;;
	esac
done

case "$command_name" in
remote)
	if [[ "${1:-}" == "get-url" ]]; then
		printf '%s\n' "${FAKE_REMOTE_URL:-https://github.com/example/repo.git}"
		exit 0
	fi
	printf 'origin\n'
	exit 0
	;;
symbolic-ref)
	printf 'refs/remotes/origin/main\n'
	exit 0
	;;
show-ref)
	exit 0
	;;
diff)
	if [[ "${FAKE_DIRTY:-0}" == "1" ]]; then
		exit 1
	fi
	exit 0
	;;
rev-parse)
	case "${1:-}" in
	--abbrev-ref)
		printf '%s\n' "${FAKE_CURRENT_BRANCH:-main}"
		;;
	--short)
		printf '%s\n' "${FAKE_SHORT_SHA:-bbbbbbb}"
		;;
	HEAD)
		printf '%s\n' "${FAKE_LOCAL_SHA:-aaaa}"
		;;
	origin/main)
		printf '%s\n' "${FAKE_UPSTREAM_SHA:-aaaa}"
		;;
	*)
		printf '%s\n' "${FAKE_LOCAL_SHA:-aaaa}"
		;;
	esac
	exit 0
	;;
fetch)
	case "${FAKE_FETCH_MODE:-success}" in
	success)
		exit 0
		;;
	auth_then_success)
		if [[ "$helper_used" == "1" ]]; then
			exit 0
		fi
		printf "fatal: could not read Password for 'https://x-access-token:%s@github.com': terminal prompts disabled\n" "${FAKE_TOKEN:-SECRET_TOKEN}" >&2
		exit 1
		;;
	auth_always_fail)
		printf "fatal: Authentication failed for 'https://x-access-token:%s@github.com/example/repo.git'\n" "${FAKE_TOKEN:-SECRET_TOKEN}" >&2
		exit 1
		;;
	*)
		printf 'fatal: fetch failed for a non-auth reason\n' >&2
		exit 1
		;;
	esac
	;;
pull)
	if [[ "${FAKE_PULL_MODE:-success}" == "diverged" ]]; then
		printf 'fatal: Not possible to fast-forward, aborting.\n' >&2
		exit 1
	fi
	exit 0
	;;
*)
	printf 'unexpected git command: %s repo=%s\n' "$command_name" "$repo_path" >&2
	exit 1
	;;
esac
FAKE_GIT

	cat >"${tmp_dir}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit "${FAKE_GH_AUTH_STATUS:-0}"
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "git-credential" ]]; then
	exit 0
fi

exit 1
FAKE_GH

	chmod +x "${tmp_dir}/bin/git" "${tmp_dir}/bin/gh"
	return 0
}

run_case() {
	local case_name="$1"
	shift
	local tmp_dir
	tmp_dir=$(mktemp -d)
	mkdir -p "${tmp_dir}/home/.config/aidevops" "${tmp_dir}/parent/repo/.git"
	make_fake_tools "$tmp_dir"
	printf '{"git_parent_dirs":["%s"]}\n' "${tmp_dir}/parent" >"${tmp_dir}/home/.config/aidevops/repos.json"

	local rc=0
	env \
		HOME="${tmp_dir}/home" \
		PATH="${tmp_dir}/bin:${PATH}" \
		FAKE_GIT_LOG="${tmp_dir}/git.log" \
		FAKE_GH_LOG="${tmp_dir}/gh.log" \
		FAKE_TOKEN="SECRET_TOKEN_${case_name}" \
		"$@" \
		"$HELPER" check >"${tmp_dir}/stdout.log" 2>"${tmp_dir}/stderr.log" || rc=$?

	LAST_CASE_DIR="$tmp_dir"
	LAST_CASE_RC="$rc"
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
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "retrying git fetch with gh credential helper" "GitHub auth fallback is logged without credentials"
assert_file_not_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "SECRET_TOKEN_github_fallback" "GitHub auth fallback log does not contain token"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "SECRET_TOKEN_github_fallback" "GitHub auth fallback command line does not contain token"

run_case non_github_no_fallback FAKE_FETCH_MODE=auth_then_success FAKE_REMOTE_URL=https://gitlab.com/example/repo.git
assert_rc 1 "$LAST_CASE_RC" "non-GitHub auth failure still fails"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "non-GitHub remote does not use gh credential helper"

run_case dirty_skip FAKE_DIRTY=1 FAKE_FETCH_MODE=auth_then_success
assert_rc 0 "$LAST_CASE_RC" "dirty worktree remains skipped"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "fetch origin main" "dirty worktree skips fetch before auth fallback"

run_case diverged_pull FAKE_FETCH_MODE=success FAKE_LOCAL_SHA=aaaa FAKE_UPSTREAM_SHA=bbbb FAKE_PULL_MODE=diverged
assert_rc 1 "$LAST_CASE_RC" "diverged pull still fails"
assert_file_not_contains "${LAST_CASE_DIR}/git.log" "credential.helper=!gh auth git-credential" "diverged pull does not use auth fallback"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "git pull --ff-only failed (diverged?)" "diverged pull keeps existing failure message"

run_case github_fallback_failure_redacts FAKE_FETCH_MODE=auth_always_fail FAKE_REMOTE_URL=https://github.com/example/repo.git
assert_rc 1 "$LAST_CASE_RC" "failed GitHub fallback exits with failure"
assert_file_not_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "SECRET_TOKEN_github_fallback_failure_redacts" "failed GitHub fallback log redacts token"
assert_file_contains "${LAST_CASE_DIR}/home/.aidevops/logs/repo-sync.log" "[redacted-credential]" "failed GitHub fallback log includes redacted credential marker"

if [[ $failures -gt 0 ]]; then
	printf '\n%d repo-sync gh-auth test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll repo-sync gh-auth tests passed\n'
exit 0
