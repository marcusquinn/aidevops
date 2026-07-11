#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../lint-helper.sh"
TEST_TMP_DIR=""
passed=0
failed=0

assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
		passed=$((passed + 1))
	else
		printf 'FAIL %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
		failed=$((failed + 1))
	fi
	return 0
}

make_repo() {
	local repo_root="$1"
	mkdir -p "$repo_root"
	/usr/bin/git -C "$repo_root" init -q
	/usr/bin/git -C "$repo_root" config user.email test@example.com
	/usr/bin/git -C "$repo_root" config user.name Test
	printf '%s\n' '{"scripts":{"lint":"eslint .","lint:fix":"eslint --fix .","typecheck":"tsc --noEmit"}}' >"$repo_root/package.json"
	printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$repo_root/.aidevops.json"
	return 0
}

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	local repo_one="${TEST_TMP_DIR}/repo-one"
	local repo_two="${TEST_TMP_DIR}/repo-two"
	local fake_home="${TEST_TMP_DIR}/home"
	make_repo "$repo_one"
	make_repo "$repo_two"
	mkdir -p "${fake_home}/.config/aidevops"
	jq -n --arg one "$repo_one" --arg two "$repo_two" '{initialized_repos:[{path:$one,features:[]},{path:$two,features:[]}]}' >"${fake_home}/.config/aidevops/repos.json"

	local output classification before after
	output=$(HOME="$fake_home" bash "$HELPER" audit --repo "$repo_one" --json)
	classification=$(printf '%s' "$output" | jq -r '.[0].classification')
	assert_equal "HOOK-MISSING" "$classification" "audit reports missing hook before feature migration"

	before=$(cksum <"$repo_one/.aidevops.json")
	HOME="$fake_home" bash "$HELPER" configure --repo "$repo_one" --dry-run >/dev/null 2>&1
	after=$(cksum <"$repo_one/.aidevops.json")
	assert_equal "$before" "$after" "configure defaults to a non-mutating dry run"

	HOME="$fake_home" bash "$HELPER" configure --repo "$repo_one" --apply --no-hook >/dev/null
	assert_equal "true" "$(jq -r '.features.code_quality' "$repo_one/.aidevops.json")" "configure enables code quality"
	assert_equal "npm run lint" "$(jq -r '.verify.lint' "$repo_one/.aidevops.json")" "configure seeds exact native lint command"
	assert_equal "true" "$(jq -r '.features.planning' "$repo_one/.aidevops.json")" "configure preserves unrelated config"

	HOME="$fake_home" bash "$HELPER" configure --all --dispatch-prs --json >/dev/null
	assert_equal "true" "$(jq -r 'length > 0' "${fake_home}/.aidevops/.agent-workspace/work/lint-configure-pr-plan.json")" "all-repo mode writes worker-ready PR plans"

	HOME="$fake_home" bash "$HELPER" reconcile --all >/dev/null
	assert_equal "2" "$(jq '[.initialized_repos[] | select((.features // []) | index("code-quality"))] | length' "${fake_home}/.config/aidevops/repos.json")" "update reconciliation seeds every non-opted-out registration"
	assert_equal "true" "$(jq -r '.features.code_quality' "$repo_two/.aidevops.json")" "update reconciliation migrates existing repo config"

	local unsafe_status=0
	HOME="$fake_home" bash "$HELPER" configure --all --apply >/dev/null 2>&1 || unsafe_status=$?
	assert_equal "2" "$unsafe_status" "all-repo direct canonical mutation is refused"

	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
