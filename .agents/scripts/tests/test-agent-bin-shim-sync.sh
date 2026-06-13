#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for t2199 / GH#19686: agent bin shims must be PATH
# discoverable after setup, and retired shims must be removed from
# ~/.aidevops/bin when no longer deployed.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
DEPLOYMENT_MODULE="${REPO_DIR}/.agents/scripts/setup/_deployment.sh"

PASS=0
FAIL=0

assert_symlink_target() {
	local test_name="$1"
	local link_path="$2"
	local expected_target="$3"
	local actual_target=""
	if [[ -L "$link_path" ]]; then
		actual_target="$(readlink "$link_path")"
		if [[ "$actual_target" == "$expected_target" ]]; then
			echo "  PASS: $test_name"
			PASS=$((PASS + 1))
			return 0
		fi
	fi
	echo "  FAIL: $test_name"
	echo "    expected symlink: $link_path -> $expected_target"
	echo "    actual: ${actual_target:-missing or not a symlink}"
	FAIL=$((FAIL + 1))
	return 1
}

assert_missing() {
	local test_name="$1"
	local path="$2"
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $test_name"
	echo "    expected missing: $path"
	FAIL=$((FAIL + 1))
	return 1
}

assert_exists() {
	local test_name="$1"
	local path="$2"
	if [[ -e "$path" || -L "$path" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $test_name"
	echo "    expected existing: $path"
	FAIL=$((FAIL + 1))
	return 1
}

echo "Test: agent bin shim sync"
echo "==========================="
echo ""

tmp_home="$(mktemp -d)"
tmp_target="${tmp_home}/.aidevops/agents"
trap 'rm -rf "$tmp_home"' EXIT

mkdir -p "${tmp_target}/bin" "${tmp_home}/.aidevops/bin" "${tmp_home}/elsewhere"
printf '#!/usr/bin/env bash\n' >"${tmp_target}/bin/gh_create_pr"
printf '#!/usr/bin/env bash\n' >"${tmp_target}/bin/gh_create_issue"
chmod +x "${tmp_target}/bin/gh_create_pr" "${tmp_target}/bin/gh_create_issue"

ln -sf "${tmp_target}/bin/retired_shim" "${tmp_home}/.aidevops/bin/retired_shim"
ln -sf "${tmp_home}/elsewhere/external" "${tmp_home}/.aidevops/bin/external_link"
printf 'user file\n' >"${tmp_home}/.aidevops/bin/user_tool"

# shellcheck disable=SC1090
source "$DEPLOYMENT_MODULE"

HOME="$tmp_home" _sync_agent_bin_shims "$tmp_target"

assert_symlink_target "gh_create_pr shim is linked into user PATH bin" \
	"${tmp_home}/.aidevops/bin/gh_create_pr" "${tmp_target}/bin/gh_create_pr"
assert_symlink_target "gh_create_issue shim is linked into user PATH bin" \
	"${tmp_home}/.aidevops/bin/gh_create_issue" "${tmp_target}/bin/gh_create_issue"
assert_missing "stale aidevops-owned shim symlink is removed" \
	"${tmp_home}/.aidevops/bin/retired_shim"
assert_exists "external symlink is preserved" \
	"${tmp_home}/.aidevops/bin/external_link"
assert_exists "user-managed file is preserved" \
	"${tmp_home}/.aidevops/bin/user_tool"

echo ""
echo "==========================="
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
