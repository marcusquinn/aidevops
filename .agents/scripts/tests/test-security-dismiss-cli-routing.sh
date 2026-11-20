#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-security-dismiss-cli-routing.sh — GH#39350/GH#39365 regression guard.
#
# Asserts that `aidevops security dismiss <id>` records the exact requested
# advisory ID (including supply-chain IDs such as TanStack and keyv) in
# dismissed.txt, never a hardcoded ID-to-helper mapping.
# Exercises aidevops.sh and secret-hygiene-helper.sh (named here so
# affected-tests-helper.sh selects this suite when either changes).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
CLI="${REPO_ROOT}/aidevops.sh"

if [[ ! -f "$CLI" ]]; then
	printf 'CLI not found: %s\n' "$CLI" >&2
	exit 1
fi

TMP_HOME="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT

IDS=("tanstack-minishaihulud-2026-05" "keyv-2026-05")
FAILURES=0

for id in "${IDS[@]}"; do
	if ! HOME="$TMP_HOME" bash "$CLI" security dismiss "$id" >/dev/null 2>&1; then
		printf 'FAIL: dismiss %s exited non-zero\n' "$id" >&2
		FAILURES=$((FAILURES + 1))
	fi
done

DISMISSED="$TMP_HOME/.aidevops/advisories/dismissed.txt"
for id in "${IDS[@]}"; do
	if [[ -f "$DISMISSED" ]] && grep -qxF -- "$id" "$DISMISSED"; then
		printf 'PASS: %s recorded\n' "$id"
	else
		printf 'FAIL: %s missing from dismissed.txt\n' "$id" >&2
		FAILURES=$((FAILURES + 1))
	fi
done

if [[ -f "$DISMISSED" ]]; then
	line_count="$(wc -l <"$DISMISSED" | tr -d ' ')"
	if [[ "$line_count" != "${#IDS[@]}" ]]; then
		printf 'FAIL: expected %s entries, found %s\n' "${#IDS[@]}" "$line_count" >&2
		FAILURES=$((FAILURES + 1))
	fi
fi

if [[ "$FAILURES" -ne 0 ]]; then
	exit 1
fi
printf 'All security dismiss routing checks passed\n'
exit 0
