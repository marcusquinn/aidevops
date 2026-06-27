#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for per-cycle pulse merge API caches.
#
# Usage: bash .agents/tests/test-pulse-merge-cycle-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
LOGFILE="${TMPDIR:-/tmp}/aidevops-pulse-cache-test.log"
TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — ${reason}}"
	return 0
}

_gh_permission_calls=0
_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local author="$2"
	local out_var="$3"
	_gh_permission_calls=$((_gh_permission_calls + 1))
	[[ "$repo_slug" == "owner/repo" && "$author" == "worker" ]] || return 1
	printf -v "$out_var" '%s' "write"
	AIDEVOPS_GH_COLLAB_PERMISSION_HTTP=200
	return 0
}

# shellcheck source=../scripts/pulse-merge-author-checks.sh
source "${SCRIPTS_DIR}/pulse-merge-author-checks.sh"

test_author_permission_lookup_uses_cycle_cache() {
	local name="author permission lookup caches repo/author within a cycle"
	local cache_dir="" first_perm="" second_perm=""
	cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-author-cache-test.XXXXXX") || return 1
	AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR="$cache_dir"
	_gh_permission_calls=0

	_pulse_author_permission_lookup "worker" "owner/repo" first_perm || true
	_pulse_author_permission_lookup "worker" "owner/repo" second_perm || true
	rm -rf -- "$cache_dir"
	unset AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR

	if [[ "$first_perm" != "write" || "$second_perm" != "write" ]]; then
		_fail "$name" "expected cached permission write/write, got ${first_perm}/${second_perm}"
		return 0
	fi
	if [[ "$_gh_permission_calls" -ne 1 ]]; then
		_fail "$name" "expected 1 API lookup, got ${_gh_permission_calls}"
		return 0
	fi
	_pass "$name"
	return 0
}

_GH_REPO_CALLS_FILE="${TMPDIR:-/tmp}/aidevops-context-cache-repo-calls.$$"
_GH_PROTECTION_CALLS_FILE="${TMPDIR:-/tmp}/aidevops-context-cache-protection-calls.$$"
_GH_RULESET_CALLS_FILE="${TMPDIR:-/tmp}/aidevops-context-cache-ruleset-calls.$$"
_increment_counter_file() {
	local counter_file="$1"
	local current_value="0"
	if [[ -f "$counter_file" ]]; then
		current_value=$(<"$counter_file")
	fi
	[[ "$current_value" =~ ^[0-9]+$ ]] || current_value=0
	current_value=$((current_value + 1))
	printf '%s\n' "$current_value" >"$counter_file"
	return 0
}

_read_counter_file() {
	local counter_file="$1"
	local current_value="0"
	if [[ -f "$counter_file" ]]; then
		current_value=$(<"$counter_file")
	fi
	[[ "$current_value" =~ ^[0-9]+$ ]] || current_value=0
	printf '%s' "$current_value"
	return 0
}

gh() {
	local subcommand="$1"
	local endpoint="${2:-}"
	[[ "$subcommand" == "api" ]] || return 1
	case "$endpoint" in
	"repos/owner/repo")
		_increment_counter_file "$_GH_REPO_CALLS_FILE"
		printf '%s\n' "main"
		return 0
		;;
	"repos/owner/repo/branches/main/protection/required_status_checks")
		_increment_counter_file "$_GH_PROTECTION_CALLS_FILE"
		printf '{"contexts":["ci/test"]}\n'
		return 0
		;;
	"repos/owner/repo/rulesets")
		_increment_counter_file "$_GH_RULESET_CALLS_FILE"
		printf '[]\n'
		return 0
		;;
	esac
	return 1
}

# shellcheck source=../scripts/pulse-merge-process.sh
source "${SCRIPTS_DIR}/pulse-merge-process.sh"

test_required_context_lookup_uses_cycle_cache() {
	local name="required context lookup caches repo default-branch contexts within a cycle"
	local cache_dir="" first_contexts="" second_contexts=""
	local repo_calls="" protection_calls="" ruleset_calls=""
	cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-context-cache-test.XXXXXX") || return 1
	AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR="$cache_dir"
	printf '0\n' >"$_GH_REPO_CALLS_FILE"
	printf '0\n' >"$_GH_PROTECTION_CALLS_FILE"
	printf '0\n' >"$_GH_RULESET_CALLS_FILE"

	first_contexts=$(_required_contexts_for_default_branch "owner/repo") || true
	second_contexts=$(_required_contexts_for_default_branch "owner/repo") || true
	rm -rf -- "$cache_dir"
	unset AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR
	repo_calls=$(_read_counter_file "$_GH_REPO_CALLS_FILE")
	protection_calls=$(_read_counter_file "$_GH_PROTECTION_CALLS_FILE")
	ruleset_calls=$(_read_counter_file "$_GH_RULESET_CALLS_FILE")
	rm -f -- "$_GH_REPO_CALLS_FILE" "$_GH_PROTECTION_CALLS_FILE" "$_GH_RULESET_CALLS_FILE"

	if [[ "$first_contexts" != "ci/test" || "$second_contexts" != "ci/test" ]]; then
		_fail "$name" "expected ci/test contexts, got ${first_contexts}/${second_contexts}"
		return 0
	fi
	if [[ "$repo_calls" -ne 1 || "$protection_calls" -ne 1 || "$ruleset_calls" -ne 1 ]]; then
		_fail "$name" "expected one repo/protection/ruleset call, got ${repo_calls}/${protection_calls}/${ruleset_calls}"
		return 0
	fi
	_pass "$name"
	return 0
}

main() {
	test_author_permission_lookup_uses_cycle_cache
	test_required_context_lookup_uses_cycle_cache

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
