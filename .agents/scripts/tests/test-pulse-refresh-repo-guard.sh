#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for pulse preflight repo refresh guard (GH#23542).

set -euo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s %s\n' "$name" "$extra"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export SCRIPT_DIR="$TEST_SCRIPTS_DIR"
	touch "$LOGFILE"
	git config --global commit.gpgsign false >/dev/null 2>&1 || true
	git config --global tag.gpgsign false >/dev/null 2>&1 || true
	git config --global init.defaultBranch main >/dev/null 2>&1 || true
	export GIT_CONFIG_NOSYSTEM=1
	export GIT_AUTHOR_NAME="Test"
	export GIT_AUTHOR_EMAIL="test@example.com"
	export GIT_COMMITTER_NAME="Test"
	export GIT_COMMITTER_EMAIL="test@example.com"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_deleted_upstream_repo() {
	local bare_dir="${TEST_ROOT}/origin.git"
	local clone_dir="${TEST_ROOT}/repo"
	git init --bare "$bare_dir" >/dev/null 2>&1
	git clone "$bare_dir" "$clone_dir" >/dev/null 2>&1
	(
		cd "$clone_dir" || exit 1
		git checkout -b main >/dev/null 2>&1
		printf 'initial\n' >file.txt
		git add file.txt
		git commit -m "initial" >/dev/null 2>&1
		git push -u origin main >/dev/null 2>&1
		git checkout -b deleted-branch >/dev/null 2>&1
		printf 'feature\n' >feature.txt
		git add feature.txt
		git commit -m "feature" >/dev/null 2>&1
		git push -u origin deleted-branch >/dev/null 2>&1
		git push origin --delete deleted-branch >/dev/null 2>&1
		git remote set-head origin main >/dev/null 2>&1
	)
	git --git-dir="$bare_dir" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
	printf '%s\n' "$clone_dir"
	return 0
}

test_refresh_skips_deleted_noncanonical_upstream() {
	local clone_dir=""
	clone_dir=$(setup_deleted_upstream_repo)
	true >"$LOGFILE"
	_pulse_refresh_repo "$clone_dir"

	if grep -Fq "refresh skipped: noncanonical or missing upstream" "$LOGFILE" && \
	   ! grep -Fq "attempting canonical-recovery" "$LOGFILE" && \
	   ! grep -Fq "git pull --ff-only failed" "$LOGFILE"; then
		print_result "deleted upstream refresh is skipped without recovery" 0
		return 0
	fi
	print_result "deleted upstream refresh is skipped without recovery" 1 "$(tr '\n' ' ' <"$LOGFILE")"
	return 0
}

main() {
	setup_sandbox
	trap teardown_sandbox EXIT
	# shellcheck source=/dev/null
	source "${TEST_SCRIPTS_DIR}/pulse-canonical-maintenance.sh"
	# shellcheck source=/dev/null
	source "${TEST_SCRIPTS_DIR}/pulse-wrapper-cycle.sh"
	declare -g -A _PULSE_REFRESHED_THIS_CYCLE=()
	test_refresh_skips_deleted_noncanonical_upstream
	printf 'Tests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
