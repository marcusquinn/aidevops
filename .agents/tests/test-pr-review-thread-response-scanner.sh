#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCANNER="${SCRIPT_DIR}/../scripts/pr-review-thread-response-scanner.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_write_fake_gh() {
	local fake_bin="$1"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	printf '123\tReview thread fixture\tfalse\t\tfixture-branch\tcollaborator\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	printf '%s\n' "$*" >>"${FAKE_GH_CAPTURE:?}"
	printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"script.sh","line":12,"url":"","body":"fixture","diffHunk":"@@","updatedAt":"2026-06-01T00:00:00Z"}]}}]}}}}}'
	exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
FAKE_GH
	chmod +x "${fake_bin}/gh"
	return 0
}

test_scan_passes_nonempty_owner_and_name_to_graphql() {
	printf '==> scan passes parsed repo owner/name to GraphQL\n'
	_setup
	local fake_bin="${TEST_TMPDIR}/bin"
	local capture="${TEST_TMPDIR}/gh-args.log"
	local output=""
	_write_fake_gh "$fake_bin"

	output="$(FAKE_GH_CAPTURE="$capture" PATH="${fake_bin}:$PATH" "$SCANNER" scan "marcusquinn/aidevops")"
	if [[ "$output" == 123$'\t'* ]]; then
		_pass "scan emits unresolved review-thread candidate"
	else
		_fail "scan emits unresolved review-thread candidate" "output: ${output}"
	fi

	if grep -q -- '-F owner=marcusquinn' "$capture" && grep -q -- '-F name=aidevops' "$capture"; then
		_pass "GraphQL owner/name flags are non-empty"
	else
		_fail "GraphQL owner/name flags are non-empty" "captured: $(tr '\n' ';' <"$capture")"
	fi

	_teardown
	return 0
}

main() {
	test_scan_passes_nonempty_owner_and_name_to_graphql
	printf 'Results: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
