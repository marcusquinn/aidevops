#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Integration Tests: Encryption and Git Storage Round-Trips (t004.42)
# =============================================================================
# Tests the three encryption tools in the aidevops stack:
#   1. secret-helper.sh  - gopass/credentials.sh secret management
#   2. sops-helper.sh    - SOPS encrypted config files for git
#   3. gocryptfs-helper.sh - FUSE encrypted directory vaults
#
# Each tool is tested for:
#   - Basic functionality (init, store, retrieve)
#   - Round-trip integrity (data in == data out)
#   - Git storage integration (commit encrypted, retrieve decrypted)
#   - Error handling (missing tools, bad input, edge cases)
#   - Redaction safety (secrets never leak to stdout)
#
# Tools that are not installed are gracefully skipped.
# All tests use isolated temp directories -- no side effects on real data.
#
# Usage:
#   ./test-encryption-git-roundtrip.sh          # Run all tests
#   ./test-encryption-git-roundtrip.sh --verbose # Verbose output
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_DIR="${SCRIPT_DIR}/.."
TEST_DIR="/tmp/t004.42-encryption-test-$$"
PASS=0
FAIL=0
SKIP=0
VERBOSE="${1:-}"

cleanup_test() {
	rm -rf "$TEST_DIR"
	return 0
}

trap cleanup_test EXIT

mkdir -p "$TEST_DIR"

# Colors (Pattern C — prefixed names, test harness only)
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_YELLOW=$'\033[1;33m'
readonly TEST_BLUE=$'\033[0;34m'
readonly TEST_RESET=$'\033[0m'

pass() {
	local msg="${1:-}"
	printf "%s\n" "${TEST_GREEN}[PASS]${TEST_RESET} $msg"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local msg="${1:-}"
	printf "%s\n" "${TEST_RED}[FAIL]${TEST_RESET} $msg"
	FAIL=$((FAIL + 1))
	return 0
}

skip() {
	local msg="${1:-}"
	printf "%s\n" "${TEST_YELLOW}[SKIP]${TEST_RESET} $msg"
	SKIP=$((SKIP + 1))
	return 0
}

info() {
	local msg="${1:-}"
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "%s\n" "${TEST_BLUE}[INFO]${TEST_RESET} $msg"
	fi
	return 0
}

# =============================================================================
# Tool availability checks
# =============================================================================

HAS_GOPASS=false
HAS_SOPS=false
HAS_AGE=false
HAS_GOCRYPTFS=false
HAS_GPG=false

command -v gopass &>/dev/null && HAS_GOPASS=true
command -v sops &>/dev/null && HAS_SOPS=true
command -v age &>/dev/null && HAS_AGE=true
command -v gocryptfs &>/dev/null && HAS_GOCRYPTFS=true
command -v gpg &>/dev/null && HAS_GPG=true

# =============================================================================
# Source sub-libraries
# =============================================================================

# shellcheck source=../test-encryption-git-roundtrip-secret.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $HELPER_DIR
source "${HELPER_DIR}/test-encryption-git-roundtrip-secret.sh"

# shellcheck source=../test-encryption-git-roundtrip-sops.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $HELPER_DIR
source "${HELPER_DIR}/test-encryption-git-roundtrip-sops.sh"

# shellcheck source=../test-encryption-git-roundtrip-gocryptfs.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $HELPER_DIR
source "${HELPER_DIR}/test-encryption-git-roundtrip-gocryptfs.sh"

# shellcheck source=../test-encryption-git-roundtrip-integration.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $HELPER_DIR
source "${HELPER_DIR}/test-encryption-git-roundtrip-integration.sh"

# =============================================================================
# Run all tests
# =============================================================================

echo "============================================="
echo "  Encryption & Git Storage Round-Trip Tests"
echo "  Task: t004.42"
echo "============================================="
echo ""
echo "Test environment: $TEST_DIR"
echo "Helper directory: $HELPER_DIR"
echo ""
echo "Tool availability:"
echo "  gopass:    $HAS_GOPASS"
echo "  sops:      $HAS_SOPS"
echo "  age:       $HAS_AGE"
echo "  gocryptfs: $HAS_GOCRYPTFS"
echo "  gpg:       $HAS_GPG"
echo ""

# Section 1: secret-helper.sh
echo "--- Section 1: secret-helper.sh ---"
test_credentials_fallback_roundtrip
test_redaction_filter
test_multi_tenant_resolution
test_secret_helper_dispatch
test_gopass_roundtrip
test_credential_update

# Section 2: sops-helper.sh
echo ""
echo "--- Section 2: sops-helper.sh ---"
test_sops_helper_dispatch
test_sops_file_type_detection
test_sops_encryption_detection
test_sops_git_roundtrip

# Section 3: gocryptfs-helper.sh
echo ""
echo "--- Section 3: gocryptfs-helper.sh ---"
test_gocryptfs_helper_dispatch
test_vault_name_validation
test_cipher_dir_detection
test_mount_point_derivation
test_fusermount_detection

# Section 4: Cross-tool integration
echo ""
echo "--- Section 4: Cross-tool integration ---"
test_encryption_decision_tree
test_git_safe_properties
test_shared_constants_integration
test_name_normalization
test_placeholder_filtering

# Section 5: Git storage round-trips
echo ""
echo "--- Section 5: Git storage round-trips ---"
test_credentials_git_exclusion
test_sops_gitattributes

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "============================================="
echo "  Test Summary"
echo "============================================="
echo ""
echo -e "  ${TEST_GREEN}PASS${TEST_RESET}: $PASS"
echo -e "  ${TEST_RED}FAIL${TEST_RESET}: $FAIL"
echo -e "  ${TEST_YELLOW}SKIP${TEST_RESET}: $SKIP"
echo ""

TOTAL=$((PASS + FAIL + SKIP))
echo "  Total: $TOTAL tests"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
	echo -e "${TEST_GREEN}All tests passed!${TEST_RESET}"
	exit 0
else
	echo -e "${TEST_RED}$FAIL test(s) failed${TEST_RESET}"
	exit 1
fi
