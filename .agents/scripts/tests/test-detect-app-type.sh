#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../detect-app-type.sh"
TEST_ROOT=""
PASSED=0
FAILED=0

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

test_cloudron_cache_preserves_root_schema() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/package"
	local config_dir="${home_dir}/.config/aidevops"
	mkdir -p "$config_dir" "$repo_dir"
	git -C "$repo_dir" init --quiet
	cat >>"${repo_dir}/.git/config" <<'GITCONFIG'
[remote "origin"]
    url = https://github.com/exampleorg/example-package.git
    fetch = +refs/heads/*:refs/remotes/origin/*
GITCONFIG
	printf '{"id":"com.example.package"}\n' >"${repo_dir}/CloudronManifest.json"
	cat >"${config_dir}/repos.json" <<JSON
{
  "initialized_repos": [
    {"slug": "exampleorg/example-package", "path": "${repo_dir}", "pulse": true},
    {"slug": "exampleorg/other", "path": "${TEST_ROOT}/other", "custom": "keep"}
  ],
  "git_parent_dirs": ["~/Git"],
  "custom_root": {"preserve": true}
}
JSON

	local output=""
	output=$(HOME="$home_dir" bash "$HELPER" "$repo_dir" --write-cache)
	assert_equal cloudron-package "$output" "Cloudron package detected"
	assert_equal cloudron-package "$(jq -r '.initialized_repos[] | select(.slug == "exampleorg/example-package") | .app_type' "${config_dir}/repos.json")" "matching entry receives app_type"
	assert_equal keep "$(jq -r '.initialized_repos[] | select(.slug == "exampleorg/other") | .custom' "${config_dir}/repos.json")" "unrelated entry preserved"
	assert_equal true "$(jq -r '.custom_root.preserve' "${config_dir}/repos.json")" "unrelated root fields preserved"
	assert_equal object "$(jq -r 'type' "${config_dir}/repos.json")" "repos.json root remains an object"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_cloudron_cache_preserves_root_schema
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
