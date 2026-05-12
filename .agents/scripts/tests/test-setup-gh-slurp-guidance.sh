#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="$PATH"
INSTALL_CALLED=0

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

print_info() { return 0; }
print_success() { return 0; }
print_warning() { printf 'WARN %s\n' "$1"; return 0; }
detect_package_manager() { printf 'apt\n'; return 0; }
install_packages() { INSTALL_CALLED=1; return 0; }
setup_prompt() {
	local var_name="$1"
	local prompt_text="$2"
	local default_value="${3:-}"
	printf -v "$var_name" '%s' "$default_value"
	printf '%s\n' "$prompt_text"
	return 0
}

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS}/shared-constants.sh"
# shellcheck source=../setup/modules/tool-install.sh
source "${AGENTS_SCRIPTS}/setup/modules/tool-install.sh"

setup_fake_old_gh() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)'
exit 0
EOF
	cat >"${TEST_ROOT}/bin/glab" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh" "${TEST_ROOT}/bin/glab"
	PATH="${TEST_ROOT}/bin:${ORIGINAL_PATH}"
	return 0
}

setup_fake_old_gh
output=$(setup_git_clis 2>&1)

if [[ "$output" == *"GitHub CLI upgrade guidance"* && "$output" == *"Ubuntu universe gh package"* ]]; then
	print_result "setup prints old-gh upgrade guidance" 0
else
	print_result "setup prints old-gh upgrade guidance" 1 "output='${output}'"
fi

if [[ "$INSTALL_CALLED" -eq 0 ]]; then
	print_result "setup does not auto-run package install for old gh" 0
else
	print_result "setup does not auto-run package install for old gh" 1
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
