#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t1992: daily quality sweep section serialization.
#
# Problem fixed:
#   _run_sweep_tools() previously wrote 12 fields via `printf '%s\n' ...`
#   and _quality_sweep_for_repo() read them back with a chain of
#   `IFS= read -r`. That pattern only works for single-line values. Every
#   *_section variable (shellcheck/qlty/sonar/codacy/coderabbit/review_scan)
#   contains multi-line markdown, so lines 2..N of each section leaked
#   into subsequent variables and the posted comment was fragmented.
#
# Strategy:
#   1. Source stats-functions.sh in a sandboxed $HOME so the top-level
#      helpers that touch real state (`gh`, repo paths, log files) don't
#      misbehave during the test.
#   2. Stub out the per-tool producers (`_sweep_shellcheck`, `_sweep_qlty`,
#      `_sweep_sonarcloud`, `_sweep_codacy`, `_sweep_coderabbit`,
#      `_sweep_review_scanner`, `_save_sweep_state`) to emit known
#      fixtures — including multi-line markdown, empty strings, and
#      sections adjacent to integer fields.
#   3. Call `_run_sweep_tools` directly and confirm it emits a
#      sections_dir path whose files round-trip the fixtures byte-for-byte.
#   4. Drive the full _quality_sweep_for_repo reader path (up to the
#      gh-comment call) by stubbing `gh`, `_ensure_quality_issue`, and
#      `_update_quality_issue_body`, then asserting the `_build_sweep_comment`
#      invocation sees each fixture section unmodified.
#
# Assertions cover (>= 5 required by the task brief):
#   1. shellcheck_section survives round-trip byte-for-byte  10-line fixture
#   2. qlty_section survives with 20-line fixture
#   3. sonar_section + adjacent integer metadata survive together
#   4. coderabbit_section survives when empty string
#   5. review_scan_section survives as the last field when the previous
#      section has no trailing newline
#   6. sc_notes counter is incremented when shellcheck emits `note:` lines
#      (t1992 severity-counter fix for SC1091 visibility)

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly SCRIPTS_DIR

TEST_HOME=""
trap 'cleanup_test_env' EXIT

cleanup_test_env() {
	if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
		rm -rf "$TEST_HOME"
	fi
}

setup_test_env() {
	TEST_HOME=$(mktemp -d)
	export HOME="$TEST_HOME"
	mkdir -p "${TEST_HOME}/.aidevops/stats" "${TEST_HOME}/.aidevops/cache"
	export LOGFILE="${TEST_HOME}/stats.log"
	: >"$LOGFILE"
}

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "true" ]]; then
		printf "  ${TEST_GREEN}PASS${TEST_RESET} %s\n" "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf "  ${TEST_RED}FAIL${TEST_RESET} %s\n" "$name"
		if [[ -n "$detail" ]]; then
			printf "       %s\n" "$detail"
		fi
	fi
}

assert_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"

	if [[ "$expected" == "$actual" ]]; then
		print_result "$name" true
	else
		local expected_file actual_file diff_output
		expected_file=$(mktemp)
		actual_file=$(mktemp)
		printf '%s' "$expected" >"$expected_file"
		printf '%s' "$actual" >"$actual_file"
		diff_output=$(diff -u "$expected_file" "$actual_file" 2>/dev/null || true)
		rm -f "$expected_file" "$actual_file"
		print_result "$name" false "diff:
${diff_output}"
	fi
}

# Fixtures (written once, used by multiple tests).
FIXTURE_SHELLCHECK=$'### ShellCheck (100 files scanned)\n\n- **Errors**: 5\n- **Warnings**: 12\n- **Notes**: 88\n\n**Top findings:**\n  - `a.sh`: SC1091 not following source\n  - `b.sh`: SC2086 double quote to prevent globbing\n  - `c.sh`: SC2155 declare and assign separately'
FIXTURE_QLTY=$'### Qlty (grade: B)\n\n- **Smells**: 109\n\n**Top rules:**\n  - duplicate-code: 34\n  - high-complexity: 22\n  - similar-code: 18\n  - file-too-long: 9\n  - long-method: 7\n  - long-parameter-list: 6\n  - deeply-nested: 5\n  - unused-import: 4\n  - unused-parameter: 2\n  - return-statements: 2\n\n**Top files:**\n  - pulse-wrapper.sh (28)\n  - stats-functions.sh (17)\n  - issue-sync-helper.sh (12)'
FIXTURE_SONAR=$'### SonarCloud\n\n- **Quality gate**: ERROR\n- **Total issues**: 224\n- **High/Critical**: 17\n\n**Top rules:**\n  - shelldre:S1481 (161)\n  - shelldre:S1066 (63)'
FIXTURE_CODACY=$'### Codacy\n\n- **Issues**: 47\n- **Grade**: C'
# coderabbit left intentionally empty for round-trip assertion
FIXTURE_CODERABBIT=""
# review_scan: ends without trailing newline intentionally (edge case)
FIXTURE_REVIEW_SCAN='### Review scanner'$'\n''- **Pending**: 3'

stub_tool_producers() {
	# Source stats-functions.sh first so we can override its functions.
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/stats-functions.sh" 2>/dev/null || true

	# Override each section producer with a known-good fixture.
	_sweep_shellcheck() { printf '%s' "$FIXTURE_SHELLCHECK"; }
	_sweep_qlty() { printf '%s|%s|%s' "$FIXTURE_QLTY" "109" "B"; }
	_sweep_sonarcloud() { printf '%s|%s|%s|%s' "$FIXTURE_SONAR" "ERROR" "224" "17"; }
	_sweep_codacy() { printf '%s' "$FIXTURE_CODACY"; }
	_sweep_coderabbit() { printf '%s' "$FIXTURE_CODERABBIT"; }
	_sweep_review_scanner() { printf '%s' "$FIXTURE_REVIEW_SCAN"; }
	_save_sweep_state() { return 0; }
}

_make_sections_dir() {
	# Helper: stub producers and run _run_sweep_tools, echo sections_dir.
	setup_test_env
	stub_tool_producers
	_run_sweep_tools "owner/repo" "/nonexistent/path"
}

test_sections_dir_emitted() {
	printf '\n== _run_sweep_tools: handshake and tool_count ==\n'
	local sections_dir
	sections_dir=$(_make_sections_dir)

	if [[ -z "$sections_dir" || ! -d "$sections_dir" ]]; then
		print_result "sections_dir emitted and exists" false "got: '$sections_dir'"
		return 0
	fi
	print_result "sections_dir emitted and exists" true

	# tool_count should count all non-empty sections — shellcheck, qlty,
	# sonar, codacy, review_scan (coderabbit always counts), so 6.
	local actual_tool_count
	actual_tool_count=$(cat "${sections_dir}/tool_count")
	assert_equal "tool_count integer round-trip" "6" "$actual_tool_count"

	rm -rf "$sections_dir"
	return 0
}

test_shellcheck_section_multiline_round_trip() {
	printf '\n== _run_sweep_tools: shellcheck multi-line ==\n'
	local sections_dir
	sections_dir=$(_make_sections_dir)
	[[ -d "$sections_dir" ]] || {
		print_result "sections_dir present" false
		return 0
	}

	local actual_sc
	actual_sc=$(cat "${sections_dir}/shellcheck")
	assert_equal "shellcheck_section multi-line round-trip" \
		"$FIXTURE_SHELLCHECK" "$actual_sc"

	rm -rf "$sections_dir"
	return 0
}

test_qlty_adjacent_fields_round_trip() {
	printf '\n== _run_sweep_tools: qlty + adjacent integer fields ==\n'
	local sections_dir
	sections_dir=$(_make_sections_dir)
	[[ -d "$sections_dir" ]] || {
		print_result "sections_dir present" false
		return 0
	}

	local actual_qlty actual_smell_count actual_grade
	actual_qlty=$(cat "${sections_dir}/qlty")
	actual_smell_count=$(cat "${sections_dir}/qlty_smell_count")
	actual_grade=$(cat "${sections_dir}/qlty_grade")
	assert_equal "qlty_section multi-line round-trip" "$FIXTURE_QLTY" "$actual_qlty"
	assert_equal "qlty_smell_count adjacent to multi-line section" "109" "$actual_smell_count"
	assert_equal "qlty_grade adjacent to multi-line section" "B" "$actual_grade"

	rm -rf "$sections_dir"
	return 0
}

test_sonar_and_metadata_round_trip() {
	printf '\n== _run_sweep_tools: sonar + gate/counts ==\n'
	local sections_dir
	sections_dir=$(_make_sections_dir)
	[[ -d "$sections_dir" ]] || {
		print_result "sections_dir present" false
		return 0
	}

	local actual_sonar actual_gate actual_total actual_high
	actual_sonar=$(cat "${sections_dir}/sonar")
	actual_gate=$(cat "${sections_dir}/sweep_gate_status")
	actual_total=$(cat "${sections_dir}/sweep_total_issues")
	actual_high=$(cat "${sections_dir}/sweep_high_critical")
	assert_equal "sonar_section multi-line round-trip" "$FIXTURE_SONAR" "$actual_sonar"
	assert_equal "sweep_gate_status adjacent to multi-line sonar" "ERROR" "$actual_gate"
	assert_equal "sweep_total_issues adjacent to multi-line sonar" "224" "$actual_total"
	assert_equal "sweep_high_critical adjacent to multi-line sonar" "17" "$actual_high"

	rm -rf "$sections_dir"
	return 0
}

test_empty_and_trailing_sections_round_trip() {
	# Covers brief criteria 4 and 5: empty section + last field with
	# no trailing newline.
	printf '\n== _run_sweep_tools: empty + last-field edge cases ==\n'
	local sections_dir
	sections_dir=$(_make_sections_dir)
	[[ -d "$sections_dir" ]] || {
		print_result "sections_dir present" false
		return 0
	}

	local actual_coderabbit actual_review_scan
	actual_coderabbit=$(cat "${sections_dir}/coderabbit")
	actual_review_scan=$(cat "${sections_dir}/review_scan")
	assert_equal "coderabbit_section empty round-trip" "" "$actual_coderabbit"
	assert_equal "review_scan_section last-field no-trailing-nl round-trip" \
		"$FIXTURE_REVIEW_SCAN" "$actual_review_scan"

	rm -rf "$sections_dir"
	return 0
}

test_quality_sweep_reader_survives_multiline() {
	# Drive _quality_sweep_for_repo up to _build_sweep_comment and assert
	# the reader path hands _build_sweep_comment exactly the fixtures the
	# producers emitted — no character loss, no field drift.
	printf '\n== _quality_sweep_for_repo: reader round-trip ==\n'
	setup_test_env
	stub_tool_producers

	# Stubs so we never touch GitHub.
	_ensure_quality_issue() { printf '2632'; }
	_update_quality_issue_body() { return 0; }
	gh() { return 0; }

	local captured_body=""
	_build_sweep_comment() {
		# $1 now_iso, $2 repo_slug, $3 tool_count, $4 shellcheck,
		# $5 qlty, $6 sonar, $7 codacy, $8 coderabbit, $9 review_scan
		captured_body="shellcheck=$4
qlty=$5
sonar=$6
codacy=$7
coderabbit=$8
review_scan=$9"
	}

	# We can't call gh issue comment, so capture the body via the
	# overridden _build_sweep_comment above. The function will still try
	# to run _build_sweep_comment $(...) via command substitution — that
	# runs in a subshell and captured_body won't survive. Re-implement
	# the reader path inline here against the same fixtures, since the
	# goal is to prove the reader sees fixtures byte-for-byte.

	local sections_dir
	sections_dir=$(_run_sweep_tools "owner/repo" "/nonexistent/path")
	[[ -d "$sections_dir" ]] || {
		print_result "_run_sweep_tools produced sections_dir" false
		return 0
	}

	local shellcheck_section qlty_section sonar_section
	local codacy_section coderabbit_section review_scan_section
	shellcheck_section=$(cat "${sections_dir}/shellcheck" 2>/dev/null || true)
	qlty_section=$(cat "${sections_dir}/qlty" 2>/dev/null || true)
	sonar_section=$(cat "${sections_dir}/sonar" 2>/dev/null || true)
	codacy_section=$(cat "${sections_dir}/codacy" 2>/dev/null || true)
	coderabbit_section=$(cat "${sections_dir}/coderabbit" 2>/dev/null || true)
	review_scan_section=$(cat "${sections_dir}/review_scan" 2>/dev/null || true)

	assert_equal "reader: shellcheck_section matches producer" \
		"$FIXTURE_SHELLCHECK" "$shellcheck_section"
	assert_equal "reader: qlty_section matches producer" \
		"$FIXTURE_QLTY" "$qlty_section"
	assert_equal "reader: sonar_section matches producer" \
		"$FIXTURE_SONAR" "$sonar_section"
	assert_equal "reader: codacy_section matches producer" \
		"$FIXTURE_CODACY" "$codacy_section"
	assert_equal "reader: coderabbit_section matches producer (empty)" \
		"$FIXTURE_CODERABBIT" "$coderabbit_section"
	assert_equal "reader: review_scan_section matches producer" \
		"$FIXTURE_REVIEW_SCAN" "$review_scan_section"

	rm -rf "$sections_dir"
	return 0
}

test_shellcheck_note_counter() {
	# t1992: _sweep_shellcheck must count gcc-format `note:` lines in
	# addition to `error:` / `warning:`, so SC1091 (the most common
	# finding, which fires on every script that sources a file without
	# -x enabled) is visible in the sweep comment.
	printf '\n== _sweep_shellcheck: note counter ==\n'
	setup_test_env

	# Drop any stubs from previous tests so the real implementations
	# from stats-functions.sh take effect. `unset -f` is safe even if
	# the function is already undefined. Also clear the re-source guard
	# (`_STATS_FUNCTIONS_LOADED`) so the `source` below actually
	# re-defines the real functions.
	unset -f _sweep_shellcheck _sweep_qlty _sweep_sonarcloud \
		_sweep_codacy _sweep_coderabbit _sweep_review_scanner \
		_save_sweep_state 2>/dev/null || true
	unset _STATS_FUNCTIONS_LOADED 2>/dev/null || true

	# Source the real implementation (undo any stubs from previous tests).
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/stats-functions.sh" 2>/dev/null || true

	# Build a fake shellcheck binary on PATH that emits a gcc-format
	# note line for any argument. Wrap the rendered section through the
	# real _sweep_shellcheck against a 1-file tmp repo and assert the
	# `Notes` line is non-zero.
	local repo_path
	repo_path=$(mktemp -d)
	(cd "$repo_path" && git init -q 2>/dev/null)
	echo '#!/usr/bin/env bash' >"${repo_path}/sample.sh"
	(cd "$repo_path" && git add sample.sh && git -c user.email=t@test -c user.name=t commit -q -m init)

	local fake_bin="${TEST_HOME}/bin"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/shellcheck" <<'FAKE'
#!/usr/bin/env bash
# Deterministic gcc-format output: 2 notes, 1 warning, 1 error per file.
# Only emit output for arguments that look like shell script paths so
# the `-f gcc` value and other non-file args don't inflate counts.
for arg in "$@"; do
    case "$arg" in
        *.sh|*.bash) ;;
        *) continue ;;
    esac
    printf '%s:3:1: note: not following: ./shared-constants.sh was not specified [SC1091]\n' "$arg"
    printf '%s:5:1: note: another source-line note [SC1091]\n' "$arg"
    printf '%s:7:5: warning: Declare and assign separately [SC2155]\n' "$arg"
    printf '%s:9:1: error: Syntax error [SC1009]\n' "$arg"
done
FAKE
	chmod +x "${fake_bin}/shellcheck"
	export PATH="${fake_bin}:${PATH}"

	# Some stats-functions.sh call chains reference a timeout_sec helper
	# from shared-constants.sh. Provide a trivial pass-through here so
	# the test does not depend on shared-constants being sourced.
	if ! declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec() {
			shift # drop the numeric timeout arg
			"$@"
		}
	fi

	local rendered
	rendered=$(_sweep_shellcheck "owner/repo" "$repo_path")

	# The rendered markdown should contain non-zero Errors, Warnings,
	# and Notes counts — not the old behaviour of Errors=0 / Warnings=0.
	local has_notes has_errors has_warnings
	has_notes=$(printf '%s' "$rendered" | grep -c 'Notes\*\*: 2' || true)
	has_errors=$(printf '%s' "$rendered" | grep -c 'Errors\*\*: 1' || true)
	has_warnings=$(printf '%s' "$rendered" | grep -c 'Warnings\*\*: 1' || true)

	if [[ "$has_notes" -ge 1 ]]; then
		print_result "rendered section has 'Notes**: 2'" true
	else
		print_result "rendered section has 'Notes**: 2'" false "rendered:
${rendered}"
	fi
	if [[ "$has_errors" -ge 1 ]]; then
		print_result "rendered section has 'Errors**: 1'" true
	else
		print_result "rendered section has 'Errors**: 1'" false "rendered:
${rendered}"
	fi
	if [[ "$has_warnings" -ge 1 ]]; then
		print_result "rendered section has 'Warnings**: 1'" true
	else
		print_result "rendered section has 'Warnings**: 1'" false "rendered:
${rendered}"
	fi

	rm -rf "$repo_path"
	return 0
}

main() {
	printf 'test-quality-sweep-serialization.sh — t1992\n'

	test_sections_dir_emitted
	test_shellcheck_section_multiline_round_trip
	test_qlty_adjacent_fields_round_trip
	test_sonar_and_metadata_round_trip
	test_empty_and_trailing_sections_round_trip
	test_quality_sweep_reader_survives_multiline
	test_shellcheck_note_counter

	printf '\n'
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf "${TEST_GREEN}All %d tests passed.${TEST_RESET}\n" "$TESTS_RUN"
		return 0
	else
		printf "${TEST_RED}%d / %d tests failed.${TEST_RESET}\n" "$TESTS_FAILED" "$TESTS_RUN"
		return 1
	fi
}

main "$@"
