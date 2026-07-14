#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dspy-cache-security.sh
source "$SCRIPT_DIR/../dspy-cache-security.sh"

TEST_TMP_ROOT="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_ROOT"
TEST_ROOT="$(mktemp -d "$TEST_TMP_ROOT/dspy-cache-security.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

test_secure_default_cache() {
	local mode
	HOME="$TEST_ROOT/home"
	mkdir -p "$HOME"
	unset AIDEVOPS_CACHE_DIR DSPY_CACHEDIR

	aidevops_secure_dspy_cache
	[[ "$DSPY_CACHEDIR" == "$HOME/.aidevops/cache/dspy" ]] || fail "unexpected default cache path"
	[[ -O "$DSPY_CACHEDIR" && ! -L "$DSPY_CACHEDIR" ]] || fail "cache is not owner-controlled"
	mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$DSPY_CACHEDIR")
	[[ "$mode" == "0o700" ]] || fail "cache mode is $mode, expected 0o700"
	return 0
}

test_rejects_relative_cache() {
	DSPY_CACHEDIR="relative/cache"
	if aidevops_secure_dspy_cache 2>/dev/null; then
		fail "relative cache path was accepted"
	fi
	return 0
}

test_rejects_symlink_cache() {
	local target="$TEST_ROOT/target"
	local link="$TEST_ROOT/cache-link"
	mkdir -p "$target"
	ln -s "$target" "$link"
	DSPY_CACHEDIR="$link"
	if aidevops_secure_dspy_cache 2>/dev/null; then
		fail "symlinked cache path was accepted"
	fi
	return 0
}

test_persists_activation_once() {
	local activate_file="$TEST_ROOT/activate"
	local marker_count
	printf '# virtualenv activation\n' >"$activate_file"

	aidevops_persist_dspy_cache_env "$activate_file"
	aidevops_persist_dspy_cache_env "$activate_file"
	marker_count=$(grep -Fc '# aidevops:dspy-cache-security' "$activate_file")
	[[ "$marker_count" == "1" ]] || fail "activation marker was not idempotent"
	return 0
}

test_secure_default_cache
test_rejects_relative_cache
test_rejects_symlink_cache
test_persists_activation_once
printf 'PASS: DSPy cache security tests\n'
