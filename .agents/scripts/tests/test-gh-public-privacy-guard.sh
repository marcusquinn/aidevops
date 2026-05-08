#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for public GitHub write privacy secret-material scanning.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
HELPER_SRC="${SCRIPT_DIR}/../privacy-guard-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '    %s\n' "$detail"
	fi
	FAIL=$((FAIL + 1))
	return 0
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gh-public-privacy-guard)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scripts"
cp "$HELPER_SRC" "$TMP/scripts/privacy-guard-helper.sh"

# Build the basename in pieces so the test source itself does not contain a
# token-looking fixture while still reproducing an aidevops helper filename with
# an embedded credential-prefix-shaped substring.
ALLOWED_BASENAME="ta""sk-dispatch-helper.sh"
touch "$TMP/scripts/$ALLOWED_BASENAME"

# shellcheck source=/dev/null
source "$TMP/scripts/privacy-guard-helper.sh"

printf '=== gh public privacy guard tests ===\n\n'

out=$(privacy_scan_secret_material_text "Worker guidance: edit .agents/scripts/$ALLOWED_BASENAME" 2>"$TMP/allow-path.err")
rc=$?
err=$(<"$TMP/allow-path.err")
if [[ "$rc" -eq 0 && -z "$out" && "$err" == *'[privacy-scan][ALLOW] aidevops script file reference'* ]]; then
	pass "aidevops script path reference is allowed with allowlist output"
else
	fail "aidevops script path reference" "rc=$rc out=$out err=$err"
fi

precomputed_input="Worker guidance: edit .agents/scripts/$ALLOWED_BASENAME"
redacted=$(_privacy_redact_aidevops_script_references "$precomputed_input" "$ALLOWED_BASENAME")
if [[ "$redacted" == *'[aidevops-script-reference]'* ]]; then
	pass "precomputed aidevops script basename allowlist is used"
else
	fail "precomputed aidevops script basename allowlist" "redacted=$redacted"
fi

redacted=$(_privacy_redact_aidevops_script_references "$precomputed_input" "")
if [[ "$redacted" == "$precomputed_input" ]]; then
	pass "empty precomputed aidevops script basename allowlist skips fallback discovery"
else
	fail "empty precomputed aidevops script basename allowlist" "redacted=$redacted"
fi

out=$(privacy_scan_secret_material_text "Reference basename \`$ALLOWED_BASENAME\` in the issue body" 2>"$TMP/allow-basename.err")
rc=$?
err=$(<"$TMP/allow-basename.err")
if [[ "$rc" -eq 0 && -z "$out" && "$err" == *'[privacy-scan][ALLOW] aidevops script file reference'* ]]; then
	pass "backticked aidevops script basename is allowed with allowlist output"
else
	fail "backticked aidevops script basename" "rc=$rc out=$out err=$err"
fi

synthetic_token="sk-""abcdefghijklmnopqrstuvwxyz"
out=$(privacy_scan_secret_material_text "Synthetic secret fixture: $synthetic_token" 2>"$TMP/block-secret.err")
rc=$?
if [[ "$rc" -eq 1 && "$out" == *'credential token prefix'* ]]; then
	pass "synthetic credential-like token remains blocked"
else
	fail "synthetic credential-like token" "rc=$rc out=$out"
fi

out=$(privacy_scan_secret_material_text "Filename-like but undocumented: ${synthetic_token}.sh" 2>"$TMP/block-undocumented.err")
rc=$?
if [[ "$rc" -eq 1 && "$out" == *'credential token prefix'* ]]; then
	pass "undocumented filename-like credential token remains blocked"
else
	fail "undocumented filename-like credential token" "rc=$rc out=$out"
fi

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
	printf '%d/%d tests passed\n' "$PASS" "$PASS"
	exit 0
fi

exit 1
