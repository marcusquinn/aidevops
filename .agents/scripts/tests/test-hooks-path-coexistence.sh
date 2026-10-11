#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-hooks-path-coexistence.sh — GH#34411
#
# Verifies the git-hook installers honour core.hooksPath (Beads sets
# .beads/hooks) and that install-hooks-helper.sh and install-pre-push-guards.sh
# coexist on pre-push/pre-commit in either order. Hooks are proven to RUN by
# repo-local stub guards that record their invocation.

# shellcheck disable=SC2016 # single-quoted bodies intentionally expand in the child shell
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/install-hooks-helper.sh"
GUARDS="${SCRIPT_DIR}/install-pre-push-guards.sh"
TASKID="${SCRIPT_DIR}/install-task-id-guard.sh"
LIB="${SCRIPT_DIR}/git-hooks-path-lib.sh"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$1"
	return 0
}
bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$1"
	return 0
}
check() {
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
	return 0
}

TMP_ROOT="$(mktemp -d "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/hookspath-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

# make_repo <name> <beads:0|1> -> prints repo path; includes stub guards + bare remote.
make_repo() {
	local name="$1" beads="$2"
	local repo="${TMP_ROOT}/${name}" remote="${TMP_ROOT}/${name}-remote.git"
	git init -q --bare "$remote"
	git init -q "$repo"
	git -C "$repo" config user.email t@example.com
	git -C "$repo" config user.name t
	git -C "$repo" config commit.gpgsign false
	git -C "$repo" remote add origin "$remote"
	mkdir -p "$repo/.agents/hooks" "$repo/.agents/scripts"
	local stub
	for stub in gh-wrapper-guard-pre-push.sh privacy-guard-pre-push.sh; do
		printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "%s" >>"%s/ran.log"\nexit 0\n' \
			"$stub" "$TMP_ROOT" >"$repo/.agents/hooks/$stub"
		chmod +x "$repo/.agents/hooks/$stub"
	done
	printf '#!/usr/bin/env bash\nprintf "pre-commit-hook:%%s\\n" "${HOOK_MODE:-}" >>"%s/ran.log"\nexit 0\n' \
		"$TMP_ROOT" >"$repo/.agents/scripts/pre-commit-hook.sh"
	chmod +x "$repo/.agents/scripts/pre-commit-hook.sh"
	if [[ "$beads" == "1" ]]; then
		git -C "$repo" config core.hooksPath .beads/hooks
		mkdir -p "$repo/.beads/hooks"
	fi
	printf '%s' "$repo"
	return 0
}

push_commit() {
	local repo="$1"
	: >"${TMP_ROOT}/ran.log"
	printf 'x\n' >>"$repo/f.txt"
	git -C "$repo" add f.txt
	git -C "$repo" commit -q -m "change" >/dev/null 2>&1 || return 1
	git -C "$repo" push -q origin HEAD:refs/heads/main >/dev/null 2>&1 || return 1
	return 0
}

ran() {
	grep -qx "$1" "${TMP_ROOT}/ran.log" && return 0
	return 1
}

run_helper_pre_push() {
	local repo="$1"
	(
		cd "$repo" || exit 1
		# shellcheck source=/dev/null
		source "$HELPER"
		install_gh_wrapper_guard_hook >/dev/null
		install_pre_push_quality_hook >/dev/null
		install_pre_commit_hook >/dev/null
	) && return 0
	return 1
}

run_guards() {
	local repo="$1"
	(cd "$repo" && bash "$GUARDS" install --guard privacy >/dev/null 2>&1) && return 0
	return 1
}

# --- 1. Resolver ---------------------------------------------------------------
R1=$(make_repo r1 1)
# shellcheck source=/dev/null
source "$LIB"
mkdir -p "$R1/sub"
check "resolver returns core.hooksPath (absolute) from a subdirectory" \
	test "$(aidevops_git_hooks_dir "$R1/sub")" = "$R1/.beads/hooks"
R0=$(make_repo r0 0)
check "resolver returns <common-dir>/hooks without core.hooksPath" \
	test "$(aidevops_git_hooks_dir "$R0")" = "$R0/.git/hooks"

# --- 2. hooks-helper first, then guards (Beads repo) -------------------------
run_helper_pre_push "$R1"
check "hooks-helper wrote pre-push into .beads/hooks" test -x "$R1/.beads/hooks/pre-push"
check "hooks-helper wrote pre-commit into .beads/hooks" test -x "$R1/.beads/hooks/pre-commit"
check "nothing written to .git/hooks/pre-push" test ! -e "$R1/.git/hooks/pre-push"
run_guards "$R1"
check "guards installer adopted the hooks-helper pre-push (no refusal)" \
	grep -q '^# aidevops-pre-push-guards$' "$R1/.beads/hooks/pre-push"
check "dispatcher kept gh-wrapper marker" grep -q '^# aidevops-gh-wrapper-guard$' "$R1/.beads/hooks/pre-push"
check "dispatcher kept quality marker" grep -q '^# aidevops-pre-push-quality-hook$' "$R1/.beads/hooks/pre-push"
push_commit "$R1" || bad "push in Beads repo (helper->guards) failed"
check "git push ran gh-wrapper guard" ran gh-wrapper-guard-pre-push.sh
check "git push ran privacy guard" ran privacy-guard-pre-push.sh
check "git push ran quality hook in pre-push mode" ran pre-commit-hook:pre-push
check "git commit ran quality hook in pre-commit mode" ran pre-commit-hook:pre-commit

# --- 3. guards first, then hooks-helper (Beads repo + trailing Beads section) -
R2=$(make_repo r2 1)
run_guards "$R2"
printf '\n# --- BEGIN BEADS INTEGRATION v1.2.3 ---\nprintf "beads-ran\\n" >>"%s/ran.log"\n# --- END BEADS INTEGRATION v1.2.3 ---\n' \
	"$TMP_ROOT" >>"$R2/.beads/hooks/pre-push"
run_helper_pre_push "$R2"
run_guards "$R2"
check "dispatcher preserved the Beads section" grep -q 'BEGIN BEADS INTEGRATION v1.2.3' "$R2/.beads/hooks/pre-push"
push_commit "$R2" || bad "push in Beads repo (guards->helper) failed"
check "guards-first: gh-wrapper guard ran" ran gh-wrapper-guard-pre-push.sh
check "guards-first: privacy guard ran" ran privacy-guard-pre-push.sh
check "guards-first: quality hook ran" ran pre-commit-hook:pre-push
check "guards-first: Beads section ran" ran beads-ran
check "guards-first: pre-commit quality hook ran" ran pre-commit-hook:pre-commit

# --- 4. A blocking guard still blocks the push ---------------------------------
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' >"$R2/.agents/hooks/gh-wrapper-guard-pre-push.sh"
printf 'y\n' >>"$R2/f.txt"
git -C "$R2" add f.txt
git -C "$R2" commit -q -m "blocked" >/dev/null 2>&1
check "blocking gh-wrapper guard rejects the push" \
	bash -c '! git -C "$1" push -q origin HEAD:refs/heads/main >/dev/null 2>&1' _ "$R2"

# --- 5. No core.hooksPath: shared common-dir hooks, unchanged behaviour -------
R3=$(make_repo r3 0)
run_helper_pre_push "$R3"
run_guards "$R3"
check "without hooksPath pre-push lands in .git/hooks" test -x "$R3/.git/hooks/pre-push"
push_commit "$R3" || bad "push in plain repo failed"
check "plain repo: gh-wrapper and privacy guards both ran" \
	bash -c 'grep -qx gh-wrapper-guard-pre-push.sh "$1" && grep -qx privacy-guard-pre-push.sh "$1"' _ "${TMP_ROOT}/ran.log"

# --- 6. task-id guard (commit-msg) honours core.hooksPath ----------------------
(cd "$R1" && bash "$TASKID" install >/dev/null 2>&1)
check "task-id guard wrote commit-msg into .beads/hooks" test -x "$R1/.beads/hooks/commit-msg"

# --- 7. Inactive-hook warning ---------------------------------------------------
R4=$(make_repo r4 0)
(cd "$R4" && bash "$GUARDS" install --guard privacy >/dev/null 2>&1)
git -C "$R4" config core.hooksPath .beads/hooks
check "inactive aidevops hook in common-dir is reported" \
	bash -c 'source "$1"; aidevops_inactive_hooks_report "$2" | grep -q "/.git/hooks/pre-push"' _ "$LIB" "$R4"
check "no inactive report when hooks dir is effective" \
	bash -c 'source "$1"; test -z "$(aidevops_inactive_hooks_report "$2")"' _ "$LIB" "$R1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
