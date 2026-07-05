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

export AIDEVOPS_OPTIMISE_NOW=2000000000
stale_output="$($HELPER linux reminder --format=toast --no-notify)"
assert_contains "$stale_output" "[WARN] Linux indexing/backup optimisation is stale"

$HELPER linux scan --dry-run >/dev/null
fresh_output="$($HELPER linux reminder --format=toast --no-notify)"
[[ -z "$fresh_output" ]] || fail "fresh state should suppress reminder"

printf 'OK: optimise-indexing-backups-helper tests passed\n'
