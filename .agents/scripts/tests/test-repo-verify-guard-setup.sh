#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
source "${INSTALL_DIR}/.agents/scripts/setup/_repo_verify_guard.sh"

TEST_TMP_DIR=""
passed=0
failed=0

print_info() { return 0; }
print_warning() { return 0; }
setup_track_skipped() { return 0; }
setup_track_configured() { return 0; }

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
	return 0
}

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	local eligible="${TEST_TMP_DIR}/eligible"
	local disabled="${TEST_TMP_DIR}/disabled"
	local fake_home="${TEST_TMP_DIR}/home"
	make_repo "$eligible"
	make_repo "$disabled"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$eligible/package.json"
	/usr/bin/git -C "$eligible" add package.json
	printf '%s\n' '{"version":"old","features":{"planning":true}}' >"$eligible/.aidevops.json"
	printf '%s\n' '{"verify":{"enabled":false}}' >"$disabled/.aidevops.json"
	mkdir -p "${fake_home}/.config/aidevops"
	jq -n --arg eligible "$eligible" --arg disabled "$disabled" \
		'{initialized_repos:[{path:$eligible,features:["code-quality"]},{path:$disabled,features:["code-quality"]}]}' >"${fake_home}/.config/aidevops/repos.json"

	HOME="$fake_home" setup_repo_verify_guard
	assert_equal "true" "$(jq -r --arg path "$eligible" '.initialized_repos[] | select(.path == $path) | (.features | index("code-quality") != null)' "${fake_home}/.config/aidevops/repos.json")" "setup seeds code-quality registration"
	assert_equal "true" "$(jq -r '.features.code_quality' "$eligible/.aidevops.json")" "setup migrates legacy code-quality feature"
	local common_dir
	common_dir=$(/usr/bin/git -C "$eligible" rev-parse --git-common-dir)
	assert_equal "1" "$(grep -c '# guard:repo-verify' "${eligible}/${common_dir}/hooks/pre-push" 2>/dev/null || printf 0)" "setup installs repo-verify in eligible repo"
	common_dir=$(/usr/bin/git -C "$disabled" rev-parse --git-common-dir)
	if [[ -f "${disabled}/${common_dir}/hooks/pre-push" ]]; then
		assert_equal "0" "$(grep -c '# guard:repo-verify' "${disabled}/${common_dir}/hooks/pre-push" 2>/dev/null || printf 0)" "setup preserves explicit opt-out"
	else
		assert_equal "0" "0" "setup preserves explicit opt-out"
	fi
	assert_equal "false" "$(jq -r '.features.code_quality // false' "$disabled/.aidevops.json")" "verify opt-out does not gain code-quality true"
	local setup_status=0
	REPO_VERIFY_INSTALLER="${TEST_TMP_DIR}/missing-installer" HOME="$fake_home" setup_repo_verify_guard || setup_status=$?
	assert_equal "1" "$setup_status" "setup reports hook rollout failures"

	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
