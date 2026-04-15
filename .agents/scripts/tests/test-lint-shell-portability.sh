#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016
# =============================================================================
# test-lint-shell-portability.sh — Fixture-based unit tests for
# lint-shell-portability.sh (GH#18787, t2076).
#
# Tests cover:
#   - 5+ unguarded command examples that MUST be flagged
#   - 5+ guarded command examples that must NOT be flagged
#   - Inline suppression comment
#   - Regression test for GH#18784 (getent passwd without guard)
#
# Usage: bash test-lint-shell-portability.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCANNER="${SCRIPT_DIR}/../lint-shell-portability.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_info() {
	local msg="$1"
	printf '%b[INFO]%b %s\n' "${TEST_YELLOW}" "${TEST_NC}" "${msg}"
	return 0
}

# Create a fixture file with given content; caller provides path in $1
_write_fixture() {
	local fixture_path="$1"
	local content="$2"
	printf '%s\n' "$content" >"$fixture_path"
	return 0
}

# Assert scanner FLAGS the given fixture (exit 1 = violations found)
_assert_flagged() {
	local desc="$1"
	local fixture="$2"
	# Capture output first: scanner exits 1 on violations, which would break
	# pipelines under `pipefail`. Capture to variable then grep.
	local output
	output=$(bash "$SCANNER" "$fixture" --summary 2>/dev/null) || true
	if echo "$output" | grep -q 'violation'; then
		_pass "scanner flags: $desc"
	else
		_fail "scanner should flag but did not: $desc"
	fi
	return 0
}

# Assert scanner PASSES the given fixture (exit 0 = clean)
_assert_clean() {
	local desc="$1"
	local fixture="$2"
	local output
	output=$(bash "$SCANNER" "$fixture" --summary 2>/dev/null) || true
	if echo "$output" | grep -q 'clean'; then
		_pass "scanner passes: $desc"
	else
		_fail "scanner should pass but flagged: $desc"
		echo "  Output: $output" >&2
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: verify scanner exists
# ---------------------------------------------------------------------------
if [[ ! -x "$SCANNER" ]]; then
	printf '%bFATAL:%b scanner not found at %s\n' "${TEST_RED}" "${TEST_NC}" "$SCANNER" >&2
	exit 1
fi

# Create temp dir for fixtures
FIXTURE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t portability-test.XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '${FIXTURE_DIR}'" EXIT

_info "Scanner: $SCANNER"
_info "Fixtures: $FIXTURE_DIR"
printf '\n'

# ---------------------------------------------------------------------------
# UNGUARDED EXAMPLES — scanner MUST flag these
# ---------------------------------------------------------------------------
_info "--- Unguarded examples (must be flagged) ---"

# 1. Regression: GH#18784 — getent passwd without command -v guard
_write_fixture "${FIXTURE_DIR}/unguarded_getent.sh" '#!/usr/bin/env bash
home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
'
_assert_flagged "GH#18784 regression: getent passwd without guard" "${FIXTURE_DIR}/unguarded_getent.sh"

# 2. sha256sum without guard
_write_fixture "${FIXTURE_DIR}/unguarded_sha256sum.sh" '#!/usr/bin/env bash
hash=$(sha256sum file.txt | cut -d" " -f1)
'
_assert_flagged "sha256sum without command -v guard" "${FIXTURE_DIR}/unguarded_sha256sum.sh"

# 3. readlink -f without guard
_write_fixture "${FIXTURE_DIR}/unguarded_readlink.sh" '#!/usr/bin/env bash
real=$(readlink -f "$path")
'
_assert_flagged "readlink -f without guard" "${FIXTURE_DIR}/unguarded_readlink.sh"

# 4. sed -r without guard
_write_fixture "${FIXTURE_DIR}/unguarded_sed_r.sh" '#!/usr/bin/env bash
result=$(echo "$input" | sed -r "s/foo/bar/")
'
_assert_flagged "sed -r without guard" "${FIXTURE_DIR}/unguarded_sed_r.sh"

# 5. grep -P without guard
_write_fixture "${FIXTURE_DIR}/unguarded_grep_P.sh" '#!/usr/bin/env bash
match=$(echo "$text" | grep -P "pattern")
'
_assert_flagged "grep -P without guard" "${FIXTURE_DIR}/unguarded_grep_P.sh"

# 6. launchctl without guard
_write_fixture "${FIXTURE_DIR}/unguarded_launchctl.sh" '#!/usr/bin/env bash
launchctl load "$plist"
'
_assert_flagged "launchctl without uname guard" "${FIXTURE_DIR}/unguarded_launchctl.sh"

# 7. stat -c without guard
_write_fixture "${FIXTURE_DIR}/unguarded_stat_c.sh" '#!/usr/bin/env bash
mtime=$(stat -c %Y "$file")
'
_assert_flagged "stat -c without guard" "${FIXTURE_DIR}/unguarded_stat_c.sh"

# 8. date -d without guard
_write_fixture "${FIXTURE_DIR}/unguarded_date_d.sh" '#!/usr/bin/env bash
ts=$(date -d "2 hours ago" +%s)
'
_assert_flagged "date -d without guard" "${FIXTURE_DIR}/unguarded_date_d.sh"

printf '\n'
# ---------------------------------------------------------------------------
# GUARDED EXAMPLES — scanner must NOT flag these
# ---------------------------------------------------------------------------
_info "--- Guarded examples (must NOT be flagged) ---"

# 1. getent guarded with command -v (canonical pattern from aidevops.sh)
_write_fixture "${FIXTURE_DIR}/guarded_getent.sh" '#!/usr/bin/env bash
if [[ -n "${SUDO_USER:-}" ]] && command -v getent &>/dev/null; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
'
_assert_clean "getent guarded with command -v (GH#18784 fixed pattern)" "${FIXTURE_DIR}/guarded_getent.sh"

# 2. sha256sum guarded with command -v
_write_fixture "${FIXTURE_DIR}/guarded_sha256sum.sh" '#!/usr/bin/env bash
if command -v sha256sum &>/dev/null; then
    hash=$(sha256sum file.txt | cut -d" " -f1)
elif command -v shasum &>/dev/null; then
    hash=$(shasum -a 256 file.txt | cut -d" " -f1)
fi
'
_assert_clean "sha256sum guarded with command -v" "${FIXTURE_DIR}/guarded_sha256sum.sh"

# 3. launchctl guarded with uname check
_write_fixture "${FIXTURE_DIR}/guarded_launchctl.sh" '#!/usr/bin/env bash
if [[ "$(uname)" == "Darwin" ]]; then
    launchctl load "$plist"
fi
'
_assert_clean "launchctl guarded with uname check" "${FIXTURE_DIR}/guarded_launchctl.sh"

# 4. stat -c guarded with OSTYPE check in BSD/GNU probe pattern
_write_fixture "${FIXTURE_DIR}/guarded_stat.sh" '#!/usr/bin/env bash
if [[ "$(uname)" == "Darwin" ]]; then
    mtime=$(stat -f %m "$file")
else
    mtime=$(stat -c %Y "$file")
fi
'
_assert_clean "stat -c in else branch after uname check" "${FIXTURE_DIR}/guarded_stat.sh"

# 5. getent with inline suppression comment
_write_fixture "${FIXTURE_DIR}/suppressed_getent.sh" '#!/usr/bin/env bash
# shell-portability: ignore next
home=$(getent passwd "$user" | cut -d: -f6)
'
_assert_clean "getent suppressed with inline comment" "${FIXTURE_DIR}/suppressed_getent.sh"

# 6. date -d in BSD-probe else branch
_write_fixture "${FIXTURE_DIR}/guarded_date_d.sh" '#!/usr/bin/env bash
if date -v-1d &>/dev/null; then
    start=$(date -v-7d +%Y-%m-%d)
else
    start=$(date -d "7 days ago" +%Y-%m-%d)
fi
'
_assert_clean "date -d in BSD-probe else branch" "${FIXTURE_DIR}/guarded_date_d.sh"

# 7. timeout with command -v guard
_write_fixture "${FIXTURE_DIR}/guarded_timeout.sh" '#!/usr/bin/env bash
if command -v timeout &>/dev/null; then
    result=$(timeout 30 bash script.sh)
fi
'
_assert_clean "timeout guarded with command -v" "${FIXTURE_DIR}/guarded_timeout.sh"

# 8. launchctl with 2>/dev/null failure suppression
_write_fixture "${FIXTURE_DIR}/guarded_launchctl_devnull.sh" '#!/usr/bin/env bash
launchctl unload "$plist" 2>/dev/null || true
'
_assert_clean "launchctl unload with 2>/dev/null || true" "${FIXTURE_DIR}/guarded_launchctl_devnull.sh"

# 9. sha256sum with || fallback on same line
_write_fixture "${FIXTURE_DIR}/guarded_sha256sum_fallback.sh" '#!/usr/bin/env bash
hash=$(sha256sum file.txt 2>/dev/null || shasum -a 256 file.txt) 
hash="${hash%% *}"
'
_assert_clean "sha256sum with 2>/dev/null || shasum fallback" "${FIXTURE_DIR}/guarded_sha256sum_fallback.sh"

# 10. grep -P with availability detection pattern
_write_fixture "${FIXTURE_DIR}/guarded_grep_P_detect.sh" '#!/usr/bin/env bash
if grep -P "" /dev/null 2>/dev/null; then
    match=$(echo "$text" | grep -P "pattern")
fi
'
_assert_clean "grep -P inside if-grep-P availability check" "${FIXTURE_DIR}/guarded_grep_P_detect.sh"

printf '\n'
# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '%b--- Test Summary ---%b\n' "${TEST_YELLOW}" "${TEST_NC}"
printf 'PASS: %d  FAIL: %d\n' "$pass_count" "$fail_count"
printf '\n'

if [[ "$fail_count" -gt 0 ]]; then
	printf '%bSome tests FAILED.%b\n' "${TEST_RED}" "${TEST_NC}" >&2
	exit 1
else
	printf '%bAll tests PASSED.%b\n' "${TEST_GREEN}" "${TEST_NC}"
	exit 0
fi
