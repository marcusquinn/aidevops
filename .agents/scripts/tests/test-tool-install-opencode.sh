#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2891: Smoke test for the active setup_opencode_cli function in
# setup-modules/tool-install.sh — the function that's actually sourced
# by setup.sh (line 753), as opposed to the orphan stub in
# .agents/scripts/setup/_services.sh that t2888 fixed.
#
# Strategy: source tool-install.sh in a sandbox, stub print_*, setup_prompt,
# run_with_spinner, npm_global_install. Verify the validator + force-heal
# logic without actually installing global packages.
#
# This complements .agents/scripts/tests/test-setup-opencode-cli.sh (t2888),
# which tests the orphan _services.sh stub. Both must keep their validator
# semantics in lockstep with t2887's headless-runtime-lib.sh::_validate_opencode_binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_INSTALL="$REPO_ROOT/setup-modules/tool-install.sh"

if [[ ! -f "$TOOL_INSTALL" ]]; then
	echo "FAIL: cannot find $TOOL_INSTALL" >&2
	exit 1
fi

SANDBOX="$(mktemp -d -t t2891-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/npm-stub"
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

# Source tool-install.sh in a subshell with stubs. tool-install.sh is large
# (~1900 lines) so we extract just the three relevant functions to avoid
# pulling in unrelated dependencies.
extract_functions() {
	# Use awk to extract the three functions by name.
	awk '
		/^_setup_validate_opencode_binary\(\)/, /^}$/ { print; next }
		/^_setup_opencode_force_heal\(\)/, /^}$/ { print; next }
		/^setup_opencode_cli\(\)/, /^}$/ { print; next }
	' "$TOOL_INSTALL" >"$SANDBOX/extract.sh"
	# Verify extraction worked
	if ! grep -q "^_setup_validate_opencode_binary()" "$SANDBOX/extract.sh"; then
		echo "FAIL: extraction did not capture _setup_validate_opencode_binary" >&2
		exit 1
	fi
	return 0
}
extract_functions

source_extracted() {
	# shellcheck disable=SC2317
	print_info() { echo "INFO: $*"; return 0; }
	# shellcheck disable=SC2317
	print_success() { echo "OK: $*"; return 0; }
	# shellcheck disable=SC2317
	print_warning() { echo "WARN: $*"; return 0; }
	# shellcheck disable=SC2317
	setup_prompt() { local _var="$1" _prompt="$2" _default="$3"; eval "$_var='$_default'"; return 0; }
	# shellcheck disable=SC2317
	run_with_spinner() { shift; "$@"; return $?; }
	# shellcheck disable=SC2317
	npm_global_install() {
		# Simulate install: drop a fake 'opencode' shim into the sandbox PATH
		# that returns a real-shaped opencode version.
		echo "[npm_global_install stub] $*" >&2
		cat >"$SANDBOX/bin/opencode" <<'INNER_EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
INNER_EOF
		chmod +x "$SANDBOX/bin/opencode"
		return 0
	}
	export -f print_info print_success print_warning setup_prompt run_with_spinner npm_global_install 2>/dev/null || true
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	return 0
}

# --- Test 1: validator on real opencode ------------------------------------
echo "Test 1: _setup_validate_opencode_binary on real opencode shim"
cat >"$SANDBOX/bin/opencode-real" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
EOF
chmod +x "$SANDBOX/bin/opencode-real"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-real" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1" 2>&1
assert_eq "real opencode -> rc=0" "0" "$(tail -1 "$SANDBOX/out1")"

# --- Test 2: validator on claude CLI shim ----------------------------------
echo "Test 2: _setup_validate_opencode_binary on claude CLI shim"
cat >"$SANDBOX/bin/opencode-claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "2.1.119 (Claude Code)"
EOF
chmod +x "$SANDBOX/bin/opencode-claude"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-claude" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2" 2>&1
assert_eq "claude shim -> rc=1" "1" "$(tail -1 "$SANDBOX/out2")"

# --- Test 3: validator on missing path -------------------------------------
echo "Test 3: _setup_validate_opencode_binary on missing path"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/does-not-exist" || rc=$?
	echo "$rc"
) >"$SANDBOX/out3" 2>&1
assert_eq "missing path -> rc=2" "2" "$(tail -1 "$SANDBOX/out3")"

# --- Test 4: setup_opencode_cli skip when valid + persists path ------------
echo "Test 4: setup_opencode_cli skip-when-valid path"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
cp "$SANDBOX/bin/opencode-real" "$SANDBOX/bin/opencode"
(
	source_extracted
	export PATH="$SANDBOX/bin:$PATH"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out4" 2>&1
rc4=$(grep '^rc=' "$SANDBOX/out4" | tail -1)
resolved4=$(tail -1 "$SANDBOX/out4")
assert_eq "skip-when-valid rc" "rc=0" "$rc4"
assert_eq "skip-when-valid resolved-path file" "$SANDBOX/bin/opencode" "$resolved4"

# --- Test 5: setup_opencode_cli auto-heal on wrong package -----------------
# Critical t2891 path: when 'opencode' resolves to claude CLI (rc=1),
# the function MUST trigger force-heal (calls npm_global_install) and
# NOT return early like the pre-fix code did.
echo "Test 5: setup_opencode_cli force-heal on claude CLI shim"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
cp "$SANDBOX/bin/opencode-claude" "$SANDBOX/bin/opencode"
(
	source_extracted
	export PATH="$SANDBOX/bin:$PATH"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out5" 2>&1
rc5=$(grep '^rc=' "$SANDBOX/out5" | tail -1)
heal_warned=$(grep -c "wrong package" "$SANDBOX/out5" || true)
heal_invoked=$(grep -c "npm_global_install stub" "$SANDBOX/out5" || true)
post_heal_success=$(grep -c "OpenCode CLI:.*1\.14\.25" "$SANDBOX/out5" || true)
assert_eq "force-heal rc" "rc=0" "$rc5"
assert_eq "force-heal warned about wrong package" "1" "$heal_warned"
assert_eq "force-heal invoked installer" "1" "$heal_invoked"
assert_eq "post-heal validation success" "1" "$post_heal_success"

# --- Test 6: post-heal persists resolved path ------------------------------
echo "Test 6: post-heal persisted resolved path"
[[ -f "$HOME/.aidevops/.opencode-bin-resolved" ]] && resolved6=$(cat "$HOME/.aidevops/.opencode-bin-resolved") || resolved6="MISSING"
assert_eq "post-heal resolved-path file populated" "$SANDBOX/bin/opencode" "$resolved6"

echo ""
echo "===== Results: $PASS passed, $FAIL failed ====="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
