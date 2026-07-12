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
	/usr/bin/git -C "$repo_root" config commit.gpgsign false
	printf '%s\n' '{"scripts":{"lint":"eslint .","lint:fix":"eslint --fix .","typecheck":"tsc --noEmit"}}' >"$repo_root/package.json"
	printf '%s\n' '{"version":"0.0.1","features":{"planning":true}}' >"$repo_root/.aidevops.json"
	/usr/bin/git -C "$repo_root" add package.json
	return 0
}

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	local repo_one="${TEST_TMP_DIR}/repo-one"
	local repo_two="${TEST_TMP_DIR}/repo-two"
	local canonical="${TEST_TMP_DIR}/canonical"
	local fake_home="${TEST_TMP_DIR}/home"
	make_repo "$repo_one"
	make_repo "$repo_two"
	make_repo "$canonical"
	/usr/bin/git -C "$canonical" add .aidevops.json
	/usr/bin/git -C "$canonical" commit -q -m fixture
	mkdir -p "${fake_home}/.config/aidevops"
	jq -n --arg one "$repo_one" --arg two "$repo_two" --arg canonical "$canonical" \
		'{initialized_repos:[{path:$one,features:[]},{path:$two,features:[]},{path:$canonical,features:["code-quality"]}]}' >"${fake_home}/.config/aidevops/repos.json"

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

	local plan_json plan_stderr plan_path
	plan_stderr=$(mktemp)
	plan_json=$(HOME="$fake_home" bash "$HELPER" configure --all --write-pr-plan --json 2>"$plan_stderr")
	plan_path=$(<"$plan_stderr")
	plan_path="${plan_path##*: }"
	assert_equal "array" "$(printf '%s' "$plan_json" | jq -r 'type')" "write-pr-plan keeps JSON stdout machine-readable"
	assert_equal "true" "$(jq -r 'length > 0' "$plan_path")" "all-repo mode writes worker-ready PR plans"
	assert_equal "600" "$(stat -f '%Lp' "$plan_path" 2>/dev/null || stat -c '%a' "$plan_path")" "PR plan protects private repository paths"
	rm -f "$plan_stderr"
	local repo_two_common repo_two_hooks
	repo_two_common=$(/usr/bin/git -C "$repo_two" rev-parse --git-common-dir)
	if [[ -z "$repo_two_common" ]]; then
		printf 'FAIL git returned an empty common directory for %s\n' "$repo_two" >&2
		exit 1
	fi
	if [[ "$repo_two_common" != /* ]]; then
		repo_two_common="${repo_two}/${repo_two_common}"
	fi
	repo_two_hooks="${repo_two_common}/hooks"
	mkdir -p "$repo_two_hooks"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${repo_two_hooks}/pre-push"
	chmod +x "${repo_two_hooks}/pre-push"

	HOME="$fake_home" bash "$HELPER" reconcile --all >/dev/null
	assert_equal "3" "$(jq '[.initialized_repos[] | select((.features // []) | index("code-quality"))] | length' "${fake_home}/.config/aidevops/repos.json")" "update reconciliation seeds every non-opted-out registration"
	assert_equal "true" "$(jq -r '.features.code_quality' "$repo_two/.aidevops.json")" "update reconciliation migrates existing repo config"
	assert_equal "false" "$(jq -r '.features.code_quality // false' "$canonical/.aidevops.json")" "update reconciliation defers tracked canonical policy"
	assert_equal "0" "$(grep -c '# guard:repo-verify' "${repo_two_hooks}/pre-push" || true)" "update reconciliation preserves unmanaged hook conflicts"

	local repo_three="${TEST_TMP_DIR}/repo-three"
	make_repo "$repo_three"
	jq --arg path "$repo_three" '.initialized_repos += [{path:$path,features:[]}]' "${fake_home}/.config/aidevops/repos.json" >"${fake_home}/repos.next"
	mv "${fake_home}/repos.next" "${fake_home}/.config/aidevops/repos.json"
	local reconcile_status=0
	HOME="$fake_home" REPO_VERIFY_INSTALLER="${TEST_TMP_DIR}/missing-installer" bash "$HELPER" reconcile --all >/dev/null 2>&1 || reconcile_status=$?
	assert_equal "1" "$reconcile_status" "reconcile returns non-zero when hook installation fails"

	local unsafe_status=0
	HOME="$fake_home" bash "$HELPER" configure --all --apply >/dev/null 2>&1 || unsafe_status=$?
	assert_equal "2" "$unsafe_status" "all-repo direct canonical mutation is refused"

	local missing_status=0
	HOME="$fake_home" AIDEVOPS_REPOS_FILE="${TEST_TMP_DIR}/missing.json" bash "$HELPER" audit --all >/dev/null 2>&1 || missing_status=$?
	assert_equal "1" "$missing_status" "all-repo audit fails when registry is unavailable"

	local unset_home_output unset_home_status=0
	unset_home_output=$(env -u HOME bash "$HELPER" audit --all 2>&1) || unset_home_status=$?
	assert_equal "1" "$unset_home_status" "all-repo audit fails cleanly when HOME is unset"
	assert_equal "0" "$(printf '%s' "$unset_home_output" | grep -c 'unbound variable' || true)" "unset HOME does not trigger nounset"

	local unset_plan_status=0
	env -u HOME AIDEVOPS_REPOS_FILE="${fake_home}/.config/aidevops/repos.json" bash "$HELPER" configure --all --write-pr-plan --json >/dev/null 2>&1 || unset_plan_status=$?
	assert_equal "1" "$unset_plan_status" "PR plan fails without resolving an unset HOME to the filesystem root"

	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
