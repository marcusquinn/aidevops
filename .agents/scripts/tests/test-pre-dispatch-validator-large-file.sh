#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-dispatch-validator-large-file.sh — Test harness for large-file and
# function-complexity pre-dispatch validators (t2367, GH#19823)
#
# Tests:
#   test_large_file_premise_falsified       — file under threshold → exit 10
#   test_large_file_premise_holds           — file over threshold → exit 0
#   test_large_file_deleted                 — file no longer exists → exit 10
#   test_function_complexity_falsified      — no violations remain → exit 10
#   test_function_complexity_holds          — violations still present → exit 0
#   test_missing_attributes                 — marker without attributes → exit 20

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../pre-dispatch-validator-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------
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
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Stub factories
# ---------------------------------------------------------------------------

# Create a `gh` stub that returns a body from a file (supports --jq).
create_gh_stub_with_body_file() {
	local body_file="$1"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

# gh api repos/<slug>/issues/<num> with --jq '.body // ""'
if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	body_file="${body_file}"
	python3 -c "
import sys
body = open('${body_file}').read()
sys.stdout.write(body)
" 2>/dev/null
	exit 0
fi

# gh issue comment / gh issue close / gh label create — succeed silently
if [[ "\${1:-}" == "issue" || "\${1:-}" == "label" ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Create a `git` stub that clones a fake repo with a specific file.
# Arguments:
#   $1 - mode: "success" or "fail"
#   $2 - optional file path to create in cloned dir
#   $3 - optional file content
create_git_stub_with_file() {
	local mode="${1:-success}"
	local file_path="${2:-}"
	local file_content="${3:-}"

	# Write file content to a temp file the stub can read
	local content_file="${TEST_ROOT}/stub_file_content.txt"
	printf '%s' "$file_content" >"$content_file"

	cat >"${TEST_ROOT}/bin/git" <<GITEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "clone" ]]; then
	_target=""
	for _arg in "\$@"; do
		[[ "\$_arg" == --* ]] && continue
		_target="\$_arg"
	done
	if [[ "${mode}" == "success" ]]; then
		mkdir -p "\$_target"
		_file_path="${file_path}"
		if [[ -n "\$_file_path" ]]; then
			mkdir -p "\$(dirname "\${_target}/\${_file_path}")"
			cat "${content_file}" > "\${_target}/\${_file_path}"
		fi
		exit 0
	else
		printf 'fatal: repository not found\n' >&2
		exit 128
	fi
fi

# Pass-through for other git commands
/usr/bin/git "\$@"
GITEOF
	chmod +x "${TEST_ROOT}/bin/git"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# test_large_file_premise_falsified — file is now UNDER threshold
# Expected: validator exits 10 (premise falsified)
test_large_file_premise_falsified() {
	setup_test_env

	# Issue body with marker: file threshold=100
	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=large-file-simplification-gate cited_file=.agents/scripts/big-file.sh threshold=100 -->\n## What\nSimplify big-file.sh\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	# Create git stub that produces a file with 50 lines (under threshold of 100)
	local file_content=""
	local i
	for i in $(seq 1 50); do
		file_content="${file_content}echo line${i}\n"
	done
	create_git_stub_with_file "success" ".agents/scripts/big-file.sh" "$(printf '%b' "$file_content")"

	local rc=0
	"$HELPER_SCRIPT" validate "100" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "large_file_premise_falsified exits 10" 0
	else
		print_result "large_file_premise_falsified exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_large_file_premise_holds — file is still OVER threshold
# Expected: validator exits 0 (dispatch proceeds)
test_large_file_premise_holds() {
	setup_test_env

	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=large-file-simplification-gate cited_file=.agents/scripts/big-file.sh threshold=100 -->\n## What\nSimplify big-file.sh\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	# Create git stub that produces a file with 150 lines (over threshold of 100)
	local file_content=""
	local i
	for i in $(seq 1 150); do
		file_content="${file_content}echo line${i}\n"
	done
	create_git_stub_with_file "success" ".agents/scripts/big-file.sh" "$(printf '%b' "$file_content")"

	local rc=0
	"$HELPER_SCRIPT" validate "101" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "large_file_premise_holds exits 0" 0
	else
		print_result "large_file_premise_holds exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_large_file_deleted — file no longer exists on HEAD
# Expected: validator exits 10 (premise falsified — file gone)
test_large_file_deleted() {
	setup_test_env

	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=large-file-simplification-gate cited_file=.agents/scripts/deleted-file.sh threshold=100 -->\n## What\nSimplify deleted-file.sh\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	# Git stub creates repo but without the cited file
	create_git_stub_with_file "success" "" ""

	local rc=0
	"$HELPER_SCRIPT" validate "102" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "large_file_deleted exits 10" 0
	else
		print_result "large_file_deleted exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_function_complexity_falsified — no functions exceed threshold
# Expected: validator exits 10 (premise falsified)
test_function_complexity_falsified() {
	setup_test_env

	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=function-complexity-gate cited_file=.agents/scripts/simple.sh threshold=50 -->\n## Complexity finding\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	# Create a file with only short functions (under 50 lines each)
	local file_content='#!/usr/bin/env bash
short_func() {
	echo "line1"
	echo "line2"
	echo "line3"
}

another_short() {
	echo "hello"
}
'
	create_git_stub_with_file "success" ".agents/scripts/simple.sh" "$file_content"

	local rc=0
	"$HELPER_SCRIPT" validate "103" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "function_complexity_falsified exits 10" 0
	else
		print_result "function_complexity_falsified exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_function_complexity_holds — functions still exceed threshold
# Expected: validator exits 0 (dispatch proceeds)
test_function_complexity_holds() {
	setup_test_env

	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=function-complexity-gate cited_file=.agents/scripts/complex.sh threshold=5 -->\n## Complexity finding\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	# Create a file with a function exceeding 5 lines
	local file_content='#!/usr/bin/env bash
big_func() {
	echo "line1"
	echo "line2"
	echo "line3"
	echo "line4"
	echo "line5"
	echo "line6"
	echo "line7"
}
'
	create_git_stub_with_file "success" ".agents/scripts/complex.sh" "$file_content"

	local rc=0
	"$HELPER_SCRIPT" validate "104" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "function_complexity_holds exits 0" 0
	else
		print_result "function_complexity_holds exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_missing_attributes — marker present but without cited_file/threshold
# Expected: validator exits 20 (validator error — missing attributes)
test_missing_attributes() {
	setup_test_env

	local body_file="${TEST_ROOT}/issue_body.txt"
	printf '<!-- aidevops:generator=large-file-simplification-gate -->\n## What\nSimplify something\n' >"$body_file"
	create_gh_stub_with_body_file "$body_file"

	local rc=0
	"$HELPER_SCRIPT" validate "105" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 20 ]]; then
		print_result "missing_attributes exits 20" 0
	else
		print_result "missing_attributes exits 20" 1 "Expected exit 20, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf 'Running pre-dispatch-validator large-file/complexity tests (t2367, GH#19823)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf '%bERROR%b: Helper script not found or not executable: %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT" >&2
		exit 1
	fi

	test_large_file_premise_falsified
	test_large_file_premise_holds
	test_large_file_deleted
	test_function_complexity_falsified
	test_function_complexity_holds
	test_missing_attributes

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
