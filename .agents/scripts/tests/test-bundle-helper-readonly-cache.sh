#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export AIDEVOPS_BUNDLE_CACHE_DIR="${HOME}/.aidevops/cache/bundle"
mkdir -p "$HOME"

repo="${TEST_ROOT}/canonical-repo"
mkdir -p "$repo"
printf '{"plugins":[]}\n' >"${repo}/.aidevops.json"
printf '{"name":"readonly-cache-test"}\n' >"${repo}/package.json"

snapshot_repo() {
	local target_repo="$1"
	cksum <"${target_repo}/.aidevops.json"
	cksum <"${target_repo}/package.json"
	printf '%s\n' "${target_repo}"/* "${target_repo}"/.[!.]* | sort
	return 0
}

before=$(snapshot_repo "$repo")
"${SCRIPT_DIR}/bundle-helper.sh" detect --force "$repo" >/dev/null
"${SCRIPT_DIR}/bundle-helper.sh" resolve --force "$repo" >/dev/null
"${SCRIPT_DIR}/bundle-helper.sh" get model_defaults.implementation "$repo" >/dev/null
"${SCRIPT_DIR}/bundle-helper.sh" show "$repo" >/dev/null
after=$(snapshot_repo "$repo")

if [[ "$before" != "$after" ]]; then
	printf 'FAIL bundle helper changed canonical checkout bytes\n' >&2
	exit 1
fi

cache_files=("${AIDEVOPS_BUNDLE_CACHE_DIR}"/*.json)
if [[ ! -f "${cache_files[0]:-}" ]]; then
	printf 'FAIL bundle helper did not write user-local cache\n' >&2
	exit 1
fi
if [[ "$(stat -f '%Lp' "${cache_files[0]}" 2>/dev/null || stat -c '%a' "${cache_files[0]}")" != "600" ]]; then
	printf 'FAIL bundle cache file is not mode 600\n' >&2
	exit 1
fi

first_detection=$("${SCRIPT_DIR}/bundle-helper.sh" detect "$repo")
second_detection=$("${SCRIPT_DIR}/bundle-helper.sh" detect "$repo")
if [[ -z "$first_detection" || "$first_detection" != "$second_detection" ]]; then
	printf 'FAIL bundle cache did not survive helper restart\n' >&2
	exit 1
fi

printf 'PASS bundle helper caches outside canonical checkout and preserves byte identity\n'
