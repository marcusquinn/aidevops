#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_MODULE="${SCRIPT_DIR}/../setup/modules/migrations.sh"
SETUP_SCRIPT="${SCRIPT_DIR}/../../../setup.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
WARNING_LOG="$TEST_ROOT/warnings.log"

print_info() {
	return 0
}

print_warning() {
	local message="$1"
	printf '%s\n' "$message" >>"$WARNING_LOG"
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

assert_file_contains() {
	local expected="$1"
	local file="$2"
	local message="$3"
	if ! grep -Fq "$expected" "$file"; then
		printf 'FAIL: %s (missing=%s)\n' "$message" "$expected" >&2
		failures=$((failures + 1))
		return 1
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null
}

assert_eq "2" "$(grep -c 'migrate_custom_model_routing_reasoning_defaults' "$SETUP_SCRIPT")" "setup runs the migration in interactive and non-interactive paths" || true
assert_eq "2" "$(grep -c 'migrate_obsolete_settings_model_routing' "$SETUP_SCRIPT")" "setup removes obsolete settings routing in interactive and non-interactive paths" || true

unset HOME
migrate_custom_model_routing_reasoning_defaults
assert_file_contains "HOME unavailable; t18137 custom model routing migration will retry" "$WARNING_LOG" "unset HOME defers migration without an unbound-variable failure" || true
HOME=""
migrate_custom_model_routing_reasoning_defaults
assert_eq "2" "$(grep -c 'HOME unavailable; t18137 custom model routing migration will retry' "$WARNING_LOG")" "empty HOME also defers migration without resolving a root-level path" || true
unset HOME
migrate_obsolete_settings_model_routing
assert_file_contains "HOME unavailable; obsolete model routing settings migration will retry" "$WARNING_LOG" "unset HOME defers obsolete settings migration safely" || true

assert_file_contains "Failed to create backup of custom model routing table at \$backup_file" "$MIGRATIONS_MODULE" "backup failure reports its destination path" || true
assert_file_contains "Failed to create temporary file for migration of \$custom_table" "$MIGRATIONS_MODULE" "temporary-file failure reports the custom table path" || true
assert_file_contains "Failed to update custom model routing table structure in \$custom_table" "$MIGRATIONS_MODULE" "jq update failure reports the custom table path" || true
assert_file_contains "Failed to replace custom model routing table at \$custom_table" "$MIGRATIONS_MODULE" "replacement failure reports the custom table path" || true

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
assert_eq "high" "$(jq -r '.tiers.thinking.reasoning.openai' "$custom_table")" "thinking custom reasoning migrates to high" || true
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

HOME="$TEST_ROOT/settings-valid"
export HOME
settings_file="$HOME/.config/aidevops/settings.json"
bash "$SCRIPT_DIR/../settings-helper.sh" init >/dev/null
assert_eq "false" "$(jq -r 'has("model_routing")' "$settings_file")" "new settings omit obsolete model routing section" || true
if bash "$SCRIPT_DIR/../settings-helper.sh" validate >/dev/null 2>&1; then
	printf 'PASS: settings without obsolete model routing validate\n'
else
	printf 'FAIL: settings without obsolete model routing should validate\n' >&2
	failures=$((failures + 1))
fi
cp "$settings_file" "${settings_file}.before-migration"
migrate_obsolete_settings_model_routing
if cmp -s "${settings_file}.before-migration" "$settings_file" && [[ ! -e "$HOME/.aidevops/config-backups/migrations/t31849-settings.json" ]]; then
	printf 'PASS: settings without obsolete model routing remain unchanged\n'
else
	printf 'FAIL: migration changed settings without obsolete model routing\n' >&2
	failures=$((failures + 1))
fi

HOME="$TEST_ROOT/settings-legacy"
export HOME
settings_file="$HOME/.config/aidevops/settings.json"
bash "$SCRIPT_DIR/../settings-helper.sh" init >/dev/null
jq '.model_routing.default_tier = "sonnet" | .preserve = true' "$settings_file" >"${settings_file}.tmp"
mv "${settings_file}.tmp" "$settings_file"
chmod 640 "$settings_file"
if validation_output=$(bash "$SCRIPT_DIR/../settings-helper.sh" validate 2>&1); then
	printf 'FAIL: stale model routing section should fail validation\n' >&2
	failures=$((failures + 1))
else
	if [[ "$validation_output" == *"model_routing is obsolete"* && "$validation_output" == *"aidevops update"* ]]; then
		printf 'PASS: stale model routing validation is actionable\n'
	else
		printf 'FAIL: stale model routing validation lacks actionable guidance\n' >&2
		failures=$((failures + 1))
	fi
fi
migrate_obsolete_settings_model_routing
assert_eq "false" "$(jq -r 'has("model_routing")' "$settings_file")" "pre-canonical sonnet fixture loses obsolete routing section" || true
assert_eq "true" "$(jq -r '.preserve' "$settings_file")" "settings migration preserves unrelated values" || true
assert_eq "sonnet" "$(jq -r '.model_routing.default_tier' "$HOME/.aidevops/config-backups/migrations/t31849-settings.json")" "settings migration preserves a pre-migration backup" || true
assert_eq "640" "$(file_mode "$settings_file")" "settings migration preserves file permissions" || true
cp "$settings_file" "${settings_file}.before-second-migration"
migrate_obsolete_settings_model_routing
if cmp -s "${settings_file}.before-second-migration" "$settings_file"; then
	printf 'PASS: obsolete model routing migration is idempotent\n'
else
	printf 'FAIL: obsolete model routing migration changed an already migrated file\n' >&2
	failures=$((failures + 1))
fi
if bash "$SCRIPT_DIR/../settings-helper.sh" validate >/dev/null 2>&1; then
	printf 'PASS: migrated settings validate\n'
else
	printf 'FAIL: migrated settings should validate\n' >&2
	failures=$((failures + 1))
fi

HOME="$TEST_ROOT/settings-canonical"
export HOME
settings_file="$HOME/.config/aidevops/settings.json"
bash "$SCRIPT_DIR/../settings-helper.sh" init >/dev/null
jq '.model_routing = {"default_tier":"standard","budget_tracking_enabled":true,"prefer_subscription":true}' "$settings_file" >"${settings_file}.tmp"
mv "${settings_file}.tmp" "$settings_file"
migrate_obsolete_settings_model_routing
assert_eq "false" "$(jq -r 'has("model_routing")' "$settings_file")" "canonical-but-unused routing section is removed" || true
assert_eq "standard" "$(jq -r '.model_routing.default_tier' "$HOME/.aidevops/config-backups/migrations/t31849-settings.json")" "canonical routing backup preserves the original value" || true

HOME="$TEST_ROOT/settings-malformed"
export HOME
settings_file="$HOME/.config/aidevops/settings.json"
bash "$SCRIPT_DIR/../settings-helper.sh" init >/dev/null
jq '.model_routing = "malformed"' "$settings_file" >"${settings_file}.tmp"
mv "${settings_file}.tmp" "$settings_file"
migrate_obsolete_settings_model_routing
assert_eq "false" "$(jq -r 'has("model_routing")' "$settings_file")" "malformed obsolete routing value is removed" || true

HOME="$TEST_ROOT/settings-symlink"
export HOME
mkdir -p "$HOME/.config/aidevops"
settings_file="$HOME/.config/aidevops/settings.json"
symlink_target="$TEST_ROOT/settings-symlink-target.json"
cp "$TEST_ROOT/settings-canonical/.aidevops/config-backups/migrations/t31849-settings.json" "$symlink_target"
ln -s "$symlink_target" "$settings_file"
migrate_obsolete_settings_model_routing
assert_eq "true" "$(jq -r 'has("model_routing")' "$symlink_target")" "symlinked settings are left untouched" || true
assert_file_contains "Skipping unsafe or unreadable settings file; obsolete model routing settings migration will retry" "$WARNING_LOG" "symlink safety refusal is actionable" || true

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d model routing migration test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll model routing reasoning migration tests passed\n'
exit 0
