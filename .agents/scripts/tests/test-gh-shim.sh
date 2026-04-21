#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for the gh PATH shim (t2685)
# =============================================================================
# Verifies:
#   1. Non-write subcommands pass through unchanged (fast path)
#   2. `gh issue comment --body` without marker gets sig appended
#   3. `gh issue comment --body` with marker passes through unchanged
#   4. `gh issue comment --body-file` without marker gets sig appended to file
#   5. `gh issue comment --body-file` with marker passes through
#   6. `gh pr create --body` without marker gets sig appended
#   7. `AIDEVOPS_GH_SHIM_DISABLE=1` bypasses the shim entirely
#   8. Recursion guard: `_AIDEVOPS_GH_SHIM_ACTIVE=1` triggers pass-through
#
# Strategy: run the shim against a stub `gh` binary that logs its args, and
# a stub `gh-signature-helper.sh` that emits a predictable footer. Assert
# the stub captured the expected (possibly modified) arg list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
SHIM="${REPO_DIR}/.agents/scripts/gh"

if [[ ! -x "$SHIM" ]]; then
	echo "FAIL: $SHIM not executable (expected at .agents/scripts/gh)"
	exit 1
fi

PASS=0
FAIL=0

_pass() {
	echo "  PASS: $1"
	PASS=$((PASS + 1))
	return 0
}

_fail() {
	echo "  FAIL: $1"
	[[ -n "${2:-}" ]] && echo "    $2"
	FAIL=$((FAIL + 1))
	return 0
}

# -----------------------------------------------------------------------------
# Test harness: build a tmp dir with stub gh + stub sig helper, point shim at them
# -----------------------------------------------------------------------------

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gh-shim-test)
trap 'rm -rf "$TMP"' EXIT

# Stub real gh — writes its argv (one per line) to $STUB_GH_LOG and
# exits 0. The shim will exec this when forwarding.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh that logs argv
: >"$STUB_GH_LOG"
for arg in "$@"; do
	printf '%s\n' "$arg" >>"$STUB_GH_LOG"
done
EOF
chmod +x "$TMP/bin/gh"

# Stub sig helper — emits a predictable footer with the canonical marker
mkdir -p "$TMP/scripts"
cat >"$TMP/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
# Stub emits fixed footer so tests are deterministic.
printf '\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) v9.9.9 stub footer\n'
EOF
chmod +x "$TMP/scripts/gh-signature-helper.sh"

# Copy the shim next to the stub helper so the shim's relative lookup
# (first candidate: $_SHIM_DIR/gh-signature-helper.sh) picks up OUR stub
# instead of the real one installed in ~/.aidevops/agents/scripts/.
cp "$SHIM" "$TMP/scripts/gh"
chmod +x "$TMP/scripts/gh"

# Put stub gh in PATH (for shim's REAL_GH discovery) and the shim in
# $TMP/scripts (for direct invocation in tests).
export PATH="$TMP/bin:$PATH"
export STUB_GH_LOG="$TMP/gh-argv.log"

SHIM_RUN="$TMP/scripts/gh"

# Convenience: read the stub gh log into a single string
_read_argv() {
	[[ -f "$STUB_GH_LOG" ]] || {
		echo "(no log)"
		return 0
	}
	cat "$STUB_GH_LOG"
	return 0
}

_reset_log() {
	: >"$STUB_GH_LOG"
	return 0
}

# =============================================================================
# Test 1: Non-write subcommand passes through unchanged (fast path)
# =============================================================================
echo "Test 1: non-write subcommand pass-through"
_reset_log
"$SHIM_RUN" --version 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == "--version" ]]; then
	_pass "gh --version passes through unchanged"
else
	_fail "gh --version pass-through" "got argv: $argv"
fi

# =============================================================================
# Test 2: gh issue comment --body without marker gets sig appended
# =============================================================================
echo ""
echo "Test 2: --body without marker gets sig appended"
_reset_log
"$SHIM_RUN" issue comment 123 --repo owner/repo --body "plain body text" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "sig marker appended to --body value"
else
	_fail "--body sig injection" "argv: $argv"
fi
if [[ "$argv" == *"plain body text"* ]]; then
	_pass "original body preserved"
else
	_fail "--body original content preservation" "argv: $argv"
fi

# =============================================================================
# Test 3: gh issue comment --body with marker passes through unchanged
# =============================================================================
echo ""
echo "Test 3: --body already signed is idempotent"
_reset_log
signed_body="already signed

<!-- aidevops:sig -->
---
prior sig"
"$SHIM_RUN" issue comment 123 --repo owner/repo --body "$signed_body" 2>/dev/null
argv=$(_read_argv)
# Count marker occurrences — should be exactly 1 (not doubled)
marker_count=$(grep -c "<!-- aidevops:sig -->" "$STUB_GH_LOG" 2>/dev/null || echo 0)
if [[ "$marker_count" -eq 1 ]]; then
	_pass "signed --body not double-injected"
else
	_fail "--body idempotency" "marker appeared $marker_count times, expected 1"
fi

# =============================================================================
# Test 4: gh issue comment --body-file without marker gets sig appended to file
# =============================================================================
echo ""
echo "Test 4: --body-file without marker gets sig appended"
body_file="$TMP/body.md"
printf 'unsigned body content\n' >"$body_file"
_reset_log
"$SHIM_RUN" issue comment 456 --repo owner/repo --body-file "$body_file" 2>/dev/null
if grep -q "<!-- aidevops:sig -->" "$body_file"; then
	_pass "sig marker appended to --body-file"
else
	_fail "--body-file sig injection" "file contents: $(cat "$body_file")"
fi
if grep -q "unsigned body content" "$body_file"; then
	_pass "original --body-file content preserved"
else
	_fail "--body-file original preservation" ""
fi

# =============================================================================
# Test 5: gh issue comment --body-file with marker is idempotent
# =============================================================================
echo ""
echo "Test 5: --body-file already signed is idempotent"
signed_file="$TMP/signed.md"
printf 'already signed\n\n<!-- aidevops:sig -->\n---\nprior sig\n' >"$signed_file"
size_before=$(wc -c <"$signed_file" | tr -d ' ')
_reset_log
"$SHIM_RUN" issue comment 789 --repo owner/repo --body-file "$signed_file" 2>/dev/null
size_after=$(wc -c <"$signed_file" | tr -d ' ')
if [[ "$size_before" == "$size_after" ]]; then
	_pass "signed --body-file not modified (idempotent)"
else
	_fail "--body-file idempotency" "size changed $size_before -> $size_after"
fi

# =============================================================================
# Test 6: gh pr create --body without marker gets sig appended
# =============================================================================
echo ""
echo "Test 6: gh pr create --body injection"
_reset_log
"$SHIM_RUN" pr create --repo owner/repo --title "test" --body "PR body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "gh pr create --body sig injected"
else
	_fail "gh pr create injection" "argv: $argv"
fi

# =============================================================================
# Test 7: AIDEVOPS_GH_SHIM_DISABLE=1 bypasses the shim
# =============================================================================
echo ""
echo "Test 7: AIDEVOPS_GH_SHIM_DISABLE=1 bypass"
_reset_log
AIDEVOPS_GH_SHIM_DISABLE=1 "$SHIM_RUN" issue comment 999 --repo owner/repo --body "unsigned" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"<!-- aidevops:sig -->"* ]]; then
	_pass "AIDEVOPS_GH_SHIM_DISABLE=1 skips sig injection"
else
	_fail "bypass env var" "sig was still injected; argv: $argv"
fi

# =============================================================================
# Test 8: Recursion guard
# =============================================================================
echo ""
echo "Test 8: recursion guard"
_reset_log
_AIDEVOPS_GH_SHIM_ACTIVE=1 "$SHIM_RUN" issue comment 111 --repo owner/repo --body "recursive" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" != *"<!-- aidevops:sig -->"* ]]; then
	_pass "recursion guard skips injection"
else
	_fail "recursion guard" "sig was injected despite guard; argv: $argv"
fi

# =============================================================================
# Test 9: --body=value equals form
# =============================================================================
echo ""
echo "Test 9: --body=value equals form"
_reset_log
"$SHIM_RUN" issue comment 222 --repo owner/repo "--body=equals form body" 2>/dev/null
argv=$(_read_argv)
if [[ "$argv" == *"<!-- aidevops:sig -->"* ]]; then
	_pass "--body=value equals form gets sig"
else
	_fail "--body=value injection" "argv: $argv"
fi

# =============================================================================
# Test 10: gh api (arbitrary subcommand) passes through
# =============================================================================
echo ""
echo "Test 10: gh api passes through"
_reset_log
"$SHIM_RUN" api /user 2>/dev/null
argv=$(_read_argv)
expected=$'api\n/user'
if [[ "$argv" == "$expected" ]]; then
	_pass "gh api pass-through"
else
	_fail "gh api pass-through" "argv: $argv"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================================"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
