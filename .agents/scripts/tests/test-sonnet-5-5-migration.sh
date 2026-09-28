#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#32848: one-time move of user Sonnet pins to anthropic/claude-sonnet-5-5.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../setup/modules/migration-sonnet-5-5.sh"
SETUP_SCRIPT="${SCRIPT_DIR}/../../../setup.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOG="$TEST_ROOT/messages.log"

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"$LOG"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"$LOG"
	return 0
}

# shellcheck source=/dev/null
source "$MODULE"

failures=0

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'PASS: %s\n' "$message"
	return 0
}

marker_exists() {
	local home="$1"
	if [[ -f "$home/.aidevops/cache/migrations/gh32848-sonnet-5-5-settings" ]]; then
		printf 'yes'
	else
		printf 'no'
	fi
	return 0
}

file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path"
	return 0
}

assert_eq "2" "$(grep -c 'migrate_sonnet_5_5_settings' "$SETUP_SCRIPT")" "setup runs the migration in interactive and non-interactive paths"

# --- Old pins across every owned file are moved; everything else is kept ---
HOME="$TEST_ROOT/pinned"
cfg="$HOME/.config/aidevops"
mkdir -p "$cfg/tenants/default" "$HOME/.aidevops/agents/custom/configs" "$HOME/.config/opencode"
cat >"$cfg/config.jsonc" <<'EOF'
{
  // pulse pin
  "orchestration": {
    "pulse_model": "anthropic/claude-sonnet-4-6",
    "headless_models": "anthropic/claude-sonnet-4-6,openai/gpt-5.3-codex"
  },
  "other": "anthropic/claude-sonnet-5-1"
}
EOF
chmod 640 "$cfg/config.jsonc"
cat >"$HOME/.aidevops/agents/custom/configs/model-routing-table.json" <<'EOF'
{"tiers":{"standard":{"models":["anthropic/claude-sonnet-5","openai/gpt-5.6-terra"],"reasoning":{"anthropic/claude-sonnet-5":"medium"}},"thinking":{"models":["anthropic/claude-opus-5-5"]}}}
EOF
cat >"$HOME/.config/opencode/opencode.json" <<'EOF'
{"model":"anthropic/claude-sonnet-4-5-20250929","provider":{"claudecli":{"models":{"claude-sonnet-4-6":{"name":"Claude Sonnet 4.6 (via CLI)"}}}},"agent":{"x":{"model":"openrouter/anthropic/claude-sonnet-4"}}}
EOF
cat >"$cfg/tenants/default/credentials.sh" <<'EOF'
export SOME_API_KEY="secret-value-anthropic/claude-sonnet-4-6"
export PULSE_MODEL="anthropic/claude-sonnet-4-6"
export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-4-6,openai/gpt-6-sol"
export CLAUDE_MODEL="claude-sonnet-4-6"
EOF
chmod 600 "$cfg/tenants/default/credentials.sh"

migrate_sonnet_5_5_settings

assert_eq '    "pulse_model": "anthropic/claude-sonnet-5-5",' "$(grep pulse_model "$cfg/config.jsonc")" "config.jsonc pulse pin moves"
assert_eq '    "headless_models": "anthropic/claude-sonnet-5-5,openai/gpt-5.3-codex"' "$(grep headless_models "$cfg/config.jsonc")" "headless model list keeps other entries"
assert_eq '  "other": "anthropic/claude-sonnet-5-1"' "$(grep '"other"' "$cfg/config.jsonc")" "newer Sonnet IDs are untouched"
assert_eq "  // pulse pin" "$(grep '//' "$cfg/config.jsonc")" "JSONC comments are preserved"
assert_eq "640" "$(file_mode "$cfg/config.jsonc")" "config permissions are preserved"

table="$HOME/.aidevops/agents/custom/configs/model-routing-table.json"
assert_eq "anthropic/claude-sonnet-5-5" "$(jq -r '.tiers.standard.models[0]' "$table")" "custom routing model moves"
assert_eq "medium" "$(jq -r '.tiers.standard.reasoning["anthropic/claude-sonnet-5-5"]' "$table")" "custom routing reasoning key moves"
assert_eq "anthropic/claude-opus-5-5" "$(jq -r '.tiers.thinking.models[0]' "$table")" "other tiers are untouched"

oc="$HOME/.config/opencode/opencode.json"
assert_eq "anthropic/claude-sonnet-5-5" "$(jq -r '.model' "$oc")" "dated OpenCode model pin moves"
assert_eq "openrouter/anthropic/claude-sonnet-5-5" "$(jq -r '.agent.x.model' "$oc")" "OpenRouter Anthropic pin moves"
assert_eq "true" "$(jq -r '.provider.claudecli.models | has("claude-sonnet-4-6")' "$oc")" "bare provider model keys are untouched"

creds="$cfg/tenants/default/credentials.sh"
assert_eq 'export PULSE_MODEL="anthropic/claude-sonnet-5-5"' "$(grep PULSE_MODEL "$creds")" "credentials pulse pin moves"
assert_eq 'export AIDEVOPS_HEADLESS_MODELS="anthropic/claude-sonnet-5-5,openai/gpt-6-sol"' "$(grep HEADLESS "$creds")" "credentials headless list moves"
assert_eq 'export SOME_API_KEY="secret-value-anthropic/claude-sonnet-4-6"' "$(grep SOME_API_KEY "$creds")" "non-model credential lines are untouched"
assert_eq 'export CLAUDE_MODEL="claude-sonnet-4-6"' "$(grep CLAUDE_MODEL "$creds")" "bare Claude CLI model names are untouched"
assert_eq "600" "$(file_mode "$creds")" "credentials permissions are preserved"

backups="$HOME/.aidevops/config-backups/migrations"
assert_eq "yes" "$([[ -f "$backups/gh32848-.config_aidevops_config.jsonc" ]] && printf yes || printf no)" "config backup exists"
assert_eq "600" "$(file_mode "$backups/gh32848-.config_aidevops_tenants_default_credentials.sh")" "credentials backup is private"
assert_eq "yes" "$(marker_exists "$HOME")" "migration records its marker"

# A later explicit pin survives because the migration runs once.
printf '%s\n' '{"orchestration":{"pulse_model":"anthropic/claude-sonnet-4-6"}}' >"$cfg/config.jsonc"
migrate_sonnet_5_5_settings
assert_eq "anthropic/claude-sonnet-4-6" "$(jq -r '.orchestration.pulse_model' "$cfg/config.jsonc")" "later explicit pin is honoured"

# --- Nothing to change: byte-identical, no backup, still marked ---
HOME="$TEST_ROOT/current"
mkdir -p "$HOME/.config/aidevops"
printf '%s\n' '{"orchestration":{"pulse_model":"anthropic/claude-sonnet-5-5"}}' >"$HOME/.config/aidevops/config.jsonc"
cp "$HOME/.config/aidevops/config.jsonc" "$TEST_ROOT/current.before"
migrate_sonnet_5_5_settings
assert_eq "same" "$(cmp -s "$TEST_ROOT/current.before" "$HOME/.config/aidevops/config.jsonc" && printf same || printf changed)" "current settings are unchanged"
assert_eq "no" "$([[ -d "$HOME/.aidevops/config-backups/migrations" ]] && [[ -n "$(ls -A "$HOME/.aidevops/config-backups/migrations")" ]] && printf yes || printf no)" "no backup when nothing changes"
assert_eq "yes" "$(marker_exists "$HOME")" "no-op run is marked complete"

# --- Symlinked configs are left to their owner and do not block the marker ---
HOME="$TEST_ROOT/symlink"
mkdir -p "$HOME/.config/opencode"
printf '%s\n' '{"model":"anthropic/claude-sonnet-4-6"}' >"$TEST_ROOT/dotfiles-opencode.json"
ln -s "$TEST_ROOT/dotfiles-opencode.json" "$HOME/.config/opencode/opencode.json"
migrate_sonnet_5_5_settings
assert_eq "anthropic/claude-sonnet-4-6" "$(jq -r '.model' "$TEST_ROOT/dotfiles-opencode.json")" "symlink target is untouched"
assert_eq "1" "$(grep -c 'Skipped symlinked' "$LOG")" "symlinked pin is reported once"
assert_eq "yes" "$(marker_exists "$HOME")" "symlinks do not block completion"

unset HOME
migrate_sonnet_5_5_settings
assert_eq "1" "$(grep -c 'HOME unavailable; GH#32848' "$LOG")" "unset HOME defers the migration"

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d Sonnet 5.5 migration test(s) failed\n' "$failures" >&2
	exit 1
fi
printf '\nAll Sonnet 5.5 migration tests passed\n'
exit 0
