#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DIR="${INSTALL_DIR}/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

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

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	local repo_root="${TEST_TMP_DIR}/repo"
	mkdir -p "$repo_root"
	/usr/bin/git -C "$repo_root" init -q
	printf '%s\n' '{"custom":{"keep":true},"features":{"planning":false}}' >"$repo_root/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit"}}' >"$repo_root/package.json"
	/usr/bin/git -C "$repo_root" add package.json

	_init_write_project_config "$repo_root/.aidevops.json" "9.9.9" "standard" false false true true true false false false false true
	assert_equal "true" "$(jq -r '.custom.keep' "$repo_root/.aidevops.json")" "init preserves unknown configuration keys"
	assert_equal "false" "$(jq -r '.features.planning' "$repo_root/.aidevops.json")" "init preserves explicit feature values"
	assert_equal "9.9.9" "$(jq -r '.version' "$repo_root/.aidevops.json")" "init refreshes managed version"

	_init_configure_repo_verify "$repo_root"
	assert_equal "npm run lint" "$(jq -r '.verify.lint' "$repo_root/.aidevops.json")" "init seeds exact lint command"
	assert_equal "npm run typecheck" "$(jq -r '.verify.typecheck' "$repo_root/.aidevops.json")" "init seeds exact typecheck command"
	local common_dir
	common_dir=$(/usr/bin/git -C "$repo_root" rev-parse --git-common-dir)
	assert_equal "1" "$(grep -c '# guard:repo-verify' "${repo_root}/${common_dir}/hooks/pre-push" 2>/dev/null || printf 0)" "init immediately installs repo-verify hook"

	local invalid_config="${TEST_TMP_DIR}/invalid.json"
	printf '{invalid\n' >"$invalid_config"
	local invalid_before invalid_after invalid_status=0
	invalid_before=$(cksum <"$invalid_config")
	_init_write_project_config "$invalid_config" "9.9.9" "standard" false false true true true false false false false true >/dev/null 2>&1 || invalid_status=$?
	invalid_after=$(cksum <"$invalid_config")
	assert_equal "1" "$invalid_status" "init refuses to overwrite invalid existing config"
	assert_equal "$invalid_before" "$invalid_after" "invalid existing config remains untouched"

	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
