#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
WRAPPER_SCRIPT="${REPO_SCRIPTS_DIR}/pulse-wrapper.sh"
DEFAULTS_SOURCE="${SCRIPT_DIR}/../../configs/aidevops.defaults.jsonc"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

seed_deployed_scripts() {
	local sandbox_home="$1"
	mkdir -p \
		"${sandbox_home}/.aidevops/agents" \
		"${sandbox_home}/.aidevops/agents/configs" \
		"${sandbox_home}/.aidevops/logs"
	ln -s "$REPO_SCRIPTS_DIR" "${sandbox_home}/.aidevops/agents/scripts"
	cp "$DEFAULTS_SOURCE" \
		"${sandbox_home}/.aidevops/agents/configs/aidevops.defaults.jsonc"
	return 0
}

make_instrumented_wrapper() {
	local source_file="$1"
	local dest_file="$2"
	python3 - "$source_file" "$dest_file" <<'PY'
import sys
source, dest = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
needle = "set -euo pipefail\n"
injection = """
if [[ "${PULSE_WRAPPER_STALE_DIR_TEST:-0}" == "1" ]]; then
\tprintf 'ready\\n' >"${PULSE_WRAPPER_STALE_DIR_READY_FILE:?}"
\tsleep 2
fi
"""
if needle not in text:
    raise SystemExit("needle not found")
open(dest, "w", encoding="utf-8").write(text.replace(needle, needle + injection, 1))
PY
	chmod +x "$dest_file"
	return 0
}

test_stale_script_dir_recovers_to_deployed_scripts() {
	local sandbox stale_dir stale_script ready_file output_file pid rc output
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home" "${sandbox}/removed-worktree/.agents/scripts"
	seed_deployed_scripts "${sandbox}/home"

	stale_dir="${sandbox}/removed-worktree/.agents/scripts"
	stale_script="${stale_dir}/pulse-wrapper.sh"
	ready_file="${sandbox}/ready"
	output_file="${sandbox}/output.txt"
	make_instrumented_wrapper "$WRAPPER_SCRIPT" "$stale_script"

	HOME="${sandbox}/home" \
		PULSE_WRAPPER_STALE_DIR_TEST=1 \
		PULSE_WRAPPER_STALE_DIR_READY_FILE="$ready_file" \
		PULSE_JITTER_MAX=0 \
		FULL_LOOP_HEADLESS=1 \
		bash "$stale_script" --self-check >"$output_file" 2>&1 &
	pid=$!

	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[[ -f "$ready_file" ]] && break
		sleep 0.2
	done
	rm -rf "${sandbox}/removed-worktree"

	if wait "$pid"; then
		rc=0
	else
		rc=$?
	fi
	output=$(<"$output_file")
	rm -rf "$sandbox"

	if [[ "$rc" -eq 0 ]] \
		&& printf '%s' "$output" | grep -q 'script directory unavailable' \
		&& printf '%s' "$output" | grep -q 'self-check: ok'; then
		print_result "removed worktree script dir recovers to deployed scripts" 0
		return 0
	fi

	print_result "removed worktree script dir recovers to deployed scripts" 1 \
		"Expected self-check recovery via deployed scripts, rc=${rc}, output=${output}"
	return 0
}

main() {
	test_stale_script_dir_recovers_to_deployed_scripts

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
