#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25292.
#
# Protected default branches must publish TODO.md/todo/ planning changes via a
# planning-only PR. The task counter remains CAS-only: this test asserts the PR
# body tells weaker models not to turn .task-counter into a PR-backed lock.

set -u

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
PLANNING_HELPER="${REPO_ROOT}/.agents/scripts/planning-commit-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ' — %s' "$detail"
	printf '\n'
	FAIL=$((FAIL + 1))
	return 0
}

setup_repo() {
	local tmpdir="$1"
	local protected_default="$2"
	local bare_dir="${tmpdir}/remote.git"
	local work_dir="${tmpdir}/work"

	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.email "test@test.local" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.name "Test" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	printf '# Tasks\n\n' >"${work_dir}/TODO.md"
	mkdir -p "${work_dir}/todo/tasks" || return 1
	git -C "$work_dir" add TODO.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m "chore: seed planning files" >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1
	git -C "$work_dir" fetch origin main >/dev/null 2>&1 || return 1
	git -C "$work_dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1 || return 1

	if [[ "$protected_default" == "true" ]]; then
		mkdir -p "${bare_dir}/hooks" || return 1
		cat >"${bare_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
	if [[ "$ref" == "refs/heads/main" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "$ref" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
		exit 1
	fi
done
exit 0
HOOK
		chmod +x "${bare_dir}/hooks/pre-receive" || return 1
	fi

	printf '%s\n' "$work_dir"
	return 0
}

write_fake_gh() {
	local fake_bin="$1"
	mkdir -p "$fake_bin" || return 1
	cat >"${fake_bin}/gh" <<'GH'
#!/usr/bin/env bash
set -u
{
	printf 'gh'
	for arg in "$@"; do
		printf '\t%s' "$arg"
	done
	printf '\n'
} >>"${GH_STUB_LOG:?}"

if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	exit 1
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	shift 2
	head_branch=""
	body_text=""
	title_text=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--head)
			head_branch="${2:-}"
			shift 2
			;;
		--head=*)
			head_branch="${1#--head=}"
			shift
			;;
		--body)
			body_text="${2:-}"
			shift 2
			;;
		--body=*)
			body_text="${1#--body=}"
			shift
			;;
		--title)
			title_text="${2:-}"
			shift 2
			;;
		--title=*)
			title_text="${1#--title=}"
			shift
			;;
		*)
			shift
			;;
		esac
	done
	printf '%s\n' "$head_branch" >"${GH_STUB_HEAD:?}"
	printf '%s\n' "$title_text" >"${GH_STUB_TITLE:?}"
	printf '%s\n' "$body_text" >"${GH_STUB_BODY:?}"
	printf 'https://github.com/example/repo/pull/1\n'
	exit 0
fi

exit 0
GH
	chmod +x "${fake_bin}/gh" || return 1
	return 0
}

append_planning_change() {
	local work_dir="$1"
	local task_id="$2"
	printf -- '- [ ] %s Protected planning fallback #bug #auto-dispatch ~30m ref:GH#25292\n' "$task_id" >>"${work_dir}/TODO.md"
	printf 'What: protected planning fallback\nHow: update planning helper\n' >"${work_dir}/todo/tasks/${task_id}-brief.md"
	return 0
}

test_protected_default_creates_planning_pr() {
	local name="protected default branch creates planning PR and cleans source"
	local tmpdir fake_bin work_dir body_file head_file title_file log_file output rc status head_branch remote_todo pr_body
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	body_file="${tmpdir}/body.md"
	head_file="${tmpdir}/head.txt"
	title_file="${tmpdir}/title.txt"
	: >"$log_file"
	write_fake_gh "$fake_bin" || { fail "$name" "fake gh setup failed"; return 0; }
	work_dir=$(setup_repo "$tmpdir" true) || { fail "$name" "repo setup failed"; return 0; }
	append_planning_change "$work_dir" "t999" || { fail "$name" "planning change failed"; return 0; }

	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" \
		GH_STUB_LOG="$log_file" GH_STUB_BODY="$body_file" GH_STUB_HEAD="$head_file" GH_STUB_TITLE="$title_file" \
		AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 AIDEVOPS_PLANNING_PR_REPO_SLUG="example/repo" \
		"$PLANNING_HELPER" "plan: add t999 protected planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 ]]; then
		fail "$name" "helper failed rc=$rc output=$output"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ -n "$status" ]]; then
		fail "$name" "source worktree dirty after PR fallback: $status"
		return 0
	fi
	if ! grep -q $'gh\tpr\tcreate' "$log_file" 2>/dev/null; then
		fail "$name" "gh pr create was not called"
		return 0
	fi
	head_branch=$(cat "$head_file" 2>/dev/null || true)
	if [[ "$head_branch" != planning/* ]]; then
		fail "$name" "unexpected PR head: ${head_branch:-<empty>}"
		return 0
	fi
	remote_todo=$(git -C "$work_dir" show "origin/main:TODO.md" 2>/dev/null || true)
	if [[ "$remote_todo" == *"t999"* ]]; then
		fail "$name" "protected default branch was updated directly"
		return 0
	fi
	git -C "$work_dir" fetch origin "$head_branch" >/dev/null 2>&1 || { fail "$name" "PR branch not pushed"; return 0; }
	remote_todo=$(git -C "$work_dir" show FETCH_HEAD:TODO.md 2>/dev/null || true)
	if [[ "$remote_todo" != *"t999"* ]]; then
		fail "$name" "PR branch does not contain TODO change"
		return 0
	fi
	pr_body=$(cat "$body_file" 2>/dev/null || true)
	if [[ "$pr_body" != *"does not update .task-counter"* ]] || [[ "$pr_body" != *"PR-backed counter update"* ]]; then
		fail "$name" "PR body missing counter safety guidance"
		return 0
	fi
	if printf '%s\n' "$pr_body" | grep -Eiq '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+'; then
		fail "$name" "planning PR body contains a closing keyword"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_unprotected_default_keeps_direct_push() {
	local name="unprotected default branch keeps direct planning push"
	local tmpdir fake_bin work_dir log_file output rc status remote_todo
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	fake_bin="${tmpdir}/bin"
	log_file="${tmpdir}/gh.log"
	: >"$log_file"
	write_fake_gh "$fake_bin" || { fail "$name" "fake gh setup failed"; return 0; }
	work_dir=$(setup_repo "$tmpdir" false) || { fail "$name" "repo setup failed"; return 0; }
	append_planning_change "$work_dir" "t1000" || { fail "$name" "planning change failed"; return 0; }
	rc=0
	output=$(cd "$work_dir" && PATH="${fake_bin}:$PATH" GH_STUB_LOG="$log_file" GH_STUB_BODY="${tmpdir}/body" GH_STUB_HEAD="${tmpdir}/head" GH_STUB_TITLE="${tmpdir}/title" \
		"$PLANNING_HELPER" "plan: add t1000 direct planning" 2>&1) || rc=$?
	if [[ $rc -ne 0 ]]; then
		fail "$name" "helper failed rc=$rc output=$output"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ -n "$status" ]]; then
		fail "$name" "source worktree dirty after direct push: $status"
		return 0
	fi
	git -C "$work_dir" fetch origin main >/dev/null 2>&1 || true
	remote_todo=$(git -C "$work_dir" show origin/main:TODO.md 2>/dev/null || true)
	if [[ "$remote_todo" != *"t1000"* ]]; then
		fail "$name" "direct push did not update origin/main"
		return 0
	fi
	if grep -q $'gh\tpr\tcreate' "$log_file" 2>/dev/null; then
		fail "$name" "unexpected PR creation on unprotected default"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_pr_unavailable_fails_before_commit() {
	local name="PR fallback unavailable fails before local commit"
	local tmpdir work_dir before_head after_head output rc status
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }
	work_dir=$(setup_repo "$tmpdir" true) || { fail "$name" "repo setup failed"; return 0; }
	append_planning_change "$work_dir" "t1001" || { fail "$name" "planning change failed"; return 0; }
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing initial HEAD"; return 0; }
	rc=0
	output=$(cd "$work_dir" && AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1 "$PLANNING_HELPER" "plan: add t1001 unavailable pr" 2>&1) || rc=$?
	if [[ $rc -eq 0 ]]; then
		fail "$name" "helper unexpectedly succeeded: $output"
		return 0
	fi
	after_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing final HEAD"; return 0; }
	if [[ "$after_head" != "$before_head" ]]; then
		fail "$name" "local HEAD changed before PR availability was proven"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ "$status" != *"TODO.md"* ]]; then
		fail "$name" "planning edits were not preserved for retry"
		return 0
	fi
	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

main() {
	if [[ ! -x "$PLANNING_HELPER" ]]; then
		fail "planning helper executable" "$PLANNING_HELPER missing or not executable"
	else
		pass "planning helper executable"
	fi
	test_protected_default_creates_planning_pr
	test_unprotected_default_keeps_direct_push
	test_pr_unavailable_fails_before_commit
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
