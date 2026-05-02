#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-inbox-triage-preview-extraction.sh — regression tests for rich _inbox previews

set -u
set +e

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local label="$3"
	if printf '%s\n' "$haystack" | grep -Fq "$needle"; then
		pass "$label"
	else
		fail "$label" "missing: $needle"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../inbox-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'FATAL: inbox-helper.sh not executable at %s\n' "$HELPER" >&2
	exit 1
fi

TMP_DIR="$(mktemp -d)"
REPO_DIR="${TMP_DIR}/repo"
BIN_DIR="${TMP_DIR}/bin"
mkdir -p "$REPO_DIR" "$BIN_DIR"

cat >"${BIN_DIR}/sensitivity-detect.sh" <<'EOF'
#!/usr/bin/env bash
printf 'public'
EOF
chmod +x "${BIN_DIR}/sensitivity-detect.sh"

cat >"${BIN_DIR}/llm-routing-helper.sh" <<'EOF'
#!/usr/bin/env bash
content=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--content)
		content="${2:-}"
		shift 2
		;;
	*) shift ;;
	esac
done
if [[ -n "${CAPTURE_FILE:-}" ]]; then
	{
		printf '%s\n' '---CONTENT---'
		printf '%s\n' "$content"
	} >>"$CAPTURE_FILE"
fi
printf '{"target_plane":"knowledge","sub_folder":"inbox","confidence":0.99,"reasoning":"fixture"}\n'
EOF
chmod +x "${BIN_DIR}/llm-routing-helper.sh"

export PATH="${BIN_DIR}:$PATH"
export CAPTURE_FILE="${TMP_DIR}/captured-previews.txt"

mkdir -p \
	"${REPO_DIR}/_inbox/_drop" \
	"${REPO_DIR}/_inbox/email" \
	"${REPO_DIR}/_inbox/scan" \
	"${REPO_DIR}/_inbox/voice" \
	"${REPO_DIR}/_inbox/web"

printf 'Plain project note\nRoute this to knowledge.\n' >"${REPO_DIR}/_inbox/_drop/plain.txt"
printf 'name,amount\nAda,42\nGrace,84\n' >"${REPO_DIR}/_inbox/_drop/table.csv"
cat >"${REPO_DIR}/_inbox/email/message.eml" <<'EOF'
From: Ada <ada@example.test>
To: Grace <grace@example.test>
Subject: Inbox preview fixture
Date: Sat, 02 May 2026 13:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="x"

--x
Content-Type: text/plain; charset="utf-8"

Email body with routing context.
--x
Content-Type: text/plain; name="notes.txt"
Content-Disposition: attachment; filename="notes.txt"

attached note
--x--
EOF
printf 'PDF bytes with invoice OCR fallback text\n' >"${REPO_DIR}/_inbox/scan/doc.pdf"
printf 'image bytes with photographed whiteboard text\n' >"${REPO_DIR}/_inbox/scan/photo.png"
printf 'fake wave bytes\n' >"${REPO_DIR}/_inbox/voice/meeting.wav"
printf 'Audio transcript sidecar about roadmap decisions\n' >"${REPO_DIR}/_inbox/voice/meeting.wav.txt"
printf 'Captured web page text for routing\n' >"${REPO_DIR}/_inbox/web/page.md"
printf '{"url":"https://example.test/page","title":"Example Page","text":"_inbox/web/page.md"}\n' \
	>"${REPO_DIR}/_inbox/web/page.meta.json"

LOG="${REPO_DIR}/_inbox/triage.log"
for rel in \
	'_inbox/_drop/plain.txt' \
	'_inbox/_drop/table.csv' \
	'_inbox/email/message.eml' \
	'_inbox/scan/doc.pdf' \
	'_inbox/scan/photo.png' \
	'_inbox/voice/meeting.wav' \
	'_inbox/web/page.meta.json'; do
	printf '{"ts":"2026-05-02T13:00:00Z","source":"test","sub":"_drop","orig":"fixture","path":"%s","status":"pending","sensitivity":"unverified"}\n' "$rel" >>"$LOG"
done

echo "=== test-inbox-triage-preview-extraction.sh ==="
output="$(cd "$REPO_DIR" && "$HELPER" triage --dry-run --explain --limit 20 2>&1)"
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "triage --dry-run --explain exits 0"
else
	fail "triage --dry-run --explain exits 0" "exit=${rc}; output=${output}"
fi

captured="$(cat "$CAPTURE_FILE" 2>/dev/null)"
combined="${output}
${captured}"

assert_contains "$combined" 'kind: text' 'plain text preview includes kind'
assert_contains "$combined" 'Plain project note' 'plain text preview includes excerpt'
assert_contains "$combined" 'kind: csv' 'CSV preview includes kind'
assert_contains "$combined" 'name,amount' 'CSV preview includes table excerpt'
assert_contains "$combined" 'kind: email' 'email preview includes kind'
assert_contains "$combined" 'Inbox preview fixture' 'email preview includes subject'
assert_contains "$combined" 'attachments:' 'email preview includes attachment metadata'
assert_contains "$combined" 'kind: pdf' 'PDF preview includes kind'
assert_contains "$combined" 'invoice OCR fallback text' 'PDF preview includes safe fallback excerpt'
assert_contains "$combined" 'kind: image' 'image preview includes kind'
assert_contains "$combined" 'photographed whiteboard text' 'image preview includes safe fallback excerpt'
assert_contains "$combined" 'kind: audio' 'audio preview includes kind'
assert_contains "$combined" 'Audio transcript sidecar' 'audio preview includes transcript excerpt'
assert_contains "$combined" 'kind: web' 'web preview includes kind'
assert_contains "$combined" 'Captured web page text' 'web preview includes captured text excerpt'
assert_contains "$combined" 'sensitivity: public' 'preview records sensitivity gate result'

rm -rf "$TMP_DIR"

echo ""
echo "Tests run: ${TESTS_RUN}"
echo "Failures:  ${TESTS_FAILED}"
[[ $TESTS_FAILED -eq 0 ]]
exit $?
