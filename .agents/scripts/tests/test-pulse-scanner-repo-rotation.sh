#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#37555: review-thread and auto-decomposer scanners rotate repos with a
# cursor so short housekeeping slices still reach every repository.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local failed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Stubs for pulse-simplification-review.sh dependencies.
_pulse_enabled_repo_slugs() {
	printf '%s\n' "o/a" "o/b" "o/c" "o/d"
	return 0
}

get_repo_role_by_slug() {
	local slug="$1"
	if [[ "$slug" == "o/b" ]]; then
		printf 'contributor\n'
		return 0
	fi
	printf 'maintainer\n'
	return 0
}

# Each stub scanner records "<slug> <cursor at call time>" and kills its
# caller when KILL_AT names the slug, reproducing a stage watchdog kill.
write_stub_scanner() {
	local path="$1"
	local cursor_file="$2"
	cat >"$path" <<EOF
#!/usr/bin/env bash
slug="\$2"
cursor=\$(sed -n '1p' "${cursor_file}" 2>/dev/null || true)
printf '%s %s\n' "\$slug" "\$cursor" >>"${TEST_ROOT}/calls.log"
if [[ -n "\${KILL_AT:-}" && "\$slug" == "\${KILL_AT}" ]]; then
	kill -KILL "\$PPID"
fi
exit 0
EOF
	chmod +x "$path"
	return 0
}

setup() {
	TEST_ROOT="$(mktemp -d -t t18944-rotation.XXXXXX)"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "$HOME" "${TEST_ROOT}/scripts"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
	export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_CURSOR_DIR="${TEST_ROOT}/prr"
	export AIDEVOPS_AUTO_DECOMPOSER_CURSOR_DIR="${TEST_ROOT}/ad"
	export AUTO_DECOMPOSER_INTERVAL=604800
	SCRIPT_DIR="${TEST_ROOT}/scripts"
	write_stub_scanner "${SCRIPT_DIR}/pr-review-thread-response-scanner.sh" "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_CURSOR_DIR}/repo.cursor"
	write_stub_scanner "${SCRIPT_DIR}/auto-decomposer-scanner.sh" "${AIDEVOPS_AUTO_DECOMPOSER_CURSOR_DIR}/repo.cursor"
	unset _PULSE_SIMPLIFICATION_REVIEW_LIB_LOADED
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-simplification-review.sh"
	return 0
}

teardown() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

calls_slugs() {
	awk '{print $1}' "${TEST_ROOT}/calls.log" | tr '\n' ' '
	return 0
}

test_rotation_helper() {
	setup
	local failed=0 cursor="${TEST_ROOT}/c/repo.cursor" out=""
	local slugs=$'o/a\no/b\no/c\no/d'
	out=$(_pulse_scanner_rotated_slugs "$cursor" "$slugs" | tr '\n' ' ')
	[[ "$out" == "o/a o/b o/c o/d " ]] || failed=1
	_pulse_scanner_mark_started "$cursor" "o/b"
	out=$(_pulse_scanner_rotated_slugs "$cursor" "$slugs" | tr '\n' ' ')
	[[ "$out" == "o/c o/d o/a o/b " ]] || failed=1
	_pulse_scanner_mark_started "$cursor" "o/d"
	out=$(_pulse_scanner_rotated_slugs "$cursor" "$slugs" | tr '\n' ' ')
	[[ "$out" == "o/a o/b o/c o/d " ]] || failed=1
	_pulse_scanner_mark_started "$cursor" "o/gone"
	out=$(_pulse_scanner_rotated_slugs "$cursor" "$slugs" | tr '\n' ' ')
	[[ "$out" == "o/a o/b o/c o/d " ]] || failed=1
	print_result "rotation resumes after cursor, wraps, and ignores stale cursors" "$failed"
	teardown
	return 0
}

run_scanner_case() {
	local scanner_fn="$1"
	local label="$2"
	setup
	local failed=0
	# First slice is killed while scanning o/c (watchdog analogue).
	{ (KILL_AT="o/c" "$scanner_fn") || true; } 2>/dev/null
	[[ "$(calls_slugs)" == "o/a o/c " ]] || failed=1
	# The cursor names the repo being scanned when the scanner starts.
	grep -qx 'o/c o/c' "${TEST_ROOT}/calls.log" || failed=1
	# Next slice resumes after the killed repo instead of restarting at o/a.
	: >"${TEST_ROOT}/calls.log"
	("$scanner_fn") || failed=1
	[[ "$(calls_slugs)" == "o/d o/a o/c " ]] || failed=1
	print_result "${label}: killed slice advances rotation past the slow repo" "$failed"
	teardown
	return 0
}

main() {
	test_rotation_helper
	run_scanner_case _run_pr_review_thread_response_scanner "pr-review-thread-response"
	run_scanner_case _run_auto_decomposer_scanner "auto-decomposer"
	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
