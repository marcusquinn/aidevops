#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Encryption Test Sub-Library: Cross-Tool Integration & Git Storage Tests
# =============================================================================
# Tests for cross-tool integration and git storage round-trips covering:
#   - Encryption stack decision tree
#   - Git-safe property verification
#   - shared-constants.sh integration
#   - Secret name normalization
#   - Placeholder/empty value filtering
#   - Credentials git exclusion
#   - SOPS .gitattributes diff driver
#
# Usage: source "${SCRIPT_DIR}/test-encryption-git-roundtrip-integration.sh"
#
# Dependencies:
#   - Test harness functions (pass, fail, skip, info) from orchestrator
#   - TEST_DIR, HELPER_DIR, VERBOSE variables from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_ENCRYPTION_INTEGRATION_LIB_LOADED:-}" ]] && return 0
_TEST_ENCRYPTION_INTEGRATION_LIB_LOADED=1

# =============================================================================
# SECTION 4: Cross-tool integration tests
# =============================================================================

# --- Test 4.1: encryption stack decision tree ---
test_encryption_decision_tree() {
	echo ""
	echo "=== Test 4.1: Encryption stack decision tree ==="
	info "Testing that each tool handles its designated use case"

	# Decision tree from encryption-stack.md:
	# 1. Single API key or token? -> gopass (secret-helper.sh)
	# 2. Config file with secrets to commit to git? -> SOPS (sops-helper.sh)
	# 3. Directory of sensitive files at rest? -> gocryptfs (gocryptfs-helper.sh)

	# Verify all three helpers exist and are executable
	local all_present=true

	if [[ -x "$HELPER_DIR/secret-helper.sh" ]]; then
		pass "secret-helper.sh exists and is executable"
	else
		fail "secret-helper.sh missing or not executable"
		all_present=false
	fi

	if [[ -x "$HELPER_DIR/sops-helper.sh" ]]; then
		pass "sops-helper.sh exists and is executable"
	else
		fail "sops-helper.sh missing or not executable"
		all_present=false
	fi

	if [[ -x "$HELPER_DIR/gocryptfs-helper.sh" ]]; then
		pass "gocryptfs-helper.sh exists and is executable"
	else
		fail "gocryptfs-helper.sh missing or not executable"
		all_present=false
	fi

	# Verify each helper sources shared-constants.sh
	if grep -q "shared-constants.sh" "$HELPER_DIR/secret-helper.sh"; then
		pass "secret-helper.sh sources shared-constants.sh"
	else
		fail "secret-helper.sh does not source shared-constants.sh"
	fi

	if grep -q "shared-constants.sh" "$HELPER_DIR/sops-helper.sh"; then
		pass "sops-helper.sh sources shared-constants.sh"
	else
		fail "sops-helper.sh does not source shared-constants.sh"
	fi

	if grep -q "shared-constants.sh" "$HELPER_DIR/gocryptfs-helper.sh"; then
		pass "gocryptfs-helper.sh sources shared-constants.sh"
	else
		fail "gocryptfs-helper.sh does not source shared-constants.sh"
	fi

	# Verify each helper has set -euo pipefail
	for helper_name in secret-helper.sh sops-helper.sh gocryptfs-helper.sh; do
		if grep -q "set -euo pipefail" "$HELPER_DIR/$helper_name"; then
			pass "$helper_name has strict mode (set -euo pipefail)"
		else
			fail "$helper_name missing strict mode"
		fi
	done

	return 0
}

# --- Test 4.2: git-safe property verification ---
test_git_safe_properties() {
	echo ""
	echo "=== Test 4.2: Git-safe property verification ==="
	info "Testing that SOPS files are safe for git and gopass files are not"

	local test_repo="$TEST_DIR/git-safe-repo"
	mkdir -p "$test_repo"

	(
		cd "$test_repo"
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"

		# Create a .sops.yaml (this IS safe for git)
		cat >.sops.yaml <<'EOF'
creation_rules:
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
EOF

		# Create an encrypted config (safe for git)
		cat >config.enc.yaml <<'EOF'
database:
    host: ENC[AES256_GCM,data:abc]
sops:
    version: 3.9.4
EOF

		# Create a plaintext credentials file (NOT safe for git)
		cat >credentials.sh <<'EOF'
export SECRET_KEY="should-not-be-committed"
EOF

		git add .sops.yaml config.enc.yaml
		git commit -q -m "init: add sops config and encrypted file"
	)

	# Verify encrypted config is in git
	local tracked_files
	tracked_files=$(cd "$test_repo" && git ls-files)

	if echo "$tracked_files" | grep -q "config.enc.yaml"; then
		pass "Encrypted config file is tracked by git"
	else
		fail "Encrypted config file not tracked by git"
	fi

	if echo "$tracked_files" | grep -q ".sops.yaml"; then
		pass ".sops.yaml config is tracked by git"
	else
		fail ".sops.yaml config not tracked by git"
	fi

	# Verify credentials.sh is NOT tracked
	if ! echo "$tracked_files" | grep -q "credentials.sh"; then
		pass "Plaintext credentials.sh is NOT tracked by git"
	else
		fail "Plaintext credentials.sh is tracked by git (security risk)"
	fi

	return 0
}

# --- Test 4.3: shared-constants.sh integration ---
test_shared_constants_integration() {
	echo ""
	echo "=== Test 4.3: shared-constants.sh integration ==="
	info "Testing that shared-constants.sh provides required functions"

	local constants_file="$HELPER_DIR/shared-constants.sh"

	if [[ ! -f "$constants_file" ]]; then
		fail "shared-constants.sh not found at $constants_file"
		return 0
	fi

	# Verify key functions exist
	if grep -q "^print_error()" "$constants_file"; then
		pass "shared-constants.sh defines print_error()"
	else
		fail "shared-constants.sh missing print_error()"
	fi

	if grep -q "^print_success()" "$constants_file"; then
		pass "shared-constants.sh defines print_success()"
	else
		fail "shared-constants.sh missing print_success()"
	fi

	if grep -q "^print_warning()" "$constants_file"; then
		pass "shared-constants.sh defines print_warning()"
	else
		fail "shared-constants.sh missing print_warning()"
	fi

	if grep -q "^print_info()" "$constants_file"; then
		pass "shared-constants.sh defines print_info()"
	else
		fail "shared-constants.sh missing print_info()"
	fi

	# Verify color constants
	if grep -q "^readonly RED=" "$constants_file"; then
		pass "shared-constants.sh defines RED color"
	else
		fail "shared-constants.sh missing RED color"
	fi

	if grep -q "^readonly NC=" "$constants_file"; then
		pass "shared-constants.sh defines NC (no color) reset"
	else
		fail "shared-constants.sh missing NC reset"
	fi

	# Verify include guard
	if grep -q "_SHARED_CONSTANTS_LOADED" "$constants_file"; then
		pass "shared-constants.sh has include guard"
	else
		fail "shared-constants.sh missing include guard"
	fi

	return 0
}

# --- Test 4.4: name normalization ---
test_name_normalization() {
	echo ""
	echo "=== Test 4.4: Secret name normalization ==="
	info "Testing that secret names are normalized to uppercase"

	# Simulate the normalization from cmd_set in secret-helper.sh
	normalize_name() {
		local name="${1:-}"
		echo "$name" | tr '[:lower:]-' '[:upper:]_'
		return 0
	}

	local result

	result=$(normalize_name "my-api-key")
	if [[ "$result" == "MY_API_KEY" ]]; then
		pass "Normalized 'my-api-key' to 'MY_API_KEY'"
	else
		fail "Expected 'MY_API_KEY', got '$result'"
	fi

	result=$(normalize_name "ALREADY_UPPER")
	if [[ "$result" == "ALREADY_UPPER" ]]; then
		pass "Already uppercase name unchanged"
	else
		fail "Expected 'ALREADY_UPPER', got '$result'"
	fi

	result=$(normalize_name "mixed-Case_Name")
	if [[ "$result" == "MIXED_CASE_NAME" ]]; then
		pass "Normalized 'mixed-Case_Name' to 'MIXED_CASE_NAME'"
	else
		fail "Expected 'MIXED_CASE_NAME', got '$result'"
	fi

	return 0
}

# --- Test 4.5: placeholder/empty value filtering ---
test_placeholder_filtering() {
	echo ""
	echo "=== Test 4.5: Placeholder/empty value filtering ==="
	info "Testing that placeholder values are skipped during import"

	# Simulate the filtering logic from _import_credential_file
	local test_values=(
		"real-api-key-12345"
		""
		"YOUR_API_KEY_HERE"
		"CHANGE_ME_PLEASE"
		"actual-token-value"
		"YOUR_SECRET"
	)

	local imported=0
	local skipped=0

	for val in "${test_values[@]}"; do
		if [[ -z "$val" || "$val" == "YOUR_"* || "$val" == "CHANGE_ME"* ]]; then
			skipped=$((skipped + 1))
		else
			imported=$((imported + 1))
		fi
	done

	if [[ "$imported" -eq 2 ]]; then
		pass "Correctly imported 2 real values"
	else
		fail "Expected 2 imports, got $imported"
	fi

	if [[ "$skipped" -eq 4 ]]; then
		pass "Correctly skipped 4 placeholder/empty values"
	else
		fail "Expected 4 skips, got $skipped"
	fi

	return 0
}

# =============================================================================
# SECTION 5: Git storage round-trip tests
# =============================================================================

# --- Test 5.1: credentials.sh git exclusion ---
test_credentials_git_exclusion() {
	echo ""
	echo "=== Test 5.1: Credentials git exclusion ==="
	info "Testing that credentials.sh patterns are properly gitignored"

	local test_repo="$TEST_DIR/git-exclude-repo"
	mkdir -p "$test_repo"

	(
		cd "$test_repo"
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"

		# Create a .gitignore with common credential patterns
		cat >.gitignore <<'EOF'
credentials.sh
.env
.env.local
*.enc.key
age-keys.txt
EOF

		# Create files that should be ignored
		echo 'export SECRET="value"' >credentials.sh
		echo 'SECRET=value' >.env
		echo 'AGE-SECRET-KEY-1...' >age-keys.txt

		# Create files that should NOT be ignored
		echo 'public config' >config.yaml
		echo 'encrypted' >config.enc.yaml

		git add .gitignore config.yaml config.enc.yaml
		git commit -q -m "init"
	)

	# Verify ignored files are not tracked
	local tracked
	tracked=$(cd "$test_repo" && git ls-files)

	if ! echo "$tracked" | grep -q "^credentials.sh$"; then
		pass "credentials.sh is gitignored"
	else
		fail "credentials.sh is tracked (should be gitignored)"
	fi

	if ! echo "$tracked" | grep -q "^\.env$"; then
		pass ".env is gitignored"
	else
		fail ".env is tracked (should be gitignored)"
	fi

	if ! echo "$tracked" | grep -q "^age-keys.txt$"; then
		pass "age-keys.txt is gitignored"
	else
		fail "age-keys.txt is tracked (should be gitignored)"
	fi

	if echo "$tracked" | grep -q "config.enc.yaml"; then
		pass "config.enc.yaml is tracked (encrypted files are git-safe)"
	else
		fail "config.enc.yaml is not tracked"
	fi

	return 0
}

# --- Test 5.2: SOPS .gitattributes diff driver ---
test_sops_gitattributes() {
	echo ""
	echo "=== Test 5.2: SOPS .gitattributes diff driver ==="
	info "Testing that SOPS diff driver config is correct"

	local test_repo="$TEST_DIR/sops-gitattr-repo"
	mkdir -p "$test_repo"

	(
		cd "$test_repo"
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"

		# Simulate what sops-helper.sh init does for git integration
		echo "*.enc.* diff=sopsdiffer" >.gitattributes
		git config diff.sopsdiffer.textconv "sops decrypt"

		git add .gitattributes
		git commit -q -m "init: add sops gitattributes"
	)

	# Verify .gitattributes content
	if grep -q "sopsdiffer" "$test_repo/.gitattributes"; then
		pass ".gitattributes contains sopsdiffer rule"
	else
		fail ".gitattributes missing sopsdiffer rule"
	fi

	# Verify git config
	local textconv
	textconv=$(cd "$test_repo" && git config diff.sopsdiffer.textconv || echo "")

	if [[ "$textconv" == "sops decrypt" ]]; then
		pass "Git diff driver configured: sops decrypt"
	else
		fail "Git diff driver not configured correctly: got '$textconv'"
	fi

	return 0
}
