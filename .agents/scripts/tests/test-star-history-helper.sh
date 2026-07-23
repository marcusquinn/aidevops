#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for deterministic static star-history generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$REPO_ROOT/.agents/scripts/star-history-helper.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/update-star-history.yml"
REUSABLE_WORKFLOW="$REPO_ROOT/.github/workflows/star-history-reusable.yml"
CALLER_TEMPLATE="$REPO_ROOT/.agents/templates/workflows/star-history-caller.yml"
DOCS_WORKFLOW="$REPO_ROOT/.github/workflows/update-website-docs.yml"
TESTS_RUN=0
TESTS_FAILED=0
TEMP_DIR=""

cleanup() {
	if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
		rm -rf "$TEMP_DIR"
	fi
	return 0
}

trap cleanup EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n     %s\n' "$name" "$detail"
	return 0
}

assert_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if grep -Fq -- "$pattern" "$file"; then
		pass "$name"
		return 0
	fi
	fail "$name" "missing pattern: $pattern"
	return 0
}

test_deterministic_chart() {
	local temp_dir="$1"
	local fixture="$temp_dir/history.json"
	local first="$temp_dir/first.svg"
	local second="$temp_dir/second.svg"
	cat >"$fixture" <<'JSON'
["2025-11-10T06:57:07Z", "2025-11-10T13:06:08Z", "2026-01-15T09:30:00Z", "2026-07-23T12:00:00Z"]
JSON
	bash "$HELPER" render --repo marcusquinn/aidevops --input "$fixture" --output "$first"
	bash "$HELPER" render --repo marcusquinn/aidevops --input "$fixture" --output "$second"
	if cmp -s "$first" "$second"; then
		pass "identical input produces deterministic SVG"
	else
		fail "identical input produces deterministic SVG" "rendered files differ"
	fi
	assert_contains "chart includes cumulative total" "$first" "4 stars"
	assert_contains "chart supports dark mode" "$first" "prefers-color-scheme: dark"
	assert_contains "chart has accessible description" "$first" 'aria-labelledby="title desc"'
	return 0
}

test_empty_and_single_point() {
	local temp_dir="$1"
	local empty="$temp_dir/empty.json"
	local single="$temp_dir/single.json"
	local empty_svg="$temp_dir/empty.svg"
	local single_svg="$temp_dir/single.svg"
	printf '[]\n' >"$empty"
	printf '["2026-07-23T12:00:00Z"]\n' >"$single"
	bash "$HELPER" render --repo marcusquinn/aidevops --input "$empty" --output "$empty_svg"
	bash "$HELPER" render --repo marcusquinn/aidevops --input "$single" --output "$single_svg"
	assert_contains "empty input renders a stable placeholder" "$empty_svg" "No star history available"
	assert_contains "single point renders without division errors" "$single_svg" "1 star"
	local seeded_svg="$temp_dir/seeded.svg"
	bash "$HELPER" seed --repo exampleorg/example --output "$seeded_svg"
	assert_contains "seed command creates an immediate placeholder" "$seeded_svg" "No star history available"
	return 0
}

test_safe_input_handling() {
	local temp_dir="$1"
	local fixture="$temp_dir/safe.json"
	local output="$temp_dir/safe.svg"
	printf '["2026-07-23T12:00:00Z"]\n' >"$fixture"
	if bash "$HELPER" render --repo 'owner/<script>' --input "$fixture" --output "$output" >/dev/null 2>&1; then
		fail "invalid repository labels are rejected" "unsafe slug was accepted"
	else
		pass "invalid repository labels are rejected"
	fi
	return 0
}

test_workflow_contract() {
	# shellcheck disable=SC2016 # GitHub expression is an intentional literal contract.
	local token_contract='GH_TOKEN: ${{ secrets.SYNC_PAT }}'
	# shellcheck disable=SC2016 # GitHub expression is an intentional literal contract.
	local caller_token_contract='SYNC_PAT: ${{ secrets.SYNC_PAT }}'
	assert_contains "workflow has a weekly schedule" "$WORKFLOW" "cron: '17 3 * * 0'"
	assert_contains "workflow requires owner-authorised token" "$WORKFLOW" "$token_contract"
	assert_contains "workflow generates only the static asset" "$WORKFLOW" "docs/assets/star-history.svg"
	assert_contains "reusable workflow uses caller repository identity" "$REUSABLE_WORKFLOW" 'GITHUB_REPOSITORY'
	assert_contains "reusable workflow requires SYNC_PAT" "$REUSABLE_WORKFLOW" 'required: true'
	assert_contains "caller schedules weekly refresh" "$CALLER_TEMPLATE" "cron: '17 3 * * 0'"
	assert_contains "caller maps owner-authorised token" "$CALLER_TEMPLATE" "$caller_token_contract"
	assert_contains "docs sync watches chart updates" "$DOCS_WORKFLOW" "'docs/assets/star-history.svg'"
	assert_contains "docs conversion uses the published website asset" "$DOCS_WORKFLOW" "'](/star-history.svg)'"
	assert_contains "docs sync publishes chart asset" "$DOCS_WORKFLOW" "cp docs/assets/star-history.svg website/star-history.svg"
	return 0
}

main() {
	TEMP_DIR=$(mktemp -d)
	test_deterministic_chart "$TEMP_DIR"
	test_empty_and_single_point "$TEMP_DIR"
	test_safe_input_handling "$TEMP_DIR"
	test_workflow_contract
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
