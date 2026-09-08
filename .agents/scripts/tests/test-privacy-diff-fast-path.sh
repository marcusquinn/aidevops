#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Offline synthetic regression cases; no real repositories or credentials.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
HELPER="${SCRIPT_DIR}/../privacy-guard-helper.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
mkdir -p "$HOME/.aidevops/configs"
ENTITIES="${ROOT}/entities"
DIFF="${ROOT}/diff"
TRACE="${ROOT}/trace"
: >"$ENTITIES"
: >"$TRACE"
PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	return 0
}

# Only substitute Git's read-only diff output. No network or commits needed.
git() {
	local operation="${1:-}"
	[[ "$operation" == diff ]] || return 2
	cat "$DIFF"
	return 0
}

fixture() {
	printf '%s\n' '+++ b/example.txt' '@@ -0,0 +1,1 @@' >"$DIFF"
	local line
	for line in "$@"; do printf '+%s\n' "$line" >>"$DIFF"; done
	return 0
}

expect() {
	local expected="$1" label="$2"
	shift 2
	local status=0
	"$@" >"${ROOT}/result" 2>"${ROOT}/stderr" || status=$?
	if [[ "$status" -eq "$expected" ]]; then pass "$label"; else fail "$label"; fi
	return 0
}

# shellcheck source=../privacy-guard-helper.sh
source "$HELPER"

# Deterministic work-count checks rather than wall-clock timing thresholds.
_privacy_redact_aidevops_script_references() {
	local text="$1"
	printf 'redact\n' >>"$TRACE"
	printf '%s' "$text"
	return 0
}
privacy_scan_public_text() {
	printf 'public\n' >>"$TRACE"
	return 0
}
fixture 'ordinary source line'
for ((i = 0; i < 5000; i++)); do printf '+ordinary source line\n' >>"$DIFF"; done
expect 0 'large benign diff passes secret scan' privacy_scan_secret_material_diff base head
expect 0 'large benign diff passes public scan' privacy_scan_public_diff base head "$ENTITIES"
if [[ ! -s "$TRACE" ]]; then
	pass 'benign lines do not fork redactors or per-line public scanners'
else
	fail 'benign lines do not fork redactors or per-line public scanners'
fi
printf 'person\tSynthetic Name\n' >"$ENTITIES"
fixture 'ordinary line'
expect 0 'nonempty inventory retains authoritative scanning' privacy_scan_public_diff base head "$ENTITIES"
[[ -s "$TRACE" ]] && pass 'custom inventory disables fast rejection' || fail 'custom inventory disables fast rejection'
: >"$ENTITIES"
: >"$TRACE"
printf 'ordinary\n' >"$HOME/.aidevops/configs/privacy-guard-private-path-patterns.txt"
expect 0 'configured path rules retain authoritative scanning' privacy_scan_public_diff base head "$ENTITIES"
[[ -s "$TRACE" ]] && pass 'custom path rules disable fast rejection' || fail 'custom path rules disable fast rejection'
rm "$HOME/.aidevops/configs/privacy-guard-private-path-patterns.txt"

# Restore the real scanners for detection, redaction, and line-number checks.
# shellcheck source=../privacy-guard-helper.sh
source "$HELPER"
synthetic_token="s""k-""0123456789abcdefghijkl"
fixture 'clean line' "example: $synthetic_token"
expect 1 'credential candidate remains blocked' privacy_scan_secret_material_diff base head
if [[ "$(cat "${ROOT}/result")" == 'example.txt:2: credential token prefix' ]]; then
	pass 'line numbers survive skipped clean lines'
else
	fail 'line numbers survive skipped clean lines'
fi
expect 1 'public scanner still blocks credential candidates' privacy_scan_public_diff base head "$ENTITIES"
fixture "-----BEGIN ""PRIVATE KEY-----" 'synthetic non-key contents' "-----END ""PRIVATE KEY-----"
expect 1 'PEM state remains blocked across ordinary-looking lines' privacy_scan_secret_material_diff base head
if [[ "$(cat "${ROOT}/result")" == *'example.txt:2: private-key PEM block content'* ]]; then
	pass 'PEM body lines remain covered'
else
	fail 'PEM body lines remain covered'
fi
fixture "-----BEGIN ""PRIVATE KEY-----" 'synthetic non-key contents'
printf '%s\n' '+++ b/unrelated.txt' '@@ -0,0 +1,1 @@' '+ordinary line' >>"$DIFF"
expect 1 'unterminated key opening is still blocked' privacy_scan_secret_material_diff base head
if [[ "$(cat "${ROOT}/result")" != *'unrelated.txt:'* ]]; then
	pass 'PEM state does not leak across file boundaries'
else
	fail 'PEM state does not leak across file boundaries'
fi
tilde='~'
for path in '/Us''ers/example/item' '/ho''me/example/item' "${tilde}/Git/example" 'file:///'Users/example/item; do
	fixture "source: $path"
	expect 1 'built-in local path candidate remains blocked' privacy_scan_public_diff base head "$ENTITIES"
done
printf 'person\tSynthetic Name\n' >"$ENTITIES"
fixture 'Synthetic Name'
expect 1 'private entity remains blocked' privacy_scan_public_diff base head "$ENTITIES"
: >"$ENTITIES"
printf '^ordinary$\n' >"$HOME/.aidevops/configs/privacy-guard-private-path-patterns.txt"
fixture 'ordinary'
expect 1 'custom anchored path rule remains blocked' privacy_scan_public_diff base head "$ENTITIES"
expect 2 'missing inventory is not treated as clean' privacy_scan_public_diff base head "${ROOT}/missing"

printf 'Tests: %d, Failures: %d\n' "$((PASS + FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]]
