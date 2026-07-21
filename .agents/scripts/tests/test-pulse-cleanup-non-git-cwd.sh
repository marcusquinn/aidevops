#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23372: pulse/worktree cleanup must not emit raw
# git fatal output when invoked from a non-git scheduler or temp directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
export LOGFILE
HOME="${TEST_ROOT}/home"
export HOME
mkdir -p "${HOME}/.config/aidevops"

# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck source=../pulse-cleanup.sh
source "${SCRIPT_DIR}/pulse-cleanup.sh"
_PULSE_CLEANUP_SCRIPT_DIR="$SCRIPT_DIR"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

test_pulse_fallback_skips_non_git_cwd() {
	local non_git_dir="${TEST_ROOT}/scheduler-cwd"
	mkdir -p "$non_git_dir"

	local output
	output=$(cd "$non_git_dir" && _cleanup_merged_prs_for_all_repos 2>&1) || true

	[[ "$output" == "0" ]] || fail "pulse fallback returned unexpected output: $output"
	[[ "$output" != *"fatal: not a git repository"* ]] || fail "pulse fallback emitted raw git fatal output"
	grep -q 'stage=merged-pr repo=unknown skipping cleanup — current directory is not a git repository' "$LOGFILE" \
		|| fail "pulse fallback did not log structured non-git skip"
	pass "pulse cleanup fallback skips non-git cwd without raw git fatal output"
	return 0
}

test_worktree_helper_skips_non_git_cwd() {
	local non_git_dir="${TEST_ROOT}/helper-cwd"
	mkdir -p "$non_git_dir"

	local output
	output=$(cd "$non_git_dir" && bash "${SCRIPT_DIR}/worktree-helper.sh" clean --auto --force-merged 2>&1) || true

	[[ "$output" != *"fatal: not a git repository"* ]] || fail "worktree helper emitted raw git fatal output"
	[[ "$output" == *"Warning: skipping worktree cleanup — current directory is not a git repository"* ]] \
		|| fail "worktree helper did not emit structured non-git warning: $output"
	pass "worktree helper skips non-git cwd without raw git fatal output"
	return 0
}

test_pulse_counts_only_verified_removal_events() {
	local fixture_repo="${TEST_ROOT}/accounting-repo"
	local helper_dir="${TEST_ROOT}/helper-bin"
	local helper_path="${helper_dir}/worktree-helper.sh"
	local output=""
	mkdir -p "$fixture_repo" "$helper_dir"
	git -C "$fixture_repo" init -q -b main
	rm -f "${HOME}/.config/aidevops/repos.json"
	_PULSE_CLEANUP_SCRIPT_DIR="$helper_dir"

	cat >"$helper_path" <<'EOF'
#!/usr/bin/env bash
printf 'Removing feature/refused...\n'
printf 'Skipped feature/refused - removal guard refused path\n'
exit 1
EOF
	chmod +x "$helper_path"
	output=$(cd "$fixture_repo" && _cleanup_merged_prs_for_all_repos)
	[[ "$output" == "0" ]] || fail "progress-only refused removal counted as completed: $output"

	cat >"$helper_path" <<'EOF'
#!/usr/bin/env bash
printf 'Removing feature/completed...\n'
printf 'AIDEVOPS_WORKTREE_REMOVAL_COMPLETED=1\n'
printf 'AIDEVOPS_WORKTREE_REMOVAL_COMPLETED=1 suffix-must-not-count\n'
exit 0
EOF
	chmod +x "$helper_path"
	output=$(cd "$fixture_repo" && _cleanup_merged_prs_for_all_repos)
	[[ "$output" == "1" ]] || fail "verified completion event produced unexpected count: $output"
	_PULSE_CLEANUP_SCRIPT_DIR="$SCRIPT_DIR"
	pass "pulse cleanup counts only exact post-verification removal events"
	return 0
}

test_pulse_fallback_skips_non_git_cwd
test_worktree_helper_skips_non_git_cwd
test_pulse_counts_only_verified_removal_events

exit 0
