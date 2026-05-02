#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Smoke test for GH#22295: inbox correction recording and learning reuse.

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

assert_file_contains() {
	local path="$1"
	local pattern="$2"
	local label="${3:-$pattern}"
	if grep -q "$pattern" "$path" 2>/dev/null; then
		pass "$label"
	else
		fail "$label missing from $path"
	fi
	return 0
}

SANDBOX="$(mktemp -d /tmp/test-inbox-correction-XXXXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '${SANDBOX}'" EXIT

echo ""
echo "=== Inbox Correction Smoke Test ==="
echo "Sandbox: ${SANDBOX}"
echo ""

(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" provision "$SANDBOX" >/dev/null 2>&1
)

item_file="${SANDBOX}/_inbox/_drop/client-note.txt"
printf 'launch campaign brief\n' > "$item_file"
item_rel="_inbox/_drop/client-note.txt"
item_hash="$(shasum -a 256 "$item_file" | cut -d' ' -f1)"

cat >> "${SANDBOX}/_inbox/triage.log" <<EOF
{"ts":"2026-05-02T00:00:00Z","status":"routed","from":"${item_rel}","to":"_knowledge/client-note.txt","dest_plane":"knowledge","dest_path":"${SANDBOX}/_knowledge/client-note.txt","confidence":72,"sensitivity":"public","llm_tier":"cloud","reasoning":"looked like reference material"}
EOF

(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" correct "$item_rel" --to campaigns/swipe --reason "Campaign swipe, not general knowledge" >/dev/null 2>&1
)

assert_file_contains "${SANDBOX}/_inbox/triage.log" '"source":"human-correction"' "correction appended to triage.log"
assert_file_contains "${SANDBOX}/_inbox/triage.log" '"original_confidence":72' "original confidence preserved"
assert_file_contains "${SANDBOX}/_inbox/triage.log" '"corrected_to":"campaigns/swipe"' "corrected destination recorded"
assert_file_contains "${SANDBOX}/_inbox/triage-examples.jsonl" "${item_hash}" "correction example stores item hash"
assert_file_contains "${SANDBOX}/_inbox/triage-examples.jsonl" '"corrected_plane":"campaigns"' "correction example stores plane"

find_output="$(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" find "client-note" 2>/dev/null
)"
if printf '%s' "$find_output" | grep -q '"source":"human-correction"'; then
	pass "find surfaces correction history"
else
	fail "find did not surface correction history"
fi

# Duplicate content should reuse the human-approved correction even when LLM deps
# are unavailable. Dry-run avoids moving the duplicate while still exercising the
# high-confidence hash-linked route decision.
dup_file="${SANDBOX}/_inbox/_drop/client-note-copy.txt"
printf 'launch campaign brief\n' > "$dup_file"
cat >> "${SANDBOX}/_inbox/triage.log" <<EOF
{"ts":"2026-05-02T00:01:00Z","source":"cli-add","sub":"_drop","orig":"${dup_file}","path":"_inbox/_drop/client-note-copy.txt","status":"pending","sensitivity":"unverified"}
EOF

triage_output="$(
	cd "$SANDBOX"
	bash "$INBOX_HELPER" triage --dry-run --limit 1 2>&1
)"
if printf '%s' "$triage_output" | grep -q 'Would route to _campaigns/swipe/'; then
	pass "duplicate hash reuses approved correction in dry-run triage"
else
	fail "duplicate hash did not reuse approved correction; output: ${triage_output}"
fi

echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
	echo "=== ALL TESTS PASSED ==="
	exit 0
else
	echo "=== ${FAIL_COUNT} TEST(S) FAILED ===" >&2
	exit 1
fi
