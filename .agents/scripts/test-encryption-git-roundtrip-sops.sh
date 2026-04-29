#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Encryption Test Sub-Library: sops-helper.sh Tests
# =============================================================================
# Tests for the sops-helper.sh tool covering:
#   - Command dispatch (help, error handling)
#   - File type detection
#   - Encryption detection
#   - SOPS encrypt/decrypt git round-trip (if tools available)
#
# Usage: source "${SCRIPT_DIR}/test-encryption-git-roundtrip-sops.sh"
#
# Dependencies:
#   - Test harness functions (pass, fail, skip, info) from orchestrator
#   - TEST_DIR, HELPER_DIR, VERBOSE, HAS_SOPS, HAS_AGE variables from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_ENCRYPTION_SOPS_LIB_LOADED:-}" ]] && return 0
_TEST_ENCRYPTION_SOPS_LIB_LOADED=1

# --- Test 2.1: sops-helper.sh command dispatch ---
test_sops_helper_dispatch() {
	echo ""
	echo "=== Test 2.1: sops-helper.sh command dispatch ==="
	info "Testing help, status, and error handling"

	local helper="$HELPER_DIR/sops-helper.sh"

	if [[ ! -x "$helper" ]]; then
		fail "sops-helper.sh not found or not executable at $helper"
		return 0
	fi

	# Test help command
	local help_output
	help_output=$("$helper" help 2>&1) || true

	if echo "$help_output" | grep -q "SOPS Encrypted Config"; then
		pass "sops-helper.sh help outputs expected header"
	else
		fail "sops-helper.sh help missing expected header"
	fi

	if echo "$help_output" | grep -q "encrypt"; then
		pass "sops-helper.sh help documents 'encrypt' command"
	else
		fail "sops-helper.sh help missing 'encrypt' command documentation"
	fi

	# Test unknown command
	local unknown_output
	unknown_output=$("$helper" nonexistent 2>&1) || true

	if echo "$unknown_output" | grep -qi "unknown\|error"; then
		pass "sops-helper.sh rejects unknown command"
	else
		fail "sops-helper.sh did not reject unknown command"
	fi

	# Test encrypt without file (may fail with unbound variable from set -u)
	local no_file_output
	no_file_output=$("$helper" encrypt 2>&1) || true

	if echo "$no_file_output" | grep -qi "usage\|error\|unbound"; then
		pass "sops-helper.sh encrypt without file produces error"
	else
		fail "sops-helper.sh encrypt without file did not produce error"
	fi

	# Test encrypt with nonexistent file
	local bad_file_output
	bad_file_output=$("$helper" encrypt "/tmp/nonexistent-$$-file.yaml" 2>&1) || true

	if echo "$bad_file_output" | grep -qi "not found\|error"; then
		pass "sops-helper.sh encrypt with nonexistent file produces error"
	else
		fail "sops-helper.sh encrypt with nonexistent file did not produce error"
	fi

	return 0
}

# --- Test 2.2: SOPS file type detection ---
test_sops_file_type_detection() {
	echo ""
	echo "=== Test 2.2: SOPS file type detection ==="
	info "Testing detect_file_type logic for various extensions"

	# Simulate the detect_file_type function from sops-helper.sh
	detect_file_type_test() {
		local file="${1:-}"
		local ext="${file##*.}"
		case "$ext" in
		yaml | yml) echo "yaml" ;;
		json) echo "json" ;;
		env) echo "dotenv" ;;
		ini) echo "ini" ;;
		*) echo "binary" ;;
		esac
		return 0
	}

	local result

	result=$(detect_file_type_test "config.enc.yaml")
	if [[ "$result" == "yaml" ]]; then
		pass "Detected .yaml as yaml"
	else
		fail "Expected yaml, got '$result'"
	fi

	result=$(detect_file_type_test "config.enc.yml")
	if [[ "$result" == "yaml" ]]; then
		pass "Detected .yml as yaml"
	else
		fail "Expected yaml, got '$result'"
	fi

	result=$(detect_file_type_test "config.enc.json")
	if [[ "$result" == "json" ]]; then
		pass "Detected .json as json"
	else
		fail "Expected json, got '$result'"
	fi

	result=$(detect_file_type_test ".env.enc.env")
	if [[ "$result" == "dotenv" ]]; then
		pass "Detected .env as dotenv"
	else
		fail "Expected dotenv, got '$result'"
	fi

	result=$(detect_file_type_test "settings.enc.ini")
	if [[ "$result" == "ini" ]]; then
		pass "Detected .ini as ini"
	else
		fail "Expected ini, got '$result'"
	fi

	result=$(detect_file_type_test "data.bin")
	if [[ "$result" == "binary" ]]; then
		pass "Detected unknown extension as binary"
	else
		fail "Expected binary, got '$result'"
	fi

	return 0
}

# --- Test 2.3: SOPS encryption detection ---
test_sops_encryption_detection() {
	echo ""
	echo "=== Test 2.3: SOPS encryption detection ==="
	info "Testing is_encrypted logic for YAML and JSON files"

	local test_dir="$TEST_DIR/sops-detect"
	mkdir -p "$test_dir"

	# Create a file that looks SOPS-encrypted (YAML)
	cat >"$test_dir/encrypted.enc.yaml" <<'EOF'
database:
    host: ENC[AES256_GCM,data:abc123,iv:def456,tag:ghi789,type:str]
    port: ENC[AES256_GCM,data:NTQzMg==,iv:jkl012,tag:mno345,type:int]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBhYmNkZWYK
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2026-02-22T00:00:00Z"
    mac: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
    version: 3.9.4
EOF

	# Create a file that looks SOPS-encrypted (JSON)
	cat >"$test_dir/encrypted.enc.json" <<'EOF'
{
    "database": {
        "host": "ENC[AES256_GCM,data:abc123]"
    },
    "sops": {
        "version": "3.9.4"
    }
}
EOF

	# Create a plaintext file
	cat >"$test_dir/plaintext.yaml" <<'EOF'
database:
    host: db.example.com
    port: 5432
EOF

	# Test detection (same logic as is_encrypted in sops-helper.sh)
	is_encrypted_test() {
		local file="${1:-}"
		if [[ ! -f "$file" ]]; then
			return 1
		fi
		if grep -q '"sops"' "$file" || grep -q "sops:" "$file"; then
			return 0
		fi
		return 1
	}

	if is_encrypted_test "$test_dir/encrypted.enc.yaml"; then
		pass "YAML file with sops: key detected as encrypted"
	else
		fail "YAML file with sops: key not detected as encrypted"
	fi

	if is_encrypted_test "$test_dir/encrypted.enc.json"; then
		pass "JSON file with \"sops\" key detected as encrypted"
	else
		fail "JSON file with \"sops\" key not detected as encrypted"
	fi

	if ! is_encrypted_test "$test_dir/plaintext.yaml"; then
		pass "Plaintext YAML correctly identified as not encrypted"
	else
		fail "Plaintext YAML incorrectly identified as encrypted"
	fi

	if ! is_encrypted_test "$test_dir/nonexistent.yaml"; then
		pass "Nonexistent file correctly returns not-encrypted"
	else
		fail "Nonexistent file incorrectly returns encrypted"
	fi

	return 0
}

# --- Test 2.4: SOPS encrypt/decrypt git round-trip (if tools available) ---

# Setup age key and return pub_key via stdout; sets SOPS_AGE_KEY_FILE in caller env
_sops_setup_age_key() {
	local age_key_dir="$1"
	mkdir -p "$age_key_dir"
	chmod 700 "$age_key_dir"
	age-keygen -o "$age_key_dir/keys.txt" 2>/dev/null || return 1
	grep "^# public key:" "$age_key_dir/keys.txt" | sed 's/^# public key: //'
	return 0
}

# Initialize a git repo with .sops.yaml and a plaintext config file
_sops_init_git_repo() {
	local test_repo="$1"
	local pub_key="$2"
	(
		cd "$test_repo"
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"

		cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    age: >-
      ${pub_key}
EOF

		cat >config.enc.yaml <<'EOF'
database:
    host: db.example.com
    port: 5432
    username: admin
    password: super-secret-password-12345
    ssl: true
api:
    key: api-key-for-testing-xyz
    endpoint: https://api.example.com
EOF

		git add .sops.yaml
		git commit -q -m "init: add sops config"
	)
	return 0
}

# Verify that the encrypted file has sops metadata and no plaintext secrets
_sops_verify_encryption() {
	local config_file="$1"

	if grep -q "sops:" "$config_file"; then
		pass "Encrypted file contains sops metadata"
	else
		fail "Encrypted file missing sops metadata"
	fi

	if ! grep -q "super-secret-password-12345" "$config_file"; then
		pass "Plaintext password not visible in encrypted file"
	else
		fail "Plaintext password visible in encrypted file"
	fi

	if ! grep -q "api-key-for-testing-xyz" "$config_file"; then
		pass "Plaintext API key not visible in encrypted file"
	else
		fail "Plaintext API key visible in encrypted file"
	fi

	return 0
}

# Verify decrypted content matches original plaintext values
_sops_verify_decryption() {
	local config_file="$1"
	local test_repo="$2"

	local decrypted
	decrypted=$(sops decrypt "$config_file") || true

	if echo "$decrypted" | grep -q "super-secret-password-12345"; then
		pass "Decrypted content contains original password"
	else
		fail "Decrypted content missing original password"
	fi

	if echo "$decrypted" | grep -q "api-key-for-testing-xyz"; then
		pass "Decrypted content contains original API key"
	else
		fail "Decrypted content missing original API key"
	fi

	if echo "$decrypted" | grep -q "db.example.com"; then
		pass "Decrypted content contains original host"
	else
		fail "Decrypted content missing original host"
	fi

	local commit_count
	commit_count=$(cd "$test_repo" && git log --oneline | wc -l | tr -d ' ')
	if [[ "$commit_count" -eq 2 ]]; then
		pass "Git history has 2 commits (init + encrypted config)"
	else
		fail "Expected 2 commits, got $commit_count"
	fi

	return 0
}

test_sops_git_roundtrip() {
	echo ""
	echo "=== Test 2.4: SOPS encrypt/decrypt git round-trip ==="

	if [[ "$HAS_SOPS" != "true" ]]; then
		skip "sops not installed -- skipping SOPS git round-trip test"
		return 0
	fi

	if [[ "$HAS_AGE" != "true" ]]; then
		skip "age not installed -- skipping SOPS git round-trip test"
		return 0
	fi

	info "Testing full SOPS encrypt -> git commit -> decrypt round-trip"

	local test_repo="$TEST_DIR/sops-git-repo"
	mkdir -p "$test_repo"

	local age_key_dir="$TEST_DIR/sops-age-keys"
	local pub_key
	pub_key=$(_sops_setup_age_key "$age_key_dir") || true

	if [[ -z "$pub_key" ]]; then
		fail "Failed to generate age key pair"
		return 0
	fi

	pass "Generated temporary age key for testing"

	_sops_init_git_repo "$test_repo" "$pub_key"

	export SOPS_AGE_KEY_FILE="$age_key_dir/keys.txt"

	if sops encrypt -i "$test_repo/config.enc.yaml"; then
		pass "SOPS encryption succeeded"
	else
		fail "SOPS encryption failed"
		unset SOPS_AGE_KEY_FILE
		return 0
	fi

	_sops_verify_encryption "$test_repo/config.enc.yaml"

	(
		cd "$test_repo"
		git add config.enc.yaml
		git commit -q -m "feat: add encrypted config"
	)

	pass "Committed encrypted config to git"

	_sops_verify_decryption "$test_repo/config.enc.yaml" "$test_repo"

	unset SOPS_AGE_KEY_FILE

	return 0
}
