#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27400: config-helper's intentional shared-module
# source cycle must not recursively invoke main().

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
REPO_DIR="$(cd "${SCRIPTS_DIR}/../.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/config-helper.sh"
CLI="${REPO_DIR}/aidevops.sh"
TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s — %s\n' "$message" "$detail"
	return 0
}

assert_success_without_recursion() {
	local name="$1"
	shift
	local output=""
	local status=0
	output=$("$@" 2>&1) || status=$?
	if [[ "$status" -eq 0 && "$output" != *"Unknown command:"* && "$output" != *"pop_var_context"* ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} output=${output}"
	fi
	return 0
}

TMP_DIR=$(mktemp -d /tmp/aidevops-config-recursion.XXXXXX) || exit 1
cleanup() {
	local tmp_dir="${TMP_DIR:-}"
	if [[ -n "$tmp_dir" && "$tmp_dir" == /tmp/aidevops-config-recursion.* ]]; then
		rm -rf "$tmp_dir"
	fi
	return 0
}
trap cleanup EXIT

export HOME="${TMP_DIR}/home"
export AIDEVOPS_AGENTS_DIR="${REPO_DIR}/.agents"
mkdir -p "${HOME}/.aidevops"
ln -s "${REPO_DIR}/.agents" "${HOME}/.aidevops/agents"

assert_success_without_recursion "direct helper get" bash "$HELPER" get orchestration.min_worker_concurrency
# shellcheck disable=SC2016 # Positional parameters intentionally expand in the child shell.
assert_success_without_recursion "sourced helper loads without dispatch" bash -c 'source "$1"; source "$1"; declare -F _jsonc_get >/dev/null' _ "$HELPER"
assert_success_without_recursion "public config get" bash "$CLI" config get orchestration.min_worker_concurrency
assert_success_without_recursion "public config set" bash "$CLI" config set orchestration.min_worker_concurrency 7
assert_success_without_recursion "public config validate" bash "$CLI" config validate

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\nAll %d tests passed\n' "$TESTS_RUN"
	exit 0
fi

printf '\n%d of %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
