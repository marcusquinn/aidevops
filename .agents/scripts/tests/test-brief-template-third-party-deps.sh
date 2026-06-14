#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-brief-template-third-party-deps.sh — regression coverage for GH#24812

set -u
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TEMPLATE_PATH="${SCRIPT_DIR}/../../templates/brief-template.md"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
	printf 'FAIL brief template missing at %s\n' "$TEMPLATE_PATH" >&2
	exit 1
fi

template_contents="$(<"$TEMPLATE_PATH")"
failures=0

if [[ "$template_contents" == *"THIRD-PARTY API/ERROR MAPPING COMPATIBILITY (GH#24812)"* ]]; then
	printf 'PASS third-party compatibility heading present\n'
else
	printf 'FAIL third-party compatibility heading missing\n' >&2
	failures=$((failures + 1))
fi

if [[ "$template_contents" == *"installed dependency version plus local"* ]]; then
	printf 'PASS installed dependency version evidence required\n'
else
	printf 'FAIL installed dependency version evidence not required\n' >&2
	failures=$((failures + 1))
fi

if [[ "$template_contents" == *"exported symbols/source"* ]]; then
	printf 'PASS local exported symbols evidence required\n'
else
	printf 'FAIL local exported symbols evidence not required\n' >&2
	failures=$((failures + 1))
fi

if [[ "$template_contents" == *"package manifest, lockfile, and installed package"* ]]; then
	printf 'PASS manifest lockfile installed package checklist present\n'
else
	printf 'FAIL manifest lockfile installed package checklist missing\n' >&2
	failures=$((failures + 1))
fi

if [[ $failures -eq 0 ]]; then
	exit 0
fi

exit 1
