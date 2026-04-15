#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-dispatch-validator.sh — Test harness for pre-dispatch-validator-helper.sh (GH#19118)
#
# Tests:
#   test_ratchet_down_falsified     — validator returns exit 10 when scan reports no proposals
#   test_ratchet_down_legitimate    — validator returns exit 0 when scan reports proposals
#   test_unregistered_generator     — issue without marker returns exit 0
#   test_validator_error            — scan fails unexpectedly → exit 20
#   test_bypass_env_var             — AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 → exit 0

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

# Create a `gh` stub that returns a specific issue body.
create_gh_stub_with_body() {
	local issue_body_file="$1"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

# gh api repos/<slug>/issues/<num> --jq '.body // ""'
if [[ "${1:-}" == "api" ]] && printf '%s' "${2:-}" | grep -qE '/issues/[0-9]+$'; then
	# Output a JSON object with the body from the file
	body_file="BODY_FILE_PLACEHOLDER"
	body=$(cat "$body_file" 2>/dev/null || echo "")
	printf '{"body": "%s"}\n' "$(printf '%s' "$body" | sed 's/"/\\"/g; s/\n/\\n/g')"
	exit 0
fi

# gh issue comment / gh issue close — succeed silently
if [[ "${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "$*" >&2
exit 1
GHEOF

	# Replace the placeholder with the actual path
	sed -i "s|BODY_FILE_PLACEHOLDER|${issue_body_file}|g" "${TEST_ROOT}/bin/gh"
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Create a `gh` stub that returns a body with a ratchet-down generator marker.
# Uses a Python-based stub for reliable JSON escaping.
create_gh_stub_ratchet_body() {
	local marker_present="${1:-true}"

	local body_file="${TEST_ROOT}/issue_body.txt"
	if [[ "$marker_present" == "true" ]]; then
		printf '<!-- aidevops:generator=ratchet-down -->\n## Automated ratchet-down (t1913)\n' >"$body_file"
	else
		printf '## Some issue without a generator marker\n' >"$body_file"
	fi

	# Create a gh stub that uses python3 to safely JSON-encode the body
	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

# gh api repos/<slug>/issues/<num> with --jq '.body // ""'
if [[ "\${1:-}" == "api" ]] && printf '%s' "\${2:-}" | grep -qE '/issues/[0-9]+\$'; then
	# Use --jq style: the helper calls gh api ... --jq '.body // ""'
	# so our stub must handle both "output the raw json" and "output the jq result"
	# We output the body directly as a JSON-encoded string
	body_file="${body_file}"
	python3 -c "
import json, sys
body = open('${body_file}').read()
# When --jq is used, gh outputs the jq result directly (unquoted string)
# Simulate that by printing the raw body
sys.stdout.write(body)
" 2>/dev/null
	exit 0
fi

# gh issue comment / gh issue close — succeed silently
if [[ "\${1:-}" == "issue" ]]; then
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Create a `complexity-scan-helper.sh` stub with configurable ratchet-check output.
create_scan_stub() {
	local mode="$1" # "no-proposals", "proposals", "error"

	cat >"${TEST_ROOT}/bin/complexity-scan-helper.sh" <<SCANEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "ratchet-check" ]]; then
	case "${mode}" in
		no-proposals)
			printf 'No ratchet-down available: all thresholds within gap of 5\n'
			exit 1
			;;
		proposals)
			printf 'FUNCTION_COMPLEXITY_THRESHOLD 120 → 110\n'
			exit 0
			;;
		error)
			printf '' >&2
			exit 2
			;;
	esac
fi

printf 'unsupported subcommand: %s\n' "\$*" >&2
exit 1
SCANEOF
	chmod +x "${TEST_ROOT}/bin/complexity-scan-helper.sh"
	return 0
}

# Create a `git` stub that simulates a successful shallow clone.
create_git_stub() {
	local mode="${1:-success}"

	cat >"${TEST_ROOT}/bin/git" <<GITEOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "clone" ]]; then
	# Find the target directory (last non-flag argument)
	_target=""
	for _arg in "\$@"; do
		[[ "\$_arg" == --* ]] && continue
		_target="\$_arg"
	done
	if [[ "${mode}" == "success" ]]; then
		mkdir -p "\$_target"
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

# Create a stub complexity-scan-helper.sh and export COMPLEXITY_SCAN_HELPER
# so the validator function uses it (via the env-override path).
setup_scan_stub_at_helper_path() {
	local mode="$1"
	create_scan_stub "$mode"
	export COMPLEXITY_SCAN_HELPER="${TEST_ROOT}/bin/complexity-scan-helper.sh"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# test_ratchet_down_falsified — stub scan returns "No ratchet-down available"
# Expected: validator exits 10
test_ratchet_down_falsified() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "no-proposals"

	local rc=0
	"$HELPER_SCRIPT" validate "42" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 10 ]]; then
		print_result "ratchet_down_falsified exits 10" 0
	else
		print_result "ratchet_down_falsified exits 10" 1 "Expected exit 10, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_ratchet_down_legitimate — stub scan returns real proposals
# Expected: validator exits 0
test_ratchet_down_legitimate() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "proposals"

	local rc=0
	"$HELPER_SCRIPT" validate "43" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "ratchet_down_legitimate exits 0" 0
	else
		print_result "ratchet_down_legitimate exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_unregistered_generator — issue body without any generator marker
# Expected: validator exits 0 (unregistered generator fallback)
test_unregistered_generator() {
	setup_test_env
	create_gh_stub_ratchet_body "false"

	local rc=0
	"$HELPER_SCRIPT" validate "44" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "unregistered_generator exits 0" 0
	else
		print_result "unregistered_generator exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_validator_error — stub scan fails with non-zero and empty output
# Expected: validator exits 20
test_validator_error() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "error"

	local rc=0
	"$HELPER_SCRIPT" validate "45" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 20 ]]; then
		print_result "validator_error exits 20" 0
	else
		print_result "validator_error exits 20" 1 "Expected exit 20, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# test_bypass_env_var — AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1
# Expected: exits 0 regardless of issue content
test_bypass_env_var() {
	setup_test_env
	create_gh_stub_ratchet_body "true"
	create_git_stub "success"
	setup_scan_stub_at_helper_path "no-proposals"

	local rc=0
	AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 "$HELPER_SCRIPT" validate "46" "marcusquinn/aidevops" >/dev/null 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "bypass_env_var exits 0" 0
	else
		print_result "bypass_env_var exits 0" 1 "Expected exit 0, got ${rc}"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf 'Running pre-dispatch-validator tests (GH#19118)...\n\n'

	if [[ ! -x "$HELPER_SCRIPT" ]]; then
		printf '%bERROR%b: Helper script not found or not executable: %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER_SCRIPT" >&2
		exit 1
	fi

	test_ratchet_down_falsified
	test_ratchet_down_legitimate
	test_unregistered_generator
	test_validator_error
	test_bypass_env_var

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
