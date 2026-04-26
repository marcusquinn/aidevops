#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2888: Smoke test for setup_opencode_cli + _setup_validate_opencode_binary.
#
# Validates the install/heal logic added to .agents/scripts/setup/_services.sh.
# Companion to t2887 (which tests the runtime canary validator). This test
# focuses on the SETUP-time validator + behavioural shape of setup_opencode_cli
# without actually performing global npm/bun installs (we shim them).
#
# Test strategy:
#   1. Source _services.sh in a subshell with print_*, $HOME, PATH stubbed
#      so the script doesn't touch the real environment.
#   2. Verify _setup_validate_opencode_binary returns the right rc for each
#      synthetic binary (real opencode, claude CLI shim, missing, garbage).
#   3. Verify setup_opencode_cli writes ~/.aidevops/.opencode-bin-resolved
#      on the success path and returns 0 on the install-fail path
#      (fail-open contract).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICES_LIB="$REPO_ROOT/.agents/scripts/setup/_services.sh"

if [[ ! -f "$SERVICES_LIB" ]]; then
	echo "FAIL: cannot find $SERVICES_LIB" >&2
	exit 1
fi

# Sandbox dir for fake $HOME + fake bin shims.
SANDBOX="$(mktemp -d -t t2888-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home" "$SANDBOX/bin"
export HOME="$SANDBOX/home"

PASS=0
FAIL=0

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $desc"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $desc -- expected '$expected', got '$actual'" >&2
	FAIL=$((FAIL + 1))
	return 1
}

# Source the lib in a subshell with stubbed print helpers.
source_lib() {
	# shellcheck disable=SC2317  # functions used after sourcing in subshell
	print_info() { echo "INFO: $*"; return 0; }
	# shellcheck disable=SC2317
	print_success() { echo "OK: $*"; return 0; }
	# shellcheck disable=SC2317
	print_warning() { echo "WARN: $*"; return 0; }
	export -f print_info print_success print_warning 2>/dev/null || true
	# shellcheck disable=SC1090
	source "$SERVICES_LIB"
	return 0
}

# --- Test 1: validator rc for a real-shaped opencode binary -----------------
echo "Test 1: _setup_validate_opencode_binary on real opencode shim"
cat >"$SANDBOX/bin/opencode-real" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
EOF
chmod +x "$SANDBOX/bin/opencode-real"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-real" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1" 2>&1
rc1=$(tail -1 "$SANDBOX/out1")
assert_eq "real opencode -> rc=0" "0" "$rc1"

# --- Test 2: validator rc for claude CLI shim -------------------------------
echo "Test 2: _setup_validate_opencode_binary on claude CLI shim"
cat >"$SANDBOX/bin/opencode-claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "2.1.119 (Claude Code)"
EOF
chmod +x "$SANDBOX/bin/opencode-claude"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-claude" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2" 2>&1
rc2=$(tail -1 "$SANDBOX/out2")
assert_eq "claude shim -> rc=1" "1" "$rc2"

# --- Test 3: validator rc for missing binary --------------------------------
echo "Test 3: _setup_validate_opencode_binary on missing path"
(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/does-not-exist" || rc=$?
	echo "$rc"
) >"$SANDBOX/out3" 2>&1
rc3=$(tail -1 "$SANDBOX/out3")
assert_eq "missing path -> rc=2" "2" "$rc3"

# --- Test 4: validator rc for garbage version output ------------------------
echo "Test 4: _setup_validate_opencode_binary on garbage shim"
cat >"$SANDBOX/bin/opencode-garbage" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "not-a-version"
EOF
chmod +x "$SANDBOX/bin/opencode-garbage"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-garbage" || rc=$?
	echo "$rc"
) >"$SANDBOX/out4" 2>&1
rc4=$(tail -1 "$SANDBOX/out4")
assert_eq "garbage version -> rc=1" "1" "$rc4"

# --- Test 5: setup_opencode_cli skips install when current binary is valid --
echo "Test 5: setup_opencode_cli skip-when-valid + persists resolved path"
(
	source_lib
	export OPENCODE_BIN="$SANDBOX/bin/opencode-real"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out5" 2>&1
rc5=$(grep '^rc=' "$SANDBOX/out5" | tail -1)
resolved5=$(tail -1 "$SANDBOX/out5")
assert_eq "skip-when-valid rc" "rc=0" "$rc5"
assert_eq "skip-when-valid resolved-path file" "$SANDBOX/bin/opencode-real" "$resolved5"

# --- Test 6: setup_opencode_cli fail-open when no installer present ---------
echo "Test 6: setup_opencode_cli fail-open when no bun/npm + invalid current"
# Wipe persisted file from previous test so we can confirm it stays absent.
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
(
	source_lib
	# Force minimal PATH so neither bun nor npm resolves; supply only the
	# claude shim under the name 'opencode'.
	rm -f "$SANDBOX/bin/opencode"
	cp "$SANDBOX/bin/opencode-claude" "$SANDBOX/bin/opencode"
	export PATH="$SANDBOX/bin"
	export OPENCODE_BIN=""
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out6" 2>&1
rc6=$(grep '^rc=' "$SANDBOX/out6" | tail -1)
no_installer_msg=$(grep -c "Neither bun nor npm" "$SANDBOX/out6" || true)
assert_eq "fail-open rc" "rc=0" "$rc6"
assert_eq "fail-open emits remediation hint" "1" "$no_installer_msg"

echo ""
echo "===== Results: $PASS passed, $FAIL failed ====="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
