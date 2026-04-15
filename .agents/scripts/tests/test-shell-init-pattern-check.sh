#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shell-init-pattern-check.sh — regression tests for the shell init
# pattern scanner (t2053 Phase 2).
#
# Tests positive and negative fixtures to ensure:
# (a) unguarded plain RED='...' fails
# (b) readonly RED='...' outside shared-constants.sh fails
# (c) Pattern A (source shared-constants.sh) passes
# (d) Pattern B ([[ -z "${VAR+x}" ]] &&) passes
# (e) Pattern C (TEST_RED=...) passes
# (f) unguarded BOLD= passes (not a canonical color)
# (g) banned set is exactly RED/GREEN/YELLOW/BLUE/PURPLE/CYAN/WHITE/NC
#
# shell-init-check:disable — this file embeds violation patterns as test fixtures

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="${TEST_SCRIPTS_DIR}/shell-init-pattern-check.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

# Fixture directory
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Helper: create a fixture file and return its path
make_fixture() {
	local name="$1" content="$2"
	local path="${TEST_ROOT}/${name}"
	printf '%s\n' "$content" >"$path"
	printf '%s' "$path"
	return 0
}

# =============================================================================
# Test (a): unguarded plain assignment of canonical color — must FAIL
# =============================================================================
for var in RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC; do
	fixture=$(make_fixture "bad_plain_${var}.sh" "#!/usr/bin/env bash
set -euo pipefail
${var}='\\033[0;31m'
echo \"hello\"")
	output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
	rc=$?
	if [[ $rc -eq 1 ]]; then
		print_result "unguarded plain ${var}= fails" 0
	else
		print_result "unguarded plain ${var}= fails" 1 "(rc=$rc output='$output')"
	fi
done

# =============================================================================
# Test (b): readonly on canonical color outside shared-constants.sh — must FAIL
# =============================================================================
for var in RED GREEN; do
	fixture=$(make_fixture "bad_readonly_${var}.sh" "#!/usr/bin/env bash
set -euo pipefail
readonly ${var}='\\033[0;31m'
echo \"hello\"")
	output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
	rc=$?
	if [[ $rc -eq 1 ]]; then
		print_result "readonly ${var}= outside shared-constants.sh fails" 0
	else
		print_result "readonly ${var}= outside shared-constants.sh fails" 1 "(rc=$rc output='$output')"
	fi
done

# =============================================================================
# Test (c): Pattern A (source shared-constants.sh) — must PASS
# =============================================================================
fixture=$(make_fixture "good_pattern_a.sh" '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
echo -e "${GREEN}[OK]${NC} sourced"')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "Pattern A (source shared-constants.sh) passes" 0
else
	print_result "Pattern A (source shared-constants.sh) passes" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (d): Pattern B (guarded with ${VAR+x}) — must PASS
# =============================================================================
fixture=$(make_fixture "good_pattern_b.sh" '#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RED+x}" ]]    && RED='"'"'\033[0;31m'"'"'
[[ -z "${GREEN+x}" ]]  && GREEN='"'"'\033[0;32m'"'"'
[[ -z "${NC+x}" ]]     && NC='"'"'\033[0m'"'"'
echo "hello"')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "Pattern B (guarded \${VAR+x}) passes" 0
else
	print_result "Pattern B (guarded \${VAR+x}) passes" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (e): Pattern C (prefixed TEST_RED) — must PASS
# =============================================================================
fixture=$(make_fixture "good_pattern_c.sh" '#!/usr/bin/env bash
set -euo pipefail
readonly TEST_RED=$'"'"'\033[0;31m'"'"'
readonly TEST_GREEN=$'"'"'\033[0;32m'"'"'
readonly TEST_RESET=$'"'"'\033[0m'"'"'
echo "hello"')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "Pattern C (TEST_RED prefix) passes" 0
else
	print_result "Pattern C (TEST_RED prefix) passes" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (f): non-canonical variable (BOLD) — must PASS
# =============================================================================
fixture=$(make_fixture "good_bold.sh" '#!/usr/bin/env bash
set -euo pipefail
BOLD='"'"'\033[1m'"'"'
echo "hello"')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "non-canonical BOLD= passes (not in banned set)" 0
else
	print_result "non-canonical BOLD= passes (not in banned set)" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (g): shared-constants.sh is exempt — must PASS
# =============================================================================
fixture=$(make_fixture "shared-constants.sh" '#!/usr/bin/env bash
readonly RED='"'"'\033[0;31m'"'"'
readonly GREEN='"'"'\033[0;32m'"'"'
readonly NC='"'"'\033[0m'"'"'')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "shared-constants.sh is exempt" 0
else
	print_result "shared-constants.sh is exempt" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (h): indented assignments (inside functions) — must PASS
# =============================================================================
fixture=$(make_fixture "good_indented.sh" '#!/usr/bin/env bash
set -euo pipefail
my_func() {
    RED='"'"'\033[0;31m'"'"'
    readonly GREEN='"'"'\033[0;32m'"'"'
    echo "$RED hello $GREEN"
}')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "indented assignments (inside functions) pass" 0
else
	print_result "indented assignments (inside functions) pass" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (i): non-.sh files are skipped — must PASS
# =============================================================================
fixture=$(make_fixture "readme.md" 'RED=bad
GREEN=bad')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "non-.sh files are skipped" 0
else
	print_result "non-.sh files are skipped" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (j): --fix-hint returns 0 and produces output
# =============================================================================
output=$(bash "$CHECKER" --fix-hint 2>&1)
rc=$?
if [[ $rc -eq 0 && "$output" == *"Pattern A"* && "$output" == *"Pattern B"* ]]; then
	print_result "--fix-hint shows remediation" 0
else
	print_result "--fix-hint shows remediation" 1 "(rc=$rc)"
fi

# =============================================================================
# Test (k): --help returns 0
# =============================================================================
output=$(bash "$CHECKER" --help 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "--help returns 0" 0
else
	print_result "--help returns 0" 1 "(rc=$rc)"
fi

# =============================================================================
# Test (l): no args returns 2 (usage error)
# =============================================================================
output=$(bash "$CHECKER" 2>&1)
rc=$?
if [[ $rc -eq 2 ]]; then
	print_result "no args returns exit 2 (usage error)" 0
else
	print_result "no args returns exit 2 (usage error)" 1 "(rc=$rc)"
fi

# =============================================================================
# Test (m): multiple files, one bad — must FAIL with correct count
# =============================================================================
good=$(make_fixture "multi_good.sh" '#!/usr/bin/env bash
[[ -z "${RED+x}" ]] && RED='"'"'\033[0;31m'"'"'')
bad=$(make_fixture "multi_bad.sh" '#!/usr/bin/env bash
RED='"'"'\033[0;31m'"'"'
GREEN='"'"'\033[0;32m'"'"'')
output=$(bash "$CHECKER" --scan-files "$good" "$bad" 2>&1)
rc=$?
if [[ $rc -eq 1 && "$output" == *"2 violation"* ]]; then
	print_result "multiple files: detects 2 violations in bad file" 0
else
	print_result "multiple files: detects 2 violations in bad file" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Test (n): file with # shell-init-check:disable directive — must PASS
# =============================================================================
fixture=$(make_fixture "disabled_check.sh" '#!/usr/bin/env bash
# shell-init-check:disable — test fixtures
RED='"'"'\033[0;31m'"'"'
GREEN='"'"'\033[0;32m'"'"'')
output=$(bash "$CHECKER" --scan-files "$fixture" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	print_result "file with shell-init-check:disable directive passes" 0
else
	print_result "file with shell-init-check:disable directive passes" 1 "(rc=$rc output='$output')"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
