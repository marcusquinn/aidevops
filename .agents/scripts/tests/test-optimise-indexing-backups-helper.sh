#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${ROOT_DIR}/.agents/scripts/optimise-indexing-backups-helper.sh"

fail() {
    local message="$1"
    printf 'FAIL: %s\n' "$message" >&2
    return 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *) fail "expected output to contain: $needle" ;;
    esac
    return 0
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    case "$haystack" in
        *"$needle"*) fail "expected output not to contain: $needle" ;;
        *) return 0 ;;
    esac
    return 0
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export HOME="$tmpdir/home"
export AIDEVOPS_STATE_DIR="$tmpdir/state"
export AIDEVOPS_LOG_DIR="$tmpdir/logs"
export AIDEVOPS_CONFIG_DIR="$tmpdir/configs"
export AIDEVOPS_HEADLESS=true
mkdir -p "$HOME"

json_output="$($HELPER macos scan --dry-run --json)"
printf '%s\n' "$json_output" | jq -e '.platform == "macos" and .mode == "dry-run" and (.project_patterns | index("<repo-root>/**/node_modules/"))' >/dev/null
assert_contains "$json_output" "<repo-root>/**/.turbo/"
assert_not_contains "$json_output" "/Users/"

linux_output="$($HELPER linux apply --json)"
printf '%s\n' "$linux_output" | jq -e '.platform == "linux" and .mode == "apply"' >/dev/null
[[ -f "$AIDEVOPS_CONFIG_DIR/optimise-indexing-backups-excludes.txt" ]] || fail "linux apply did not create exclude file"
assert_contains "$(<"$AIDEVOPS_CONFIG_DIR/optimise-indexing-backups-excludes.txt")" "<repo-root>/**/.venv/"

windows_json_output="$($HELPER windows scan --dry-run --json)"
printf '%s\n' "$windows_json_output" | jq -e '.platform == "windows" and .mode == "dry-run" and (.candidate_paths | index("%LOCALAPPDATA%\\Temp\\")) and (.project_patterns | index("<repo-root>\\**\\node_modules\\")) and (.support_posture | contains("limited experimental"))' >/dev/null
windows_paths="$(printf '%s\n' "$windows_json_output" | jq -r '.candidate_paths[], .project_patterns[]')"
assert_contains "$windows_paths" '%LOCALAPPDATA%\Temp\'
assert_contains "$windows_paths" '<repo-root>\**\.turbo\'
assert_not_contains "$windows_paths" "/Users/"

windows_apply_output="$($HELPER windows apply --json)"
printf '%s\n' "$windows_apply_output" | jq -e '.platform == "windows" and .mode == "apply"' >/dev/null
windows_exclude_file="$AIDEVOPS_CONFIG_DIR/optimise-indexing-backups-windows-excludes.txt"
[[ -f "$windows_exclude_file" ]] || fail "windows apply did not create recommendation file"
windows_excludes="$(<"$windows_exclude_file")"
assert_contains "$windows_excludes" "Safe apply scope: this file only"
assert_contains "$windows_excludes" '%LOCALAPPDATA%\Temp\'
assert_contains "$windows_excludes" '<repo-root>\**\.next\'
assert_not_contains "$windows_excludes" "/Users/"

windows_alias_status="$($HELPER windows-native status --json)"
printf '%s\n' "$windows_alias_status" | jq -e '.platform == "windows"' >/dev/null

export AIDEVOPS_OPTIMISE_NOW=2000000000
stale_output="$($HELPER linux reminder --format=toast --no-notify)"
assert_contains "$stale_output" "[WARN] Linux indexing/backup optimisation is stale"
windows_stale_output="$($HELPER windows reminder --format=toast --no-notify)"
assert_contains "$windows_stale_output" "[WARN] Windows indexing/backup optimisation is stale — run /optimise-windows-indexing-backups"

$HELPER linux scan --dry-run >/dev/null
fresh_output="$($HELPER linux reminder --format=toast --no-notify)"
[[ -z "$fresh_output" ]] || fail "fresh state should suppress reminder"

$HELPER linux scan --dry-run --path >/dev/null
$HELPER linux reminder --format >/dev/null

printf '[]\n' >"$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json"
$HELPER linux scan --dry-run >/dev/null
printf '%s\n' "$(<"$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json")" | jq -e '.linux.last_applied_count == 0 and .linux.last_warning_count == 0' >/dev/null

export AIDEVOPS_OPTIMISE_NOW=2000000000
$HELPER linux apply >/dev/null
applied_before="$(jq -r '.linux.last_applied_count' "$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json")"
warnings_before="$(jq -r '.linux.last_warning_count' "$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json")"
export AIDEVOPS_OPTIMISE_NOW=3000000000
$HELPER linux reminder --format=toast --no-notify >/dev/null
applied_after="$(jq -r '.linux.last_applied_count' "$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json")"
warnings_after="$(jq -r '.linux.last_warning_count' "$AIDEVOPS_STATE_DIR/optimise-indexing-backups.json")"
[[ "$applied_after" == "$applied_before" ]] || fail "reminder should preserve last applied count"
[[ "$warnings_after" == "$warnings_before" ]] || fail "reminder should preserve last warning count"

printf 'OK: optimise-indexing-backups-helper tests passed\n'
