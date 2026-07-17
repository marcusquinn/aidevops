#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../.agents/scripts/setup/_services.sh
source "${REPO_ROOT}/.agents/scripts/setup/_services.sh"

assert_ephemeral() {
	local path="$1"

	if ! _setup_opencode_binary_is_ephemeral "$path"; then
		printf 'FAIL: expected ephemeral path: %s\n' "$path" >&2
		return 1
	fi

	return 0
}

assert_durable() {
	local path="$1"

	if _setup_opencode_binary_is_ephemeral "$path"; then
		printf 'FAIL: expected durable path: %s\n' "$path" >&2
		return 1
	fi

	return 0
}

TMPDIR="${TEST_DIR}/runtime-temp"
export TMPDIR

assert_ephemeral "${TMPDIR}/nvm/bin/opencode"
assert_ephemeral "/tmp/nvm/bin/opencode"
assert_ephemeral "/private/tmp/nvm/bin/opencode"
assert_ephemeral "/var/folders/aa/bb/T/tmp.example/.nvm/bin/opencode"
assert_ephemeral "/private/var/folders/aa/bb/T/tmp.example/.nvm/bin/opencode"
assert_durable "/opt/homebrew/bin/opencode"
assert_durable "${HOME}/.nvm/versions/node/v24/bin/opencode"

mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/home"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TEST_DIR}/bin/opencode"
chmod +x "${TEST_DIR}/bin/opencode"
PATH="${TEST_DIR}/bin:/usr/bin:/bin"
HOME="${TEST_DIR}/home"
export PATH HOME

VALIDATION_LOG="${TEST_DIR}/validation.log"
_setup_validate_opencode_binary() {
	local bin="$1"

	printf '%s\n' "$bin" >>"$VALIDATION_LOG"
	[[ "$bin" == "/opt/homebrew/bin/opencode" ]] || return 1
	return 0
}

ephemeral_preferred="${TMPDIR}/tmp.install/.nvm/versions/node/v24/bin/opencode"
resolved=$(_setup_find_valid_opencode_binary "$ephemeral_preferred")
if [[ "$resolved" != "/opt/homebrew/bin/opencode" ]]; then
	printf 'FAIL: expected durable fallback, got: %s\n' "$resolved" >&2
	exit 1
fi
if grep -Fq "$ephemeral_preferred" "$VALIDATION_LOG"; then
	printf 'FAIL: ephemeral preferred binary reached validation\n' >&2
	exit 1
fi

_setup_validate_opencode_binary() {
	local bin="$1"

	[[ "$bin" == "${TEST_DIR}/bin/opencode" ]] || return 1
	return 0
}
if _setup_find_valid_opencode_binary "$ephemeral_preferred" >/dev/null; then
	printf 'FAIL: resolved an OpenCode binary from a temporary PATH entry\n' >&2
	exit 1
fi

printf 'PASS: OpenCode setup rejects temporary binary paths\n'
