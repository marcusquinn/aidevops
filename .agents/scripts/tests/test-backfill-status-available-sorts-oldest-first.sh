#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: the bounded backfill query must request oldest-first results.

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
	export GH_ARGS_FILE="${TEST_ROOT}/gh-args"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '%s\n' "$@" >"$GH_ARGS_FILE"
	printf '[]\n'
	exit 0
fi

exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

capture_search_query() {
	local line=""
	local expect_value=0
	local search_query=""
	local search_arg_count=0

	while IFS= read -r line; do
		if [[ "$expect_value" -eq 1 ]]; then
			search_query="$line"
			expect_value=0
			continue
		fi
		if [[ "$line" == "--search" ]]; then
			search_arg_count=$((search_arg_count + 1))
			expect_value=1
		fi
	done <"$GH_ARGS_FILE"

	if [[ "$search_arg_count" -ne 1 || -z "$search_query" ]]; then
		fail "expected exactly one populated --search argument"
	fi
	printf '%s' "$search_query"
	return 0
}

count_sort_qualifiers() {
	local search_query="$1"
	local remainder="$search_query"
	local count=0

	while [[ "$remainder" == *"sort:created-asc"* ]]; do
		count=$((count + 1))
		remainder="${remainder#*sort:created-asc}"
	done

	printf '%d' "$count"
	return 0
}

main() {
	trap cleanup EXIT
	setup_test_env

	"$BACKFILL_SCRIPT" --dry-run --repo owner/repo >/dev/null

	local search_query
	search_query=$(capture_search_query)
	local qualifier_count
	qualifier_count=$(count_sort_qualifiers "$search_query")

	if [[ "$qualifier_count" -ne 1 ]]; then
		fail "expected exactly one sort:created-asc qualifier, got ${qualifier_count}"
	fi
	if [[ "$search_query" != *" sort:created-asc" ]]; then
		fail "expected sort:created-asc at the end of the search query"
	fi
	if grep -Fxq -- '--sort' "$GH_ARGS_FILE" || grep -Fxq -- '--direction' "$GH_ARGS_FILE"; then
		fail "unsupported gh issue list sorting flags were passed"
	fi

	printf 'PASS backfill-status-available sorts oldest first\n'
	return 0
}

main "$@"
