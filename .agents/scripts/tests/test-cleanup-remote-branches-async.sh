#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-cleanup-remote-branches-async.sh — Unit tests for cleanup-remote-branches-async-helper.sh (GH#22415)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../cleanup-remote-branches-async-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		if [[ -n "$message" ]]; then
			printf '  %s\n' "$message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

write_stub_helper() {
	local stub_dir="$1"
	local marker_file="$2"
	mkdir -p "$stub_dir"
	cat >"${stub_dir}/shared-constants.sh" <<'STUB'
# stub shared-constants.sh
STUB
	cat >"${stub_dir}/remote-branch-cleanup-helper.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"${marker_file}"
for arg in "\$@"; do
	if [[ "\$arg" == "--apply" ]]; then
		printf '%s\n' "APPLY" >>"${marker_file}"
	fi
done
STUB
	chmod +x "${stub_dir}/remote-branch-cleanup-helper.sh"
	return 0
}

copy_helper_to_stub_dir() {
	local stub_dir="$1"
	cp "$HELPER" "${stub_dir}/cleanup-remote-branches-async-helper.sh"
	chmod +x "${stub_dir}/cleanup-remote-branches-async-helper.sh"
	return 0
}

make_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path"
	git init -q "$repo_path"
	git -C "$repo_path" config user.email test@example.invalid
	git -C "$repo_path" config user.name "Remote Branch Async Test"
	git -C "$repo_path" config commit.gpgsign false
	printf 'base\n' >"${repo_path}/base.txt"
	git -C "$repo_path" add base.txt
	git -C "$repo_path" commit -qm base
	return 0
}

write_repos_config() {
	local repo_path="$1"
	local config_dir="${TEST_DIR}/.config/aidevops"
	mkdir -p "$config_dir"
	cat >"${config_dir}/repos.json" <<JSON
{"initialized_repos":[{"path":"${repo_path}","local_only":false}],"git_parent_dirs":[]}
JSON
	return 0
}

run_helper_in_isolation() {
	local extra_env_name="${1:-}"
	local extra_env_value="${2:-}"
	local stub_dir="${TEST_DIR}/scripts"
	local marker_file="${TEST_DIR}/mock-ran"
	write_stub_helper "$stub_dir" "$marker_file"
	copy_helper_to_stub_dir "$stub_dir"

	if [[ -n "$extra_env_name" ]]; then
		env HOME="$TEST_DIR" \
			CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN="${CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN:-10}" \
			AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT:-1}" \
			AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY:-0}" \
			"$extra_env_name"="$extra_env_value" \
			bash "${stub_dir}/cleanup-remote-branches-async-helper.sh" 2>/dev/null || true
	else
		env HOME="$TEST_DIR" \
			CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN="${CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN:-10}" \
			AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT:-1}" \
			AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY:-0}" \
			bash "${stub_dir}/cleanup-remote-branches-async-helper.sh" 2>/dev/null || true
	fi
	return 0
}

test_cold_start_dry_run() {
	local repo_path="${TEST_DIR}/repo"
	local marker_file="${TEST_DIR}/mock-ran"
	make_repo "$repo_path"
	write_repos_config "$repo_path"
	rm -f "$marker_file"

	AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT=1 run_helper_in_isolation

	if [[ -f "$marker_file" ]] && grep -q -- "--repo ${repo_path}" "$marker_file" && ! grep -q "APPLY" "$marker_file"; then
		print_result "cold-start: audits current repo in dry-run mode" 0
	else
		print_result "cold-start: audits current repo in dry-run mode" 1 "mock marker missing or apply flag present"
	fi
	return 0
}

test_apply_requires_explicit_flag() {
	local repo_path="${TEST_DIR}/repo-apply"
	local marker_file="${TEST_DIR}/mock-ran"
	local last_run_file="${TEST_DIR}/.aidevops/logs/cleanup_remote_branches.last-run"
	make_repo "$repo_path"
	write_repos_config "$repo_path"
	rm -f "$marker_file" "$last_run_file"

	AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY=1 AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT=1 \
		run_helper_in_isolation

	if [[ -f "$marker_file" ]] && grep -q "APPLY" "$marker_file"; then
		print_result "apply mode: passes --apply only when explicitly enabled" 0
	else
		print_result "apply mode: passes --apply only when explicitly enabled" 1 "--apply was not passed"
	fi
	return 0
}

test_cadence_gate() {
	local repo_path="${TEST_DIR}/repo-cadence"
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local marker_file="${TEST_DIR}/mock-ran"
	make_repo "$repo_path"
	write_repos_config "$repo_path"
	mkdir -p "$logs_dir"
	printf '%s\n' "$(( $(date +%s) - 30 ))" >"${logs_dir}/cleanup_remote_branches.last-run"
	rm -f "$marker_file"

	AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT=1 CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN=10 \
		run_helper_in_isolation

	if [[ ! -f "$marker_file" ]]; then
		print_result "cadence-gate: skips when last run is recent" 0
	else
		print_result "cadence-gate: skips when last run is recent" 1 "cleanup ran despite recent last-run"
	fi
	return 0
}

test_lock_held() {
	local repo_path="${TEST_DIR}/repo-lock"
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local lock_dir="${logs_dir}/cleanup_remote_branches.lock"
	local marker_file="${TEST_DIR}/mock-ran"
	make_repo "$repo_path"
	write_repos_config "$repo_path"
	mkdir -p "$lock_dir"
	printf '%s\n' "$$" >"${lock_dir}/pid"
	rm -f "$marker_file"

	AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT=1 run_helper_in_isolation

	if [[ ! -f "$marker_file" ]]; then
		print_result "lock-held: skips when live lock exists" 0
	else
		print_result "lock-held: skips when live lock exists" 1 "cleanup ran despite live lock"
	fi
	rm -rf "$lock_dir" 2>/dev/null || true
	return 0
}

test_low_rate_limit_skip() {
	local repo_path="${TEST_DIR}/repo-rate"
	local stub_dir="${TEST_DIR}/scripts"
	local marker_file="${TEST_DIR}/mock-ran"
	make_repo "$repo_path"
	write_repos_config "$repo_path"
	write_stub_helper "$stub_dir" "$marker_file"
	cat >"${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	printf '%s\n' '0'
fi
STUB
	chmod +x "${stub_dir}/gh"
	copy_helper_to_stub_dir "$stub_dir"
	rm -f "$marker_file"

	env HOME="$TEST_DIR" PATH="$stub_dir:$PATH" \
		AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT=0 \
		AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING=100 \
		bash "${stub_dir}/cleanup-remote-branches-async-helper.sh" 2>/dev/null || true

	if [[ ! -f "$marker_file" ]]; then
		print_result "rate-limit: skips cleanup when API budget is low" 0
	else
		print_result "rate-limit: skips cleanup when API budget is low" 1 "cleanup ran despite low rate limit"
	fi
	return 0
}

main() {
	setup
	test_cold_start_dry_run
	test_apply_requires_explicit_flag
	test_cadence_gate
	test_lock_held
	test_low_rate_limit_skip

	printf '\nTests run: %s, passed: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
