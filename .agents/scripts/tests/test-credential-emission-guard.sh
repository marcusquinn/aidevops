#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-credential-emission-guard.sh — t2458 regression guard.
#
# Asserts that .agents/hooks/credential-emission-pre-push.sh blocks pushes
# that introduce new `echo $remote_url` / `log_info "... $origin_url"` lines
# in .agents/scripts or .agents/hooks, and that sanitize_url-wrapped lines
# pass. The .agents/scripts/tests/ and fixtures/ subdirectories are excluded.
#
# Test strategy: create an isolated temp repo with an "initial" empty commit
# and a "head" commit that introduces a known mix of good and bad .sh files,
# then invoke the guard with a simulated pre-push stdin and assert both the
# exit code and the specific offending lines surfaced.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
GUARD="${REPO_ROOT}/.agents/hooks/credential-emission-pre-push.sh"

if [[ ! -x "$GUARD" ]]; then
	printf 'guard not found or not executable: %s\n' "$GUARD" >&2
	exit 1
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2458-guard.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP" || exit 1
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -q -m "initial"
INITIAL=$(git rev-parse HEAD)

# Create files covering all important cases.
mkdir -p .agents/scripts .agents/hooks .agents/scripts/tests

# Violation 1: bare echo of $remote_url
cat >.agents/scripts/bad-echo.sh <<'BAD'
#!/usr/bin/env bash
remote_url="$(git remote get-url origin)"
echo "Remote: $remote_url"
BAD

# Violation 2: log_info of ${origin_url}
cat >.agents/scripts/bad-log.sh <<'BAD'
#!/usr/bin/env bash
origin_url="$(git remote get-url origin)"
log_info "Fetching from ${origin_url}"
BAD

# Violation 3: printf of $remote_url in a hook
cat >.agents/hooks/bad-hook.sh <<'BAD'
#!/usr/bin/env bash
remote_url="$1"
printf 'remote=%s\n' "$remote_url"
BAD

# Clean 1: sanitize_url-wrapped emit (should NOT trigger)
cat >.agents/scripts/good-wrapped.sh <<'GOOD'
#!/usr/bin/env bash
remote_url="$(git remote get-url origin)"
echo "Remote: $(sanitize_url "$remote_url")"
GOOD

# Clean 2: scrub_credentials-wrapped emit (should NOT trigger)
cat >.agents/scripts/good-scrubbed.sh <<'GOOD'
#!/usr/bin/env bash
origin_url="$(git remote get-url origin)"
log_info "from $(scrub_credentials "$origin_url")"
GOOD

# Clean 3: assignment only, no emit (should NOT trigger)
cat >.agents/scripts/good-assignment.sh <<'GOOD'
#!/usr/bin/env bash
remote_url="$(git remote get-url origin)"
other="$remote_url"
GOOD

# Excluded: tests/ directory (should NOT be scanned even if violation present)
cat >.agents/scripts/tests/test-sample.sh <<'SKIP'
#!/usr/bin/env bash
remote_url="https://fake@example.com"
echo "test emit: $remote_url"
SKIP

git add -A
git commit -q -m "add files"
HEAD_SHA=$(git rev-parse HEAD)

# =============================================================================
# Test 1: Violations are detected (exit 1)
# =============================================================================
echo "[test] Guard blocks pushes with unsanitized emits"

output=$(printf 'refs/heads/test %s refs/heads/test %s\n' "$HEAD_SHA" "$INITIAL" \
	| bash "$GUARD" origin test 2>&1 || true)
exit_code=$(printf 'refs/heads/test %s refs/heads/test %s\n' "$HEAD_SHA" "$INITIAL" \
	| bash "$GUARD" origin test >/dev/null 2>&1; echo $?)

if [[ "$exit_code" -eq 1 ]]; then
	pass "exit code is 1 on violations"
else
	fail "exit code should be 1, got $exit_code"
fi

if [[ "$output" == *"bad-echo.sh"* ]]; then
	pass "bad-echo.sh violation reported"
else
	fail "bad-echo.sh NOT reported" "$output"
fi

if [[ "$output" == *"bad-log.sh"* ]]; then
	pass "bad-log.sh violation reported"
else
	fail "bad-log.sh NOT reported" "$output"
fi

if [[ "$output" == *"bad-hook.sh"* ]]; then
	pass "bad-hook.sh (hook directory) violation reported"
else
	fail "bad-hook.sh NOT reported" "$output"
fi

# =============================================================================
# Test 2: Safe patterns are NOT flagged
# =============================================================================
echo ""
echo "[test] Guard does not flag sanitize_url / scrub_credentials wrappers"

if [[ "$output" != *"good-wrapped.sh"* ]]; then
	pass "good-wrapped.sh (sanitize_url) not flagged"
else
	fail "good-wrapped.sh false positive" "$output"
fi

if [[ "$output" != *"good-scrubbed.sh"* ]]; then
	pass "good-scrubbed.sh (scrub_credentials) not flagged"
else
	fail "good-scrubbed.sh false positive" "$output"
fi

if [[ "$output" != *"good-assignment.sh"* ]]; then
	pass "good-assignment.sh (no emit) not flagged"
else
	fail "good-assignment.sh false positive" "$output"
fi

# =============================================================================
# Test 3: tests/ directory is excluded
# =============================================================================
echo ""
echo "[test] Guard excludes .agents/scripts/tests/"

if [[ "$output" != *"tests/test-sample.sh"* ]]; then
	pass "tests/test-sample.sh excluded"
else
	fail "tests/ directory NOT excluded" "$output"
fi

# =============================================================================
# Test 4: CREDENTIAL_GUARD_DISABLE bypass
# =============================================================================
echo ""
echo "[test] CREDENTIAL_GUARD_DISABLE bypass"

bypass_exit=$(printf 'refs/heads/test %s refs/heads/test %s\n' "$HEAD_SHA" "$INITIAL" \
	| CREDENTIAL_GUARD_DISABLE=1 bash "$GUARD" origin test >/dev/null 2>&1; echo $?)

if [[ "$bypass_exit" -eq 0 ]]; then
	pass "CREDENTIAL_GUARD_DISABLE=1 bypasses the guard"
else
	fail "bypass did not work, exit=$bypass_exit"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
