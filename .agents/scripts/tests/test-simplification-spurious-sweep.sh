#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-simplification-spurious-sweep.sh — Tests for the defensive auto-close
# sweep that closes spurious "0 smells remaining" re-queue issues (GH#18795).
#
# The sweep is a self-healing safety net for the pre-PR-#18848 grep-c bug in
# _simplification_backfill_verify_remaining_smells. It runs each pulse cycle
# during _complexity_scan_state_refresh and closes any open re-queue issue
# whose title contains "0 smells remaining" AND whose target file currently
# has zero Qlty smells per a fresh probe. Both conditions are required so a
# legitimate finding with a coincidentally matching title is never closed.
#
# Tests:
#   - Pattern matcher accepts the clean form "(pass 1, 0 smells remaining)"
#   - Pattern matcher accepts the bug-corrupted form "(pass 1, 0\n0 smells remaining)"
#   - Pattern matcher rejects legitimate non-zero counts
#   - Pattern matcher rejects unrelated re-queue titles
#   - Function is a no-op when qlty CLI is unavailable
#   - Function is a no-op when no matching issues are returned
#   - Function bails when gh fails (no error cascade)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
ORIGINAL_PATH="${PATH}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export LOGFILE
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	export PATH="$ORIGINAL_PATH"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Make a minimal git repo with one clean shell file and one nominally-smelly
# file (the "smelly" file has a long function so qlty stub returns smells).
# The qlty stub is keyed off the path, so any string the test uses works.
make_test_repo() {
	local repo_path="$1"
	mkdir -p "${repo_path}/.agents/scripts"
	mkdir -p "${repo_path}/.agents/services"
	git -C "$repo_path" init -q 2>/dev/null
	git -C "$repo_path" config user.email "test@test.com" 2>/dev/null
	git -C "$repo_path" config user.name "Test" 2>/dev/null
	printf '#!/usr/bin/env bash\necho clean\n' >"${repo_path}/.agents/scripts/clean.sh"
	printf '#!/usr/bin/env bash\necho smelly\n' >"${repo_path}/.agents/scripts/smelly.sh"
	git -C "$repo_path" add . 2>/dev/null
	git -C "$repo_path" commit -q -m "init" 2>/dev/null
	return 0
}

# Install a fake qlty CLI on PATH whose smell count is keyed off the path
# in $1. clean.sh → empty output (0 smells). smelly.sh → 3 smell lines.
install_fake_qlty() {
	local stub_dir="${TEST_ROOT}/stub-bin"
	mkdir -p "$stub_dir"
	cat >"${stub_dir}/qlty" <<'EOF'
#!/usr/bin/env bash
# Fake qlty for spurious-sweep tests.
# Args: smells <path>
target="${2:-}"
case "$target" in
	*clean.sh|*ubicloud.md|*pulse-dispatch-engine.sh)
		# Empty output = 0 smells
		exit 0
		;;
	*smelly.sh)
		printf 'finding 1\nfinding 2\nfinding 3\n'
		exit 0
		;;
esac
exit 0
EOF
	chmod +x "${stub_dir}/qlty"
	export PATH="${stub_dir}:${PATH}"
	return 0
}

# Install a fake gh CLI that returns canned issue lists for `gh issue list`
# and records every `gh issue close` invocation to $TEST_ROOT/gh-closes.log.
install_fake_gh() {
	local issues_json="$1"
	local stub_dir="${TEST_ROOT}/stub-bin"
	mkdir -p "$stub_dir"
	printf '%s' "$issues_json" >"${TEST_ROOT}/gh-issues.json"
	: >"${TEST_ROOT}/gh-closes.log"
	cat >"${stub_dir}/gh" <<EOF
#!/usr/bin/env bash
# Fake gh for spurious-sweep tests.
case "\$1" in
	issue)
		case "\$2" in
			list)
				cat "${TEST_ROOT}/gh-issues.json"
				exit 0
				;;
			close)
				printf '%s\n' "\$@" >>"${TEST_ROOT}/gh-closes.log"
				exit 0
				;;
		esac
		;;
esac
exit 0
EOF
	chmod +x "${stub_dir}/gh"
	export PATH="${stub_dir}:${PATH}"
	return 0
}

# =============================================================================
# Pattern-matcher tests — exercise the title regex used by the sweep.
# =============================================================================

# Replicate the title-match logic from _simplification_close_spurious_requeue_issues
# in isolation so we can test the regex independently of the gh/qlty wrappers.
match_spurious_title() {
	local title="$1"
	local stripped
	stripped=$(printf '%s' "$title" | tr -d '[:space:]')
	[[ "$stripped" =~ \(pass[0-9]+,0+smellsremaining\) ]]
}

test_pattern_matches_clean_zero_form() {
	local title="simplification: re-queue .agents/scripts/foo.sh (pass 1, 0 smells remaining)"
	if match_spurious_title "$title"; then
		print_result "pattern: matches clean form '(pass 1, 0 smells remaining)'" 0
	else
		print_result "pattern: matches clean form '(pass 1, 0 smells remaining)'" 1 "regex failed on '$title'"
	fi
	return 0
}

test_pattern_matches_corrupted_newline_form() {
	# This is the literal form produced by the pre-PR-#18848 bug:
	# the count captured a literal "0\n0" because grep -c on zero
	# matches exits non-zero and `|| echo 0` appended a second 0.
	local title="simplification: re-queue .agents/services/hosting/ubicloud.md (pass 2, 0
0 smells remaining)"
	if match_spurious_title "$title"; then
		print_result "pattern: matches bug-corrupted form '(pass 2, 0\\n0 smells remaining)'" 0
	else
		print_result "pattern: matches bug-corrupted form '(pass 2, 0\\n0 smells remaining)'" 1 "regex failed on corrupted form"
	fi
	return 0
}

test_pattern_rejects_legitimate_nonzero_count() {
	local title="simplification: re-queue .agents/scripts/foo.sh (pass 1, 17 smells remaining)"
	if ! match_spurious_title "$title"; then
		print_result "pattern: rejects legitimate nonzero count '(pass 1, 17 ...)'" 0
	else
		print_result "pattern: rejects legitimate nonzero count '(pass 1, 17 ...)'" 1 "regex falsely matched 17"
	fi
	return 0
}

test_pattern_rejects_unrelated_title() {
	local title="simplification-debt: .agents/scripts/shared-constants.sh exceeds 2000 lines"
	if ! match_spurious_title "$title"; then
		print_result "pattern: rejects unrelated 'exceeds 2000 lines' title" 0
	else
		print_result "pattern: rejects unrelated 'exceeds 2000 lines' title" 1 "regex falsely matched"
	fi
	return 0
}

test_pattern_rejects_complexity_title() {
	local title="simplification: reduce function complexity in .agents/scripts/foo.sh (2 functions >100 lines)"
	if ! match_spurious_title "$title"; then
		print_result "pattern: rejects 'reduce function complexity' title" 0
	else
		print_result "pattern: rejects 'reduce function complexity' title" 1 "regex falsely matched"
	fi
	return 0
}

# =============================================================================
# Function-level tests — exercise the full _simplification_close_spurious_requeue_issues
# entry point with stubbed qlty + gh.
# =============================================================================

test_noop_when_qlty_unavailable() {
	local repo_path="${TEST_ROOT}/repo-no-qlty"
	make_test_repo "$repo_path"
	# Restore PATH to a minimum that excludes any qlty
	local saved="$PATH"
	export PATH="/usr/bin:/bin"
	# Also ensure $HOME/.qlty/bin/qlty does not exist
	if [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
		# We are in a sandboxed HOME; this should never trigger
		rm -f "${HOME}/.qlty/bin/qlty"
	fi
	local out
	out=$(_simplification_close_spurious_requeue_issues "$repo_path" "test/repo" 2>/dev/null) || out=""
	export PATH="$saved"
	if [[ "$out" == "0" ]]; then
		print_result "function: noop when qlty unavailable" 0
	else
		print_result "function: noop when qlty unavailable" 1 "expected '0', got '$out'"
	fi
	return 0
}

test_noop_when_no_open_issues() {
	local repo_path="${TEST_ROOT}/repo-no-issues"
	make_test_repo "$repo_path"
	install_fake_qlty
	install_fake_gh "[]"
	local out
	out=$(_simplification_close_spurious_requeue_issues "$repo_path" "test/repo")
	if [[ "$out" == "0" ]]; then
		print_result "function: noop when gh returns empty list" 0
	else
		print_result "function: noop when gh returns empty list" 1 "expected '0', got '$out'"
	fi
	return 0
}

test_closes_spurious_clean_issue() {
	local repo_path="${TEST_ROOT}/repo-spurious"
	make_test_repo "$repo_path"
	install_fake_qlty
	# Issue title points at clean.sh which the fake qlty reports as 0 smells
	local issues='[{"number":99001,"title":"simplification: re-queue .agents/scripts/clean.sh (pass 1, 0 smells remaining)"}]'
	install_fake_gh "$issues"
	local out
	out=$(_simplification_close_spurious_requeue_issues "$repo_path" "test/repo")
	if [[ "$out" == "1" ]] && grep -q "close" "${TEST_ROOT}/gh-closes.log" 2>/dev/null; then
		print_result "function: closes spurious clean issue" 0
	else
		local closes
		closes=$(cat "${TEST_ROOT}/gh-closes.log" 2>/dev/null || echo "<none>")
		print_result "function: closes spurious clean issue" 1 "out='$out' closes='$closes'"
	fi
	return 0
}

test_leaves_legitimate_smelly_issue_open() {
	local repo_path="${TEST_ROOT}/repo-legit"
	make_test_repo "$repo_path"
	install_fake_qlty
	# Title coincidentally matches the spurious pattern, BUT the file genuinely
	# has smells per the qlty stub. Function must NOT close it.
	local issues='[{"number":99002,"title":"simplification: re-queue .agents/scripts/smelly.sh (pass 1, 0 smells remaining)"}]'
	install_fake_gh "$issues"
	local out
	out=$(_simplification_close_spurious_requeue_issues "$repo_path" "test/repo")
	if [[ "$out" == "0" ]] && ! grep -q "close" "${TEST_ROOT}/gh-closes.log" 2>/dev/null; then
		print_result "function: leaves legitimate smelly issue open" 0
	else
		local closes
		closes=$(cat "${TEST_ROOT}/gh-closes.log" 2>/dev/null || echo "<none>")
		print_result "function: leaves legitimate smelly issue open" 1 "out='$out' closes='$closes'"
	fi
	return 0
}

test_skips_unrelated_titles() {
	local repo_path="${TEST_ROOT}/repo-unrelated"
	make_test_repo "$repo_path"
	install_fake_qlty
	# Mix of unrelated titles — none should be closed.
	local issues='[
		{"number":99003,"title":"simplification-debt: .agents/scripts/clean.sh exceeds 2000 lines"},
		{"number":99004,"title":"simplification: reduce function complexity in .agents/scripts/clean.sh (2 functions >100 lines)"}
	]'
	install_fake_gh "$issues"
	local out
	out=$(_simplification_close_spurious_requeue_issues "$repo_path" "test/repo")
	if [[ "$out" == "0" ]] && ! grep -q "close" "${TEST_ROOT}/gh-closes.log" 2>/dev/null; then
		print_result "function: skips unrelated re-queue titles" 0
	else
		local closes
		closes=$(cat "${TEST_ROOT}/gh-closes.log" 2>/dev/null || echo "<none>")
		print_result "function: skips unrelated re-queue titles" 1 "out='$out' closes='$closes'"
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	setup_test_env

	echo "=== Spurious zero-smell sweep tests (GH#18795) ==="
	echo ""

	test_pattern_matches_clean_zero_form
	test_pattern_matches_corrupted_newline_form
	test_pattern_rejects_legitimate_nonzero_count
	test_pattern_rejects_unrelated_title
	test_pattern_rejects_complexity_title
	test_noop_when_qlty_unavailable
	test_noop_when_no_open_issues
	test_closes_spurious_clean_issue
	test_leaves_legitimate_smelly_issue_open
	test_skips_unrelated_titles

	echo ""
	echo "Results: ${TESTS_RUN} run, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"

	teardown_test_env

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
