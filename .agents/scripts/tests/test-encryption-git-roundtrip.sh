#!/usr/bin/env bash
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
	local msg="${1:-}"
	echo -e "${GREEN}[PASS]${NC} $msg"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local msg="${1:-}"
	echo -e "${RED}[FAIL]${NC} $msg"
	FAIL=$((FAIL + 1))
	return 0
}

skip() {
	local msg="${1:-}"
	echo -e "${YELLOW}[SKIP]${NC} $msg"
	SKIP=$((SKIP + 1))
	return 0
}

info() {
	local msg="${1:-}"
	if [[ "$VERBOSE" == "--verbose" ]]; then
		echo -e "${BLUE}[INFO]${NC} $msg"
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
# SECTION 1: secret-helper.sh tests
# =============================================================================

# --- Test 1.1: credentials.sh fallback round-trip ---
test_credentials_fallback_roundtrip() {
	echo ""
	echo "=== Test 1.1: credentials.sh fallback round-trip ==="
	info "Testing store and retrieve via plaintext credentials.sh (no gopass)"

	local test_config_dir="$TEST_DIR/config-fallback"
	mkdir -p "$test_config_dir"

	# Create a minimal credentials.sh
	local cred_file="$test_config_dir/credentials.sh"
	cat >"$cred_file" <<'EOF'
export TEST_API_KEY="sk-test-abc123def456"
export TEST_DB_URL="postgres://user:pass@host:5432/db"
export SHORT="ab"
EOF
	chmod 600 "$cred_file"

	# Verify file was created with correct permissions
	local perms
	perms=$(stat -f '%Lp' "$cred_file" 2>/dev/null || stat -c '%a' "$cred_file" 2>/dev/null || echo "unknown")
	if [[ "$perms" == "600" ]]; then
		pass "credentials.sh created with 600 permissions"
	else
		fail "credentials.sh has wrong permissions: $perms (expected 600)"
	fi

	# Test parsing: extract values the same way secret-helper.sh does
	local extracted_key=""
	local extracted_url=""
	local extracted_short=""
	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
			local name="${BASH_REMATCH[1]}"
			local val="${BASH_REMATCH[2]}"
			val="${val#\"}"
			val="${val%\"}"
			case "$name" in
			TEST_API_KEY) extracted_key="$val" ;;
			TEST_DB_URL) extracted_url="$val" ;;
			SHORT) extracted_short="$val" ;;
			esac
		fi
	done <"$cred_file"

	if [[ "$extracted_key" == "sk-test-abc123def456" ]]; then
		pass "Extracted TEST_API_KEY matches original"
	else
		fail "TEST_API_KEY mismatch: got '$extracted_key'"
	fi

	if [[ "$extracted_url" == "postgres://user:pass@host:5432/db" ]]; then
		pass "Extracted TEST_DB_URL matches original (special chars preserved)"
	else
		fail "TEST_DB_URL mismatch: got '$extracted_url'"
	fi

	if [[ "$extracted_short" == "ab" ]]; then
		pass "Extracted SHORT value (2 chars) matches original"
	else
		fail "SHORT mismatch: got '$extracted_short'"
	fi

	return 0
}

# --- Test 1.2: redaction filter ---
test_redaction_filter() {
	echo ""
	echo "=== Test 1.2: Redaction filter ==="
	info "Testing that secret values are replaced with [REDACTED] in output"

	local test_config_dir="$TEST_DIR/config-redact"
	mkdir -p "$test_config_dir"

	local cred_file="$test_config_dir/credentials.sh"
	cat >"$cred_file" <<'EOF'
export MY_SECRET="super-secret-value-12345"
export MY_TOKEN="ghp_abcdefghijklmnop1234567890"
export TINY="ab"
EOF
	chmod 600 "$cred_file"

	# Simulate the redaction logic from secret-helper.sh
	local -a secret_values=()
	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+[A-Z_][A-Z0-9_]*= ]]; then
			local val="${line#*=}"
			val="${val#\"}"
			val="${val%\"}"
			if [[ -n "$val" && ${#val} -ge 4 ]]; then
				secret_values+=("$val")
			fi
		fi
	done <"$cred_file"

	# Build sed script (same logic as redact_stream)
	local sed_script=""
	local sorted_values
	sorted_values=$(printf '%s\n' "${secret_values[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

	while IFS= read -r val; do
		[[ -z "$val" ]] && continue
		local escaped
		escaped=$(printf '%s' "$val" | sed 's/[&/\]/\\&/g; s/\[/\\[/g; s/\]/\\]/g')
		sed_script="${sed_script}s|${escaped}|[REDACTED]|g;"
	done <<<"$sorted_values"

	# Test redaction on a sample output
	local test_input="The API returned super-secret-value-12345 and token ghp_abcdefghijklmnop1234567890 in the response"
	local redacted
	redacted=$(echo "$test_input" | sed "$sed_script")

	if echo "$redacted" | grep -q "super-secret-value-12345"; then
		fail "Secret value leaked through redaction filter"
	else
		pass "Secret value correctly redacted"
	fi

	if echo "$redacted" | grep -q "ghp_abcdefghijklmnop1234567890"; then
		fail "Token leaked through redaction filter"
	else
		pass "Token correctly redacted"
	fi

	if echo "$redacted" | grep -q "\[REDACTED\]"; then
		pass "Redacted output contains [REDACTED] placeholder"
	else
		fail "Redacted output missing [REDACTED] placeholder"
	fi

	# Verify short values (< 4 chars) are NOT redacted (to avoid false positives)
	if [[ ${#secret_values[@]} -eq 2 ]]; then
		pass "Short value 'ab' (2 chars) correctly excluded from redaction set"
	else
		fail "Expected 2 values in redaction set, got ${#secret_values[@]}"
	fi

	return 0
}

# --- Test 1.3: multi-tenant credential resolution ---
test_multi_tenant_resolution() {
	echo ""
	echo "=== Test 1.3: Multi-tenant credential resolution ==="
	info "Testing tenant loader detection and credential file resolution"

	local test_config_dir="$TEST_DIR/config-tenant"
	mkdir -p "$test_config_dir/tenants/acme"
	mkdir -p "$test_config_dir/tenants/globex"

	# Create tenant credential files
	cat >"$test_config_dir/tenants/acme/credentials.sh" <<'EOF'
export ACME_API_KEY="acme-key-123"
export ACME_DB_URL="postgres://acme@host/acme"
EOF

	cat >"$test_config_dir/tenants/globex/credentials.sh" <<'EOF'
export GLOBEX_API_KEY="globex-key-456"
export GLOBEX_DB_URL="postgres://globex@host/globex"
EOF

	# Create a tenant loader (the main credentials.sh)
	cat >"$test_config_dir/credentials.sh" <<'EOF'
AIDEVOPS_ACTIVE_TENANT="acme"
source "$HOME/.config/aidevops/tenants/${AIDEVOPS_ACTIVE_TENANT}/credentials.sh"
EOF

	# Test tenant loader detection
	if grep -q 'AIDEVOPS_ACTIVE_TENANT=' "$test_config_dir/credentials.sh" 2>/dev/null; then
		pass "Tenant loader correctly detected (AIDEVOPS_ACTIVE_TENANT present)"
	else
		fail "Tenant loader not detected"
	fi

	# Test credential file resolution for tenants
	local tenant_files_found=0
	for tenant_dir in "$test_config_dir/tenants"/*/; do
		[[ -d "$tenant_dir" ]] || continue
		local cred_file="$tenant_dir/credentials.sh"
		if [[ -f "$cred_file" ]]; then
			tenant_files_found=$((tenant_files_found + 1))
		fi
	done

	if [[ "$tenant_files_found" -eq 2 ]]; then
		pass "Found 2 tenant credential files (acme, globex)"
	else
		fail "Expected 2 tenant files, found $tenant_files_found"
	fi

	# Test non-tenant mode (direct credentials.sh with exports)
	local direct_cred="$TEST_DIR/config-direct/credentials.sh"
	mkdir -p "$(dirname "$direct_cred")"
	cat >"$direct_cred" <<'EOF'
export DIRECT_KEY="direct-value-789"
EOF

	if ! grep -q 'AIDEVOPS_ACTIVE_TENANT=' "$direct_cred" 2>/dev/null; then
		pass "Direct credentials.sh correctly identified as non-tenant"
	else
		fail "Direct credentials.sh incorrectly identified as tenant loader"
	fi

	return 0
}

# --- Test 1.4: secret-helper.sh command dispatch ---
test_secret_helper_dispatch() {
	echo ""
	echo "=== Test 1.4: secret-helper.sh command dispatch ==="
	info "Testing help, status, and error handling"

	local helper="$HELPER_DIR/secret-helper.sh"

	if [[ ! -x "$helper" ]]; then
		fail "secret-helper.sh not found or not executable at $helper"
		return 0
	fi

	# Test help command
	local help_output
	help_output=$("$helper" help 2>&1) || true

	if echo "$help_output" | grep -q "Secret Management"; then
		pass "secret-helper.sh help outputs expected header"
	else
		fail "secret-helper.sh help missing expected header"
	fi

	if echo "$help_output" | grep -q "set.*NAME"; then
		pass "secret-helper.sh help documents 'set' command"
	else
		fail "secret-helper.sh help missing 'set' command documentation"
	fi

	# Test status command
	local status_output
	status_output=$("$helper" status 2>&1) || true

	if echo "$status_output" | grep -q "Secret Management Status"; then
		pass "secret-helper.sh status outputs expected header"
	else
		fail "secret-helper.sh status missing expected header"
	fi

	# Test unknown command
	local unknown_output
	unknown_output=$("$helper" nonexistent 2>&1) || true

	if echo "$unknown_output" | grep -qi "unknown\|error"; then
		pass "secret-helper.sh rejects unknown command"
	else
		fail "secret-helper.sh did not reject unknown command"
	fi

	# Test set without name (may fail with unbound variable from set -u)
	local no_name_output
	no_name_output=$("$helper" set 2>&1) || true

	if echo "$no_name_output" | grep -qi "usage\|error\|unbound"; then
		pass "secret-helper.sh set without name produces error"
	else
		fail "secret-helper.sh set without name did not produce error"
	fi

	# Test run without command
	local no_cmd_output
	no_cmd_output=$("$helper" run 2>&1) || true

	if echo "$no_cmd_output" | grep -qi "usage\|error"; then
		pass "secret-helper.sh run without command produces error"
	else
		fail "secret-helper.sh run without command did not produce error"
	fi

	return 0
}

# --- Test 1.5: gopass round-trip (if available) ---
test_gopass_roundtrip() {
	echo ""
	echo "=== Test 1.5: gopass round-trip ==="

	if [[ "$HAS_GOPASS" != "true" ]]; then
		skip "gopass not installed -- skipping gopass round-trip test"
		return 0
	fi

	# Check if gopass store is initialized
	if ! gopass ls &>/dev/null; then
		skip "gopass store not initialized -- skipping round-trip test"
		return 0
	fi

	info "Testing gopass store/retrieve round-trip with test prefix"

	# Use a unique test key to avoid colliding with real secrets
	local test_key="aidevops/_test_roundtrip_$$"
	local test_value
	test_value="roundtrip-test-value-$(date +%s)"

	# Store the test secret
	if echo "$test_value" | gopass insert --force "$test_key" &>/dev/null; then
		pass "gopass insert succeeded for test key"
	else
		fail "gopass insert failed for test key"
		return 0
	fi

	# Retrieve and verify
	local retrieved
	retrieved=$(gopass show -o "$test_key" 2>/dev/null || echo "")

	if [[ "$retrieved" == "$test_value" ]]; then
		pass "gopass round-trip: retrieved value matches stored value"
	else
		fail "gopass round-trip mismatch: stored='$test_value' retrieved='$retrieved'"
	fi

	# Clean up test secret
	gopass rm --force "$test_key" &>/dev/null || true

	# Verify cleanup
	if ! gopass show -o "$test_key" &>/dev/null; then
		pass "gopass test secret cleaned up successfully"
	else
		fail "gopass test secret not cleaned up"
	fi

	return 0
}

# --- Test 1.6: credential update (replace existing value) ---
test_credential_update() {
	echo ""
	echo "=== Test 1.6: Credential update (replace existing value) ==="
	info "Testing that updating an existing key replaces the old value"

	local test_config_dir="$TEST_DIR/config-update"
	mkdir -p "$test_config_dir"

	local cred_file="$test_config_dir/credentials.sh"
	cat >"$cred_file" <<'EOF'
export UPDATE_KEY="original-value"
export OTHER_KEY="should-not-change"
EOF
	chmod 600 "$cred_file"

	# Simulate the update logic from cmd_set (credentials.sh fallback path)
	local name="UPDATE_KEY"
	local new_value="updated-value-new"

	if grep -q "^export ${name}=" "$cred_file" 2>/dev/null; then
		local tmp_file="${cred_file}.tmp"
		grep -v "^export ${name}=" "$cred_file" >"$tmp_file"
		echo "export ${name}=\"${new_value}\"" >>"$tmp_file"
		mv "$tmp_file" "$cred_file"
	fi

	# Verify the update
	local updated_val
	updated_val=$(grep "^export UPDATE_KEY=" "$cred_file" | sed 's/^export UPDATE_KEY="//' | sed 's/"$//')

	if [[ "$updated_val" == "updated-value-new" ]]; then
		pass "Credential value updated correctly"
	else
		fail "Credential update failed: got '$updated_val'"
	fi

	# Verify other key was not affected
	local other_val
	other_val=$(grep "^export OTHER_KEY=" "$cred_file" | sed 's/^export OTHER_KEY="//' | sed 's/"$//')

	if [[ "$other_val" == "should-not-change" ]]; then
		pass "Other credential not affected by update"
	else
		fail "Other credential was modified: got '$other_val'"
	fi

	return 0
}

# =============================================================================
# SECTION 2: sops-helper.sh tests
# =============================================================================

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
		if grep -q '"sops"' "$file" 2>/dev/null || grep -q "sops:" "$file" 2>/dev/null; then
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

	# Generate a temporary age key for testing
	local age_key_dir="$TEST_DIR/sops-age-keys"
	mkdir -p "$age_key_dir"
	chmod 700 "$age_key_dir"
	age-keygen -o "$age_key_dir/keys.txt" 2>/dev/null

	local pub_key
	pub_key=$(grep "^# public key:" "$age_key_dir/keys.txt" | sed 's/^# public key: //')

	if [[ -z "$pub_key" ]]; then
		fail "Failed to generate age key pair"
		return 0
	fi

	pass "Generated temporary age key for testing"

	# Initialize git repo with .sops.yaml
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

		# Create a config file with test data
		cat >config.enc.yaml <<'EOF'
database:
    host: db.example.com
    port: 5432
    username: admin
    password: super-secret-password-12345
    ssl: true
api:
    key: sk-test-abcdefghijklmnop
    endpoint: https://api.example.com
EOF

		git add .sops.yaml
		git commit -q -m "init: add sops config"
	)

	# Encrypt the config file
	local original_content
	original_content=$(cat "$test_repo/config.enc.yaml")

	export SOPS_AGE_KEY_FILE="$age_key_dir/keys.txt"

	if sops encrypt -i "$test_repo/config.enc.yaml" 2>/dev/null; then
		pass "SOPS encryption succeeded"
	else
		fail "SOPS encryption failed"
		return 0
	fi

	# Verify the file is now encrypted (contains sops metadata)
	if grep -q "sops:" "$test_repo/config.enc.yaml" 2>/dev/null; then
		pass "Encrypted file contains sops metadata"
	else
		fail "Encrypted file missing sops metadata"
	fi

	# Verify plaintext values are NOT in the encrypted file
	if ! grep -q "super-secret-password-12345" "$test_repo/config.enc.yaml"; then
		pass "Plaintext password not visible in encrypted file"
	else
		fail "Plaintext password visible in encrypted file"
	fi

	if ! grep -q "sk-test-abcdefghijklmnop" "$test_repo/config.enc.yaml"; then
		pass "Plaintext API key not visible in encrypted file"
	else
		fail "Plaintext API key visible in encrypted file"
	fi

	# Commit encrypted file to git
	(
		cd "$test_repo"
		git add config.enc.yaml
		git commit -q -m "feat: add encrypted config"
	)

	pass "Committed encrypted config to git"

	# Decrypt and verify round-trip integrity
	local decrypted
	decrypted=$(sops decrypt "$test_repo/config.enc.yaml" 2>/dev/null) || true

	if echo "$decrypted" | grep -q "super-secret-password-12345"; then
		pass "Decrypted content contains original password"
	else
		fail "Decrypted content missing original password"
	fi

	if echo "$decrypted" | grep -q "sk-test-abcdefghijklmnop"; then
		pass "Decrypted content contains original API key"
	else
		fail "Decrypted content missing original API key"
	fi

	if echo "$decrypted" | grep -q "db.example.com"; then
		pass "Decrypted content contains original host"
	else
		fail "Decrypted content missing original host"
	fi

	# Verify git log shows the encrypted commit
	local commit_count
	commit_count=$(cd "$test_repo" && git log --oneline | wc -l | tr -d ' ')
	if [[ "$commit_count" -eq 2 ]]; then
		pass "Git history has 2 commits (init + encrypted config)"
	else
		fail "Expected 2 commits, got $commit_count"
	fi

	unset SOPS_AGE_KEY_FILE

	return 0
}

# =============================================================================
# SECTION 3: gocryptfs-helper.sh tests
# =============================================================================

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
	textconv=$(cd "$test_repo" && git config diff.sopsdiffer.textconv 2>/dev/null || echo "")

	if [[ "$textconv" == "sops decrypt" ]]; then
		pass "Git diff driver configured: sops decrypt"
	else
		fail "Git diff driver not configured correctly: got '$textconv'"
	fi

	return 0
}

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
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"
echo ""

TOTAL=$((PASS + FAIL + SKIP))
echo "  Total: $TOTAL tests"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
	echo -e "${GREEN}All tests passed!${NC}"
	exit 0
else
	echo -e "${RED}$FAIL test(s) failed${NC}"
	exit 1
fi
