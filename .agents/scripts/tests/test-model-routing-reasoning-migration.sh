#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_MODULE="${SCRIPT_DIR}/../setup/modules/migrations.sh"
SETUP_SCRIPT="${SCRIPT_DIR}/../../../setup.sh"
TEST_ROOT=$(mktemp -d)
trap '[[ -z "${TEST_ROOT:-}" ]] || rm -rf "$TEST_ROOT"' EXIT

print_info() {
	return 0
}

print_warning() {
	return 0
}

# shellcheck source=/dev/null
source "$MIGRATIONS_MODULE"

failures=0

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
		failures=$((failures + 1))
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_eq "2" "$(grep -c 'migrate_custom_model_routing_reasoning_defaults' "$SETUP_SCRIPT")" "setup runs the migration in interactive and non-interactive paths" || true

HOME="$TEST_ROOT/no-custom"
mkdir -p "$HOME"
migrate_custom_model_routing_reasoning_defaults
assert_eq "yes" "$([[ -f "$HOME/.aidevops/cache/migrations/t18137-model-routing-reasoning-defaults" ]] && printf yes || printf no)" "install without custom table is marked complete" || true
assert_eq "no" "$([[ -e "$HOME/.aidevops/agents/custom/configs/model-routing-table.json" ]] && printf yes || printf no)" "migration does not create a custom routing table" || true

HOME="$TEST_ROOT/custom"
custom_table="$HOME/.aidevops/agents/custom/configs/model-routing-table.json"
mkdir -p "${custom_table%/*}"
cat >"$custom_table" <<'JSON'
{
  "tiers": {
    "simple": {"models": ["custom/simple"], "reasoning": {"openai": "low", "other": "keep"}},
    "thinking": {"models": ["custom/thinking"], "reasoning": {"openai": "xhigh"}}
  },
  "user_setting": "preserve"
}
JSON
migrate_custom_model_routing_reasoning_defaults
assert_eq "medium" "$(jq -r '.tiers.simple.reasoning.openai' "$custom_table")" "simple custom reasoning migrates to medium" || true
assert_eq "max" "$(jq -r '.tiers.thinking.reasoning.openai' "$custom_table")" "thinking custom reasoning migrates to max" || true
assert_eq "custom/simple" "$(jq -r '.tiers.simple.models[0]' "$custom_table")" "custom model order is preserved" || true
assert_eq "keep" "$(jq -r '.tiers.simple.reasoning.other' "$custom_table")" "unrelated reasoning settings are preserved" || true
assert_eq "preserve" "$(jq -r '.user_setting' "$custom_table")" "unrelated custom configuration is preserved" || true
assert_eq "low" "$(jq -r '.tiers.simple.reasoning.openai' "$HOME/.aidevops/config-backups/migrations/t18137-model-routing-table.json")" "pre-migration backup is retained" || true

jq '.tiers.simple.reasoning.openai = "high"' "$custom_table" >"${custom_table}.tmp"
mv "${custom_table}.tmp" "$custom_table"
migrate_custom_model_routing_reasoning_defaults
assert_eq "high" "$(jq -r '.tiers.simple.reasoning.openai' "$custom_table")" "marker prevents later user changes from being overwritten" || true

HOME="$TEST_ROOT/invalid"
custom_table="$HOME/.aidevops/agents/custom/configs/model-routing-table.json"
mkdir -p "${custom_table%/*}"
printf '{invalid\n' >"$custom_table"
migrate_custom_model_routing_reasoning_defaults
assert_eq "{invalid" "$(tr -d '\n' <"$custom_table")" "invalid custom table remains untouched" || true
assert_eq "no" "$([[ -f "$HOME/.aidevops/cache/migrations/t18137-model-routing-reasoning-defaults" ]] && printf yes || printf no)" "invalid custom table remains eligible for retry" || true

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d model routing migration test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll model routing reasoning migration tests passed\n'
exit 0
