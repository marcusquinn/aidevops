#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: backfill-status-available must collapse multiple JSON
# documents from gh issue list before using jq length in arithmetic [[ ]].

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
BACKFILL_SCRIPT="${SCRIPT_DIR}/../backfill-status-available.sh"

TEST_ROOT=""

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	return 1
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '[{"number":2,"title":"candidate","labels":[{"name":"auto-dispatch"}]}]\n[]\n'
	exit 0
fi

exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

main() {
	trap cleanup EXIT
	setup_test_env

	local output
	output=$("$BACKFILL_SCRIPT" --dry-run --repo owner/repo 2>&1)

	if [[ "$output" == *"syntax error in expression"* ]]; then
		fail "arithmetic syntax error leaked for multi-document gh output"
	fi
	if [[ "$output" != *"Dry-run summary: 1 candidate(s) found"* ]]; then
		printf '%s\n' "$output" >&2
		fail "expected one normalized candidate in dry-run summary"
	fi

	printf 'PASS backfill-status-available normalizes gh output\n'
	return 0
}

main "$@"
