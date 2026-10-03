#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#32807: one-time reset of raised OpenCode compaction targets to 240K.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../setup/modules/migration-compaction-target.sh"
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

settings_for() {
	local home="$1"
	printf '%s/.config/aidevops/settings.json' "$home"
	return 0
}

write_settings() {
	local home="$1"
	local json="$2"
	mkdir -p "$home/.config/aidevops"
	printf '%s\n' "$json" >"$(settings_for "$home")"
	chmod 640 "$(settings_for "$home")"
	return 0
}

marker_exists() {
	local home="$1"
	if [[ -f "$home/.aidevops/cache/migrations/gh32807-compaction-target-240k" ]]; then
		printf 'yes'
	else
		printf 'no'
	fi
	return 0
}

assert_eq "2" "$(grep -c 'migrate_compaction_target_240k' "$SETUP_SCRIPT")" "setup runs the migration in interactive and non-interactive paths"

# Raised opt-outs are reset once, unrelated settings and permissions preserved.
HOME="$TEST_ROOT/raised"
write_settings "$HOME" '{"keep":1,"runtime":{"opencode":{"astra_compaction_target":400000,"astra_context_cap":false,"gpt6_context_cap":false,"gpt56_context_cap":false,"v2_compaction_target":false,"gpt6_context_cap_other":true}}}'
migrate_compaction_target_240k
settings="$(settings_for "$HOME")"
assert_eq "240000" "$(jq -r '.runtime.opencode.astra_compaction_target' "$settings")" "Astra 400K target resets to 240K"
assert_eq "true" "$(jq -r '.runtime.opencode.astra_context_cap' "$settings")" "Astra cap opt-out is re-enabled"
assert_eq "false" "$(jq -r '.runtime.opencode | has("gpt6_context_cap")' "$settings")" "GPT-6 cap opt-out is removed"
assert_eq "false" "$(jq -r '.runtime.opencode | has("gpt56_context_cap")' "$settings")" "GPT-5.6 cap opt-out is removed"
assert_eq "240000" "$(jq -r '.runtime.opencode.v2_compaction_target' "$settings")" "OpenCode 2 opt-out resets to 240K"
assert_eq "1" "$(jq -r '.keep' "$settings")" "unrelated settings are preserved"
assert_eq "true" "$(jq -r '.runtime.opencode.gpt6_context_cap_other' "$settings")" "unrelated runtime keys are preserved"
assert_eq "400000" "$(jq -r '.runtime.opencode.astra_compaction_target' "$HOME/.aidevops/config-backups/migrations/gh32807-settings.json")" "backup keeps the original settings"
assert_eq "640" "$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings")" "settings permissions are preserved"
assert_eq "yes" "$(marker_exists "$HOME")" "migration records its marker"

# A later explicit opt-out survives because the migration runs once.
jq '.runtime.opencode.astra_compaction_target = 400000' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
migrate_compaction_target_240k
assert_eq "400000" "$(jq -r '.runtime.opencode.astra_compaction_target' "$settings")" "later explicit opt-out is honoured"

# Already-default settings are left byte-identical but still marked.
HOME="$TEST_ROOT/default"
write_settings "$HOME" '{"runtime":{"opencode":{"astra_compaction_target":240000,"astra_context_cap":true,"v2_compaction_target":240000}}}'
cp "$(settings_for "$HOME")" "$TEST_ROOT/default.before"
migrate_compaction_target_240k
assert_eq "same" "$(cmp -s "$TEST_ROOT/default.before" "$(settings_for "$HOME")" && printf same || printf changed)" "default settings are unchanged"
assert_eq "no" "$([[ -e "$HOME/.aidevops/config-backups/migrations/gh32807-settings.json" ]] && printf yes || printf no)" "no backup when nothing changes"
assert_eq "yes" "$(marker_exists "$HOME")" "no-op run is marked complete"

# Missing settings are marked complete without creating a file.
HOME="$TEST_ROOT/missing"
mkdir -p "$HOME"
migrate_compaction_target_240k
assert_eq "no" "$([[ -e "$(settings_for "$HOME")" ]] && printf yes || printf no)" "missing settings are not created"
assert_eq "yes" "$(marker_exists "$HOME")" "missing settings are marked complete"

# Invalid JSON and symlinks are untouched and retried later.
HOME="$TEST_ROOT/invalid"
write_settings "$HOME" '{invalid'
migrate_compaction_target_240k
assert_eq "{invalid" "$(tr -d '\n' <"$(settings_for "$HOME")")" "invalid settings remain untouched"
assert_eq "no" "$(marker_exists "$HOME")" "invalid settings remain eligible for retry"

HOME="$TEST_ROOT/symlink"
mkdir -p "$HOME/.config/aidevops"
printf '%s\n' '{"runtime":{"opencode":{"astra_compaction_target":400000}}}' >"$TEST_ROOT/symlink-target.json"
ln -s "$TEST_ROOT/symlink-target.json" "$(settings_for "$HOME")"
migrate_compaction_target_240k
assert_eq "400000" "$(jq -r '.runtime.opencode.astra_compaction_target' "$TEST_ROOT/symlink-target.json")" "symlinked settings are untouched"
assert_eq "no" "$(marker_exists "$HOME")" "symlinked settings remain eligible for retry"

unset HOME
migrate_compaction_target_240k
assert_eq "1" "$(grep -c 'HOME unavailable; GH#32807' "$LOG")" "unset HOME defers the migration"

if [[ "$failures" -ne 0 ]]; then
	printf '\n%d compaction target migration test(s) failed\n' "$failures" >&2
	exit 1
fi
printf '\nAll compaction target migration tests passed\n'
exit 0
