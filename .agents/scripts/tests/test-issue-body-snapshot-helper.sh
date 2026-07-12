#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../issue-body-snapshot-helper.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/issue-snapshot-test-XXXXXX")"
FAKE_BIN="${TEST_TMP}/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
	rm -rf "$TEST_TMP"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${GH_FAIL:-0}" == "1" ]]; then exit 1; fi
printf '%s' '{"number":45,"title":"Bounded context","body":"Implement focused tests.","updatedAt":"2026-07-12T10:00:00Z"}'
EOF
cat >"${FAKE_BIN}/scanner" <<'EOF'
#!/usr/bin/env bash
[[ "${SCANNER_BLOCK:-0}" != "1" ]]
EOF
chmod +x "${FAKE_BIN}/gh" "${FAKE_BIN}/scanner"

export PATH="${FAKE_BIN}:${PATH}"
export ISSUE_BODY_SNAPSHOT_DIR="${TEST_TMP}/snapshots"
export ISSUE_BODY_SNAPSHOT_SCANNER="${FAKE_BIN}/scanner"

live=$("$HELPER" fetch owner/repo 45) || fail "live fetch failed"
[[ "$live" == *'"body":"Implement focused tests."'* ]] || fail "live body was not returned"
snapshot="${ISSUE_BODY_SNAPSHOT_DIR}/owner_repo-45.json"
[[ -f "$snapshot" ]] || fail "snapshot was not written"
mode=$(stat -f '%Lp' "$snapshot" 2>/dev/null || stat -c '%a' "$snapshot")
[[ "$mode" == "600" ]] || fail "snapshot mode is ${mode}"
jq -e '.repo == "owner/repo" and .issue == 45 and .title and .body and .sourceUpdatedAt and .capturedAt and .bodyHash' "$snapshot" >/dev/null || fail "snapshot schema is incomplete"

fallback=$(GH_FAIL=1 "$HELPER" fetch owner/repo 45) || fail "validated fallback failed"
[[ "$fallback" == *'"snapshotFallback":true'* ]] || fail "fallback was not identified"

if GH_FAIL=1 ISSUE_BODY_SNAPSHOT_ENABLED=0 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "disabled snapshot fallback was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"snapshots are disabled"* ]] || fail "rollback flag blocker was not precise"

jq '.repo = "other/repo"' "$snapshot" >"${snapshot}.tmp" && chmod 600 "${snapshot}.tmp" && mv "${snapshot}.tmp" "$snapshot"
if GH_FAIL=1 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "identity-mismatched snapshot was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"identity validation failed"* ]] || fail "identity blocker was not precise"

GH_FAIL=0 "$HELPER" fetch owner/repo 45 >/dev/null || fail "snapshot refresh failed"
jq '.capturedAt = "2020-01-01T00:00:00Z"' "$snapshot" >"${snapshot}.tmp" && chmod 600 "${snapshot}.tmp" && mv "${snapshot}.tmp" "$snapshot"
if GH_FAIL=1 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "stale snapshot was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"snapshot is stale"* ]] || fail "stale blocker was not precise"

"$HELPER" cleanup || fail "cleanup failed"
[[ ! -e "$snapshot" ]] || fail "cleanup retained an expired snapshot"
GH_FAIL=0 "$HELPER" fetch owner/repo 45 >/dev/null || fail "snapshot recreation failed"

jq '.body = "tampered"' "$snapshot" >"${snapshot}.tmp" && chmod 600 "${snapshot}.tmp" && mv "${snapshot}.tmp" "$snapshot"
if GH_FAIL=1 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "tampered snapshot was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"body hash validation failed"* ]] || fail "tamper blocker was not precise"

GH_FAIL=0 "$HELPER" fetch owner/repo 45 >/dev/null || fail "snapshot refresh failed"
chmod 644 "$snapshot"
if GH_FAIL=1 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "unsafe permissions were accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"expected 600"* ]] || fail "permission blocker was not precise"

chmod 600 "$snapshot"
if GH_FAIL=1 SCANNER_BLOCK=1 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "scanner-blocked snapshot was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"scanner blocked"* ]] || fail "scanner blocker was not precise"

if ISSUE_BODY_SNAPSHOT_MAX_BYTES=5 "$HELPER" fetch owner/repo 45 2>"${TEST_TMP}/error"; then fail "oversized live body was accepted"; fi
[[ "$(<"${TEST_TMP}/error")" == *"exceeds 5-byte limit"* ]] || fail "size blocker was not precise"

printf 'PASS: issue body snapshots are bounded, validated, fallback-only, and mode 0600\n'
exit 0
