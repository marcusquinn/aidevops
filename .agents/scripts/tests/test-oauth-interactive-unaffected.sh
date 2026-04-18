#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-oauth-interactive-unaffected.sh — t2249 regression guard.
#
# Asserts that a headless worker rotating its isolated auth does NOT
# touch the shared interactive auth file. This is the safety invariant
# that makes the t2249 fix acceptable — the rotation skip in PR #15099
# was defensive against shared-file corruption, and we must prove the
# skip is no longer necessary.
#
# Tests:
#   1. Shared auth bytes unchanged after pre-dispatch rotate of isolated
#   2. Shared auth mtime unchanged after pre-dispatch rotate
#   3. Extracted OPENCODE_AUTH_FILE with XDG set → does NOT point to shared
#
# Strategy: create both a "shared" file (simulating
# ~/.local/share/opencode/auth.json) and an "isolated" file in separate
# tmpdirs. Run the pre-dispatch rotation helper with XDG_DATA_HOME
# pointing at the isolated dir. Hash + stat the shared file before and
# after. Equality = no interference.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/headless-runtime-helper.sh"
OAUTH_HELPER="${SCRIPTS_DIR}/oauth-pool-helper.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
}

fail() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
}

[[ -f "$HELPER" ]] || { printf 'FATAL: %s\n' "$HELPER" >&2; exit 1; }
[[ -f "$OAUTH_HELPER" ]] || { printf 'FATAL: %s\n' "$OAUTH_HELPER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || {
	printf 'SKIP: jq not installed\n' >&2
	exit 0
}

printf '%s[test]%s t2249 — interactive shared auth.json remains byte-identical\n' "$TEST_BLUE" "$TEST_NC"

# Extract the function (as in test 2).
FN_DEF=$(bash -c "source '$HELPER' help >/dev/null 2>&1 || true; declare -f _maybe_rotate_isolated_auth")
[[ -n "$FN_DEF" ]] || { printf 'FATAL: function not extractable\n' >&2; exit 1; }

print_info() { :; }
print_warning() { :; }
eval "$FN_DEF"

# --- Fixture setup ----------------------------------------------------------

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t2249-interactive-unaffected.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/shared/opencode" "$TMP/isolated/opencode" "$TMP/bin"

# The "shared" auth.json represents ~/.local/share/opencode/auth.json.
cat >"$TMP/shared/opencode/auth.json" <<'JSON'
{
  "anthropic": {
    "type": "oauth",
    "access": "INTERACTIVE-access-token-DO-NOT-MUTATE",
    "refresh": "INTERACTIVE-refresh-token-DO-NOT-MUTATE",
    "email": "interactive@example.com"
  }
}
JSON
chmod 600 "$TMP/shared/opencode/auth.json"

# The isolated auth — production shape (access-only, no email) because
# build_auth_entry drops email on every rotation. This is the shape every
# worker inherits after the first rotation, and the shape the original
# t2249 PR failed to match, silently defeating rotation for every worker
# except the first one. The cooldown-marked account is identified by its
# access token in the pool.
cat >"$TMP/isolated/opencode/auth.json" <<'JSON'
{
  "anthropic": {
    "type": "oauth",
    "access": "PROD-access-marcusquinn-at-mac-com",
    "refresh": "PROD-refresh-marcusquinn-at-mac-com",
    "expires": 0
  }
}
JSON

# Shared pool: the cooldown-marked account carries both email AND access
# so either lookup path would resolve it. The rotation path exercised
# here is access-token match (because isolated has no email).
cat >"$TMP/pool.json" <<JSON
{
  "anthropic": [
    {"email": "marcusquinn@mac.com", "access": "PROD-access-marcusquinn-at-mac-com", "cooldownUntil": $(($(date +%s) * 1000 + 60000)), "status": "rate_limited", "priority": 10},
    {"email": "healthy@example.com", "access": "healthy-access-token", "cooldownUntil": 0, "status": "available", "priority": 1}
  ]
}
JSON

# Stub oauth-pool-helper that rotates the isolated file only. Crucially,
# it writes ONLY to "${XDG_DATA_HOME}/opencode/auth.json" — the same path
# the real helper resolves to with the t2249 XDG-aware line. Mirrors
# build_auth_entry: writes type/access/refresh/expires and no email.
cat >"$TMP/bin/oauth-pool-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -u
target="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
if [[ "${1:-}" == "rotate" && "${2:-}" == "anthropic" && -f "$target" ]]; then
	tmpfile=$(mktemp)
	jq '.anthropic = {type: "oauth", access: "healthy-access-token", refresh: "healthy-refresh", expires: 0}' \
		"$target" >"$tmpfile"
	mv "$tmpfile" "$target"
fi
exit 0
STUB
chmod +x "$TMP/bin/oauth-pool-helper.sh"

# Hash the shared file before rotation.
sha_before=$(shasum -a 256 "$TMP/shared/opencode/auth.json" | awk '{print $1}')
mtime_before=$(stat -f %m "$TMP/shared/opencode/auth.json" 2>/dev/null || stat -c %Y "$TMP/shared/opencode/auth.json" 2>/dev/null || echo 0)

# --- Execute rotation with XDG pointing at isolated -------------------------

export OAUTH_POOL_HELPER="$TMP/bin/oauth-pool-helper.sh"
export AIDEVOPS_OAUTH_POOL_FILE="$TMP/pool.json"
export XDG_DATA_HOME="$TMP/isolated"

_maybe_rotate_isolated_auth "$TMP/isolated/opencode/auth.json" "anthropic"
rc=$?

# --- Test 1: shared file bytes unchanged -----------------------------------

sha_after=$(shasum -a 256 "$TMP/shared/opencode/auth.json" | awk '{print $1}')
if [[ "$sha_before" == "$sha_after" ]]; then
	pass "shared auth.json byte-identical after pre-dispatch rotation (sha=${sha_before:0:12}…)"
else
	fail "shared auth.json bytes CHANGED — interactive session corruption risk"
	printf '    before: %s\n    after:  %s\n' "$sha_before" "$sha_after"
fi

# --- Test 2: shared file mtime unchanged -----------------------------------

sleep 1 # ensure any errant mtime bump would be visible
mtime_after=$(stat -f %m "$TMP/shared/opencode/auth.json" 2>/dev/null || stat -c %Y "$TMP/shared/opencode/auth.json" 2>/dev/null || echo 0)
if [[ "$mtime_before" == "$mtime_after" ]]; then
	pass "shared auth.json mtime unchanged (mtime=$mtime_before)"
else
	fail "shared auth.json mtime CHANGED from $mtime_before → $mtime_after"
fi

# --- Test 3: rotation actually updated the isolated file -------------------
#
# Post-rotation shape mirrors build_auth_entry — no email field. The
# proof-of-rotation is the access-token change, not an email change.

new_access=$(jq -r '.anthropic.access' "$TMP/isolated/opencode/auth.json")
post_has_email=$(jq -r '.anthropic | has("email")' "$TMP/isolated/opencode/auth.json")
if [[ "$rc" -eq 0 && "$new_access" == "healthy-access-token" && "$post_has_email" == "false" ]]; then
	pass "isolated auth.json was rotated via access-token match, post-rotation shape drops email (access=${new_access:0:20}, has_email=$post_has_email, rc=$rc)"
else
	fail "isolated auth.json was NOT rotated as expected (rc=$rc, access=$new_access, has_email=$post_has_email)"
fi

# --- Test 4: the real oauth-pool-helper.sh's OPENCODE_AUTH_FILE with XDG set
# does NOT resolve to the shared default. -----------------------------------

LINE=$(grep -E '^OPENCODE_AUTH_FILE=' "$OAUTH_HELPER" | head -1)
resolved=$(env -i HOME=/h XDG_DATA_HOME="$TMP/isolated" bash -c "$LINE; printf '%s' \"\$OPENCODE_AUTH_FILE\"")
if [[ "$resolved" == "$TMP/isolated/opencode/auth.json" ]]; then
	pass "real helper's OPENCODE_AUTH_FILE with XDG set points to isolated, not shared"
else
	fail "real helper resolves to '$resolved', expected '$TMP/isolated/opencode/auth.json'"
fi

# --- Summary ---------------------------------------------------------------

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
