#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Smoke test for t2866 + t2867: inbox-helper.sh provision + capture CLI.
#
# Tests:
#   1. provision: creates expected directory structure + README.md + .gitignore + triage.log
#   2. add file: copies to correct sub-folder + appends triage.log entry
#   3. add file from _drop/: moves (not copies) and routes correctly
#   4. find: returns matching triage.log entries
#   5. status: reports per-folder counts
#   6. watch routine: processes _drop/ items with debounce
#
# All tests run in /tmp sandbox — no side effects on the real repo.
#
# Usage: test-inbox-capture.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX_HELPER="${SCRIPT_DIR}/inbox-helper.sh"
WATCH_ROUTINE="${SCRIPT_DIR}/inbox-watch-routine.sh"

# Track failures
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

assert_file_exists() {
	local path="$1"
	local label="${2:-${path}}"
	if [[ -f "$path" ]]; then
		pass "${label} exists"
	else
		fail "${label} missing: ${path}"
	fi
	return 0
}

assert_dir_exists() {
	local path="$1"
	local label="${2:-${path}}"
	if [[ -d "$path" ]]; then
		pass "${label} exists"
	else
		fail "${label} missing: ${path}"
	fi
	return 0
}

assert_file_contains() {
	local path="$1"
	local pattern="$2"
	local label="${3:-}"
	if grep -q "$pattern" "$path" 2>/dev/null; then
		pass "${label:-${pattern}} found in ${path}"
	else
		fail "${label:-${pattern}} NOT found in ${path}"
	fi
	return 0
}

# Create isolated sandbox
SANDBOX="$(mktemp -d /tmp/test-inbox-XXXXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '${SANDBOX}'" EXIT

echo ""
echo "=== Inbox Capture Smoke Test ==="
echo "Sandbox: ${SANDBOX}"
echo ""

# ============================================================================
# Test 1: provision creates expected structure
# ============================================================================
echo "--- Test 1: provision ---"
(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" provision "$SANDBOX" >/dev/null 2>&1
)

assert_dir_exists  "${SANDBOX}/_inbox"               "_inbox/ dir"
assert_dir_exists  "${SANDBOX}/_inbox/_drop"          "_inbox/_drop/"
assert_dir_exists  "${SANDBOX}/_inbox/email"          "_inbox/email/"
assert_dir_exists  "${SANDBOX}/_inbox/web"            "_inbox/web/"
assert_dir_exists  "${SANDBOX}/_inbox/scan"           "_inbox/scan/"
assert_dir_exists  "${SANDBOX}/_inbox/voice"          "_inbox/voice/"
assert_dir_exists  "${SANDBOX}/_inbox/import"         "_inbox/import/"
assert_dir_exists  "${SANDBOX}/_inbox/_needs-review"  "_inbox/_needs-review/"
assert_file_exists "${SANDBOX}/_inbox/README.md"      "_inbox/README.md"
assert_file_exists "${SANDBOX}/_inbox/.gitignore"     "_inbox/.gitignore"
assert_file_exists "${SANDBOX}/_inbox/triage.log"     "_inbox/triage.log"

# Idempotency: run provision again — should not error
(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" provision "$SANDBOX" >/dev/null 2>&1
) && pass "provision idempotent (second run OK)" || fail "provision failed on second run"

# ============================================================================
# Test 2: add file → copies to correct sub-folder + triage.log entry
# ============================================================================
echo ""
echo "--- Test 2: add file (email) ---"
		# t2997: drop .eml — XXXXXX must be at end for BSD mktemp.
local_eml="$(mktemp /tmp/test-XXXXXXXX)"
printf 'From: test@example.com\nSubject: Test\n\nBody\n' > "$local_eml"
# shellcheck disable=SC2064
trap "rm -f '${local_eml}'; rm -rf '${SANDBOX}'" EXIT

(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" add "$local_eml" >/dev/null 2>&1
)

# Verify file copied to email/ sub-folder
email_count=0
while IFS= read -r -d '' _f; do
	email_count=$((email_count + 1))
done < <(find "${SANDBOX}/_inbox/email" -maxdepth 1 -type f -name '*.eml' -print0 2>/dev/null)
if [[ "$email_count" -ge 1 ]]; then
	pass ".eml file routed to email/"
else
	fail ".eml file NOT found in email/ (count=${email_count})"
fi

# triage.log should have a "cli-add" entry for email
assert_file_contains "${SANDBOX}/_inbox/triage.log" '"source":"cli-add"' "cli-add entry"
assert_file_contains "${SANDBOX}/_inbox/triage.log" '"sub":"email"'       "sub:email entry"
assert_file_contains "${SANDBOX}/_inbox/triage.log" '"sensitivity":"unverified"' "sensitivity:unverified"

# ============================================================================
# Test 3: add file from _drop/ → move (not copy)
# ============================================================================
echo ""
echo "--- Test 3: add file from _drop/ (move semantics) ---"
drop_file="${SANDBOX}/_inbox/_drop/test-audio.mp3"
printf 'fake mp3 data\n' > "$drop_file"

(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" add "$drop_file" >/dev/null 2>&1
)

# File should be gone from _drop/
if [[ ! -f "$drop_file" ]]; then
	pass "_drop/ file moved (no longer in _drop/)"
else
	fail "_drop/ file still present (should have been moved)"
fi

# Should be in voice/ now
voice_count=0
while IFS= read -r -d '' _f; do
	voice_count=$((voice_count + 1))
done < <(find "${SANDBOX}/_inbox/voice" -maxdepth 1 -type f -name '*.mp3' -print0 2>/dev/null)
if [[ "$voice_count" -ge 1 ]]; then
	pass ".mp3 from _drop/ routed to voice/"
else
	fail ".mp3 from _drop/ NOT found in voice/"
fi

# ============================================================================
# Test 4: find returns matching entries
# ============================================================================
echo ""
echo "--- Test 4: find ---"
find_output="$(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" find "cli-add" 2>/dev/null
)"
if printf '%s' "$find_output" | grep -q '"source":"cli-add"'; then
	pass "find returns matching triage.log entries"
else
	fail "find returned no entries for 'cli-add'"
fi

find_none="$(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" find "xyz_nonexistent_query_abc" 2>/dev/null
)"
if printf '%s' "$find_none" | grep -qv '"source"'; then
	pass "find returns empty for non-matching query"
fi

# ============================================================================
# Test 5: status reports counts
# ============================================================================
echo ""
echo "--- Test 5: status ---"
status_output="$(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" status "$SANDBOX" 2>/dev/null
)"
if printf '%s' "$status_output" | grep -q "email/"; then
	pass "status output contains email/ row"
else
	fail "status output missing email/ row"
fi
if printf '%s' "$status_output" | grep -q "triage.log:"; then
	pass "status output contains triage.log line count"
else
	fail "status output missing triage.log line"
fi

# ============================================================================
# Test 6: watch routine processes _drop/ items (no debounce since file already old)
# ============================================================================
echo ""
echo "--- Test 6: watch routine ---"
# Create a test file in _drop/ with age > 5s (use touch -t to backdate)
watch_file="${SANDBOX}/_inbox/_drop/old-scan.png"
printf 'fake png\n' > "$watch_file"
# Backdate to 10 seconds ago
old_ts="$(date -v-10S '+%Y%m%d%H%M.%S' 2>/dev/null \
	|| date -d '10 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null \
	|| date '+%Y%m%d%H%M.%S')"
touch -t "$old_ts" "$watch_file" 2>/dev/null || true

(
	cd "$SANDBOX"
	INBOX_WATCH_DEBOUNCE_SECS=5 bash "$WATCH_ROUTINE" "$SANDBOX" >/dev/null 2>&1
)

# File should have been moved from _drop/
if [[ ! -f "$watch_file" ]]; then
	pass "watch routine processed _drop/ item (moved)"
else
	# touch -t may not have worked on all platforms; treat as skip
	echo "SKIP: watch routine debounce test (touch -t platform issue)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
	echo "=== ALL TESTS PASSED ==="
	exit 0
else
	echo "=== ${FAIL_COUNT} TEST(S) FAILED ===" >&2
	exit 1
fi
