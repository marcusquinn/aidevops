#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shared-pr-base.sh — GH#39167 regression guard for shared-pr-base.sh:
#   1. resolver precedence: env > repo config > repos.json > remote default
#   2. no hard-coded `main` fallback when nothing resolves
#   3. merge guard: matching base / stacked parent / non-worker → proceed
#   4. merge guard: wrong base built on PR base → retarget + skip
#   5. merge guard: wrong base not built on PR base → hold comment + skip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
LIB="${SCRIPT_DIR}/../shared-pr-base.sh"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

check() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Stub behaviour comes from files under $TEST_ROOT/state:
#   default   — REST default_branch ("" = API failure)
#   parents   — branches that are open PR heads (one per line)
#   ahead-<branch> — compare ahead_by for <branch>...head
setup() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/state" "${TEST_ROOT}/home/.config/aidevops"
	export HOME="${TEST_ROOT}/home"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"
	export STATE="${TEST_ROOT}/state"
	unset WORKER_PR_BASE_BRANCH DISPATCH_REPO_PR_BASE_BRANCH AIDEVOPS_PR_BASE_BRANCH
	printf '{"initialized_repos":[{"slug":"o/configured","pr_base_branch":"develop"}]}\n' \
		>"${HOME}/.config/aidevops/repos.json"
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
args="$*"
case "$args" in
"api repos/"*"/pulls?state=open&head="*)
	branch="${args#*head=*:}"
	branch="${branch%%&*}"
	if grep -qxF -- "$branch" "${STATE}/parents" 2>/dev/null; then echo 1; else echo 0; fi
	exit 0 ;;
"api repos/"*"/compare/"*)
	range="${args#*compare/}"
	base="${range%%...*}"
	cat "${STATE}/ahead-${base//\//_}" 2>/dev/null || exit 1
	exit 0 ;;
"api -X PATCH "*) exit 0 ;;
"api repos/"*"/issues/"*"/comments"*) exit 0 ;;
"api repos/"*)
	value=$(cat "${STATE}/default" 2>/dev/null)
	[[ -n "$value" ]] || exit 1
	printf '%s\n' "$value"
	exit 0 ;;
esac
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	gh_pr_comment() { printf 'COMMENT %s\n' "$*" >>"$GH_CALLS"; return 0; }
	# shellcheck source=/dev/null
	source "$LIB"
	return 0
}

reset_state() {
	: >"$GH_CALLS"
	: >"$LOGFILE"
	rm -f "${STATE}"/*
	printf 'dev\n' >"${STATE}/default"
	_AIDEVOPS_PR_BASE_CACHE=""
	_PMP_HUMAN_GATED=0
	return 0
}

test_resolver_precedence() {
	reset_state
	local out=""
	out=$(aidevops_pr_base_resolve "o/plain" "")
	check "remote default when unconfigured" "$([[ "$out" == "dev remote-default" ]] && echo 0 || echo 1)" "$out"
	out=$(aidevops_pr_base_resolve "o/configured" "")
	check "repos.json pr_base_branch beats remote default" "$([[ "$out" == "develop repos-json" ]] && echo 0 || echo 1)" "$out"
	mkdir -p "${TEST_ROOT}/wd"
	printf '{"pr_base_branch":"staging"}\n' >"${TEST_ROOT}/wd/.aidevops.json"
	out=$(aidevops_pr_base_resolve "o/configured" "${TEST_ROOT}/wd")
	check ".aidevops.json beats repos.json" "$([[ "$out" == "staging repo-config" ]] && echo 0 || echo 1)" "$out"
	out=$(WORKER_PR_BASE_BRANCH=hotfix aidevops_pr_base_resolve "o/configured" "${TEST_ROOT}/wd")
	check "dispatch env beats config" "$([[ "$out" == "hotfix env" ]] && echo 0 || echo 1)" "$out"
	: >"${STATE}/default"
	local rc=0
	out=$(aidevops_pr_base_resolve "o/plain" "") || rc=$?
	check "unresolvable → failure, never main" "$([[ "$rc" -ne 0 && -z "$out" ]] && echo 0 || echo 1)" "rc=$rc out=$out"
	return 0
}

test_guard_proceeds() {
	reset_state
	local rc=0
	aidevops_pr_base_merge_guard 10 o/plain dev abc1234 ",origin:worker," || rc=$?
	check "guard: matching base proceeds" "$rc"
	rc=0
	aidevops_pr_base_merge_guard 10 o/plain main abc1234 ",origin:interactive," || rc=$?
	check "guard: non-worker PR proceeds" "$rc"
	rc=0
	printf 'feature/parent\n' >"${STATE}/parents"
	aidevops_pr_base_merge_guard 10 o/plain feature/parent abc1234 ",origin:worker," || rc=$?
	check "guard: stacked parent base proceeds" "$rc"
	return 0
}

test_guard_retargets() {
	reset_state
	printf '2\n' >"${STATE}/ahead-dev"
	printf '40\n' >"${STATE}/ahead-main"
	local rc=0
	aidevops_pr_base_merge_guard 11 o/plain main abc1234 ",origin:worker," || rc=$?
	check "guard: wrong base retarget skips cycle" "$([[ "$rc" -eq 1 ]] && echo 0 || echo 1)" "rc=$rc"
	check "guard: retarget PATCHes base=dev" \
		"$(grep -q -- 'api -X PATCH repos/o/plain/pulls/11 -f base=dev' "$GH_CALLS" && echo 0 || echo 1)" "$(cat "$GH_CALLS")"
	check "guard: retarget leaves audit comment" \
		"$(grep -q 'COMMENT 11 .*pr-base-mismatch retargeted' "$GH_CALLS" &&
			grep -q 'Retargeted this worker PR from .main. to .dev.' "$GH_CALLS" && echo 0 || echo 1)"
	return 0
}

test_guard_holds() {
	reset_state
	printf '40\n' >"${STATE}/ahead-dev"
	printf '2\n' >"${STATE}/ahead-main"
	local rc=0
	aidevops_pr_base_merge_guard 12 o/plain main abc1234 ",origin:worker," || rc=$?
	check "guard: unbuilt wrong base holds" "$([[ "$rc" -eq 1 && "$_PMP_HUMAN_GATED" -eq 1 ]] && echo 0 || echo 1)" "rc=$rc gated=$_PMP_HUMAN_GATED"
	check "guard: hold does not retarget" "$(grep -q 'PATCH' "$GH_CALLS" && echo 1 || echo 0)"
	check "guard: hold posts diagnosis" "$(grep -q 'COMMENT 12 .*pr-base-mismatch held' "$GH_CALLS" && echo 0 || echo 1)"
	return 0
}

main() {
	trap 'rm -rf "$TEST_ROOT"' EXIT
	setup
	test_resolver_precedence
	test_guard_proceeds
	test_guard_retargets
	test_guard_holds
	printf '\n%s tests run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
