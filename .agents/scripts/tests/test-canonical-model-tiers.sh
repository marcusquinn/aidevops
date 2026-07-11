#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Prevent provider/model-family names from returning as workload tiers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

failures=0

check_absent() {
	local description="$1"
	local pattern="$2"
	shift 2
	if rg -n "$pattern" "$@"; then
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

check_absent \
	"agent frontmatter uses only canonical workload tiers" \
	'^(model|model-tier): (haiku|sonnet|opus|flash|pro|composer2)$' \
	.agents --glob '*.md'

check_absent \
	"documentation does not describe provider families as tiers" \
	'\b(haiku|sonnet|opus|flash|pro|composer2)[ -]tier\b|\btier[ :_-]+(haiku|sonnet|opus|flash|pro|composer2)\b' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

check_absent \
	"framework configuration contains no legacy tier values" \
	'"(haiku|sonnet|opus|flash|pro|composer2)"' \
	.agents/configs .agents/bundles --glob '*.{json,jsonc}'

check_absent \
	"dispatch tracking labels use canonical tiers" \
	'(dispatched|implemented|retried|failed):(haiku|sonnet|opus|flash|pro|composer2)' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

legacy_pin_pattern='model:'"opus-4-7|AIDEVOPS_"'OPUS_ESCALATION_MODEL'
check_absent \
	"dispatch metadata does not pin a concrete model label" \
	"$legacy_pin_pattern" \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

check_absent \
	"legacy tier-specific reasoning environment variables are absent" \
	'AIDEVOPS_HEADLESS_VARIANT_(HAIKU|SONNET|OPUS|FLASH|PRO)' \
	.agents --glob '*.{md,sh,py,mjs,json,jsonc,toon}'

actual_tiers=$(jq -r '.tiers | keys | sort | join(",")' .agents/configs/model-routing-table.json)
if [[ "$actual_tiers" == "simple,standard,thinking" ]]; then
	printf 'PASS: routing table exposes exactly three workload tiers\n'
else
	printf 'FAIL: routing table tiers are %s\n' "$actual_tiers" >&2
	failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d canonical tier check(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll canonical workload tier checks passed\n'
