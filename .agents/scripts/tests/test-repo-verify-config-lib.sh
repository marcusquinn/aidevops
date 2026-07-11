#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/../repo-verify-config-lib.sh"

passed=0
failed=0
TEST_TMP_DIR=""

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

new_repo() {
	local root="$1"
	mkdir -p "$root"
	git -C "$root" init -q
	return 0
}

test_exact_package_scripts() {
	local root="$1/package"
	new_repo "$root"
	cat >"$root/package.json" <<'JSON'
{"scripts":{"format":"prettier --write .","format:fix":"prettier --write .","lint":"eslint .","lint:fix":"eslint --fix .","typecheck":"tsc --noEmit"}}
JSON
	: >"$root/pnpm-lock.yaml"
	/usr/bin/git -C "$root" add package.json pnpm-lock.yaml
	repo_verify_detect "$root" || true
	assert_equal "ready" "$REPO_VERIFY_STATUS" "package scripts are detected"
	assert_equal "pnpm run lint" "$REPO_VERIFY_LINT" "package manager follows exact lockfile"
	assert_equal "" "$REPO_VERIFY_FORMAT" "mutating format script is not used as a check"
	assert_equal "pnpm run format:fix" "$REPO_VERIFY_FORMAT_FIX" "declared format fix is preserved"
	assert_equal "pnpm run typecheck" "$REPO_VERIFY_TYPECHECK" "typecheck script is detected"
	return 0
}

test_conflicting_lockfiles() {
	local root="$1/conflict"
	new_repo "$root"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root/package.json"
	: >"$root/pnpm-lock.yaml"
	: >"$root/yarn.lock"
	/usr/bin/git -C "$root" add package.json pnpm-lock.yaml yarn.lock
	repo_verify_detect "$root" || true
	assert_equal "ambiguous" "$REPO_VERIFY_STATUS" "multiple package manager locks are ambiguous"
	assert_equal "" "$REPO_VERIFY_LINT" "ambiguous package manager does not invent a command"
	return 0
}

test_package_manager_declaration_conflict() {
	local root="$1/manager-conflict"
	new_repo "$root"
	printf '%s\n' '{"packageManager":"pnpm@10.0.0","scripts":{"lint":"eslint ."}}' >"$root/package.json"
	: >"$root/package-lock.json"
	/usr/bin/git -C "$root" add package.json package-lock.json
	repo_verify_detect "$root" || true
	assert_equal "ambiguous" "$REPO_VERIFY_STATUS" "packageManager conflicting with lockfile is ambiguous"
	return 0
}

test_untracked_evidence_rejected() {
	local root="$1/untracked"
	new_repo "$root"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root/package.json"
	repo_verify_detect "$root" || true
	assert_equal "none" "$REPO_VERIFY_STATUS" "untracked package metadata is not provisioning evidence"
	return 0
}

test_python_evidence() {
	local root="$1/python-weak"
	new_repo "$root"
	printf '%s\n' '[project]' 'name="fixture"' >"$root/pyproject.toml"
	/usr/bin/git -C "$root" add pyproject.toml
	repo_verify_detect "$root" || true
	assert_equal "none" "$REPO_VERIFY_STATUS" "plain pyproject does not imply Ruff"

	root="$1/python-ruff"
	new_repo "$root"
	printf '%s\n' '[tool.ruff]' 'line-length=100' >"$root/pyproject.toml"
	/usr/bin/git -C "$root" add pyproject.toml
	repo_verify_detect "$root" || true
	assert_equal "defaults(PYTHON_RUFF)" "$REPO_VERIFY_SOURCE" "committed Ruff config is exact evidence"
	assert_equal "ruff check ." "$REPO_VERIFY_LINT" "Ruff lint command is seeded"
	return 0
}

test_explicit_opt_out() {
	local root="$1/disabled"
	new_repo "$root"
	printf '%s\n' '{"verify":{"enabled":false},"features":{"code_quality":false}}' >"$root/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root/package.json"
	repo_verify_detect "$root" || true
	assert_equal "disabled" "$REPO_VERIFY_STATUS" "explicit verify opt-out wins over detection"
	local before after
	before=$(cksum <"$root/.aidevops.json")
	repo_verify_apply_config "$root" true >/dev/null 2>&1 || true
	after=$(cksum <"$root/.aidevops.json")
	assert_equal "$before" "$after" "configure preserves explicit opt-out"
	return 0
}

test_feature_opt_out() {
	local root="$1/feature-disabled"
	new_repo "$root"
	printf '%s\n' '{"features":{"code_quality":false}}' >"$root/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root/package.json"
	/usr/bin/git -C "$root" add package.json
	repo_verify_detect "$root" || true
	assert_equal "disabled" "$REPO_VERIFY_STATUS" "code-quality feature false disables inferred checks"
	return 0
}

test_canonical_tracked_config_guard() {
	local root="$1/canonical"
	new_repo "$root"
	printf '%s\n' '{}' >"$root/.aidevops.json"
	/usr/bin/git -C "$root" add .aidevops.json
	/usr/bin/git -C "$root" -c user.email=test@example.com -c user.name=Test commit -q -m config
	/usr/bin/git -C "$root" branch -m develop
	local status=0
	repo_verify_config_is_safe_to_modify "$root" || status=$?
	assert_equal "1" "$status" "canonical tracked config is protected on non-main default branch"
	local linked="$1/linked"
	/usr/bin/git -C "$root" worktree add -q -b feature/test "$linked"
	status=0
	repo_verify_config_is_safe_to_modify "$linked" || status=$?
	assert_equal "0" "$status" "tracked config is writable in a linked worktree"
	return 0
}

test_concurrent_registration_writes() {
	local root_a="$1/concurrent-a"
	local root_b="$1/concurrent-b"
	local repos_file="$1/repos.json"
	new_repo "$root_a"
	new_repo "$root_b"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root_a/package.json"
	printf '%s\n' '{"scripts":{"lint":"eslint ."}}' >"$root_b/package.json"
	/usr/bin/git -C "$root_a" add package.json
	/usr/bin/git -C "$root_b" add package.json
	jq -n --arg a "$root_a" --arg b "$root_b" '{initialized_repos:[{path:$a,features:[]},{path:$b,features:[]}]}' >"$repos_file"
	printf '%s\n' '99999999' >"${repos_file}.aidevops-lock"
	(AIDEVOPS_REPOS_FILE="$repos_file" repo_verify_migrate_registration "$root_a") &
	local pid_a=$!
	(AIDEVOPS_REPOS_FILE="$repos_file" repo_verify_migrate_registration "$root_b") &
	local pid_b=$!
	wait "$pid_a"
	wait "$pid_b"
	assert_equal "2" "$(jq '[.initialized_repos[] | select((.features // []) | index("code-quality"))] | length' "$repos_file")" "concurrent registration migrations preserve both updates"
	return 0
}

test_config_merge() {
	local root="$1/merge"
	new_repo "$root"
	printf '%s\n' '{"custom":{"keep":true},"features":{"planning":true}}' >"$root/.aidevops.json"
	printf '%s\n' '{"scripts":{"lint":"eslint .","lint:fix":"eslint --fix ."}}' >"$root/package.json"
	/usr/bin/git -C "$root" add package.json
	repo_verify_apply_config "$root" true
	assert_equal "true" "$(jq -r '.custom.keep' "$root/.aidevops.json")" "configure preserves unknown keys"
	assert_equal "true" "$(jq -r '.features.planning' "$root/.aidevops.json")" "configure preserves existing features"
	assert_equal "true" "$(jq -r '.features.code_quality' "$root/.aidevops.json")" "configure enables code quality"
	assert_equal "npm run lint" "$(jq -r '.verify.lint' "$root/.aidevops.json")" "configure seeds exact lint command"
	assert_equal "npm run lint:fix" "$(jq -r '.verify.lint_fix' "$root/.aidevops.json")" "configure seeds only declared fix command"
	return 0
}

main() {
	TEST_TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TEST_TMP_DIR"' EXIT
	test_exact_package_scripts "$TEST_TMP_DIR"
	test_conflicting_lockfiles "$TEST_TMP_DIR"
	test_package_manager_declaration_conflict "$TEST_TMP_DIR"
	test_untracked_evidence_rejected "$TEST_TMP_DIR"
	test_python_evidence "$TEST_TMP_DIR"
	test_explicit_opt_out "$TEST_TMP_DIR"
	test_feature_opt_out "$TEST_TMP_DIR"
	test_config_merge "$TEST_TMP_DIR"
	test_canonical_tracked_config_guard "$TEST_TMP_DIR"
	test_concurrent_registration_writes "$TEST_TMP_DIR"
	printf '\nRan %d tests, %d failed.\n' "$((passed + failed))" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main "$@"
