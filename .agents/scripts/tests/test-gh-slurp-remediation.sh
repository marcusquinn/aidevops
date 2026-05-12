#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPDATE_CHECK_SCRIPT="${AGENTS_SCRIPTS}/aidevops-update-check.sh"
TOOL_INSTALL_SCRIPT="${AGENTS_SCRIPTS}/setup/modules/tool-install.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="$PATH"

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	PATH="$ORIGINAL_PATH"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	[[ -n "$detail" ]] && printf '  %s\n' "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

make_fake_gh() {
	local version_line="$1"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home"
	cat >"${TEST_ROOT}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${version_line}'
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	PATH="${TEST_ROOT}/bin:${ORIGINAL_PATH}"
	return 0
}

call_update_prereq_check() {
	HOME="${TEST_ROOT}/home" PATH="$PATH" bash -c "
		set +e
		source '${AGENTS_SCRIPTS}/shared-constants.sh'
		$(sed -n '/_check_gh_slurp_prerequisite()/,/^}/p' "$UPDATE_CHECK_SCRIPT")
		uname() { printf 'Linux\\n'; return 0; }
		_check_gh_slurp_prerequisite
	" 2>/dev/null
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "missing '${needle}' in '${haystack}'"
	fi
	return 0
}

make_fake_gh "gh version 2.50.0"
old_notice=$(call_update_prereq_check)
assert_contains "update-check emits warning for old gh" "$old_notice" "[WARN] GitHub CLI (gh) 2.50.0 is too old"
assert_contains "update-check points Linux users at setup" "$old_notice" "Run aidevops setup to upgrade gh"

make_fake_gh "gh version 2.51.0"
new_notice=$(call_update_prereq_check)
if [[ -z "$new_notice" ]]; then
	print_result "update-check silent when gh supports slurp" 0
else
	print_result "update-check silent when gh supports slurp" 1 "got '${new_notice}'"
fi

setup_offer_output=$(bash -c "
	set +e
	print_info() { local msg=\"\$*\"; printf 'INFO:%s\n' \"\$msg\"; return 0; }
	print_warning() { local msg=\"\$*\"; printf 'WARN:%s\n' \"\$msg\"; return 0; }
	print_success() { local msg=\"\$*\"; printf 'OK:%s\n' \"\$msg\"; return 0; }
	setup_prompt() { local var_name=\"\$1\" prompt_text=\"\$2\"; printf '%s' \"\$prompt_text\"; printf -v \"\$var_name\" '%s' 'N'; return 0; }
	install_packages() { printf 'INSTALL:%s\n' \"\$*\"; return 0; }
	uname() { printf 'Linux\n'; return 0; }
	aidevops_gh_slurp_supported() { return 1; }
	AIDEVOPS_GH_MIN_SLURP_VERSION=2.51.0
	source '$TOOL_INSTALL_SCRIPT'
	_offer_gh_slurp_upgrade apt
")
assert_contains "setup offers Linux gh upgrade" "$setup_offer_output" "Try to upgrade GitHub CLI (gh) using apt?"
assert_contains "setup skipped path prints manual guidance" "$setup_offer_output" "official GitHub CLI package source"

setup_yes_output=$(bash -c "
	set +e
	print_info() { local msg=\"\$*\"; printf 'INFO:%s\n' \"\$msg\"; return 0; }
	print_warning() { local msg=\"\$*\"; printf 'WARN:%s\n' \"\$msg\"; return 0; }
	print_success() { local msg=\"\$*\"; printf 'OK:%s\n' \"\$msg\"; return 0; }
	setup_prompt() { local var_name=\"\$1\" prompt_text=\"\$2\"; printf '%s' \"\$prompt_text\"; printf -v \"\$var_name\" '%s' 'Y'; return 0; }
	install_packages() { printf 'INSTALL:%s\n' \"\$*\"; return 0; }
	uname() { printf 'Linux\n'; return 0; }
	aidevops_gh_slurp_supported() { return 0; }
	AIDEVOPS_GH_MIN_SLURP_VERSION=2.51.0
	source '$TOOL_INSTALL_SCRIPT'
	_offer_gh_slurp_upgrade apt
")
assert_contains "setup accepted path invokes package upgrade" "$setup_yes_output" "INSTALL:apt"
assert_contains "setup accepted path rechecks prerequisite" "$setup_yes_output" "GitHub CLI now satisfies"

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
