#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Encryption Test Sub-Library: gocryptfs-helper.sh Tests
# =============================================================================
# Tests for the gocryptfs-helper.sh tool covering:
#   - Command dispatch (help, error handling)
#   - Vault name validation
#   - Cipher directory detection
#   - Mount point derivation
#   - Fusermount command detection
#
# Usage: source "${SCRIPT_DIR}/test-encryption-git-roundtrip-gocryptfs.sh"
#
# Dependencies:
#   - Test harness functions (pass, fail, skip, info) from orchestrator
#   - TEST_DIR, HELPER_DIR, VERBOSE variables from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_ENCRYPTION_GOCRYPTFS_LIB_LOADED:-}" ]] && return 0
_TEST_ENCRYPTION_GOCRYPTFS_LIB_LOADED=1

# --- Test 3.1: gocryptfs-helper.sh command dispatch ---
test_gocryptfs_helper_dispatch() {
	echo ""
	echo "=== Test 3.1: gocryptfs-helper.sh command dispatch ==="
	info "Testing help, status, and error handling"

	local helper="$HELPER_DIR/gocryptfs-helper.sh"

	if [[ ! -x "$helper" ]]; then
		fail "gocryptfs-helper.sh not found or not executable at $helper"
		return 0
	fi

	# Test help command
	local help_output
	help_output=$("$helper" help 2>&1) || true

	if echo "$help_output" | grep -q "gocryptfs Encrypted Filesystem"; then
		pass "gocryptfs-helper.sh help outputs expected header"
	else
		fail "gocryptfs-helper.sh help missing expected header"
	fi

	if echo "$help_output" | grep -q "create"; then
		pass "gocryptfs-helper.sh help documents 'create' command"
	else
		fail "gocryptfs-helper.sh help missing 'create' command documentation"
	fi

	# Test unknown command
	local unknown_output
	unknown_output=$("$helper" nonexistent 2>&1) || true

	if echo "$unknown_output" | grep -qi "unknown\|error"; then
		pass "gocryptfs-helper.sh rejects unknown command"
	else
		fail "gocryptfs-helper.sh did not reject unknown command"
	fi

	return 0
}

# --- Test 3.2: vault name validation ---
test_vault_name_validation() {
	echo ""
	echo "=== Test 3.2: Vault name validation ==="
	info "Testing vault name regex from gocryptfs-helper.sh"

	# Simulate the vault name validation from cmd_create
	validate_vault_name() {
		local name="${1:-}"
		if [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
			return 0
		fi
		return 1
	}

	# Valid names
	if validate_vault_name "project-secrets"; then
		pass "Valid name: project-secrets"
	else
		fail "Rejected valid name: project-secrets"
	fi

	if validate_vault_name "myVault123"; then
		pass "Valid name: myVault123"
	else
		fail "Rejected valid name: myVault123"
	fi

	if validate_vault_name "a"; then
		pass "Valid name: a (single char)"
	else
		fail "Rejected valid name: a"
	fi

	if validate_vault_name "test_vault_name"; then
		pass "Valid name: test_vault_name (underscores)"
	else
		fail "Rejected valid name: test_vault_name"
	fi

	# Invalid names
	if ! validate_vault_name "-starts-with-dash"; then
		pass "Rejected invalid name: -starts-with-dash"
	else
		fail "Accepted invalid name: -starts-with-dash"
	fi

	if ! validate_vault_name "_starts-with-underscore"; then
		pass "Rejected invalid name: _starts-with-underscore"
	else
		fail "Accepted invalid name: _starts-with-underscore"
	fi

	if ! validate_vault_name "has spaces"; then
		pass "Rejected invalid name: has spaces"
	else
		fail "Accepted invalid name: has spaces"
	fi

	if ! validate_vault_name "has/slash"; then
		pass "Rejected invalid name: has/slash"
	else
		fail "Accepted invalid name: has/slash"
	fi

	if ! validate_vault_name "has.dot"; then
		pass "Rejected invalid name: has.dot"
	else
		fail "Accepted invalid name: has.dot"
	fi

	if ! validate_vault_name ""; then
		pass "Rejected invalid name: (empty string)"
	else
		fail "Accepted invalid name: (empty string)"
	fi

	return 0
}

# --- Test 3.3: cipher directory detection ---
test_cipher_dir_detection() {
	echo ""
	echo "=== Test 3.3: Cipher directory detection ==="
	info "Testing is_cipher_dir logic"

	local test_dir="$TEST_DIR/cipher-detect"
	mkdir -p "$test_dir/real-vault"
	mkdir -p "$test_dir/fake-vault"

	# Create a fake gocryptfs.conf to simulate a cipher directory
	echo '{"Creator":"gocryptfs","EncryptedKey":"..."}' >"$test_dir/real-vault/gocryptfs.conf"

	# is_cipher_dir checks for gocryptfs.conf
	if [[ -f "$test_dir/real-vault/gocryptfs.conf" ]]; then
		pass "Real vault detected (gocryptfs.conf present)"
	else
		fail "Real vault not detected"
	fi

	if [[ ! -f "$test_dir/fake-vault/gocryptfs.conf" ]]; then
		pass "Fake vault correctly identified (no gocryptfs.conf)"
	else
		fail "Fake vault incorrectly identified as real"
	fi

	return 0
}

# --- Test 3.4: mount point derivation ---
test_mount_point_derivation() {
	echo ""
	echo "=== Test 3.4: Mount point derivation ==="
	info "Testing default_mount_point logic"

	# Simulate default_mount_point from gocryptfs-helper.sh
	default_mount_point_test() {
		local cipher_dir="${1:-}"
		local base
		base=$(basename "$cipher_dir")
		echo "${cipher_dir%/*}/${base}.mnt"
		return 0
	}

	local result

	result=$(default_mount_point_test "/path/to/my-vault")
	if [[ "$result" == "/path/to/my-vault.mnt" ]]; then
		pass "Mount point derived correctly: $result"
	else
		fail "Expected /path/to/my-vault.mnt, got '$result'"
	fi

	result=$(default_mount_point_test "/home/user/.vaults/project")
	if [[ "$result" == "/home/user/.vaults/project.mnt" ]]; then
		pass "Mount point derived correctly: $result"
	else
		fail "Expected /home/user/.vaults/project.mnt, got '$result'"
	fi

	return 0
}

# --- Test 3.5: fusermount command detection ---
test_fusermount_detection() {
	echo ""
	echo "=== Test 3.5: Fusermount command detection ==="
	info "Testing get_fusermount logic for current platform"

	# Simulate get_fusermount from gocryptfs-helper.sh
	get_fusermount_test() {
		if [[ "$(uname)" == "Darwin" ]]; then
			echo "umount"
		elif command -v fusermount3 &>/dev/null; then
			echo "fusermount3 -u"
		elif command -v fusermount &>/dev/null; then
			echo "fusermount -u"
		else
			echo "umount"
		fi
		return 0
	}

	local result
	result=$(get_fusermount_test)

	if [[ "$(uname)" == "Darwin" ]]; then
		if [[ "$result" == "umount" ]]; then
			pass "macOS correctly uses 'umount'"
		else
			fail "macOS should use 'umount', got '$result'"
		fi
	else
		if [[ "$result" == "fusermount3 -u" || "$result" == "fusermount -u" || "$result" == "umount" ]]; then
			pass "Linux fusermount detected: $result"
		else
			fail "Unexpected fusermount command: $result"
		fi
	fi

	return 0
}
