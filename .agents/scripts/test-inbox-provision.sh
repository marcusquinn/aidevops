#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Smoke test for t2866: inbox-helper.sh provision + provision-workspace
# must create the full _inbox/ directory contract idempotently.
#
# Tests:
#   1. provision creates all required sub-folders under a sandbox repo.
#   2. provision is idempotent (re-run does not fail or duplicate).
#   3. Required files (README.md, .gitignore, triage.log) are present.
#   4. .gitignore policy is correct (README.md + triage.log not excluded,
#      arbitrary captures excluded).
#   5. status reports the correct zero-count table on a fresh inbox.
#   6. validate passes on a correctly provisioned inbox.
#   7. provision-workspace creates structure under a temp AIDEVOPS_HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX_HELPER="${SCRIPT_DIR}/inbox-helper.sh"

declare -i FAIL_COUNT=0

fail() {
	local msg="$1"
	echo "FAIL: $msg" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

pass() {
	local msg="$1"
	echo "PASS: $msg"
	return 0
}

assert_dir() {
	local path="$1" label="$2"
	if [[ -d "$path" ]]; then
		pass "$label exists"
	else
		fail "$label missing: $path"
	fi
	return 0
}

assert_file() {
	local path="$1" label="$2"
	if [[ -f "$path" ]]; then
		pass "$label exists"
	else
		fail "$label missing: $path"
	fi
	return 0
}

# Create a temp sandbox repo directory that is cleaned up on exit.
SANDBOX=""
cleanup() {
	[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"
	return 0
}
trap cleanup EXIT

SANDBOX="$(mktemp -d)"

# =============================================================================
# Test 1: provision creates all required directories and files
# =============================================================================
echo ""
echo "=== Test 1: provision creates full _inbox/ directory contract ==="

"$INBOX_HELPER" provision "$SANDBOX" >/dev/null

assert_dir  "$SANDBOX/_inbox"                   "_inbox/"
assert_dir  "$SANDBOX/_inbox/_drop"             "_inbox/_drop/"
assert_dir  "$SANDBOX/_inbox/email"             "_inbox/email/"
assert_dir  "$SANDBOX/_inbox/web"               "_inbox/web/"
assert_dir  "$SANDBOX/_inbox/scan"              "_inbox/scan/"
assert_dir  "$SANDBOX/_inbox/voice"             "_inbox/voice/"
assert_dir  "$SANDBOX/_inbox/import"            "_inbox/import/"
assert_dir  "$SANDBOX/_inbox/_needs-review"     "_inbox/_needs-review/"
assert_file "$SANDBOX/_inbox/README.md"         "_inbox/README.md"
assert_file "$SANDBOX/_inbox/.gitignore"        "_inbox/.gitignore"
assert_file "$SANDBOX/_inbox/triage.log"        "_inbox/triage.log"

# =============================================================================
# Test 2: provision is idempotent (re-run succeeds, no duplicates)
# =============================================================================
echo ""
echo "=== Test 2: provision is idempotent ==="

if "$INBOX_HELPER" provision "$SANDBOX" >/dev/null 2>&1; then
	pass "idempotent re-run exits 0"
else
	fail "idempotent re-run failed"
fi

assert_dir  "$SANDBOX/_inbox/_drop"   "_inbox/_drop/ still exists after re-run"
assert_file "$SANDBOX/_inbox/README.md" "README.md not overwritten"

# =============================================================================
# Test 3: .gitignore excludes captures but keeps README.md and triage.log
# =============================================================================
echo ""
echo "=== Test 3: .gitignore policy ==="

GITIGNORE="$SANDBOX/_inbox/.gitignore"
if grep -q "README.md" "$GITIGNORE" && grep -q "triage.log" "$GITIGNORE"; then
	pass ".gitignore whitelists README.md and triage.log"
else
	fail ".gitignore does not whitelist README.md and/or triage.log"
fi

if grep -qE '^\*$' "$GITIGNORE"; then
	pass ".gitignore has catch-all exclude (*)"
else
	fail ".gitignore missing catch-all exclude (*)"
fi

# =============================================================================
# Test 4: validate passes on a correctly provisioned inbox
# =============================================================================
echo ""
echo "=== Test 4: validate reports success on correctly provisioned inbox ==="

if "$INBOX_HELPER" validate "$SANDBOX" >/dev/null 2>&1; then
	pass "validate exits 0 on correct structure"
else
	fail "validate failed on correctly provisioned inbox"
fi

# =============================================================================
# Test 5: status reports zero items on a fresh empty inbox
# =============================================================================
echo ""
echo "=== Test 5: status reports zero total items on fresh inbox ==="

status_output="$("$INBOX_HELPER" status "$SANDBOX" 2>&1 || true)"
if echo "$status_output" | grep -q "Total items:  0"; then
	pass "status reports 0 total items on fresh inbox"
else
	fail "status did not report 0 total items; output was: $status_output"
fi

# =============================================================================
# Test 6: provision-workspace provisions under a custom HOME
# =============================================================================
echo ""
echo "=== Test 6: provision-workspace creates workspace inbox ==="

FAKE_HOME="$(mktemp -d)"
# Override HOME so provision-workspace targets our sandbox location.
# inbox-helper.sh uses $HOME/.aidevops/.agent-workspace/inbox
HOME="$FAKE_HOME" "$INBOX_HELPER" provision-workspace >/dev/null

assert_dir  "$FAKE_HOME/.aidevops/.agent-workspace/inbox"               "workspace inbox root"
assert_dir  "$FAKE_HOME/.aidevops/.agent-workspace/inbox/_drop"         "workspace inbox/_drop/"
assert_dir  "$FAKE_HOME/.aidevops/.agent-workspace/inbox/email"         "workspace inbox/email/"
assert_file "$FAKE_HOME/.aidevops/.agent-workspace/inbox/README.md"     "workspace inbox/README.md"
assert_file "$FAKE_HOME/.aidevops/.agent-workspace/inbox/.gitignore"    "workspace inbox/.gitignore"
assert_file "$FAKE_HOME/.aidevops/.agent-workspace/inbox/triage.log"    "workspace inbox/triage.log"

rm -rf "$FAKE_HOME"

# =============================================================================
# Test 7: provision-workspace is idempotent
# =============================================================================
echo ""
echo "=== Test 7: provision-workspace is idempotent ==="

FAKE_HOME2="$(mktemp -d)"
HOME="$FAKE_HOME2" "$INBOX_HELPER" provision-workspace >/dev/null
if HOME="$FAKE_HOME2" "$INBOX_HELPER" provision-workspace >/dev/null 2>&1; then
	pass "provision-workspace idempotent re-run exits 0"
else
	fail "provision-workspace idempotent re-run failed"
fi
rm -rf "$FAKE_HOME2"

# =============================================================================
# Summary
# =============================================================================
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
	echo "=== All tests passed ==="
	exit 0
else
	echo "=== $FAIL_COUNT test(s) failed ==="
	exit 1
fi
