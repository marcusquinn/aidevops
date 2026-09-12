#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for localhost-helper optional command parameters.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/localhost-helper.sh"
TEST_TMP_BASE="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_TMP_BASE"
TEST_ROOT="$(mktemp -d "$TEST_TMP_BASE/localhost-helper-arguments.XXXXXX")"
PASS=0
FAIL=0

record_pass() {
    printf 'PASS: %s\n' "$1"
    PASS=$((PASS + 1))
    return 0
}

record_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
    return 0
}

assert_command_output() {
    local description="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if [[ "$output" == *"$expected"* ]]; then
        record_pass "$description"
    else
        record_fail "$description"
    fi
    return 0
}

cleanup() {
    rm -rf "$TEST_ROOT"
    return 0
}

trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEST_ROOT/bin/lsof"

cat >"$TEST_ROOT/bin/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEST_ROOT/bin/nc"
export PATH="$TEST_ROOT/bin:$PATH"
hash -r

assert_command_output "no arguments prints usage" "Usage:" "$HELPER"
assert_command_output "help prints usage" "Usage:" "$HELPER" help
assert_command_output "long help prints usage" "Usage:" "$HELPER" --help
assert_command_output "find-port uses the default start port" "3000" "$HELPER" find-port
assert_command_output "find-port accepts an explicit start port" "3188" "$HELPER" find-port 3188
assert_command_output "check-port reports a missing port" "Port number required" "$HELPER" check-port
assert_command_output "generate-cert reports a missing domain" "Please specify a domain" "$HELPER" generate-cert
assert_command_output "create-app reports missing required parameters" "Usage: create-app" "$HELPER" create-app

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
