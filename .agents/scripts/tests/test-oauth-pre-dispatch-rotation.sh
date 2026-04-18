#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-oauth-pre-dispatch-rotation.sh — t2249 regression guard.
#
# Asserts that `_maybe_rotate_isolated_auth` (defined in
# headless-runtime-helper.sh) rotates the ISOLATED auth file when the
# current account's cooldownUntil is in the future, and does nothing
# when the account is healthy.
#
# Production failure this prevents (GH#19787, t2249): the pulse cascade
# on 2026-04-18 22:00-22:15 UTC killed 6+ workers back-to-back because
# they all inherited the same rate-limited OAuth account and had no
# mechanism to rotate away from it before dispatch.
#
# Tests:
#   1. Cooldown in future      → rotate helper is invoked with correct XDG
#   2. Cooldown in past (0)    → rotate helper is NOT invoked
#   3. Missing jq              → exits 0 without action (best-effort guard)
#   4. Missing pool file       → exits 0 without action (best-effort guard)
#
# Strategy: extract the function definition via `declare -f` from a
# subshell source (side-effect-isolated), then eval it into the test
# shell along with stub `print_info` / `print_warning` functions and a
# stub oauth-pool-helper that records its invocation.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/headless-runtime-helper.sh"

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

# --- Prereqs ----------------------------------------------------------------

[[ -f "$HELPER" ]] || {
	printf 'FATAL: helper not found: %s\n' "$HELPER" >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	printf 'SKIP: jq not installed — cannot exercise _maybe_rotate_isolated_auth\n' >&2
	exit 0
}

# Extract the function definition. The helper calls `main "$@"` at its
# bottom; passing `help` keeps it on the safe `show_help` path while we
# capture the function body.
FN_DEF=$(bash -c "source '$HELPER' help >/dev/null 2>&1 || true; declare -f _maybe_rotate_isolated_auth")
[[ -n "$FN_DEF" ]] || {
	printf 'FATAL: could not extract _maybe_rotate_isolated_auth from %s\n' "$HELPER" >&2
	exit 1
}

printf '%s[test]%s t2249 — _maybe_rotate_isolated_auth behaviour\n' "$TEST_BLUE" "$TEST_NC"

# Stub the logging functions — test shell calls the function directly.
print_info() { :; }
print_warning() { :; }

# Eval the extracted function into the current shell.
eval "$FN_DEF"

# --- Fixture helpers --------------------------------------------------------

make_fixture() {
	# Creates a tmpdir with:
	#   $TMP/isolated/opencode/auth.json   (isolated worker auth)
	#   $TMP/pool.json                     (shared pool metadata)
	#   $TMP/bin/oauth-pool-helper.sh      (stub recording its invocation)
	#   $TMP/bin/invocation.log            (stub call log)
	#
	# $1 = cooldownUntil_ms for marcusquinn@mac.com in the shared pool
	local cooldown_ms="$1"
	local tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/t2249-rotation-test.XXXXXX")

	mkdir -p "$tmp/isolated/opencode" "$tmp/bin"

	# Isolated auth has marcusquinn@mac.com as current account.
	cat >"$tmp/isolated/opencode/auth.json" <<'JSON'
{
  "anthropic": {
    "type": "oauth",
    "access": "fake-access-token",
    "refresh": "fake-refresh-token",
    "email": "marcusquinn@mac.com"
  }
}
JSON

	# Shared pool: marcusquinn@mac.com with cooldown, healthy@example.com available.
	cat >"$tmp/pool.json" <<JSON
{
  "anthropic": [
    {"email": "marcusquinn@mac.com", "cooldownUntil": ${cooldown_ms}, "status": "rate_limited", "priority": 10},
    {"email": "healthy@example.com", "cooldownUntil": 0, "status": "available", "priority": 1}
  ]
}
JSON

	# Stub helper: records args to a log, and on `rotate anthropic` rewrites
	# the isolated auth.json's email to the healthy account.
	cat >"$tmp/bin/oauth-pool-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'STUB_CALLED: XDG_DATA_HOME=%s args=%s\n' "${XDG_DATA_HOME:-}" "$*" >>"${STUB_LOG}"
if [[ "${1:-}" == "rotate" && "${2:-}" == "anthropic" ]]; then
	target="${XDG_DATA_HOME}/opencode/auth.json"
	if [[ -f "$target" ]]; then
		tmpfile=$(mktemp)
		jq '.anthropic.email = "healthy@example.com"' "$target" >"$tmpfile" && mv "$tmpfile" "$target"
	fi
fi
exit 0
STUB
	chmod +x "$tmp/bin/oauth-pool-helper.sh"
	: >"$tmp/bin/invocation.log"

	printf '%s' "$tmp"
}

now_ms() { printf '%s' "$(($(date +%s) * 1000))"; }

# --- Test 1: cooldown in the future → rotation fires -------------------------

fixture=$(make_fixture "$(($(now_ms) + 60000))") # cooldown 60s in the future
export OAUTH_POOL_HELPER="$fixture/bin/oauth-pool-helper.sh"
export AIDEVOPS_OAUTH_POOL_FILE="$fixture/pool.json"
export STUB_LOG="$fixture/bin/invocation.log"

_maybe_rotate_isolated_auth "$fixture/isolated/opencode/auth.json" "anthropic"
rc=$?

final_email=$(jq -r '.anthropic.email' "$fixture/isolated/opencode/auth.json" 2>/dev/null || echo "")
stub_calls=$(wc -l <"$STUB_LOG" | tr -d ' ')

if [[ "$rc" -eq 0 && "$final_email" == "healthy@example.com" && "$stub_calls" -ge 1 ]]; then
	pass "cooldown-active → rotation invoked and isolated auth email changed (rc=$rc, email=$final_email, calls=$stub_calls)"
else
	fail "cooldown-active expectations not met (rc=$rc, email=$final_email, calls=$stub_calls)"
	cat "$STUB_LOG" 2>/dev/null | sed 's/^/    log: /' || true
fi
rm -rf "$fixture"

# --- Test 2: cooldown in the past → no rotation -----------------------------

fixture=$(make_fixture "0") # cooldown cleared
export OAUTH_POOL_HELPER="$fixture/bin/oauth-pool-helper.sh"
export AIDEVOPS_OAUTH_POOL_FILE="$fixture/pool.json"
export STUB_LOG="$fixture/bin/invocation.log"

_maybe_rotate_isolated_auth "$fixture/isolated/opencode/auth.json" "anthropic"
rc=$?

final_email=$(jq -r '.anthropic.email' "$fixture/isolated/opencode/auth.json" 2>/dev/null || echo "")
stub_calls=$(wc -l <"$STUB_LOG" | tr -d ' ')

if [[ "$rc" -eq 0 && "$final_email" == "marcusquinn@mac.com" && "$stub_calls" -eq 0 ]]; then
	pass "no-cooldown → rotation skipped, account unchanged (rc=$rc, email=$final_email, calls=$stub_calls)"
else
	fail "no-cooldown expectations not met (rc=$rc, email=$final_email, calls=$stub_calls)"
fi
rm -rf "$fixture"

# --- Test 3: missing pool file → silent noop --------------------------------

fixture=$(make_fixture "$(($(now_ms) + 60000))")
export OAUTH_POOL_HELPER="$fixture/bin/oauth-pool-helper.sh"
export AIDEVOPS_OAUTH_POOL_FILE="/nonexistent/pool.json"
export STUB_LOG="$fixture/bin/invocation.log"

_maybe_rotate_isolated_auth "$fixture/isolated/opencode/auth.json" "anthropic"
rc=$?

stub_calls=$(wc -l <"$STUB_LOG" | tr -d ' ')
if [[ "$rc" -eq 0 && "$stub_calls" -eq 0 ]]; then
	pass "missing-pool-file → silent noop (rc=$rc, calls=$stub_calls)"
else
	fail "missing-pool-file should be silent noop (rc=$rc, calls=$stub_calls)"
fi
rm -rf "$fixture"

# --- Test 4: missing isolated auth → silent noop ----------------------------

fixture=$(make_fixture "$(($(now_ms) + 60000))")
export OAUTH_POOL_HELPER="$fixture/bin/oauth-pool-helper.sh"
export AIDEVOPS_OAUTH_POOL_FILE="$fixture/pool.json"
export STUB_LOG="$fixture/bin/invocation.log"

_maybe_rotate_isolated_auth "/nonexistent/auth.json" "anthropic"
rc=$?

stub_calls=$(wc -l <"$STUB_LOG" | tr -d ' ')
if [[ "$rc" -eq 0 && "$stub_calls" -eq 0 ]]; then
	pass "missing-isolated-auth → silent noop (rc=$rc, calls=$stub_calls)"
else
	fail "missing-isolated-auth should be silent noop (rc=$rc, calls=$stub_calls)"
fi
rm -rf "$fixture"

# --- Summary ----------------------------------------------------------------

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
