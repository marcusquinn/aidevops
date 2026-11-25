#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-commit-hook-pipe-early-exit.sh — validate_pipe_early_exit in
# pre-commit-hook.sh (GH#40407) blocks an early-exit pipe reader added under
# pipefail, allows the here-string form, ignores a pre-existing match on an
# unchanged line, and never blocks when it has no files or no HEAD commit.
# The real pipe-early-exit-check.sh runs against throwaway Git repositories.
# pipe-early-exit-check:disable — fixtures below contain the anti-pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HOOK_SCRIPT="${SCRIPTS_DIR}/pre-commit-hook.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local name="$1" failed="$2" detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -z "$detail" ]] || printf '       %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

print_error() { local msg="$1"; printf '[ERROR] %s\n' "$msg" >&2; return 0; }
print_warning() { local msg="$1"; printf '[WARNING] %s\n' "$msg" >&2; return 0; }
print_info() { local msg="$1"; printf '[INFO] %s\n' "$msg" >&2; return 0; }

# Load only the validator under test; main "$@" must not run.
validator_src=$(awk '/^validate_pipe_early_exit\(\)/ { c=1 } c { print } c && /^}$/ { c=0 }' "$HOOK_SCRIPT")
[[ -n "$validator_src" ]] || { printf 'FAIL validate_pipe_early_exit not found in %s\n' "$HOOK_SCRIPT"; exit 1; }
# shellcheck disable=SC1090  # evaluating the extracted hook function is the point
eval "$validator_src"
SCRIPT_DIR="$SCRIPTS_DIR"

init_repo() {
	local name="$1"
	mkdir -p "${TEST_ROOT}/${name}"
	cd "${TEST_ROOT}/${name}" || exit 1
	git init -q
	git config user.email "pipe-test@example.invalid"
	git config user.name "Pipe Test"
	git config commit.gpgsign false
	return 0
}

# shellcheck disable=SC2016  # fixture bodies are literal shell source
BASE_BODY='#!/usr/bin/env bash
set -euo pipefail
f() {
	local x="$1"
	printf "%s" "$x" | grep -q legacy
	return 0
}
'
# shellcheck disable=SC2016  # fixture bodies are literal shell source
ADDED_PIPE='	printf "%s" "$x" | grep -q added
'
# shellcheck disable=SC2016  # fixture bodies are literal shell source
ADDED_HERESTRING='	grep -q added <<<"$x"
'

run_validator() {
	local out_var="$1"
	shift
	local captured="" rc=0
	captured=$(validate_pipe_early_exit "$@" 2>&1) || rc=$?
	printf -v "$out_var" '%s' "$captured"
	return "$rc"
}

out="" rc=0
init_repo added_pipe
printf '%s' "$BASE_BODY" >s.sh
git add s.sh && git commit -q --no-verify -m base
printf '%s%s' "$BASE_BODY" "$ADDED_PIPE" >s.sh
git add s.sh
run_validator out s.sh || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF 's.sh:8: early-exit pipe under pipefail' <<<"$out" && ! grep -qF 's.sh:5:' <<<"$out"; then
	print_result "added early-exit pipe reader blocks and names only the added line" 0
else
	print_result "added early-exit pipe reader blocks and names only the added line" 1 "rc=${rc} out=[${out}]"
fi

rc=0
init_repo added_herestring
printf '%s' "$BASE_BODY" >s.sh
git add s.sh && git commit -q --no-verify -m base
printf '%s%s' "$BASE_BODY" "$ADDED_HERESTRING" >s.sh
git add s.sh
run_validator out s.sh || rc=$?
print_result "here-string form passes beside a pre-existing match" "$rc" "out=[${out}]"

rc=0
init_repo no_files
run_validator out || rc=$?
print_result "no files is a no-op pass (installer dry-run)" "$rc" "out=[${out}]"

rc=0
init_repo no_head
printf '%s%s' "$BASE_BODY" "$ADDED_PIPE" >s.sh
git add s.sh
run_validator out s.sh || rc=$?
if [[ "$rc" -eq 0 ]] && grep -qF 'skipping early-exit pipe validation' <<<"$out"; then
	print_result "initial commit without HEAD skips instead of blocking" 0
else
	print_result "initial commit without HEAD skips instead of blocking" 1 "rc=${rc} out=[${out}]"
fi

rc=0
init_repo missing_checker
printf '%s' "$BASE_BODY" >s.sh
git add s.sh && git commit -q --no-verify -m base
printf '%s%s' "$BASE_BODY" "$ADDED_PIPE" >s.sh
git add s.sh
SCRIPT_DIR="${TEST_ROOT}/missing_checker"
run_validator out s.sh || rc=$?
SCRIPT_DIR="$SCRIPTS_DIR"
if [[ "$rc" -eq 0 ]] && grep -qF 'pipe-early-exit-check.sh not found' <<<"$out"; then
	print_result "missing checker warns instead of blocking" 0
else
	print_result "missing checker warns instead of blocking" 1 "rc=${rc} out=[${out}]"
fi

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%s/%s test(s) failed\n' "$TESTS_FAILED" "$TESTS_RUN"
	exit 1
fi
printf 'All %s tests passed\n' "$TESTS_RUN"
exit 0
