#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Checks cross-review text extraction against OpenCode event-stream and legacy shapes (GH#39571).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="${SCRIPT_DIR}/compare-models-cross-review-lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

eval "$(sed -n '/^_cross_review_extract_text()/,/^}/p;/^_cross_review_failure_reason()/,/^}/p' "$lib")"

printf '%s\n' '{"type":"step_start"}' '{"type":"text","part":{"type":"text","text":"OK"}}' >"$tmp/stream.json"
printf '%s\n' '{"parts":[{"type":"text","text":"legacy"}]}' >"$tmp/legacy.json"
printf '%s\n' '{"type":"step_start"}' >"$tmp/notext.json"
: >"$tmp/empty.json"

fail=0
check() {
	local name="$1" want="$2" got="$3"
	if [[ "$got" == "$want" ]]; then echo "PASS: $name"; else echo "FAIL: $name (got '$got')"; fail=1; fi
	return 0
}

check "event stream" "OK" "$(_cross_review_extract_text "$tmp/stream.json")"
check "legacy shape" "legacy" "$(_cross_review_extract_text "$tmp/legacy.json")"
check "no text event" "no text event (timeout or incomplete run)" "$(_cross_review_failure_reason "$tmp/notext.json" /dev/null)"
check "empty output" "runner error (no output produced)" "$(_cross_review_failure_reason "$tmp/empty.json" /dev/null)"
exit "$fail"
